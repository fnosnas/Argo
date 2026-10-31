/**
 * WebSSH Console — 单文件 Cloudflare Worker
 * 部署：Cloudflare 控制台 → Workers & Pages → 创建 → 从 Hello World 开始 → 编辑代码，
 *       全选删掉，把本文件全部内容贴进去 → Deploy。
 * 换背景：Worker → 设置 → 变量和机密 → 添加文本变量 BG_URL = 图片直链 → 保存部署。
 *
 * 功能：浏览器里打开登录页 → 填 VPS 的主机/端口/用户名/密码 → 进入命令行。
 *   - 支持复制、粘贴、手动输入
 *   - 支持 IPv4 和 IPv6 的 VPS
 *   - 关闭页面后不保留任何数据（服务端不落盘，前端只用内存）
 *   - 背景图片可在后台用环境变量 BG_URL 自定义
 *
 * SSH 实现：纯 JS，基于 Workers 的 connect() TCP + Web Crypto。
 *   KEX   curve25519-sha256        加密  aes256-ctr
 *   MAC   hmac-sha2-256            认证  私钥(Ed25519/RSA/ECDSA) / 密码 / keyboard-interactive
 *   注意：为保持精简，未校验服务器主机公钥指纹（等同 StrictHostKeyChecking no）。
 */

