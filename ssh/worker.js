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
 *   - 右上：文件管理（SFTP）——浏览、上传（可拖拽）、下载、文件夹打包下载、新建、重命名、删除
 *   - 右下：AI 运维助手——填兼容 OpenAI 的 API 地址/Key/模型即可，AI 可在服务器上执行命令、写文件；
 *           危险命令会先弹出确认。Key 只存在页面内存里，经 Worker 转发，不保存
 *   - 空闲保活：浏览器 20 秒心跳 + Worker 30 秒 SSH keepalive
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

    // AI 接口转发（避免浏览器跨域）：Key 只随本次请求经过，不保存
    if (url.pathname === "/ai" && request.method === "POST") {
      try {
        const { base, key, body, op } = await request.json();
        let api = String(base || "").trim().replace(/\/+$/, "").replace(/\/chat\/completions$/, "");
        if (!/^https?:\/\//i.test(api)) return Response.json({ error: { message: "API 地址要以 http(s):// 开头" } }, { status: 400 });
        if (op === "models") {                       // 获取可用模型列表
          const r = await fetch(api + "/models", { headers: { "authorization": "Bearer " + String(key || "").trim() } });
          return new Response(r.body, { status: r.status, headers: { "content-type": r.headers.get("content-type") || "application/json" } });
        }
        api += "/chat/completions";
        const r = await fetch(api, { method: "POST", headers: { "content-type": "application/json", "authorization": "Bearer " + String(key || "").trim() }, body: JSON.stringify(body) });
        return new Response(r.body, { status: r.status, headers: { "content-type": r.headers.get("content-type") || "application/json" } });
      } catch (e) {
        return Response.json({ error: { message: "请求 AI 接口失败：" + (e && e.message || e) } }, { status: 502 });
      }
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

  const st = { sftp: null, handles: new Map(), nextH: 1 };
  const send = (obj) => { try { ws.send(JSON.stringify(obj)); } catch (_) {} };

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
          if (o && o.t === "rpc") {                    // 文件管理 / AI 执行命令
            handleRpc(ssh, st, o, send).then((res) => send({ t: "rpc", id: o.id, ok: true, res }))
              .catch((e) => send({ t: "rpc", id: o.id, ok: false, err: String(e && e.message || e) }));
            return;
          }
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


/* ============================ 额外通道 / SFTP / exec ============================ */

class Chan {
  constructor(ssh, id) {
    this.ssh = ssh; this.id = id; this.peer = null;
    this.rwin = 0; this.rmax = 0x8000;        // 对方窗口
    this.lwin = 0x200000; this.consumed = 0;  // 本地窗口
    this.replies = []; this.winWaiters = [];
    this.isClosed = false; this.sentClose = false;
    this.exitCode = null; this.exitSignal = null;
    this.onData = () => {}; this.onExt = () => {}; this.onClose = () => {};
    this.closedP = new Promise((r) => (this._resolveClosed = r));
  }
  open() {
    return new Promise((resolve, reject) => {
      this._openWait = { resolve, reject };
      this.ssh.writePacket(concat(new Uint8Array([90]), sshString(te.encode("session")),
        u32(this.id), u32(this.lwin), u32(0x8000))).catch(reject);
    });
  }
  request(name, wantReply, extra) {
    const p = concat(new Uint8Array([98]), u32(this.peer), sshString(te.encode(name)),
      new Uint8Array([wantReply ? 1 : 0]), extra || new Uint8Array(0));
    if (!wantReply) return this.ssh.writePacket(p);
    return new Promise((resolve, reject) => {
      this.replies.push({ resolve, reject });
      this.ssh.writePacket(p).catch(reject);
    });
  }
  write(bytes) {
    // 串行写：一个 SFTP 包可能拆成多个数据包，不能和别的包交错
    const job = (this.wq || Promise.resolve()).then(() => this._write(bytes));
    this.wq = job.catch(() => {});
    return job;
  }
  async _write(bytes) {
    let off = 0;
    while (off < bytes.length) {
      if (this.isClosed) throw new Error("通道已关闭");
      while (this.rwin <= 0) {
        await new Promise((r) => this.winWaiters.push(r));
        if (this.isClosed) throw new Error("通道已关闭");
      }
      const n = Math.min(bytes.length - off, this.rwin, this.rmax, 0x8000);
      this.rwin -= n;
      await this.ssh.writePacket(concat(new Uint8Array([94]), u32(this.peer), sshString(bytes.subarray(off, off + n))));
      off += n;
    }
  }
  eof() { return this.ssh.writePacket(concat(new Uint8Array([96]), u32(this.peer))).catch(() => {}); }
  close() {
    if (this.sentClose || this.isClosed || this.peer === null) return;
    this.sentClose = true;
    this.ssh.writePacket(concat(new Uint8Array([97]), u32(this.peer))).catch(() => {});
  }
  _closed() {
    if (this.isClosed) return;
    this.isClosed = true;
    this.ssh.chans.delete(this.id);
    if (this._openWait) { this._openWait.reject(new Error("通道已关闭")); this._openWait = null; }
    for (const r of this.replies) r.reject(new Error("通道已关闭"));
    this.replies = [];
    for (const w of this.winWaiters) w();
    this.winWaiters = [];
    try { this.onClose(); } catch (_) {}
    this._resolveClosed();
  }
  async consume(n) {
    this.consumed += n;
    if (this.consumed >= 0x80000) {
      const add = this.consumed; this.consumed = 0;
      await this.ssh.writePacket(concat(new Uint8Array([93]), u32(this.peer), u32(add))).catch(() => {});
    }
  }
  async handle(p) {
    const t = p[0];
    if (t === 91) {                                   // OPEN_CONFIRMATION
      this.peer = readU32(p, 5); this.rwin = readU32(p, 9); this.rmax = readU32(p, 13) || 0x8000;
      if (this._openWait) { this._openWait.resolve(); this._openWait = null; }
    } else if (t === 92) {                            // OPEN_FAILURE
      if (this._openWait) { this._openWait.reject(new Error("服务器拒绝打开新通道")); this._openWait = null; }
      this.isClosed = true; this.ssh.chans.delete(this.id);
    } else if (t === 93) {                            // WINDOW_ADJUST
      this.rwin += readU32(p, 5);
      const w = this.winWaiters; this.winWaiters = []; for (const f of w) f();
    } else if (t === 94) {
      const d = readSshString(p, 5).val; try { this.onData(d); } catch (_) {} await this.consume(d.length);
    } else if (t === 95) {
      const d = readSshString(p, 9).val; try { this.onExt(d); } catch (_) {} await this.consume(d.length);
    } else if (t === 96) {                            // EOF
    } else if (t === 97) {                            // CLOSE
      if (!this.sentClose) { this.sentClose = true; await this.ssh.writePacket(concat(new Uint8Array([97]), u32(this.peer))).catch(() => {}); }
      this._closed();
    } else if (t === 98) {                            // 对方的请求：exit-status / exit-signal
      const r = readSshString(p, 5); const name = td.decode(r.val); const want = p[r.next];
      if (name === "exit-status") this.exitCode = readU32(p, r.next + 1);
      else if (name === "exit-signal") this.exitSignal = td.decode(readSshString(p, r.next + 1).val);
      if (want) await this.ssh.writePacket(concat(new Uint8Array([100]), u32(this.peer))).catch(() => {});
    } else if (t === 99 || t === 100) {
      const r = this.replies.shift();
      if (r) t === 99 ? r.resolve() : r.reject(new Error("服务器拒绝了请求"));
    }
  }
}

// 在独立通道上执行一条命令（AI 用），返回输出和退出码
async function sshExec(ssh, cmd, timeoutSec, onChunk) {
  const ch = await ssh.openChan();
  const parts = []; let total = 0; const CAP = 2 * 1024 * 1024;
  const push = (d) => { if (total < CAP) { parts.push(d); total += d.length; } try { onChunk && onChunk(d); } catch (_) {} };
  ch.onData = push; ch.onExt = push;
  const full = "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a TERM=dumb PAGER=cat SYSTEMD_PAGER=cat; " + cmd;
  try { await ch.request("exec", true, sshString(te.encode(full))); }
  catch (e) { ch.close(); throw new Error("服务器拒绝执行命令"); }
  await ch.eof();                                     // 不给标准输入，避免命令卡在等待输入
  let timedOut = false;
  const tm = setTimeout(() => { timedOut = true; ch.request("signal", false, sshString(te.encode("KILL"))).catch(() => {}); ch.close(); },
    Math.max(5, Math.min(timeoutSec || 120, 1800)) * 1000);
  await ch.closedP;
  clearTimeout(tm);
  return { out: td.decode(concat(...parts)), code: ch.exitCode, signal: ch.exitSignal, timedOut };
}

// SFTP v3 客户端
class SFTP {
  constructor(ch) {
    this.ch = ch; this.buf = new Uint8Array(0); this.nextId = 1; this.pending = new Map();
    ch.onData = (d) => this._feed(d);
    ch.onClose = () => { for (const p of this.pending.values()) p.reject(new Error("SFTP 已断开")); this.pending.clear(); };
  }
  static async start(ssh) {
    const ch = await ssh.openChan();
    const s = new SFTP(ch);
    await ch.request("subsystem", true, sshString(te.encode("sftp")));
    const v = new Promise((resolve, reject) => s.pending.set(0, { resolve, reject }));
    await ch.write(concat(u32(5), new Uint8Array([1]), u32(3)));   // SSH_FXP_INIT v3
    await v;
    return s;
  }
  _feed(d) {
    this.buf = this.buf.length ? concat(this.buf, d) : d;
    while (this.buf.length >= 4) {
      const len = readU32(this.buf, 0);
      if (this.buf.length < 4 + len) break;
      const pkt = this.buf.slice(4, 4 + len);
      this.buf = this.buf.slice(4 + len);
      const type = pkt[0];
      if (type === 2) { const p = this.pending.get(0); if (p) { this.pending.delete(0); p.resolve(); } continue; }
      const id = readU32(pkt, 1);
      const p = this.pending.get(id); if (!p) continue;
      this.pending.delete(id);
      if (type === 101) {
        const code = readU32(pkt, 5);
        let msg = ""; try { msg = td.decode(readSshString(pkt, 9).val); } catch (_) {}
        if (code === 0) p.resolve({ ok: true });
        else if (code === 1) p.resolve({ eof: true });
        else p.reject(new Error(SFTP_ERR[code] || msg || ("SFTP 错误 " + code)));
      } else p.resolve({ type, pkt });
    }
  }
  req(type, body) {
    const id = this.nextId++;
    const payload = concat(new Uint8Array([type]), u32(id), body);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ch.write(concat(u32(payload.length), payload)).catch((e) => { this.pending.delete(id); reject(e); });
    });
  }
  async realpath(path) { const r = await this.req(16, sshString(te.encode(path))); return td.decode(readSshString(r.pkt, 9).val); }
  async stat(path) { const r = await this.req(17, sshString(te.encode(path))); return parseAttrs(r.pkt, 5).attrs; }
  async list(path) {
    const h = await this.req(11, sshString(te.encode(path)));
    const handle = readSshString(h.pkt, 5).val;
    const items = [];
    try {
      while (true) {
        const r = await this.req(12, sshString(handle));
        if (r.eof) break;
        const pkt = r.pkt; const n = readU32(pkt, 5); let o = 9;
        for (let i = 0; i < n; i++) {
          const fn = readSshString(pkt, o); o = fn.next;
          const ln = readSshString(pkt, o); o = ln.next;
          const a = parseAttrs(pkt, o); o = a.next;
          const name = td.decode(fn.val);
          if (name === "." || name === "..") continue;
          items.push({ name, ...a.attrs });
        }
      }
    } finally { this.req(4, sshString(handle)).catch(() => {}); }
    return items;
  }
  async open(path, flags) { const r = await this.req(3, concat(sshString(te.encode(path)), u32(flags), u32(0))); return readSshString(r.pkt, 5).val; }
  async read(handle, off, len) {
    const r = await this.req(5, concat(sshString(handle), u64(off), u32(len)));
    if (r.eof) return null;
    return readSshString(r.pkt, 5).val;
  }
  write(handle, off, data) { return this.req(6, concat(sshString(handle), u64(off), sshString(data))); }
  closeHandle(handle) { return this.req(4, sshString(handle)); }
  remove(path) { return this.req(13, sshString(te.encode(path))); }
  mkdir(path) { return this.req(14, concat(sshString(te.encode(path)), u32(0))); }
  rmdir(path) { return this.req(15, sshString(te.encode(path))); }
  rename(a, b) { return this.req(18, concat(sshString(te.encode(a)), sshString(te.encode(b)))); }
}
const SFTP_ERR = { 2: "文件或目录不存在", 3: "没有权限", 4: "操作失败", 8: "服务器不支持该操作" };
function u64(n) { const a = new Uint8Array(8); writeU32(a, 0, Math.floor(n / 4294967296)); writeU32(a, 4, n >>> 0); return a; }
function parseAttrs(a, o) {
  const flags = readU32(a, o); o += 4; const at = {};
  if (flags & 1) { at.size = readU32(a, o) * 4294967296 + readU32(a, o + 4); o += 8; }
  if (flags & 2) { at.uid = readU32(a, o); at.gid = readU32(a, o + 4); o += 8; }
  if (flags & 4) { at.mode = readU32(a, o); o += 4; }
  if (flags & 8) { at.atime = readU32(a, o); at.mtime = readU32(a, o + 4); o += 8; }
  if (flags & 0x80000000) { const n = readU32(a, o); o += 4; for (let i = 0; i < n; i++) { o = readSshString(a, o).next; o = readSshString(a, o).next; } }
  return { attrs: at, next: o };
}
function b64enc(a) { let s = ""; for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode.apply(null, a.subarray(i, i + 0x8000)); return btoa(s); }
function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