import { connect } from "cloudflare:sockets";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // WebSocket：浏览器终端 <-> Worker <-> VPS
    if (url.pathname === "/ws") {
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("expected websocket", { status: 426 });
      }
      const pair = new WebSocketPair();
      const client = pair[0], server = pair[1];
      server.accept();
      handleSession(server).catch((e) => {
        try { server.send(JSON.stringify({ t: "err", m: String(e && e.message || e) })); } catch (_) {}
        try { server.close(); } catch (_) {}
      });
      return new Response(null, { status: 101, webSocket: client });
    }

    // 登录页 + 终端页（同一个单页）
    const bg = (env && env.BG_URL) ? env.BG_URL :
      "https://images.unsplash.com/photo-1506744038136-46273834b3fb?auto=format&fit=crop&w=1920&q=80";
    return new Response(PAGE.replace("__BG_URL__", bg.replace(/"/g, "&quot;")), {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
};

/* ============================ WebSocket 会话 ============================ */

async function handleSession(ws) {
  // 等第一条消息：连接参数
  const first = await new Promise((resolve, reject) => {
    const onMsg = (ev) => { cleanup(); resolve(ev.data); };
    const onClose = () => { cleanup(); reject(new Error("closed")); };
    function cleanup() { ws.removeEventListener("message", onMsg); ws.removeEventListener("close", onClose); }
    ws.addEventListener("message", onMsg);
    ws.addEventListener("close", onClose);
  });

  let cfg;
  try { cfg = JSON.parse(first); } catch (_) { throw new Error("bad config"); }
  const host = String(cfg.host || "").trim().replace(/^\[|\]$/g, "");
  const port = parseInt(cfg.port, 10) || 22;
  const user = String(cfg.user || "").trim();
  const pass = cfg.pass == null ? "" : String(cfg.pass);
  const key = cfg.key ? String(cfg.key) : "";
  let cols = parseInt(cfg.cols, 10) || 80;
  let rows = parseInt(cfg.rows, 10) || 24;
  if (!host || !user) throw new Error("主机地址和用户名不能为空");
  if (!pass && !key) throw new Error("请填写密码或上传私钥");

  ws.send(JSON.stringify({ t: "info", m: `正在连接 ${host}:${port} ...` }));

  // connect() 对 IPv6 需要用方括号包裹
  const hostname = host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
  const socket = connect({ hostname, port });
  await socket.opened;

  const ssh = new SSHClient(socket, { user, pass, key, cols, rows });
  ssh.onData = (bytes) => { try { ws.send(bytes); } catch (_) {} };
  ssh.onReady = () => { try { ws.send(JSON.stringify({ t: "ready" })); } catch (_) {} };
  ssh.onClose = () => { try { ws.close(); } catch (_) {} };
  ssh.onError = (m) => { try { ws.send(JSON.stringify({ t: "err", m })); } catch (_) {} };

  // 浏览器 -> VPS
  ws.addEventListener("message", (ev) => {
    const d = ev.data;
    if (typeof d === "string") {
      // 控制消息（目前只有 resize）；普通按键也可能是字符串
      if (d.length && d[0] === "{") {
        try {
          const o = JSON.parse(d);
          if (o && o.t === "ping") { try { ws.send('{"t":"pong"}'); } catch (_) {} return; } // 浏览器心跳
          if (o && o.t === "resize") { ssh.resize(o.cols, o.rows); return; }
          if (o && o.t === "data") { ssh.write(o.d); return; }
        } catch (_) { /* 当普通输入处理 */ }
      }
      ssh.write(d);
    } else {
      ssh.writeBytes(new Uint8Array(d));
    }
  });
  // 保活：每 30 秒向 VPS 发一次 SSH keepalive，防止中间链路/防火墙因空闲断开 TCP
  const ka = setInterval(() => { ssh.keepalive(); }, 30000);
  ws.addEventListener("close", () => { clearInterval(ka); ssh.close(); });
  ws.addEventListener("error", () => { clearInterval(ka); ssh.close(); });

  try { await ssh.run(); } finally { clearInterval(ka); }
}

/* ============================ SSH-2.0 客户端 ============================ */

const te = new TextEncoder();
const td = new TextDecoder();

class SSHClient {
  constructor(socket, opts) {
    this.socket = socket;
    this.opts = opts;
    this.reader = socket.readable.getReader();
    this.writer = socket.writable.getWriter();
    this.inbuf = new Uint8Array(0);
    this.wq = Promise.resolve();
    this.seqIn = 0; this.seqOut = 0;
    this.enc = null; this.dec = null; // 加密上下文
    this.sessionId = null;
    this.channel = 0; this.peerChannel = null;
    this.window = 0; this.maxPacket = 0;
    this.ready = false;
    this.closed = false;
    this.onData = () => {}; this.onReady = () => {}; this.onClose = () => {};
    this.onError = () => {};
    this.V_C = "SSH-2.0-WebSSHWorker_1.0";
  }

  async run() {
    try {
      await this.handshake();
      await this.readLoop();
    } catch (e) {
      if (!this.closed) this.onError(String(e && e.message || e));
    } finally {
      this.close();
      this.onClose();
    }
  }

  /* ---------- 底层收发 ---------- */

  async sendRaw(bytes) { await this.writer.write(bytes); }

  async pull() {
    const { value, done } = await this.reader.read();
    if (done) throw new Error("连接被对方关闭");
    const merged = new Uint8Array(this.inbuf.length + value.length);
    merged.set(this.inbuf, 0); merged.set(value, this.inbuf.length);
    this.inbuf = merged;
  }

  async need(n) { while (this.inbuf.length < n) await this.pull(); }

  consume(n) { const out = this.inbuf.slice(0, n); this.inbuf = this.inbuf.slice(n); return out; }

  /* ---------- 版本交换 ---------- */

  async handshake() {
    await this.sendRaw(te.encode(this.V_C + "\r\n"));
    // 读服务器版本行（可能前面有若干行 banner）
    let line = "";
    while (true) {
      await this.need(1);
      const b = this.consume(1)[0];
      if (b === 0x0a) { if (line.startsWith("SSH-")) break; line = ""; continue; }
      if (b !== 0x0d) line += String.fromCharCode(b);
    }
    this.V_S = line;
    if (!this.V_S.startsWith("SSH-2.0")) throw new Error("服务器不支持 SSH-2.0：" + this.V_S);

    await this.kex();
    await this.auth();
    await this.openShell();
  }

  /* ---------- 读一个明文/密文 SSH 包 ---------- */

  async readPacket() {
    if (!this.dec) {
      await this.need(4);
      const lenBuf = this.inbuf.slice(0, 4);
      const pktLen = readU32(lenBuf, 0);
      await this.need(4 + pktLen);
      const full = this.consume(4 + pktLen);
      const padLen = full[4];
      const payload = full.slice(5, 4 + pktLen - padLen);
      this.seqIn = (this.seqIn + 1) >>> 0;
      return payload;
    }
    // aes-ctr + hmac：先解密长度块（整包是块大小整数倍）
    const bs = 16;
    await this.need(bs);
    const firstEnc = this.inbuf.slice(0, bs);
    const firstDec = await this.dec.decrypt(firstEnc);
    const pktLen = readU32(firstDec, 0);
    const total = 4 + pktLen;
    await this.need(total + 32); // + mac(hmac-sha2-256)
    const restEnc = this.inbuf.slice(bs, total);
    const mac = this.inbuf.slice(total, total + 32);
    this.consume(total + 32);
    const restDec = await this.dec.decrypt(restEnc);
    const plain = new Uint8Array(total);
    plain.set(firstDec, 0); plain.set(restDec, bs);
    // 校验 MAC
    const ok = await this.dec.verifyMac(this.seqIn, plain, mac);
    if (!ok) throw new Error("MAC 校验失败");
    const padLen = plain[4];
    const payload = plain.slice(5, total - padLen);
    this.seqIn = (this.seqIn + 1) >>> 0;
    return payload;
  }

  writePacket(payload) {
    // 所有发包串行执行，避免序号/计数器并发错乱
    const job = this.wq.then(() => this._writePacket(payload));
    this.wq = job.catch(() => {});
    return job;
  }

  async _writePacket(payload) {
    const bs = this.enc ? 16 : 8;
    let padLen = bs - ((5 + payload.length) % bs);
    if (padLen < 4) padLen += bs;
    const total = 4 + 1 + payload.length + padLen;
    const pkt = new Uint8Array(total);
    writeU32(pkt, 0, total - 4);
    pkt[4] = padLen;
    pkt.set(payload, 5);
    crypto.getRandomValues(pkt.subarray(5 + payload.length));
    if (!this.enc) {
      await this.sendRaw(pkt);
      this.seqOut = (this.seqOut + 1) >>> 0;
      return;
    }
    const mac = await this.enc.computeMac(this.seqOut, pkt);
    const encd = await this.enc.encrypt(pkt);
    const out = new Uint8Array(encd.length + mac.length);
    out.set(encd, 0); out.set(mac, encd.length);
    await this.sendRaw(out);
    this.seqOut = (this.seqOut + 1) >>> 0;
  }

  /* ---------- 密钥交换 curve25519-sha256 ---------- */

  async kex() {
    const cookie = crypto.getRandomValues(new Uint8Array(16));
    const kexAlgs = "curve25519-sha256,curve25519-sha256@libssh.org";
    const hostKeyAlgs = "ssh-ed25519,rsa-sha2-256,rsa-sha2-512,ssh-rsa";
    const encAlgs = "aes256-ctr,aes128-ctr";
    const macAlgs = "hmac-sha2-256";
    const none = "none";

    const I_C = buildKexInit(cookie, kexAlgs, hostKeyAlgs, encAlgs, macAlgs, none);
    await this.writePacket(I_C);

    // 读服务器 KEXINIT
    let I_S = null;
    while (true) {
      const p = await this.readPacket();
      if (p[0] === 20) { I_S = p; break; }       // SSH_MSG_KEXINIT
      if (p[0] === 1) throw new Error(disconnectMsg(p));
    }

    // 生成 X25519 临时密钥
    const kp = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
    const rawPub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey)); // 32B Q_C

    // SSH_MSG_KEX_ECDH_INIT (30)
    const initP = concat(new Uint8Array([30]), sshString(rawPub));
    await this.writePacket(initP);

    // SSH_MSG_KEX_ECDH_REPLY (31)
    let reply = null;
    while (true) {
      const p = await this.readPacket();
      if (p[0] === 31) { reply = p; break; }
      if (p[0] === 1) throw new Error(disconnectMsg(p));
    }
    let off = 1;
    const K_S = readSshString(reply, off); off = K_S.next;      // 服务器公钥(host key) blob
    const Q_S = readSshString(reply, off); off = Q_S.next;      // 服务器临时公钥 32B
    const sig = readSshString(reply, off); off = sig.next;      // 签名（此处不校验）

    // 计算共享密钥 K
    const serverPub = await crypto.subtle.importKey("raw", Q_S.val, { name: "X25519" }, false, []);
    const sharedBits = new Uint8Array(await crypto.subtle.deriveBits({ name: "X25519", public: serverPub }, kp.privateKey, 256));
    const K = mpint(sharedBits);

    // 交换哈希 H
    const hbuf = concat(
      sshString(te.encode(this.V_C)),
      sshString(te.encode(this.V_S)),
      sshString(I_C),
      sshString(I_S),
      sshString(K_S.val),
      sshString(rawPub),
      sshString(Q_S.val),
      K
    );
    const H = new Uint8Array(await crypto.subtle.digest("SHA-256", hbuf));
    if (!this.sessionId) this.sessionId = H;

    // 等待/发送 NEWKEYS (21)
    await this.writePacket(new Uint8Array([21]));
    while (true) {
      const p = await this.readPacket();
      if (p[0] === 21) break;
      if (p[0] === 1) throw new Error(disconnectMsg(p));
    }

    // 派生密钥：HASH(K || H || X || session_id)，不足时迭代扩展
    const derive = async (letter, len) => {
      let out = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(K, H, te.encode(letter), this.sessionId)));
      while (out.length < len) {
        const more = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(K, H, out)));
        out = concat(out, more);
      }
      return out.slice(0, len);
    };
    const ivC = await derive("A", 16), ivS = await derive("B", 16);
    const keyC = await derive("C", 32), keyS = await derive("D", 32);
    const macC = await derive("E", 32), macS = await derive("F", 32);

    this.enc = await makeCipher(keyC, ivC, macC);
    this.dec = await makeCipher(keyS, ivS, macS);
  }

  /* ---------- 用户认证 ---------- */

  async auth() {
    // 先请求 ssh-userauth 服务
    await this.writePacket(concat(new Uint8Array([5]), sshString(te.encode("ssh-userauth")))); // SERVICE_REQUEST
    while (true) {
      const p = await this.readPacket();
      if (p[0] === 6) break; // SERVICE_ACCEPT
      if (p[0] === 1) throw new Error(disconnectMsg(p));
    }

    // 方式零：私钥
    if (this.opts.key) {
      if (await this.authPublicKey()) return;
      if (!this.opts.pass) throw new Error("私钥认证失败：服务器未接受该私钥");
    }

    // 方式一：password
    const passReq = concat(
      new Uint8Array([50]),                       // SSH_MSG_USERAUTH_REQUEST
      sshString(te.encode(this.opts.user)),
      sshString(te.encode("ssh-connection")),
      sshString(te.encode("password")),
      new Uint8Array([0]),
      sshString(te.encode(this.opts.pass))
    );
    await this.writePacket(passReq);

    while (true) {
      const p = await this.readPacket();
      const t = p[0];
      if (t === 52) return;                         // USERAUTH_SUCCESS
      if (t === 53) continue;                        // USERAUTH_BANNER
      if (t === 51) {                                // USERAUTH_FAILURE
        // 尝试 keyboard-interactive
        const methods = readSshString(p, 1).val;
        if (td.decode(methods).includes("keyboard-interactive")) {
          if (await this.authKeyboard()) return;
        }
        throw new Error("认证失败：用户名或密码错误");
      }
      if (t === 1) throw new Error(disconnectMsg(p));
    }
  }

  async authPublicKey() {
    const k = await loadPrivateKey(this.opts.key);
    const S = (x) => sshString(typeof x === "string" ? te.encode(x) : x);
    const data = concat(
      S(this.sessionId), new Uint8Array([50]), S(this.opts.user), S("ssh-connection"),
      S("publickey"), new Uint8Array([1]), S(k.alg), S(k.pubBlob)
    );
    const sig = await k.sign(data);
    const req = concat(
      new Uint8Array([50]), S(this.opts.user), S("ssh-connection"), S("publickey"),
      new Uint8Array([1]), S(k.alg), S(k.pubBlob), S(concat(S(k.alg), S(sig)))
    );
    await this.writePacket(req);
    while (true) {
      const p = await this.readPacket();
      if (p[0] === 52) return true;
      if (p[0] === 53) continue;
      if (p[0] === 51) return false;
      if (p[0] === 1) throw new Error(disconnectMsg(p));
    }
  }

  async authKeyboard() {
    const req = concat(
      new Uint8Array([50]),
      sshString(te.encode(this.opts.user)),
      sshString(te.encode("ssh-connection")),
      sshString(te.encode("keyboard-interactive")),
      sshString(new Uint8Array(0)),
      sshString(new Uint8Array(0))
    );
    await this.writePacket(req);
    while (true) {
      const p = await this.readPacket();
      const t = p[0];
      if (t === 52) return true;
      if (t === 53) continue;
      if (t === 51) return false;
      if (t === 60) {                                // USERAUTH_INFO_REQUEST
        let off = 1;
        let s = readSshString(p, off); off = s.next;  // name
        s = readSshString(p, off); off = s.next;       // instruction
        s = readSshString(p, off); off = s.next;       // language
        const num = readU32(p, off); off += 4;
        const answers = [];
        for (let i = 0; i < num; i++) {
          const prompt = readSshString(p, off); off = prompt.next;
          off += 1;                                    // echo 布尔
          answers.push(this.opts.pass);                // 所有提示都回答密码
        }
        let resp = concat(new Uint8Array([61]), u32(num)); // INFO_RESPONSE
        for (const a of answers) resp = concat(resp, sshString(te.encode(a)));
        await this.writePacket(resp);
        continue;
      }
      if (t === 1) throw new Error(disconnectMsg(p));
    }
  }

  /* ---------- 打开 shell 通道 ---------- */

  async openShell() {
    const win = 0x200000, max = 0x8000;
    this.window = win; this.maxPacket = max;
    const open = concat(
      new Uint8Array([90]),                          // CHANNEL_OPEN
      sshString(te.encode("session")),
      u32(this.channel), u32(win), u32(max)
    );
    await this.writePacket(open);
    // 等 CHANNEL_OPEN_CONFIRMATION
    while (true) {
      const p = await this.readPacket();
      if (p[0] === 91) {
        this.peerChannel = readU32(p, 5);
        break;
      }
      if (p[0] === 92) throw new Error("服务器拒绝打开会话通道");
      if (p[0] === 1) throw new Error(disconnectMsg(p));
    }
    // pty-req
    const term = te.encode("xterm-256color");
    const ptyReq = concat(
      new Uint8Array([98]),                          // CHANNEL_REQUEST
      u32(this.peerChannel),
      sshString(te.encode("pty-req")),
      new Uint8Array([1]),                           // want_reply
      sshString(term),
      u32(this.opts.cols), u32(this.opts.rows),
      u32(0), u32(0),
      sshString(new Uint8Array([0]))                 // 空终端模式
    );
    await this.writePacket(ptyReq);
    // shell
    const shellReq = concat(
      new Uint8Array([98]),
      u32(this.peerChannel),
      sshString(te.encode("shell")),
      new Uint8Array([1])
    );
    await this.writePacket(shellReq);
  }

  /* ---------- 主循环：把通道数据交给浏览器 ---------- */

  async readLoop() {
    while (!this.closed) {
      const p = await this.readPacket();
      const t = p[0];
      if ((t === 94 || t === 95) && !this.ready) { this.ready = true; this.onReady(); }
      if (t === 94) {                                // CHANNEL_DATA
        const dataStr = readSshString(p, 5);
        this.onData(dataStr.val);
        await this.adjustWindow(dataStr.val.length);
      } else if (t === 95) {                          // CHANNEL_EXTENDED_DATA（stderr）
        const dataStr = readSshString(p, 9);
        this.onData(dataStr.val);
        await this.adjustWindow(dataStr.val.length);
      } else if (t === 93) {                          // CHANNEL_WINDOW_ADJUST
        /* 忽略，发送量不大 */
      } else if (t === 98) {                          // CHANNEL_REQUEST（如 keepalive@openssh.com）
        const req = readSshString(p, 5);
        if (p[req.next] === 1) await this.writePacket(concat(new Uint8Array([100]), u32(this.peerChannel)));
      } else if (t === 80) {                          // GLOBAL_REQUEST（如 keepalive）
        const req = readSshString(p, 1);
        if (p[req.next] === 1) await this.writePacket(new Uint8Array([82]));
      } else if (t === 99 || t === 100) {             // CHANNEL_SUCCESS/FAILURE（针对 pty/shell）
        if (!this.ready) { this.ready = true; this.onReady(); }
      } else if (t === 96) {                          // CHANNEL_EOF
      } else if (t === 97) {                          // CHANNEL_CLOSE
        this.close(); return;
      } else if (t === 1) {                           // DISCONNECT
        throw new Error(disconnectMsg(p));
      } else if (t === 2) {                           // IGNORE
      } else if (t === 3) {                           // UNIMPLEMENTED
      } else if (t === 6) {
      }
      if (!this.ready && this.peerChannel !== undefined) {
        // 某些服务器 shell 请求无 reply，首个数据到达即视为就绪
      }
    }
  }

  async adjustWindow(n) {
    this.consumed = (this.consumed || 0) + n;
    if (this.consumed >= 0x100000) {
      const add = this.consumed;
      this.consumed = 0;
      const p = concat(new Uint8Array([93]), u32(this.peerChannel), u32(add));
      await this.writePacket(p).catch(() => {});
    }
  }

  /* ---------- 浏览器输入 ---------- */

  async write(str) { await this.writeBytes(te.encode(str)); }

  async writeBytes(bytes) {
    if (this.closed || this.peerChannel === null) return;
    const p = concat(new Uint8Array([94]), u32(this.peerChannel), sshString(bytes));
    try { await this.writePacket(p); } catch (_) {}
  }

  async keepalive() {
    if (this.closed || !this.ready) return;
    // SSH_MSG_GLOBAL_REQUEST "keepalive@openssh.com"，与 OpenSSH 的 ServerAliveInterval 相同
    const p = concat(new Uint8Array([80]), sshString(te.encode("keepalive@openssh.com")), new Uint8Array([1]));
    try { await this.writePacket(p); } catch (_) {}
  }

  async resize(cols, rows) {
    if (this.closed || this.peerChannel === null) return;
    const p = concat(
      new Uint8Array([98]), u32(this.peerChannel),
      sshString(te.encode("window-change")),
      new Uint8Array([0]),
      u32(cols), u32(rows), u32(0), u32(0)
    );
    try { await this.writePacket(p); } catch (_) {}
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    try { this.reader.releaseLock(); } catch (_) {}
    try { this.writer.releaseLock(); } catch (_) {}
    try { this.socket.close(); } catch (_) {}
  }
}

/* ---------- aes-256-ctr + hmac-sha2-256 ---------- */

async function makeCipher(key, iv, macKey) {
  const aesKey = await crypto.subtle.importKey("raw", key, { name: "AES-CTR" }, false, ["encrypt", "decrypt"]);
  const hmacKey = await crypto.subtle.importKey("raw", macKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
  let counter = iv.slice(0);
  return {
    async encrypt(data) {
      const out = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 128 }, aesKey, data));
      incCounter(counter, data.length / 16);
      return out;
    },
    async decrypt(data) {
      const out = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 128 }, aesKey, data));
      incCounter(counter, data.length / 16);
      return out;
    },
    async computeMac(seq, plainPacket) {
      const buf = concat(u32(seq), plainPacket);
      return new Uint8Array(await crypto.subtle.sign("HMAC", hmacKey, buf));
    },
    async verifyMac(seq, plainPacket, mac) {
      const buf = concat(u32(seq), plainPacket);
      return await crypto.subtle.verify("HMAC", hmacKey, mac, buf);
    },
  };
}

function incCounter(c, blocks) {
  // 把 128 位大端计数器加上 blocks（带进位）
  let carry = Math.round(blocks);
  for (let i = c.length - 1; i >= 0 && carry > 0; i--) {
    const v = c[i] + (carry % 256);
    carry = Math.floor(carry / 256) + (v > 255 ? 1 : 0);
    c[i] = v & 255;
  }
}