// 浏览器发来的文件/命令请求
async function handleRpc(ssh, st, o, send) {
  const getSftp = async () => { if (!st.sftp) st.sftp = SFTP.start(ssh); try { return await st.sftp; } catch (e) { st.sftp = null; throw e; } };
  const H = (h) => { const x = st.handles.get(h); if (!x) throw new Error("文件句柄已失效"); return x; };
  switch (o.op) {
    case "home": return { path: await (await getSftp()).realpath(o.path || ".") };
    case "ls": {
      const sf = await getSftp(); const path = await sf.realpath(o.path || ".");
      const items = await sf.list(path);
      await Promise.all(items.filter((i) => ((i.mode || 0) & 0o170000) === 0o120000).map(async (i) => {
        i.link = true; try { const t = await sf.stat(path.replace(/\/$/, "") + "/" + i.name); i.dirLink = ((t.mode || 0) & 0o170000) === 0o040000; } catch (_) {}
      }));
      return { path, items };
    }
    case "mkdir": await (await getSftp()).mkdir(o.path); return {};
    case "rename": await (await getSftp()).rename(o.from, o.to); return {};
    case "rm": {
      if (o.dir) { const r = await sshExec(ssh, "rm -rf -- " + shq(o.path), 300); if (r.code) throw new Error(r.out.trim() || "删除失败"); }
      else await (await getSftp()).remove(o.path);
      return {};
    }
    case "open": {
      const sf = await getSftp();
      let size = 0;
      if (o.mode === "r") { const a = await sf.stat(o.path); size = a.size || 0; }
      const h = await sf.open(o.path, o.mode === "r" ? 1 : (2 | 8 | 0x10));
      const id = "h" + (st.nextH++); st.handles.set(id, h);
      return { h: id, size };
    }
    case "read": {
      const sf = await getSftp(); const h = H(o.h); const len = Math.min(o.len || 262144, 524288);
      const CH = 65536, jobs = [];
      for (let off = 0; off < len; off += CH) jobs.push(sf.read(h, o.off + off, Math.min(CH, len - off)));
      const res = await Promise.all(jobs); const parts = []; let eof = false;
      for (let i = 0; i < res.length; i++) {          // 遇到短读就停（后面块的偏移已不连续）
        const r = res[i]; if (!r) { eof = true; break; }
        parts.push(r); if (r.length < Math.min(CH, len - i * CH)) break;
      }
      const data = parts.length ? concat(...parts) : new Uint8Array(0);
      return { b64: b64enc(data), n: data.length, eof: eof || data.length === 0 };
    }
    case "write": {
      const sf = await getSftp(); const h = H(o.h); const data = b64ToBytes(o.b64); const CH = 65536, jobs = [];
      for (let off = 0; off < data.length; off += CH) jobs.push(sf.write(h, o.off + off, data.subarray(off, off + CH)));
      await Promise.all(jobs); return { n: data.length };
    }
    case "close": { const h = st.handles.get(o.h); st.handles.delete(o.h); if (h) await (await getSftp()).closeHandle(h).catch(() => {}); return {}; }
    case "writefile": {
      const sf = await getSftp(); const data = te.encode(String(o.content || ""));
      const h = await sf.open(o.path, 2 | 8 | 0x10);
      try { const CH = 65536, jobs = []; for (let off = 0; off < data.length; off += CH) jobs.push(sf.write(h, off, data.subarray(off, off + CH))); await Promise.all(jobs); }
      finally { await sf.closeHandle(h).catch(() => {}); }
      return { n: data.length };
    }
    case "exec": {
      const dec = new TextDecoder();
      const r = await sshExec(ssh, String(o.cmd || ""), o.timeout, (d) => send({ t: "exo", id: o.id, d: dec.decode(d, { stream: true }) }));
      return r;
    }
    default: throw new Error("未知操作");
  }
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
    this.chans = new Map(); this.nextChan = 1;   // 额外通道：SFTP、AI 执行命令
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
      // 额外通道（SFTP / exec）的消息交给各自的通道对象
      if (t >= 91 && t <= 100 && p.length >= 5) {
        const rc = readU32(p, 1);
        if (rc !== this.channel && this.chans.has(rc)) { await this.chans.get(rc).handle(p); continue; }
      }
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

  // 打开一个新的 session 通道（用于 SFTP 或 exec）
  async openChan() {
    if (this.closed || !this.ready) throw new Error("SSH 未就绪");
    const ch = new Chan(this, this.nextChan++);
    this.chans.set(ch.id, ch);
    await ch.open();
    return ch;
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
    for (const ch of this.chans.values()) { try { ch._closed(); } catch (_) {} }
    this.chans.clear();
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
  #term-wrap { position:fixed; inset:0; background:#0b0f17; display:none; flex-direction:column; }
  #bar { height:36px; flex:none; background:#111827; color:#d1d5db; display:flex; align-items:center; gap:8px; padding:0 12px; font-size:13px; }
  #bar .dot { color:#22c55e; } #bar .sp { flex:1; }
  #bar button { background:#374151; color:#e5e7eb; border:none; border-radius:6px; padding:5px 10px; cursor:pointer; font-size:12px; }
  #bar button.on { background:#2563eb; }
  #main { flex:1; display:flex; min-height:0; }
  #left { flex:1 1 0; min-width:200px; display:flex; background:#000; overflow:hidden; }
  #term { flex:1 1 0; min-width:0; padding:6px; overflow:hidden; }
  #right { flex:none; width:44%; min-width:280px; max-width:calc(100% - 205px); overflow:hidden; display:flex; flex-direction:column; background:#111827; color:#e5e7eb; font-size:13px; }
  .vsplit { width:5px; flex:none; cursor:col-resize; background:#1f2937; } .vsplit:hover { background:#2563eb; }
  .hsplit { height:5px; flex:none; cursor:row-resize; background:#1f2937; } .hsplit:hover { background:#2563eb; }
  .pane { display:flex; flex-direction:column; min-height:80px; flex:1; overflow:hidden; }
  .ph { flex:none; display:flex; align-items:center; gap:6px; min-width:0; overflow-x:auto; scrollbar-width:none; padding:6px 8px; background:#0f172a; border-bottom:1px solid #1f2937; }
  .ph b { font-size:13px; white-space:nowrap; margin-right:4px; }
  .ph button, .ib { background:#1f2937; color:#e5e7eb; border:1px solid #334155; border-radius:6px; padding:3px 8px; cursor:pointer; font-size:12px; white-space:nowrap; }
  .ph button:hover, .ib:hover { background:#334155; }
  .ph input { flex:1; min-width:60px; background:#0b1220; color:#e5e7eb; border:1px solid #334155; border-radius:6px; padding:4px 8px; font-size:12px; outline:none; font-family:Menlo,Consolas,monospace; }
  #flist { flex:1; overflow:auto; position:relative; }
  #flist.drag { outline:2px dashed #3b82f6; outline-offset:-6px; background:#0f1d33; }
  .fr { display:grid; grid-template-columns: 1fr 80px 120px 86px; gap:6px; align-items:center; padding:4px 10px; border-bottom:1px solid #172033; cursor:default; user-select:none; }
  .fr:hover { background:#1e293b; } .fr.hd { position:sticky; top:0; background:#0f172a; color:#94a3b8; font-size:12px; z-index:1; }
  .fr .nm { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; } .fr .nm.dir { color:#93c5fd; cursor:pointer; }
  .fr .sz, .fr .tm, .fr .pm { color:#94a3b8; font-size:12px; white-space:nowrap; overflow:hidden; } .fr .pm { font-family:Menlo,Consolas,monospace; }
  .fr .acts { display:none; gap:4px; } .fr:hover .acts { display:flex; } .fr:hover .pm { display:none; }
  .acts span { cursor:pointer; padding:1px 5px; border-radius:4px; background:#334155; font-size:11px; } .acts span:hover { background:#2563eb; }
  #fstat { flex:none; padding:4px 10px; font-size:12px; color:#94a3b8; border-top:1px solid #1f2937; min-height:24px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  #fstat .bar { display:inline-block; width:120px; height:6px; background:#1f2937; border-radius:3px; vertical-align:middle; margin:0 6px; overflow:hidden; }
  #fstat .bar i { display:block; height:100%; background:#22c55e; width:0; }
  #aiset { flex:none; padding:8px; display:grid; grid-template-columns:1fr 1fr; gap:6px; background:#0f172a; border-bottom:1px solid #1f2937; }
  #aiset input { background:#0b1220; color:#e5e7eb; border:1px solid #334155; border-radius:6px; padding:5px 8px; font-size:12px; outline:none; }
  #aiset .full { grid-column:1/-1; }
  #aiset .ib.warn { background:#7f1d1d; border-color:#b91c1c; color:#fff; } #aiset .ib:disabled { opacity:.5; }
  #aiset .row { display:flex; gap:6px; min-width:0; } #aiset .row input { flex:1; min-width:0; }
  #aiset select { flex:1; min-width:0; background:#0b1220; color:#e5e7eb; border:1px solid #334155; border-radius:6px; padding:5px 6px; font-size:12px; outline:none; } #aiset .tip { grid-column:1/-1; color:#94a3b8; font-size:11px; }
  #msgs { flex:1; overflow:auto; padding:10px; display:flex; flex-direction:column; gap:8px; }
  .m { max-width:96%; line-height:1.55; white-space:pre-wrap; word-break:break-word; }
  .m.u { align-self:flex-end; background:#2563eb; color:#fff; padding:6px 10px; border-radius:10px 10px 2px 10px; }
  .m.a { align-self:flex-start; background:#1e293b; padding:6px 10px; border-radius:10px 10px 10px 2px; }
  .m.e { align-self:stretch; color:#fca5a5; background:#3b1220; padding:6px 10px; border-radius:8px; }
  .m.s { align-self:center; color:#94a3b8; font-size:12px; }
  .m code { background:#0b1220; padding:0 4px; border-radius:4px; font-family:Menlo,Consolas,monospace; font-size:12px; }
  .m pre { background:#0b1220; padding:8px; border-radius:6px; overflow:auto; margin:6px 0; white-space:pre; font-size:12px; }
  .tc { align-self:stretch; border:1px solid #334155; border-radius:8px; overflow:hidden; background:#0b1220; }
  .tc .th { display:flex; align-items:center; gap:6px; padding:5px 8px; background:#111c2e; cursor:pointer; font-family:Menlo,Consolas,monospace; font-size:12px; }
  .tc .th .c { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:#e2e8f0; }
  .tc .bd { display:none; max-height:260px; overflow:auto; padding:6px 8px; white-space:pre-wrap; word-break:break-all; font-family:Menlo,Consolas,monospace; font-size:12px; color:#cbd5e1; }
  .tc.open .bd { display:block; }
  .badge { font-size:11px; padding:1px 6px; border-radius:8px; background:#334155; white-space:nowrap; }
  .badge.ok { background:#14532d; color:#86efac; } .badge.bad { background:#7f1d1d; color:#fecaca; } .badge.run { background:#1e3a8a; color:#bfdbfe; }
  .warn { padding:8px; background:#3a2a0a; border-top:1px solid #a16207; color:#fde68a; font-size:12px; }
  .warn button { margin:6px 6px 0 0; border:none; border-radius:6px; padding:4px 12px; cursor:pointer; color:#fff; }
  #aiin { flex:none; display:flex; gap:6px; padding:8px; border-top:1px solid #1f2937; }
  #aiin textarea { flex:1; min-width:0; resize:none; height:52px; background:#0b1220; color:#e5e7eb; border:1px solid #334155; border-radius:8px; padding:6px 8px; font-size:13px; outline:none; font-family:inherit; }
  #aiin button { flex:none; width:64px; border:none; border-radius:8px; background:#16a34a; color:#fff; font-weight:700; cursor:pointer; }
  #aiin button.stop { background:#dc2626; }
  @media (max-width:900px){ #main{flex-direction:column;} #right{width:auto!important;height:50%;min-width:0;} .vsplit{display:none;} #left{min-height:200px;} .fr{grid-template-columns:1fr 70px 0 80px;} .fr .tm{display:none;} }
  #toast { position:fixed; left:50%; top:18px; transform:translateX(-50%); background:rgba(0,0,0,.8); color:#fff;
    padding:8px 16px; border-radius:8px; font-size:14px; display:none; z-index:99; }
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
      <button id="tg-files" class="on" onclick="togglePane('files')">📁 文件</button>
      <button id="tg-ai" class="on" onclick="togglePane('ai')">🤖 AI</button>
      <button onclick="doCopy()">复制</button>
      <button onclick="doPaste()">粘贴</button>
      <button onclick="location.replace(location.pathname+location.hash)">断开</button>
    </div>
    <div id="main">
      <div id="left"><div id="term"></div></div>
      <div class="vsplit" id="vsplit"></div>
      <div id="right">
        <div class="pane" id="files">
          <div class="ph">
            <b>文件</b>
            <button title="上级目录" onclick="fsUp()">⬆</button>
            <input id="fpath" spellcheck="false" title="输入路径后回车">
            <button title="刷新" onclick="fsList(cwd)">⟳</button>
            <button title="新建文件夹" onclick="fsMkdir()">＋📁</button>
            <button title="上传文件（也可以直接拖进来）" onclick="$('upfile').click()">⤒ 上传</button>
            <button title="在左侧终端切换到这个目录" onclick="termCd()">&gt;_</button>
            <input type="file" id="upfile" multiple style="display:none">
          </div>
          <div id="flist"></div>
          <div id="fstat"></div>
        </div>
        <div class="hsplit" id="hsplit"></div>
        <div class="pane" id="ai">
          <div class="ph">
            <b>AI 助手</b><span style="flex:1"></span>
            <button onclick="toggleAiSet()">⚙ 接口设置</button>
            <button onclick="aiClear()">清空对话</button>
          </div>
          <div id="aiset">
            <input id="ai-base" class="full" placeholder="API 地址，如 https://api.openai.com/v1" value="https://api.openai.com/v1" spellcheck="false">
            <div class="row full">
              <input id="ai-key" type="password" placeholder="API Key（不保存，关页即清）" autocomplete="new-password">
              <button class="ib" id="ai-fetch" onclick="fetchModels()">获取模型</button>
              <button class="ib" id="ai-test" onclick="testModels()" disabled>测试可用</button>
            </div>
            <div class="row full">
              <select id="ai-sel" onchange="$('ai-model').value=''"><option value="">← 先点“获取模型”</option></select>
              <input id="ai-model" placeholder="或手动输入模型名" spellcheck="false" style="flex:0 0 38%">
            </div>
            <div class="row full" style="align-items:center;font-size:12px;color:#94a3b8">
              <label id="ai-freebox" style="display:none;flex:none;cursor:pointer;white-space:nowrap"><input type="checkbox" id="ai-freeonly" onchange="renderModels()" style="vertical-align:-2px"> 只看免费</label>
              <span id="ai-mstat" style="min-width:0"></span>
            </div>
            <div class="tip">兼容 OpenAI 接口即可（OpenAI、DeepSeek、通义、Kimi、各类中转站），模型需支持工具调用。危险命令会先问你。</div>
          </div>
          <div id="msgs"><div class="m s">告诉我你想在这台服务器上做什么，比如“装个 Docker”“帮我搭个网站”“为什么内存满了”。</div></div>
          <div id="aiin">
            <textarea id="aitext" placeholder="输入需求，Enter 发送，Shift+Enter 换行"></textarea>
            <button id="aisend" onclick="aiSendOrStop()">发送</button>
          </div>
        </div>
      </div>
    </div>
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
  SESS={host:host,user:user,port:port};

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
      let o; try{ o=JSON.parse(ev.data); }catch(_){ term.write(ev.data); return; }
      if(o.t==='rpc'){ const p=RPC.get(o.id); if(p){ RPC.delete(o.id); o.ok?p.resolve(o.res):p.reject(new Error(o.err)); } }
      else if(o.t==='exo'){ const p=RPC.get(o.id); if(p&&p.onOut) p.onOut(o.d); }
      else if(o.t==='ready'){ onReady(); if(cmd&&!sentCmd){ sentCmd=true; setTimeout(()=>ws.send(cmd+'\r'),300); } }
      else if(o.t==='err'){ term.write('\r\n\x1b[31m'+o.m+'\x1b[0m\r\n'); }
    } else term.write(new Uint8Array(ev.data));
  };
  // 心跳：每 20 秒发一次，避免 Cloudflare 因约 100 秒无流量而断开 WebSocket
  const hb=setInterval(()=>{ if(ws.readyState===1) ws.send('{"t":"ping"}'); },20000);
  ws.onclose=()=>{ clearInterval(hb); term.write('\r\n\x1b[33m*** 连接已关闭 ***\x1b[0m\r\n'); keyText='';
    RPC.forEach(p=>p.reject(new Error('连接已关闭'))); RPC.clear(); };

  term.onData(d=>{ if(ws.readyState===1) ws.send(JSON.stringify({t:'data',d})); });
  term.onSelectionChange(()=>{ const s=term.getSelection(); if(s) navigator.clipboard.writeText(s).catch(()=>{}); }); // 选中即复制
  term.attachCustomKeyEventHandler(e=>{ // Ctrl+Shift+C 复制 / Ctrl+Shift+V 粘贴
    if(e.type==='keydown'&&e.ctrlKey&&e.shiftKey&&(e.key==='C'||e.key==='c')){ doCopy(); return false; }
    if(e.type==='keydown'&&e.ctrlKey&&e.shiftKey&&(e.key==='V'||e.key==='v')){ doPaste(); return false; }
    return true;
  });
  $('term').addEventListener('contextmenu',e=>{ e.preventDefault(); doPaste(); }); // 右键粘贴
  window.addEventListener('resize',onResize);
  initSplitters();
}
function onResize(){ if(!fit) return; try{ fit.fit(); }catch(_){} if(ws&&ws.readyState===1) ws.send(JSON.stringify({t:'resize',cols:term.cols,rows:term.rows})); }
async function doCopy(){ const s=term&&term.getSelection(); if(!s) return; try{ await navigator.clipboard.writeText(s); toast('已复制',800);}catch(_){} term.focus(); }
async function doPaste(){
  try{ const t=await navigator.clipboard.readText(); if(t) term.paste(t); }
  catch(_){ toast('浏览器不允许读剪贴板，请用 Ctrl+V / ⌘V',1800); }
  term.focus();
}
window.addEventListener('pagehide',()=>{ try{ ws&&ws.close(); }catch(_){} keyText=''; $('ai-key').value=''; });
$('pass').addEventListener('keydown',e=>{ if(e.key==='Enter') startConnect(); });
$('cmd').addEventListener('keydown',e=>{ if(e.key==='Enter') startConnect(); });

/* ---------------- 与 Worker 的请求通道 ---------------- */
let SESS=null, RPC=new Map(), rpcId=0, readyDone=false;
function rpc(op, args, onOut){
  return new Promise((resolve,reject)=>{
    if(!ws||ws.readyState!==1) return reject(new Error('连接已断开'));
    const id=++rpcId; RPC.set(id,{resolve,reject,onOut});
    ws.send(JSON.stringify(Object.assign({t:'rpc',id:id,op:op},args||{})));
  });
}
function onReady(){ if(readyDone) return; readyDone=true; rpc('home',{}).then(r=>fsList(r.path)).catch(e=>fstat('文件列表加载失败：'+e.message)); }
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function b64e(u8){ let s=''; for(let i=0;i<u8.length;i+=0x8000) s+=String.fromCharCode.apply(null,u8.subarray(i,i+0x8000)); return btoa(s); }
function b64d(b){ const s=atob(b); const a=new Uint8Array(s.length); for(let i=0;i<s.length;i++) a[i]=s.charCodeAt(i); return a; }
function shq(s){ return "'"+String(s).replace(/'/g,"'\\''")+"'"; }

/* ---------------- 分栏拖动 / 显示隐藏 ---------------- */
function initSplitters(){
  const drag=(el,move)=>el.addEventListener('mousedown',e=>{ e.preventDefault(); document.body.style.userSelect='none';
    const mm=ev=>{ move(ev); onResize(); }; const mu=()=>{ document.removeEventListener('mousemove',mm); document.removeEventListener('mouseup',mu); document.body.style.userSelect=''; onResize(); };
    document.addEventListener('mousemove',mm); document.addEventListener('mouseup',mu); });
  drag($('vsplit'),ev=>{ const w=Math.max(280,Math.min(window.innerWidth-240,window.innerWidth-ev.clientX)); $('right').style.width=w+'px'; });
  drag($('hsplit'),ev=>{ const r=$('right').getBoundingClientRect(); const h=Math.max(80,Math.min(r.height-80,ev.clientY-r.top)); $('files').style.flex='none'; $('files').style.height=h+'px'; });
}
function togglePane(name){
  const el=$(name), btn=$('tg-'+name); const show=el.style.display==='none';
  el.style.display=show?'flex':'none'; btn.classList.toggle('on',show);
  const f=$('files').style.display!=='none', a=$('ai').style.display!=='none';
  $('hsplit').style.display=(f&&a)?'block':'none';
  if(!a) { $('files').style.flex='1'; $('files').style.height=''; }
  $('right').style.display=(f||a)?'flex':'none'; $('vsplit').style.display=(f||a)?'block':'none';
  setTimeout(onResize,30);
}

/* ---------------- 文件管理 ---------------- */
let cwd='/', fitems=[];
function fstat(h){ $('fstat').innerHTML=h||''; }
const joinp=(d,n)=>(d==='/'?'':d.replace(/\/$/,''))+'/'+n;
const parentp=p=>{ const x=p.replace(/\/+$/,'').split('/'); x.pop(); return x.join('/')||'/'; };
function fsize(n){ if(n==null) return ''; const u=['B','K','M','G','T']; let i=0; while(n>=1024&&i<4){ n/=1024; i++; } return (i?n.toFixed(1):n)+u[i]; }
function fperm(m){ if(m==null) return ''; const t={0o040000:'d',0o120000:'l'}[m&0o170000]||'-'; let s=t; const r='rwxrwxrwx'; for(let i=0;i<9;i++) s+=(m&(1<<(8-i)))?r[i]:'-'; return s; }
function ftime(t){ if(!t) return ''; const d=new Date(t*1000), p=n=>String(n).padStart(2,'0'); return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes()); }
const isDir=i=>((i.mode||0)&0o170000)===0o040000||i.dirLink;
async function fsList(path){
  fstat('加载中…');
  try{
    const r=await rpc('ls',{path:path}); cwd=r.path; $('fpath').value=cwd;
    fitems=r.items.sort((a,b)=>(isDir(b)-isDir(a))||a.name.localeCompare(b.name));
    let h='<div class="fr hd"><div>名称</div><div>大小</div><div>修改时间</div><div>权限</div></div>';
    if(cwd!=='/') h+='<div class="fr" ondblclick="fsUp()"><div class="nm dir" onclick="fsUp()">📁 ..</div><div></div><div></div><div></div></div>';
    fitems.forEach((it,i)=>{
      const d=isDir(it);
      h+='<div class="fr" data-i="'+i+'" ondblclick="fsOpen('+i+')"><div class="nm'+(d?' dir':'')+'" '+(d?'onclick="fsOpen('+i+')"':'')+' title="'+esc(it.name)+'">'+(d?'📁 ':(it.link?'🔗 ':'📄 '))+esc(it.name)+'</div>'+
        '<div class="sz">'+(d?'':fsize(it.size))+'</div><div class="tm">'+ftime(it.mtime)+'</div>'+
        '<div><span class="pm">'+fperm(it.mode)+'</span><span class="acts">'+
        '<span onclick="fsDown('+i+')" title="'+(d?'打包下载':'下载')+'">⤓</span><span onclick="fsRen('+i+')" title="重命名">✎</span><span onclick="fsDel('+i+')" title="删除">✕</span></span></div></div>';
    });
    if(!fitems.length) h+='<div class="m s" style="padding:16px">空文件夹，可以把文件拖进来上传</div>';
    $('flist').innerHTML=h; fstat(fitems.length+' 项');
  }catch(e){ fstat('打开失败：'+esc(e.message)); }
}
function fsUp(){ fsList(parentp(cwd)); }
function fsOpen(i){ const it=fitems[i]; if(isDir(it)) fsList(joinp(cwd,it.name)); else fsDown(i); }
$('fpath').addEventListener('keydown',e=>{ if(e.key==='Enter') fsList($('fpath').value.trim()||'/'); });
async function fsMkdir(){ const n=prompt('新文件夹名称：'); if(!n) return; try{ await rpc('mkdir',{path:joinp(cwd,n)}); fsList(cwd); }catch(e){ toast('创建失败：'+e.message,2500); } }
async function fsRen(i){ const it=fitems[i]; const n=prompt('重命名为：',it.name); if(!n||n===it.name) return;
  try{ await rpc('rename',{from:joinp(cwd,it.name),to:n.startsWith('/')?n:joinp(cwd,n)}); fsList(cwd); }catch(e){ toast('重命名失败：'+e.message,2500); } }
async function fsDel(i){ const it=fitems[i], d=isDir(it)&&!it.link;
  if(!confirm('确定删除'+(d?'文件夹（含里面所有内容）':'文件')+'：\n'+joinp(cwd,it.name)+' ？')) return;
  try{ await rpc('rm',{path:joinp(cwd,it.name),dir:d}); fsList(cwd); }catch(e){ toast('删除失败：'+e.message,2500); } }
function termCd(){ if(ws&&ws.readyState===1){ ws.send(JSON.stringify({t:'data',d:'cd '+shq(cwd)+'\r'})); term.focus(); } }
function progress(label,done,total){ const pc=total?Math.min(100,done/total*100):0;
  fstat(esc(label)+'<span class="bar"><i style="width:'+pc.toFixed(1)+'%"></i></span>'+fsize(done)+' / '+fsize(total)); }

const CH=262144, PAR=4;
async function uploadFile(file, dir){
  const path=joinp(dir,file.name); const r=await rpc('open',{path:path,mode:'w'}); let done=0, next=0;
  try{
    const worker=async()=>{ while(next<file.size){ const off=next; next+=CH;
      const buf=new Uint8Array(await file.slice(off,off+CH).arrayBuffer());
      await rpc('write',{h:r.h,off:off,b64:b64e(buf)}); done+=buf.length; progress('上传 '+file.name,done,file.size); } };
    await Promise.all(Array.from({length:PAR},worker));
  } finally { await rpc('close',{h:r.h}).catch(()=>{}); }
}
async function uploadFiles(files){
  const dir=cwd;
  for(const f of files){ try{ progress('上传 '+f.name,0,f.size); await uploadFile(f,dir); }catch(e){ toast('上传失败 '+f.name+'：'+e.message,3000); } }
  fsList(cwd); toast('上传完成',1200);
}
$('upfile').addEventListener('change',e=>{ const fs=[...e.target.files]; e.target.value=''; if(fs.length) uploadFiles(fs); });
const fl=$('flist');
fl.addEventListener('dragover',e=>{ e.preventDefault(); fl.classList.add('drag'); });
fl.addEventListener('dragleave',()=>fl.classList.remove('drag'));
fl.addEventListener('drop',e=>{ e.preventDefault(); fl.classList.remove('drag'); const fs=[...e.dataTransfer.files]; if(fs.length) uploadFiles(fs); });

async function downloadPath(path, name){
  const r=await rpc('open',{path:path,mode:'r'}); const parts=[]; let done=0;
  try{
    if(r.size>0){
      const n=Math.ceil(r.size/CH); let next=0;
      const worker=async()=>{ while(next<n){ const k=next++; let off=k*CH; const end=Math.min(r.size,off+CH); const segs=[];
        while(off<end){ const x=await rpc('read',{h:r.h,off:off,len:end-off}); if(!x.n) break; segs.push(b64d(x.b64)); off+=x.n; done+=x.n; progress('下载 '+name,done,r.size); if(x.eof) break; }
        parts[k]=new Blob(segs); } };
      await Promise.all(Array.from({length:PAR},worker));
    } else {
      let off=0; while(true){ const x=await rpc('read',{h:r.h,off:off,len:CH}); if(x.n){ parts.push(b64d(x.b64)); off+=x.n; done+=x.n; progress('下载 '+name,done,done); } if(x.eof||!x.n) break; }
    }
  } finally { await rpc('close',{h:r.h}).catch(()=>{}); }
  const url=URL.createObjectURL(new Blob(parts)); const a=document.createElement('a'); a.href=url; a.download=name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),60000); fstat('下载完成：'+esc(name));
}
async function fsDown(i){
  const it=fitems[i];
  try{
    if(isDir(it)){
      fstat('正在打包 '+esc(it.name)+' …');
      const tmp='/tmp/.webssh_'+Date.now()+'.tar.gz';
      const x=await rpc('exec',{cmd:'tar czf '+shq(tmp)+' -C '+shq(cwd)+' '+shq(it.name),timeout:600});
      if(x.code){ throw new Error(x.out.trim().slice(-200)||'打包失败'); }
      try{ await downloadPath(tmp,it.name+'.tar.gz'); } finally { rpc('exec',{cmd:'rm -f '+shq(tmp),timeout:30}).catch(()=>{}); }
    } else await downloadPath(joinp(cwd,it.name),it.name);
  }catch(e){ fstat(''); toast('下载失败：'+e.message,3000); }
}

/* ---------------- AI 助手 ---------------- */
let aiMsgs=[], aiBusy=false, aiAbort=null, aiStop=false;
function toggleAiSet(){ const s=$('aiset'); s.style.display=s.style.display==='none'?'grid':'none'; }
function aiClear(){ if(aiBusy) return; aiMsgs=[]; $('msgs').innerHTML='<div class="m s">对话已清空</div>'; }
function scrollMsgs(){ const m=$('msgs'); m.scrollTop=m.scrollHeight; }
function md(t){ // 极简 markdown：代码块、行内代码、粗体
  const BT=String.fromCharCode(96), IC=new RegExp(BT+'([^'+BT+'\\n]+)'+BT,'g');
  const parts=String(t||'').split(BT+BT+BT); let h='';
  parts.forEach((p,i)=>{ if(i%2){ h+='<pre>'+esc(p.replace(/^[^\n]*\n/,''))+'</pre>'; } else h+=esc(p).replace(IC,'<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>'); });
  return h;
}
function addMsg(cls,html){ const d=document.createElement('div'); d.className='m '+cls; d.innerHTML=html; $('msgs').appendChild(d); scrollMsgs(); return d; }
function setBusy(b){ aiBusy=b; const btn=$('aisend'); btn.textContent=b?'停止':'发送'; btn.classList.toggle('stop',b); }
function aiSendOrStop(){ if(aiBusy){ aiStop=true; if(aiAbort) aiAbort.abort(); return; } aiSend(); }
$('aitext').addEventListener('keydown',e=>{ if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){ e.preventDefault(); aiSendOrStop(); } });

function sysPrompt(){
  return [
'你是“VPS 运维助手”，嵌在一个网页版 SSH 终端里。用户已经通过 SSH 登录到一台 Linux 服务器：主机 '+SESS.host+'，端口 '+SESS.port+'，登录用户 '+SESS.user+'。',
'你的使命：替不熟悉命令行、不会写脚本的用户，完成这台服务器上的一切运维工作——安装和配置软件、部署网站和服务、编写并运行脚本、排查故障、查看资源和日志、管理文件、安全加固等。你拥有通过工具完全操作这台服务器的能力，要主动动手，而不是只教用户怎么做。',
'',
'工具：',
'- run_command：在服务器上执行 shell 命令。非交互、没有 TTY、没有标准输入；每次都是全新的 shell，cd 和环境变量不会保留，需要时写成 cd /路径 && 命令。返回输出和退出码，输出过长会被截断。',
'- write_file：直接把完整内容写入文件（会覆盖），写脚本、配置文件时用它，比 echo/heredoc 可靠。',
'',
'工作方法：',
'1. 接到第一个任务时，先用一条命令摸清环境：cat /etc/os-release; uname -m; id; free -h; df -h /; 以及可用的包管理器。之后按需再查，不要重复查。',
'2. 动手前用一两句话说明打算怎么做，然后一步一步执行；每步看结果再决定下一步。出错时自己分析原因、换方法修复，不要直接把报错丢给用户。',
'3. 命令必须非交互：apt/yum/dnf 加 -y；安装脚本使用自动确认参数或 yes |；不要运行 vim、nano、top、less、htop 等全屏程序（用 cat、sed、top -bn1 等代替）。',
'4. 会运行很久或需要常驻的程序，用 systemd 服务或 nohup ... > 日志 2>&1 & 放到后台；给 run_command 设置合适的 timeout 秒数（默认 120，最长 1800），大型安装可以设 600 以上。',
'5. 如果不是 root，用 sudo；若 sudo 需要密码，停下来请用户在左侧终端里自己执行那条命令。确实需要人工在终端里交互的步骤，也请用户在左侧终端完成，并把要输入的内容告诉他。',
'6. 谨慎行事：不做用户没要求的破坏性操作；修改或删除重要文件前先备份（如 cp a a.bak.$(date +%s)）；改 SSH、防火墙时先确保当前 SSH 端口 '+SESS.port+' 保持放行，避免把用户锁在服务器外面。危险命令系统会自动弹窗请用户确认，被拒绝时换一种安全的做法或询问用户。',
'7. 从网上下载安装脚本时优先使用官方来源，并告诉用户来源。',
'8. 用简体中文回复，通俗易懂，假设用户是新手，少用术语。任务完成后简短总结：做了什么、结果如何、接下来怎么用（访问地址、端口、账号密码在哪、常用管理命令）。',
'9. 只为用户的需求操作这台服务器；不要回显或泄露用户的密码、私钥和 API Key。'
  ].join('\n');
}
const TOOLS=[
  {type:'function',function:{name:'run_command',description:'在当前 SSH 登录的服务器上执行一条 shell 命令（非交互、无标准输入），返回输出与退出码',
    parameters:{type:'object',properties:{command:{type:'string',description:'要执行的 shell 命令'},timeout:{type:'integer',description:'超时秒数，默认120，最长1800'}},required:['command']}}},
  {type:'function',function:{name:'write_file',description:'把完整内容写入服务器上的文件（覆盖原文件，不存在则创建）',
    parameters:{type:'object',properties:{path:{type:'string',description:'绝对路径'},content:{type:'string',description:'文件完整内容'}},required:['path','content']}}}
];
const DANGER=[
  /\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rRf]/, /\bmkfs/, /\bdd\b[^|;&]*\bof=/, /\b(fdisk|sfdisk|gdisk|parted|wipefs|shred)\b/,
  /\b(shutdown|reboot|poweroff|halt)\b/, /\binit\s+[06]\b/, />\s*\/dev\/(sd|vd|hd|xvd|nvme)/,
  /\b(chmod|chown|chgrp)\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*R/, /\b(userdel|deluser|passwd|chpasswd|usermod)\b/,
  /\b(iptables|ip6tables)\b[^;&|]*\s(-F|--flush|-X|-P\s+\w+\s+DROP)/, /\bufw\s+(enable|reset|default)/, /\bnft\s+flush/,
  /\bsystemctl\s+(stop|disable|mask|restart)\s+(ssh|sshd)\b/, /\b(kill|pkill|killall)\b[^;&|]*\bsshd?\b/, /:\(\)\s*\{/,
  /\b(apt|apt-get|yum|dnf|zypper)\s+(-y\s+)?(remove|purge|autoremove|erase)\b/, /\bcrontab\s+-r\b/, /\btruncate\b/,
  /\bmv\s+[^;&|]*\s\/(etc|bin|sbin|usr|lib|lib64|boot)(\/|\s|$)/, /\b(reinstall|InstallNET|netboot)/i,
  />\s*\/etc\/(passwd|shadow|sudoers|fstab|ssh\/sshd_config)/, /\bsed\s+-i[^;&|]*\/etc\/(ssh|passwd|shadow|sudoers|fstab)/
];
const DANGER_PATH=/^\/(boot|etc\/(ssh\/|passwd|shadow|group|sudoers|fstab|network\/|netplan\/|resolv\.conf|hosts$)|bin\/|sbin\/|usr\/bin\/|lib)/;
function isDanger(name,a){ if(name==='write_file') return DANGER_PATH.test(String(a.path||'')); return DANGER.some(r=>r.test(String(a.command||''))); }

function toolCard(name,a){
  const d=document.createElement('div'); d.className='tc';
  const label=name==='write_file'?('✎ 写入 '+a.path):('$ '+a.command);
  d.innerHTML='<div class="th"><span class="c"></span><span class="badge run">执行中</span></div><div class="bd"></div>';
  d.querySelector('.c').textContent=label; d.querySelector('.c').title=label;
  d.querySelector('.th').onclick=()=>d.classList.toggle('open');
  if(name==='write_file'){ d.querySelector('.bd').textContent=a.content||''; }
  $('msgs').appendChild(d); scrollMsgs(); return d;
}
function setBadge(card,cls,txt){ const b=card.querySelector('.badge'); b.className='badge '+cls; b.textContent=txt; }
function askConfirm(card){
  return new Promise(res=>{
    setBadge(card,'bad','待确认'); card.classList.add('open');
    const w=document.createElement('div'); w.className='warn';
    w.innerHTML='⚠ 这是可能有风险的操作（删除、改系统/SSH/防火墙、重启等），确定要让 AI 执行吗？<br><button style="background:#dc2626">执行</button><button style="background:#475569">拒绝</button>';
    const [y,n]=w.querySelectorAll('button');
    y.onclick=()=>{ w.remove(); res(true); }; n.onclick=()=>{ w.remove(); res(false); };
    card.appendChild(w); scrollMsgs();
  });
}
function clip(s,max){ s=String(s||''); if(s.length<=max) return s; const h=Math.floor(max*0.3); return s.slice(0,h)+'\n…（中间省略 '+(s.length-max)+' 个字符）…\n'+s.slice(s.length-(max-h)); }
async function runTool(name,a){
  const card=toolCard(name,a);
  if(isDanger(name,a)){ const ok=await askConfirm(card); if(!ok){ setBadge(card,'bad','已拒绝'); return '用户拒绝执行这个操作。请换一种更安全的方式，或先向用户说明原因并询问。'; } setBadge(card,'run','执行中'); }
  try{
    if(name==='write_file'){
      const r=await rpc('writefile',{path:a.path,content:a.content||''}); setBadge(card,'ok','已写入'); if(cwd&&String(a.path).startsWith(cwd)) fsList(cwd);
      return '已写入 '+a.path+'（'+r.n+' 字节）';
    }
    const bd=card.querySelector('.bd'); card.classList.add('open'); let shown='';
    const r=await rpc('exec',{cmd:String(a.command||''),timeout:a.timeout||120},(t)=>{ shown+=t; if(shown.length<200000){ bd.textContent=shown; bd.scrollTop=bd.scrollHeight; scrollMsgs(); } });
    bd.textContent=r.out||'(无输出)';
    if(r.timedOut) setBadge(card,'bad','超时'); else setBadge(card,r.code===0?'ok':'bad','退出码 '+(r.code==null?'?':r.code));
    if(r.code===0&&!r.timedOut) setTimeout(()=>card.classList.remove('open'),800);
    return (r.timedOut?'[命令超时被终止，可调大 timeout 或改为后台运行]\n':'')+'exit_code: '+(r.code==null?'unknown':r.code)+(r.signal?(' signal: '+r.signal):'')+'\n'+clip(r.out||'(无输出)',12000);
  }catch(e){ setBadge(card,'bad','失败'); return '执行失败：'+e.message; }
}
function trimHistory(){ // 对话太长时，把较早的命令输出缩短，避免超出模型上下文
  let total=aiMsgs.reduce((n,m)=>n+String(m.content||'').length,0);
  for(let i=1;i<aiMsgs.length-8&&total>120000;i++){ const m=aiMsgs[i]; if(m.role==='tool'&&m.content.length>600){ total-=m.content.length-300; m.content=m.content.slice(0,300)+'\n…（较早的输出已省略）'; } }
}
function curModel(){ return $('ai-model').value.trim()||$('ai-sel').value; }
let MODELS=[], mHasInfo=false, mTotal=0, mTesting=false, mStop=false, mTested=false;
function isFree(m){
  if(/:free$/.test(m.id)) return true;
  const p=m.pricing; if(!p) return false;
  return parseFloat(p.prompt)===0 && parseFloat(p.completion)===0;
}
function renderModels(){
  const sel=$('ai-sel'), prev=sel.value, freeOnly=$('ai-freeonly').checked;
  let list=MODELS.slice();
  if(freeOnly) list=list.filter(m=>m.free);
  if(mTested) list=list.filter(m=>m.ok===true).sort((a,b)=>a.ms-b.ms);
  else list.sort((a,b)=>(b.free-a.free)||a.id.localeCompare(b.id));
  const head=mTested?('已测通 '+list.length+' 个，按速度排序'):('共 '+list.length+' 个'+(freeOnly?'免费':'')+(mHasInfo?('，已筛出支持工具调用的，原有 '+mTotal+' 个'):''));
  sel.innerHTML='<option value="">请选择模型（'+head+'）</option>'+list.map(m=>'<option value="'+esc(m.id)+'">'+
    (m.ok===true?'✓ '+(m.ms/1000).toFixed(1)+'s  ':'')+(m.free&&!freeOnly?'【免费】':'')+esc(m.id)+'</option>').join('');
  if(prev&&list.some(m=>m.id===prev)) sel.value=prev;
  $('ai-test').disabled=!MODELS.length;
}
async function fetchModels(){
  const base=$('ai-base').value.trim(), key=$('ai-key').value.trim();
  if(!base||!key){ toast('请先填写 API 地址和 Key',2000); return; }
  if(mTesting){ toast('正在测试，先停止测试',1500); return; }
  const btn=$('ai-fetch'); btn.disabled=true; btn.textContent='获取中…';
  try{
    const r=await fetch('/ai',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({op:'models',base:base,key:key})});
    const txt=await r.text(); let j; try{ j=JSON.parse(txt); }catch(_){ throw new Error('HTTP '+r.status+'：'+txt.slice(0,200)); }
    if(!r.ok||j.error) throw new Error((j.error&&(j.error.message||JSON.stringify(j.error)))||('HTTP '+r.status));
    let list=(Array.isArray(j)?j:(j.data||j.models||[])).map(m=>typeof m==='string'?{id:m}:m).filter(m=>m&&(m.id||m.name));
    list.forEach(m=>{ m.id=m.id||m.name; });
    // 有的平台（如 OpenRouter）会标明是否支持工具调用、是否免费
    mHasInfo=list.some(m=>Array.isArray(m.supported_parameters));
    mTotal=list.length;
    if(mHasInfo) list=list.filter(m=>(m.supported_parameters||[]).indexOf('tools')>=0);
    if(!list.length) throw new Error('没有获取到可用模型');
    MODELS=list.map(m=>({id:m.id,free:isFree(m)}));
    const nFree=MODELS.filter(m=>m.free).length;
    $('ai-freebox').style.display=nFree?'':'none';
    $('ai-freeonly').checked=nFree>0;
    mTested=false; renderModels();
    $('ai-mstat').textContent=nFree?('其中免费 '+nFree+' 个。点“测试可用”只保留能回应的。'):'点“测试可用”只保留能回应的。';
    toast('获取到 '+MODELS.length+' 个模型',1500);
  }catch(e){ toast('获取模型失败：'+e.message,3500); }
  finally{ btn.disabled=false; btn.textContent='获取模型'; }
}
function errKind(st,msg){
  msg=String(msg||'');
  if(st===402||/credit|balance|insufficient|payment|quota|余额/i.test(msg)) return '需付费/余额不足';
  if(st===429||/rate.?limit|too many/i.test(msg)) return '限流';
  if(st===401||st===403) return '无权限';
  if(st===404||/no endpoints|not found|tool/i.test(msg)) return '不可用/不支持工具';
  if(st==='timeout') return '超时';
  return '其他错误';
}
async function testOne(base,key,m){
  const ac=new AbortController(), t0=Date.now(); const tm=setTimeout(()=>ac.abort(),25000);
  try{
    const r=await fetch('/ai',{method:'POST',headers:{'content-type':'application/json'},signal:ac.signal,
      body:JSON.stringify({base:base,key:key,body:{model:m.id,messages:[{role:'user',content:'ping，只回复 OK'}],tools:TOOLS,tool_choice:'auto',max_tokens:64,temperature:0}})});
    const txt=await r.text(); let j=null; try{ j=JSON.parse(txt); }catch(_){}
    if(r.ok&&j&&!j.error&&j.choices&&j.choices[0]&&j.choices[0].message){ m.ok=true; m.ms=Date.now()-t0; return; }
    m.ok=false; m.err=errKind(r.status,(j&&j.error&&(j.error.message||JSON.stringify(j.error)))||txt.slice(0,200));
  }catch(e){ m.ok=false; m.err=ac.signal.aborted&&!mStop?'超时':'已停止'; }
  finally{ clearTimeout(tm); }
}
async function testModels(){
  if(mTesting){ mStop=true; return; }
  const base=$('ai-base').value.trim(), key=$('ai-key').value.trim();
  if(!base||!key||!MODELS.length){ toast('请先获取模型',1500); return; }
  const freeOnly=$('ai-freeonly').checked;
  const todo=MODELS.filter(m=>!freeOnly||m.free);
  const nPaid=todo.filter(m=>!m.free).length;
  if(todo.length>40||nPaid) if(!confirm('将逐个测试 '+todo.length+' 个模型，大约需要 '+Math.ceil(todo.length/3*4/60)+' 分钟。'+
      (nPaid?('\n其中 '+nPaid+' 个是付费模型，每个测试会扣极少的费用（一次很短的对话）。'):'')+
      (freeOnly?'\n免费模型通常有每日请求次数上限，测试也会占用次数。':'')+'\n继续吗？')) return;
  MODELS.forEach(m=>{ delete m.ok; delete m.err; delete m.ms; });
  mTesting=true; mStop=false; const btn=$('ai-test'); btn.textContent='停止测试'; btn.classList.add('warn');
  let done=0, ok=0; const st=$('ai-mstat'); const q=todo.slice();
  const show=()=>{ st.textContent='测试中 '+done+'/'+todo.length+'，已测通 '+ok+' 个…'; };
  show();
  const worker=async()=>{ while(q.length&&!mStop){ const m=q.shift(); await testOne(base,key,m); done++; if(m.ok) ok++; show(); } };
  await Promise.all([worker(),worker(),worker()]);
  mTesting=false; btn.textContent='测试可用'; btn.classList.remove('warn');
  const fails={}; todo.forEach(m=>{ if(m.ok===false&&m.err!=='已停止') fails[m.err]=(fails[m.err]||0)+1; });
  const fs=Object.keys(fails).map(k=>k+' '+fails[k]).join('、');
  mTested=true; renderModels();
  st.textContent=(mStop?'已停止。':'')+'测试了 '+done+' 个，可用 '+ok+' 个'+(fs?('；失败：'+fs):'')+'。'+(fails['限流']?'被限流的可以稍后再测。':'')+'重新点“获取模型”可恢复完整列表。';
  if(ok){ const sel=$('ai-sel'); if(!sel.value&&sel.options.length>1) sel.selectedIndex=1; }
}
async function callAI(){
  const base=$('ai-base').value.trim(), key=$('ai-key').value.trim(), model=curModel();
  aiAbort=new AbortController();
  const r=await fetch('/ai',{method:'POST',headers:{'content-type':'application/json'},signal:aiAbort.signal,
    body:JSON.stringify({base:base,key:key,body:{model:model,messages:aiMsgs,tools:TOOLS,tool_choice:'auto',temperature:0.2}})});
  const txt=await r.text(); let j; try{ j=JSON.parse(txt); }catch(_){ throw new Error('接口返回异常（HTTP '+r.status+'）：'+txt.slice(0,300)); }
  if(!r.ok||j.error) throw new Error((j.error&&(j.error.message||JSON.stringify(j.error)))||('HTTP '+r.status));
  if(!j.choices||!j.choices[0]) throw new Error('接口没有返回结果：'+txt.slice(0,300));
  return j.choices[0].message||{};
}
async function aiSend(){
  const text=$('aitext').value.trim(); if(!text) return;
  if(!$('ai-key').value.trim()||!curModel()||!$('ai-base').value.trim()){ $('aiset').style.display='grid'; toast('请先填写 API 地址、Key，并选择模型',2200); return; }
  if(!ws||ws.readyState!==1){ toast('SSH 连接已断开',2000); return; }
  $('aitext').value=''; $('aiset').style.display='none';
  if(!aiMsgs.length) aiMsgs.push({role:'system',content:sysPrompt()});
  addMsg('u',esc(text));
  aiMsgs.push({role:'user',content:text+'\n\n（右侧文件面板当前所在目录：'+cwd+'）'});
  setBusy(true); aiStop=false;
  try{
    for(let step=0; step<50; step++){
      if(aiStop) throw new Error('已停止');
      trimHistory();
      const thinking=addMsg('s','思考中…');
      let msg; try{ msg=await callAI(); } finally { thinking.remove(); }
      const calls=msg.tool_calls||[];
      const clean={role:'assistant',content:msg.content||''}; if(calls.length) clean.tool_calls=calls;
      aiMsgs.push(clean);
      if(msg.content&&String(msg.content).trim()) addMsg('a',md(msg.content));
      if(!calls.length) break;
      for(const c of calls){
        let a={}; try{ a=JSON.parse(c.function&&c.function.arguments||'{}'); }catch(_){}
        const out=aiStop?'用户已停止':await runTool(c.function&&c.function.name,a);
        aiMsgs.push({role:'tool',tool_call_id:c.id,content:out});
      }
      if(step===49) addMsg('s','已连续执行很多步，先暂停。需要继续请回复“继续”。');
    }
  }catch(e){ if(aiStop||e.name==='AbortError') addMsg('s','已停止'); else addMsg('e','出错了：'+esc(e.message)); }
  finally{ setBusy(false); aiAbort=null; }
}
</script>
</body>
</html>`;