/* ---------- 私钥解析：OpenSSH / PKCS#8 / PKCS#1(RSA)，支持 Ed25519、RSA、ECDSA P-256 ---------- */

function b64ToBytes(b64) { const bin = atob(b64.replace(/\s+/g, "")); const a = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i); return a; }
function bytesToB64url(a) { let s = ""; for (const b of a) s += String.fromCharCode(b); return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
function b64urlToBytes(s) { s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "="; return b64ToBytes(s); }
function stripZeros(a) { let i = 0; while (i < a.length - 1 && a[i] === 0) i++; return a.slice(i); }
function bytesToBig(a) { let x = 0n; for (const b of a) x = (x << 8n) | BigInt(b); return x; }
function bigToBytes(x) { if (x === 0n) return new Uint8Array([0]); const out = []; while (x > 0n) { out.unshift(Number(x & 255n)); x >>= 8n; } return new Uint8Array(out); }
function padTo(a, n) { if (a.length >= n) return a.slice(a.length - n); const o = new Uint8Array(n); o.set(a, n - a.length); return o; }

function derLen(n) { if (n < 128) return new Uint8Array([n]); const b = bigToBytes(BigInt(n)); return concat(new Uint8Array([0x80 | b.length]), b); }
function der(tag, body) { return concat(new Uint8Array([tag]), derLen(body.length), body); }

async function loadPrivateKey(pem) {
  pem = pem.trim();
  const m = pem.match(/-----BEGIN ([A-Z ]+)-----([\s\S]+?)-----END \1-----/);
  if (!m) throw new Error("无法识别的私钥格式");
  const type = m[1], body = b64ToBytes(m[2]);
  if (type === "OPENSSH PRIVATE KEY") return loadOpenSSH(body);
  if (type === "ENCRYPTED PRIVATE KEY" || /ENCRYPTED/.test(m[2])) throw new Error("暂不支持带口令的私钥，请先用 ssh-keygen -p 去掉口令");
  if (type === "PRIVATE KEY") return loadPKCS8(body);
  if (type === "RSA PRIVATE KEY") {
    // PKCS#1 → 包成 PKCS#8
    const algId = der(0x30, concat(der(0x06, new Uint8Array([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01])), new Uint8Array([0x05, 0x00])));
    return loadPKCS8(der(0x30, concat(new Uint8Array([0x02, 0x01, 0x00]), algId, der(0x04, body))));
  }
  throw new Error("不支持的私钥类型：" + type);
}

async function loadPKCS8(pk8) {
  const tries = [
    [{ name: "Ed25519" }, "ed"],
    [{ name: "ECDSA", namedCurve: "P-256" }, "ec"],
    [{ name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, "rsa"],
  ];
  for (const [alg, kind] of tries) {
    try {
      const k = await crypto.subtle.importKey("pkcs8", pk8, alg, true, ["sign"]);
      const jwk = await crypto.subtle.exportKey("jwk", k);
      return fromJwk(jwk);
    } catch (_) {}
  }
  throw new Error("无法解析 PKCS#8 私钥");
}

async function loadOpenSSH(b) {
  const magic = "openssh-key-v1\0";
  if (td.decode(b.slice(0, magic.length)) !== magic) throw new Error("OpenSSH 私钥格式错误");
  let o = magic.length;
  const cipher = readSshString(b, o); o = cipher.next;
  const kdf = readSshString(b, o); o = kdf.next;
  const kdfo = readSshString(b, o); o = kdfo.next;
  if (td.decode(cipher.val) !== "none") throw new Error("暂不支持带口令的私钥，请先用 ssh-keygen -p 去掉口令");
  o += 4;                                         // nkeys
  const pub = readSshString(b, o); o = pub.next;
  const priv = readSshString(b, o).val;
  let p = 8;                                      // check1, check2
  const kt = readSshString(priv, p); p = kt.next;
  const keyType = td.decode(kt.val);
  const next = () => { const r = readSshString(priv, p); p = r.next; return r.val; };
  if (keyType === "ssh-ed25519") {
    const pk = next(), sk = next();
    return fromJwk({ kty: "OKP", crv: "Ed25519", x: bytesToB64url(pk), d: bytesToB64url(sk.slice(0, 32)) });
  }
  if (keyType === "ssh-rsa") {
    const n = stripZeros(next()), e = stripZeros(next()), d = stripZeros(next());
    const iqmp = stripZeros(next()), P = stripZeros(next()), Q = stripZeros(next());
    const D = bytesToBig(d);
    return fromJwk({
      kty: "RSA", n: bytesToB64url(n), e: bytesToB64url(e), d: bytesToB64url(d),
      p: bytesToB64url(P), q: bytesToB64url(Q),
      dp: bytesToB64url(bigToBytes(D % (bytesToBig(P) - 1n))),
      dq: bytesToB64url(bigToBytes(D % (bytesToBig(Q) - 1n))),
      qi: bytesToB64url(iqmp),
    });
  }
  if (keyType === "ecdsa-sha2-nistp256") {
    next(); const Qp = next(); const d = next();
    return fromJwk({ kty: "EC", crv: "P-256", x: bytesToB64url(Qp.slice(1, 33)), y: bytesToB64url(Qp.slice(33, 65)), d: bytesToB64url(padTo(stripZeros(d), 32)) });
  }
  throw new Error("不支持的私钥算法：" + keyType);
}

async function fromJwk(jwk) {
  const S = (x) => sshString(typeof x === "string" ? te.encode(x) : x);
  const mp = (bytes) => mpint(bytes);
  if (jwk.kty === "OKP") {
    const key = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x, d: jwk.d }, { name: "Ed25519" }, false, ["sign"]);
    return {
      alg: "ssh-ed25519",
      pubBlob: concat(S("ssh-ed25519"), S(b64urlToBytes(jwk.x))),
      sign: async (data) => new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, data)),
    };
  }
  if (jwk.kty === "RSA") {
    const key = await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e, d: jwk.d, p: jwk.p, q: jwk.q, dp: jwk.dp, dq: jwk.dq, qi: jwk.qi, alg: "RS256" },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
    return {
      alg: "rsa-sha2-256",
      pubBlob: concat(S("ssh-rsa"), mp(b64urlToBytes(jwk.e)), mp(b64urlToBytes(jwk.n))),
      sign: async (data) => new Uint8Array(await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, key, data)),
    };
  }
  if (jwk.kty === "EC") {
    const key = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, d: jwk.d }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const Qp = concat(new Uint8Array([4]), b64urlToBytes(jwk.x), b64urlToBytes(jwk.y));
    return {
      alg: "ecdsa-sha2-nistp256",
      pubBlob: concat(S("ecdsa-sha2-nistp256"), S("nistp256"), S(Qp)),
      sign: async (data) => {
        const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, data));
        return concat(mp(raw.slice(0, 32)), mp(raw.slice(32)));
      },
    };
  }
  throw new Error("不支持的私钥");
}

/* ---------- SSH 编码辅助 ---------- */

function readU32(a, o) { return ((a[o] << 24) | (a[o + 1] << 16) | (a[o + 2] << 8) | a[o + 3]) >>> 0; }
function writeU32(a, o, v) { a[o] = (v >>> 24) & 255; a[o + 1] = (v >>> 16) & 255; a[o + 2] = (v >>> 8) & 255; a[o + 3] = v & 255; }
function u32(v) { const a = new Uint8Array(4); writeU32(a, 0, v); return a; }
function concat(...arrs) {
  let n = 0; for (const a of arrs) n += a.length;
  const out = new Uint8Array(n); let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
}
function sshString(bytes) { return concat(u32(bytes.length), bytes); }
function readSshString(a, o) { const len = readU32(a, o); const val = a.slice(o + 4, o + 4 + len); return { val, next: o + 4 + len }; }
function mpint(bytes) {
  let i = 0; while (i < bytes.length - 1 && bytes[i] === 0) i++;
  let b = bytes.slice(i);
  if (b.length && (b[0] & 0x80)) b = concat(new Uint8Array([0]), b);
  return concat(u32(b.length), b);
}
function buildKexInit(cookie, kex, hostKey, enc, mac, comp) {
  const S = (s) => sshString(te.encode(s));
  return concat(
    new Uint8Array([20]), cookie,
    S(kex), S(hostKey), S(enc), S(enc), S(mac), S(mac), S(comp), S(comp),
    S(""), S(""),
    new Uint8Array([0]), u32(0)
  );
}
function disconnectMsg(p) {
  try { const r = readU32(p, 1); const m = readSshString(p, 5); return "服务器断开连接(" + r + ")：" + td.decode(m.val); }
  catch (_) { return "服务器断开连接"; }
}

/* ============================ 前端页面 ============================ */

const PAGE = String.raw`<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>WebSSH Console</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
<style>
  * { box-sizing: border-box; }
  html,body { margin:0; height:100%; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif; }
  body { min-height:100%; background:#6b7fa8 url("__BG_URL__") center/cover no-repeat fixed;
    display:flex; align-items:center; justify-content:center; }
  .card { width:min(680px,94vw); background:rgba(255,255,255,.22); backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px);
    border:1px solid rgba(255,255,255,.35); border-radius:18px; padding:30px 34px 28px; box-shadow:0 10px 40px rgba(0,0,0,.18); }
  h1 { text-align:center; margin:0 0 10px; color:#1d4ed8; font-size:38px; font-weight:700; letter-spacing:.5px; }
  .rule { width:300px; max-width:60%; height:3px; background:#1d4ed8; border-radius:3px; margin:0 auto 26px; }
  .grid { display:grid; grid-template-columns:1fr 1fr; gap:18px 20px; }
  .field label { display:block; font-weight:700; font-size:14px; color:#374151; margin-bottom:8px; }
  .field input { width:100%; height:40px; padding:0 14px; border:1px solid rgba(255,255,255,.45); border-radius:10px;
    background:rgba(255,255,255,.35); font-size:15px; color:#111827; outline:none; }
  .field input::placeholder { color:#6b7280; }
  .field input:focus { background:rgba(255,255,255,.6); }
  .field.full { grid-column:1 / -1; }
  .keybox { display:flex; height:40px; border-radius:10px; overflow:hidden; border:1px solid rgba(255,255,255,.45); background:rgba(255,255,255,.35); }
  .keybox button { border:none; background:#3b9cf5; color:#fff; font-weight:700; font-size:15px; padding:0 22px; cursor:pointer; white-space:nowrap; }
  .keybox span { flex:1; display:flex; align-items:center; padding:0 12px; font-size:14px; color:#374151; overflow:hidden; white-space:nowrap; text-overflow:ellipsis; }
  .keybox .x { flex:none; padding:0 10px; cursor:pointer; color:#b91c1c; display:none; }
  .btns { display:flex; gap:12px; justify-content:center; margin-top:26px; flex-wrap:wrap; }
  .btn { border:none; border-radius:9px; padding:11px 20px; font-size:15px; font-weight:700; color:#fff; cursor:pointer; }
  .btn.red { background:#dc2626; } .btn.blue { background:#3b9cf5; } .btn.green { background:#16a34a; }
  .btn:active { transform:translateY(1px); }
  @media (max-width:560px){ .grid{grid-template-columns:1fr;} h1{font-size:30px;} .card{padding:24px 18px;} }
  #term-wrap { position:fixed; inset:0; background:#000; display:none; flex-direction:column; }
  #bar { height:36px; background:#111827; color:#d1d5db; display:flex; align-items:center; gap:10px; padding:0 12px; font-size:13px; }
  #bar .dot { color:#22c55e; } #bar .sp { flex:1; }
  #bar button { background:#374151; color:#e5e7eb; border:none; border-radius:6px; padding:5px 10px; cursor:pointer; font-size:12px; }
  #term { flex:1; padding:6px; overflow:hidden; }
  #toast { position:fixed; left:50%; top:18px; transform:translateX(-50%); background:rgba(0,0,0,.75); color:#fff;
    padding:8px 16px; border-radius:8px; font-size:14px; display:none; z-index:9; }
</style>
</head>
<body>
  <div class="card" id="login">
    <h1>WebSSH Console</h1><div class="rule"></div>
    <div class="grid">
      <div class="field"><label>主机地址 (Hostname)</label><input id="host" placeholder="IPv4 / IPv6 / 域名" autocomplete="off"></div>
      <div class="field"><label>端口 (Port)</label><input id="port" placeholder="请输入端口(默认22)" autocomplete="off"></div>
      <div class="field"><label>用户名 (Username)</label><input id="user" placeholder="请输入用户名" autocomplete="off"></div>
      <div class="field"><label>密码 (Password)</label><input id="pass" type="password" placeholder="请输入密码" autocomplete="new-password"></div>
      <div class="field full"><label>私钥 (Private Key，可选)</label>
        <div class="keybox"><button type="button" onclick="document.getElementById('keyfile').click()">📂 上传密钥</button>
          <span id="keyname">未上传密钥文件</span><span class="x" id="keyclear" onclick="clearKey()">✕</span></div>
        <input type="file" id="keyfile" style="display:none">
      </div>
      <div class="field full"><label>初始命令 (Initial command)</label><input id="cmd" placeholder="登录后要执行的命令" autocomplete="off"></div>
    </div>
    <div class="btns">
      <button class="btn red" onclick="resetForm()">↻ 重置输入</button>
      <button class="btn blue" onclick="makeLink()">🔗 生成链接</button>
      <button class="btn green" onclick="startConnect()">&gt;_ 连接SSH</button>
    </div>
  </div>

  <div id="term-wrap">
    <div id="bar">
      <span class="dot">●</span><span id="bar-host"></span><span class="sp"></span>
      <button onclick="doCopy()">复制</button>
      <button onclick="doPaste()">粘贴</button>
      <button onclick="location.replace(location.pathname)">断开</button>
    </div>
    <div id="term"></div>
  </div>
  <div id="toast"></div>

<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
<script>
// 所有数据只存在于这个页面的内存里：不用 cookie / localStorage，关页即消失
let term, fit, ws, keyText = '';
const $ = (id) => document.getElementById(id);
function toast(m, ms){ const t=$('toast'); if(!m){t.style.display='none';return;} t.textContent=m; t.style.display='block'; if(ms) setTimeout(()=>toast(''),ms); }

$('keyfile').addEventListener('change', async (e) => {
  const f = e.target.files[0]; if (!f) return;
  keyText = await f.text(); $('keyname').textContent = f.name; $('keyclear').style.display = 'block';
  e.target.value = '';
});
function clearKey(){ keyText=''; $('keyname').textContent='未上传密钥文件'; $('keyclear').style.display='none'; }
function resetForm(){ ['host','port','user','pass','cmd'].forEach(i=>$(i).value=''); clearKey(); history.replaceState(null,'',location.pathname); }

// 生成链接：只带主机/端口/用户名/初始命令，不带密码和私钥；放在 # 后面，不会发到服务器
function makeLink(){
  const p = new URLSearchParams();
  ['host','port','user','cmd'].forEach(k=>{ const v=$(k).value.trim(); if(v) p.set(k,v); });
  const link = location.origin + location.pathname + '#' + p.toString();
  navigator.clipboard.writeText(link).then(()=>toast('链接已复制（不含密码）',1500)).catch(()=>prompt('复制这个链接：',link));
}
(function fillFromHash(){
  if (!location.hash) return;
  const p = new URLSearchParams(location.hash.slice(1));
  ['host','port','user','cmd'].forEach(k=>{ if(p.get(k)) $(k).value=p.get(k); });
})();

function startConnect(){
  const host=$('host').value.trim(), user=$('user').value.trim(), pass=$('pass').value;
  const port=parseInt($('port').value,10)||22, cmd=$('cmd').value;
  if(!host||!user){ toast('请填写主机地址和用户名',1800); return; }
  if(!pass&&!keyText){ toast('请填写密码或上传私钥',1800); return; }

  $('login').style.display='none'; $('term-wrap').style.display='flex';
  $('bar-host').textContent=user+'@'+host+':'+port;

  term=new Terminal({cursorBlink:true,fontSize:14,fontFamily:'Menlo,Consolas,"Courier New",monospace',theme:{background:'#000000'},scrollback:5000});
  fit=new FitAddon.FitAddon(); term.loadAddon(fit);
  term.open($('term')); fit.fit(); term.focus();
  term.write('\x1b[90m正在连接 '+host+':'+port+' ...\x1b[0m\r\n');

  ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/ws');
  ws.binaryType='arraybuffer';
  let sentCmd=false;
  ws.onopen=()=>{ ws.send(JSON.stringify({host,port,user,pass,key:keyText,cols:term.cols,rows:term.rows})); $('pass').value=''; };
  ws.onmessage=(ev)=>{
    if(typeof ev.data==='string'){
      try{ const o=JSON.parse(ev.data);
        if(o.t==='ready'){ if(cmd&&!sentCmd){ sentCmd=true; setTimeout(()=>ws.send(cmd+'\r'),300); } }
        else if(o.t==='err'){ term.write('\r\n\x1b[31m'+o.m+'\x1b[0m\r\n'); }
      }catch(_){ term.write(ev.data); }
    } else term.write(new Uint8Array(ev.data));
  };
  // 心跳：每 20 秒发一次，避免 Cloudflare 因约 100 秒无流量而断开 WebSocket
  const hb=setInterval(()=>{ if(ws.readyState===1) ws.send('{"t":"ping"}'); },20000);
  ws.onclose=()=>{ clearInterval(hb); term.write('\r\n\x1b[33m*** 连接已关闭 ***\x1b[0m\r\n'); keyText=''; };

  term.onData(d=>{ if(ws.readyState===1) ws.send(JSON.stringify({t:'data',d})); });
  term.onSelectionChange(()=>{ const s=term.getSelection(); if(s) navigator.clipboard.writeText(s).catch(()=>{}); }); // 选中即复制
  term.attachCustomKeyEventHandler(e=>{ // Ctrl+Shift+C 复制 / Ctrl+Shift+V 粘贴
    if(e.type==='keydown'&&e.ctrlKey&&e.shiftKey&&(e.key==='C'||e.key==='c')){ doCopy(); return false; }
    if(e.type==='keydown'&&e.ctrlKey&&e.shiftKey&&(e.key==='V'||e.key==='v')){ doPaste(); return false; }
    return true;
  });
  $('term').addEventListener('contextmenu',e=>{ e.preventDefault(); doPaste(); }); // 右键粘贴
  const onResize=()=>{ fit.fit(); if(ws.readyState===1) ws.send(JSON.stringify({t:'resize',cols:term.cols,rows:term.rows})); };
  window.addEventListener('resize',onResize);
}
async function doCopy(){ const s=term&&term.getSelection(); if(!s) return; try{ await navigator.clipboard.writeText(s); toast('已复制',800);}catch(_){} term.focus(); }
async function doPaste(){
  try{ const t=await navigator.clipboard.readText(); if(t) term.paste(t); }
  catch(_){ toast('浏览器不允许读剪贴板，请用 Ctrl+V / ⌘V',1800); }
  term.focus();
}
window.addEventListener('pagehide',()=>{ try{ ws&&ws.close(); }catch(_){} keyText=''; });
$('pass').addEventListener('keydown',e=>{ if(e.key==='Enter') startConnect(); });
$('cmd').addEventListener('keydown',e=>{ if(e.key==='Enter') startConnect(); });
</script>
</body>
</html>`;
