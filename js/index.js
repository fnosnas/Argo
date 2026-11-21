#!/usr/bin/env node

const os = require('os');
const http = require('http');
const fs = require('fs');
const net = require('net');
const dns = require('dns');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const { Buffer } = require('buffer');
const axios = require('axios');
const { spawn, spawnSync } = require('child_process');
const { WebSocket, createWebSocketStream } = require('ws');

// ========================== 环境变量配置 ==========================
const UUID = process.env.UUID || 'd1cf4b9c-3e57-085d-b34a-797fcf801380'; // 节点UUID、tg-webproxy的secret
const KOMARI_SERVER = process.env.KOMARI_SERVER || '';     // komari面板地址，格式：https://km.xxx.com
const KOMARI_TOKEN = process.env.KOMARI_TOKEN || '';       // komari面板里该服务器的token
const DOMAIN = process.env.DOMAIN || 'your-domain.com';    // 项目分配的域名或回源后的域名,例如：xxx.xxx.com
const AUTO_ACCESS = process.env.AUTO_ACCESS || false;      // 是否开启自动访问保活，需确保DOMAIN可用
const SUB_PATH = process.env.SUB_PATH || 'sub';            // 订阅token
const NAME = process.env.NAME || '';                       // 节点名称
const PORT = process.env.PORT || 3000;                     // http+ws端口
const TLS_MODE = /^(1|true|yes|on)$/i.test(process.env.TLS || '');  // 可选：true 时由本程序直接开 TLS（平台只给 IP+端口时用）
const TLS_CERT = process.env.TLS_CERT || '';               // 可选：证书，文件路径或 PEM 内容；不填则自动生成自签证书
const TLS_KEY = process.env.TLS_KEY || '';                 // 可选：私钥，文件路径或 PEM 内容
const USE_PM2 = /^(1|true|yes)$/i.test(process.env.USE_PM2 || ''); // 可选：true 时自动交给 pm2 常驻（容器平台不要开）
const PM2_NAME = process.env.PM2_NAME || 'node-ws';        // pm2 进程名

// 日志控制 
const SHOW_LOG = /^(1|true|yes)$/i.test(process.env.SHOW_LOG || '');   // 默认关闭所有日志，SHOW_LOG=1 才输出
if (!SHOW_LOG) { const noop = () => {}; console.log = console.info = console.warn = console.error = console.debug = noop; }
function log(...args) { if (SHOW_LOG) console.log(...args); }
function logErr(...args) { if (SHOW_LOG) console.error(...args); }
function logWarn(...args) { if (SHOW_LOG) console.warn(...args); }

// 辅助工具
const WSPATH = process.env.WSPATH || UUID.slice(0, 8); // WS 路径
let uuid = UUID.replace(/-/g, ""), CurrentDomain = DOMAIN, Tls = 'tls', CurrentPort = 443, ISP = '';
const DNS_SERVERS = ['8.8.4.4', '1.1.1.1'];
const BLOCKED_DOMAINS = [
  'speedtest.net', 'fast.com', 'speedtest.cn', 'speed.cloudflare.com', 'speedof.me',
   'testmy.net', 'bandwidth.place', 'speed.io', 'librespeed.org', 'speedcheck.org'
];

// block speedtest domains
function isBlockedDomain(host) {
  if (!host) return false;
  const hostLower = host.toLowerCase();
  return BLOCKED_DOMAINS.some(blocked => {
    return hostLower === blocked || hostLower.endsWith('.' + blocked);
  });
}

// 获取isp
async function getisp() {
  if (!axios) { ISP = ''; return; }
  try {
    const res = await axios.get('https://api.ip.sb/geoip', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 }});
    const data = res.data;
    ISP = `${data.country_code}-${data.isp}`.replace(/ /g, '_');
  } catch (e) {
    try {
      const res2 = await axios.get('http://ip-api.com/json', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 }});
      const data2 = res2.data;
      ISP = `${data2.countryCode}-${data2.org}`.replace(/ /g, '_');
    } catch (e2) {
      ISP = 'Unknown';
    }
  }
}

// 获取ip
async function getip() {
  if (TLS_MODE) {
    // 本程序自己开 TLS：直连 域名或IP:PORT，走 tls
    let host = (DOMAIN && DOMAIN !== 'your-domain.com') ? DOMAIN : '';
    if (!host) { try { host = String((await axios.get('https://api-ipv4.ip.sb/ip', { timeout: 5000 })).data).trim(); } catch (e) { host = 'cahnge-your-domain.com'; } }
    CurrentDomain = host, Tls = 'tls', CurrentPort = PORT;
    return;
  }
  if (!DOMAIN || DOMAIN === 'your-domain.com') {
      try {
          const res = await axios.get('https://api-ipv4.ip.sb/ip', { timeout: 5000 });
          const ip = res.data.trim();
          CurrentDomain = ip, Tls = 'none', CurrentPort = PORT;
      } catch (e) {
          console.error('Failed to get IP', e.message);
          CurrentDomain = 'cahnge-your-domain.com', Tls = 'tls', CurrentPort = 443;
      }
  } else {
      CurrentDomain = DOMAIN, Tls = 'tls', CurrentPort = 443;
  }
}

// HTTP 路由
async function requestHandler(req, res) {
  try { if (await tgRoute(req, res)) return; } catch (e) { console.error('[TG] route error:', e.message); }
  if (req.url === '/') {
    const filePath = path.join(__dirname, 'index.html');
    fs.readFile(filePath, 'utf8', (err, content) => {
      if (err) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end('Hello world!');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(content);
    });
    return;
  } else if (req.url === `/${SUB_PATH}`) {
    await getisp();await getip();
    const namePart = NAME ? `${NAME}-${ISP}` : ISP;
    const tlsParam = Tls === 'tls' ? 'tls' : 'none';
    const insecure = TLS_MODE && tlsSelfSigned ? '&allowInsecure=1&insecure=1' : '';
    const ssTlsParam = Tls === 'tls' ? 'tls;' : '';
    const vlsURL = `vless://${UUID}@${CurrentDomain}:${CurrentPort}?encryption=none&security=${tlsParam}&sni=${CurrentDomain}&fp=chrome${insecure}&type=ws&host=${CurrentDomain}&path=%2F${WSPATH}#${namePart}`;
    const troURL = `trojan://${UUID}@${CurrentDomain}:${CurrentPort}?security=${tlsParam}&sni=${CurrentDomain}&fp=chrome${insecure}&type=ws&host=${CurrentDomain}&path=%2F${WSPATH}#${namePart}`;
    const ssMethodPassword = Buffer.from(`none:${UUID}`).toString('base64');
    const ssURL = `ss://${ssMethodPassword}@${CurrentDomain}:${CurrentPort}?plugin=v2ray-plugin;mode%3Dwebsocket;host%3D${CurrentDomain};path%3D%2F${WSPATH};${ssTlsParam}sni%3D${CurrentDomain};skip-cert-verify%3Dtrue;mux%3D0#${namePart}`;
    const subscription = vlsURL + '\n' + troURL + '\n' + ssURL;
    const base64Content = Buffer.from(subscription).toString('base64');

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(base64Content + '\n');
  } else if (req.url === `/${SUB_PATH}-tg`) {
    await getip();
    const tgLink = `https://t.me/webproxy?server=${CurrentDomain}&secret=${uuid}`;
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('TG Webproxy link:' + '\n\n'+ tgLink);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found\n');
  }
}
const httpServer = http.createServer(requestHandler);

// Custom DNS
function resolveHost(host) {
  return new Promise((resolve, reject) => {
    if (/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/.test(host)) {
      resolve(host);
      return;
    }
    let attempts = 0;
    function tryNextDNS() {
      if (!axios) {
        dns.promises.resolve4(host).then(resolve, () => reject(new Error(`Failed to resolve ${host}`)));
        return;
      }
      if (attempts >= DNS_SERVERS.length) {
        reject(new Error(`Failed to resolve ${host} with all DNS servers`));
        return;
      }
      const dnsServer = DNS_SERVERS[attempts];
      attempts++;
      const dnsQuery = `https://dns.google/resolve?name=${encodeURIComponent(host)}&type=A`;
      axios.get(dnsQuery, {
        timeout: 5000,
        headers: { 'Accept': 'application/dns-json' }
      })
        .then(response => {
          const data = response.data;
          if (data.Status === 0 && data.Answer && data.Answer.length > 0) {
            const ip = data.Answer.find(record => record.type === 1);
            if (ip) { resolve(ip.data); return; }
          }
          tryNextDNS();
        })
        .catch(error => { tryNextDNS(); });
    }
    tryNextDNS();
  });
}

// VLE-SS处理
function handleVlsConnection(ws, msg) {
  const [VERSION] = msg;
  const id = msg.slice(1, 17);
  if (!id.every((v, i) => v == parseInt(uuid.substr(i * 2, 2), 16))) return false;

  let i = msg.slice(17, 18).readUInt8() + 19;
  const port = msg.slice(i, i += 2).readUInt16BE(0);
  const ATYP = msg.slice(i, i += 1).readUInt8();
  const host = ATYP == 1 ? msg.slice(i, i += 4).join('.') :
    (ATYP == 2 ? new TextDecoder().decode(msg.slice(i + 1, i += 1 + msg.slice(i, i + 1).readUInt8())) :
      (ATYP == 3 ? msg.slice(i, i += 16).reduce((s, b, i, a) => (i % 2 ? s.concat(a.slice(i - 1, i + 1)) : s), []).map(b => b.readUInt16BE(0).toString(16)).join(':') : ''));

  if (isBlockedDomain(host)) { ws.close(); return false; }
  ws.send(new Uint8Array([VERSION, 0]));
  const duplex = createWebSocketStream(ws);
  resolveHost(host)
    .then(resolvedIP => {
      net.connect({ host: resolvedIP, port }, function () {
        this.write(msg.slice(i));
        duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
      }).on('error', () => { });
    })
    .catch(error => {
      net.connect({ host, port }, function () {
        this.write(msg.slice(i));
        duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
      }).on('error', () => { });
    });
  return true;
}

// Tro-jan处理
function handleTrojConnection(ws, msg) {
  try {
    if (msg.length < 58) return false;
    const receivedPasswordHash = msg.slice(0, 56).toString();
    const possiblePasswords = [UUID];
    let matchedPassword = null;
    for (const pwd of possiblePasswords) {
      const hash = crypto.createHash('sha224').update(pwd).digest('hex');
      if (hash === receivedPasswordHash) { matchedPassword = pwd; break; }
    }
    if (!matchedPassword) return false;
    let offset = 56;
    if (msg[offset] === 0x0d && msg[offset + 1] === 0x0a) offset += 2;
    const cmd = msg[offset];
    if (cmd !== 0x01) return false;
    offset += 1;
    const atyp = msg[offset];
    offset += 1;
    let host, port;
    if (atyp === 0x01) {
      host = msg.slice(offset, offset + 4).join('.'); offset += 4;
    } else if (atyp === 0x03) {
      const hostLen = msg[offset]; offset += 1;
      host = msg.slice(offset, offset + hostLen).toString(); offset += hostLen;
    } else if (atyp === 0x04) {
      host = msg.slice(offset, offset + 16).reduce((s, b, i, a) => (i % 2 ? s.concat(a.slice(i - 1, i + 1)) : s), []).map(b => b.readUInt16BE(0).toString(16)).join(':'); offset += 16;
    } else { return false; }
    port = msg.readUInt16BE(offset); offset += 2;
    if (offset < msg.length && msg[offset] === 0x0d && msg[offset + 1] === 0x0a) offset += 2;
    if (isBlockedDomain(host)) { ws.close(); return false; }
    const duplex = createWebSocketStream(ws);
    resolveHost(host)
      .then(resolvedIP => {
        net.connect({ host: resolvedIP, port }, function () {
          if (offset < msg.length) this.write(msg.slice(offset));
          duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
        }).on('error', () => { });
      })
      .catch(error => {
        net.connect({ host, port }, function () {
          if (offset < msg.length) this.write(msg.slice(offset));
          duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
        }).on('error', () => { });
      });
    return true;
  } catch (error) { return false; }
}

// Ss处理
function handleSsConnection(ws, msg) {
  try {
    let offset = 0;
    const atyp = msg[offset]; offset += 1;
    let host, port;
    if (atyp === 0x01) {
      host = msg.slice(offset, offset + 4).join('.'); offset += 4;
    } else if (atyp === 0x03) {
      const hostLen = msg[offset]; offset += 1;
      host = msg.slice(offset, offset + hostLen).toString(); offset += hostLen;
    } else if (atyp === 0x04) {
      host = msg.slice(offset, offset + 16).reduce((s, b, i, a) => (i % 2 ? s.concat(a.slice(i - 1, i + 1)) : s), []).map(b => b.readUInt16BE(0).toString(16)).join(':'); offset += 16;
    } else { return false; }
    port = msg.readUInt16BE(offset); offset += 2;
    if (isBlockedDomain(host)) { ws.close(); return false; }
    const duplex = createWebSocketStream(ws);
    resolveHost(host)
      .then(resolvedIP => {
        net.connect({ host: resolvedIP, port }, function () {
          if (offset < msg.length) this.write(msg.slice(offset));
          duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
        }).on('error', () => { });
      })
      .catch(error => {
        net.connect({ host, port }, function () {
          if (offset < msg.length) this.write(msg.slice(offset));
          duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
        }).on('error', () => { });
      });
    return true;
  } catch (error) { return false; }
}

// Ws handler
const wss = new WebSocket.Server({ noServer: true });
// WS 路径分发：/${WSPATH} -> vless/trojan/ss；/api/v1/ws -> Telegram WEB Proxy
function upgradeHandler(req, socket, head) {
  const url = req.url || '';
  if (url === '/api/v1/ws') {
    tgWsUpgrade(req, socket, head);
  } else if (url.startsWith(`/${WSPATH}`)) {
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  } else {
    socket.destroy();
  }
}
httpServer.on('upgrade', upgradeHandler);
wss.on('connection', (ws, req) => {
  const url = req.url || '';
  const expectedPath = `/${WSPATH}`;
  if (!url.startsWith(expectedPath)) { ws.close(); return; }

  ws.once('message', msg => {
    if (msg.length > 17 && msg[0] === 0) {
      const id = msg.slice(1, 17);
      const isVless = id.every((v, i) => v == parseInt(uuid.substr(i * 2, 2), 16));
      if (isVless) { if (!handleVlsConnection(ws, msg)) ws.close(); return; }
    }
    if (msg.length >= 58) { if (handleTrojConnection(ws, msg)) return; }
    if (msg.length > 0 && (msg[0] === 0x01 || msg[0] === 0x03 || msg[0] === 0x04)) {
      if (handleSsConnection(ws, msg)) return;
    }
    ws.close();
  }).on('error', () => { });
});

// 添加自动保活任务
async function addAccessTask() {
  if (!AUTO_ACCESS || !axios) return;
  if (!DOMAIN) return;
  const fullURL = `https://${DOMAIN}/${SUB_PATH}`;
  try {
    const res = await axios.post("https://oooo.serv00.net/add-url", { url: fullURL }, { headers: { 'Content-Type': 'application/json' } });
    console.log('Automatic Access Task added successfully');
  } catch (error) { }
}

// ==================== Komari-Agent（纯 JS，内置在 Node 里，不下载任何程序） ====================
// 协议与官方 komari-agent 1.6.x 相同：v2 JSON-RPC
//   上报基础信息：POST  {面板}/api/clients/v2/rpc?token=xxx   method=agent.basicInfo
//   实时状态：    WS    {面板}/api/clients/v2/rpc?token=xxx   method=agent.report（每 3 秒）
//   WS 连不上时自动改用 POST 上报 + 拉取任务，同时每 30 秒尝试恢复 WS
//   支持：网页终端（agent.terminal.request）、远程命令（agent.exec）、延迟检测（agent.ping）
// 保活方式与原哪吒 agent 一样：跟随 Node 进程运行，断线 10 秒后自动重连，永不退出
const KOMARI_VERSION = 'nodejs-komari-1.0.0';
const REPORT_INTERVAL = 3000;      // 状态上报间隔
const RETRY_DELAY = 10000;         // 断线重连间隔
const INFO_INTERVAL = 5 * 60000;   // 基础信息刷新间隔
const IP_REFRESH = 30 * 60000;     // 公网 IP 刷新间隔
const KOMARI_SSH = !/^(1|true|yes)$/i.test(process.env.KOMARI_DISABLE_SSH || ''); // KOMARI_DISABLE_SSH=true 关闭网页终端和远程命令

const EXCLUDE_IFACES = ['lo', 'tun', 'docker', 'veth', 'br-', 'vmbr', 'vnet', 'kube', 'Meta', 'tailscale', 'fw', 'tap', 'cni', 'flannel', 'cali'];
let komariEndpoint = '', komariWs = null, komariWsAlive = false;
let lastCpu = null, lastNet = null, cachedIP = { ipv4: '', ipv6: '', at: 0 };
const ackIds = [];
const seenEvents = new Map();

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
function readText(f) { try { return fs.readFileSync(f, 'utf8'); } catch (e) { return ''; } }
function goArch() { return { x64: 'amd64', arm64: 'arm64', ia32: '386', arm: 'arm', s390x: 's390x', ppc64: 'ppc64le' }[process.arch] || process.arch; }

// ---------- 系统信息 ----------
function osName() {
  const rel = readText('/etc/os-release');
  const m = rel.match(/^PRETTY_NAME="?([^"\n]+)"?/m);
  if (m) return m[1];
  return `${os.type()} ${os.release()}`;
}

function virtualization() {
  if (fs.existsSync('/.dockerenv')) return 'docker';
  if (fs.existsSync('/run/.containerenv')) return 'podman';
  const cg = readText('/proc/1/cgroup');
  if (/kubepods/.test(cg)) return 'kubernetes';
  if (/docker|containerd/.test(cg)) return 'docker';
  if (/lxc/.test(cg) || /container=lxc/.test(readText('/proc/1/environ'))) return 'lxc';
  return '';
}

// 容器里优先用 cgroup 的内存上限，否则用 /proc/meminfo，最后用 os 模块
function cgroupMem() {
  let max = readText('/sys/fs/cgroup/memory.max').trim(), cur = readText('/sys/fs/cgroup/memory.current').trim();
  if (!max) { max = readText('/sys/fs/cgroup/memory/memory.limit_in_bytes').trim(); cur = readText('/sys/fs/cgroup/memory/memory.usage_in_bytes').trim(); }
  const total = Number(max), used = Number(cur);
  if (!total || !isFinite(total) || total <= 0 || total >= os.totalmem() || !used) return null;
  let cache = 0;
  const stat = readText('/sys/fs/cgroup/memory.stat') || readText('/sys/fs/cgroup/memory/memory.stat');
  const m = stat.match(/^(?:inactive_file|total_inactive_file) (\d+)/m);
  if (m) cache = Number(m[1]);
  return { total, used: Math.max(0, used - cache) };
}

function memInfo() {
  const info = {};
  readText('/proc/meminfo').split('\n').forEach(l => { const m = l.match(/^(\w+):\s+(\d+)/); if (m) info[m[1]] = Number(m[2]) * 1024; });
  let total = info.MemTotal || os.totalmem();
  let used = info.MemAvailable !== undefined ? total - info.MemAvailable : total - os.freemem();
  const cg = cgroupMem();
  if (cg) { total = cg.total; used = cg.used; }
  return { total, used: Math.max(0, used), swapTotal: info.SwapTotal || 0, swapUsed: Math.max(0, (info.SwapTotal || 0) - (info.SwapFree || 0)) };
}

function diskInfo() {
  try {
    if (fs.statfsSync) {
      const s = fs.statfsSync('/');
      const total = s.blocks * s.bsize;
      return { total, used: Math.max(0, total - s.bfree * s.bsize) };
    }
  } catch (e) { }
  try {
    const out = spawnSync('df', ['-kP', '/'], { encoding: 'utf8', timeout: 5000 }).stdout || '';
    const p = out.trim().split('\n').pop().split(/\s+/);
    if (p.length >= 4) return { total: Number(p[1]) * 1024, used: Number(p[2]) * 1024 };
  } catch (e) { }
  return { total: 0, used: 0 };
}

function cpuUsage() {
  let idle = 0, total = 0;
  const line = readText('/proc/stat').split('\n')[0];
  if (line.startsWith('cpu ')) {
    const v = line.trim().split(/\s+/).slice(1).map(Number);
    idle = v[3] + (v[4] || 0); total = v.slice(0, 8).reduce((a, b) => a + b, 0);
  } else {
    for (const c of os.cpus()) { const t = c.times; idle += t.idle; total += t.user + t.nice + t.sys + t.idle + t.irq; }
  }
  let usage = 0.001;
  if (lastCpu && total > lastCpu.total) usage = Math.max(0.001, (1 - (idle - lastCpu.idle) / (total - lastCpu.total)) * 100);
  lastCpu = { idle, total };
  return Math.round(usage * 100) / 100;
}

function netInfo() {
  let rx = 0, tx = 0;
  readText('/proc/net/dev').split('\n').slice(2).forEach(l => {
    const m = l.trim().match(/^([^:]+):\s*(.*)$/);
    if (!m || EXCLUDE_IFACES.some(x => m[1].includes(x))) return;
    const v = m[2].split(/\s+/).map(Number);
    rx += v[0] || 0; tx += v[8] || 0;
  });
  const now = Date.now();
  let up = 0, down = 0;
  if (lastNet && now > lastNet.t) {
    const dt = (now - lastNet.t) / 1000;
    down = Math.max(0, Math.round((rx - lastNet.rx) / dt));
    up = Math.max(0, Math.round((tx - lastNet.tx) / dt));
  }
  lastNet = { rx, tx, t: now };
  return { up, down, totalUp: tx, totalDown: rx };
}

function connCount() {
  const n = f => Math.max(0, readText(f).split('\n').filter(Boolean).length - 1);
  return { tcp: n('/proc/net/tcp') + n('/proc/net/tcp6'), udp: n('/proc/net/udp') + n('/proc/net/udp6') };
}

function procCount() {
  try { return fs.readdirSync('/proc').filter(d => /^\d+$/.test(d)).length; } catch (e) { return 0; }
}

async function fetchIP() {
  if (cachedIP.at && Date.now() - cachedIP.at < IP_REFRESH) return cachedIP;
  const get = async (urls, family) => {
    for (const url of urls) {
      try {
        const r = await axios.get(url, { timeout: 8000, responseType: 'text', headers: { 'User-Agent': 'Mozilla/5.0' }, lookup: (h, o, cb) => dns.lookup(h, { family }, cb) });
        const body = String(r.data).trim();
        const ip = (body.match(/^ip=(.+)$/m) || [null, body])[1].trim();
        if ((family === 4 && net.isIPv4(ip)) || (family === 6 && net.isIPv6(ip))) return ip;
      } catch (e) { }
    }
    return '';
  };
  const [ipv4, ipv6] = await Promise.all([
    get(['https://api-ipv4.ip.sb/ip', 'https://www.cloudflare.com/cdn-cgi/trace'], 4),
    get(['https://api-ipv6.ip.sb/ip', 'https://www.cloudflare.com/cdn-cgi/trace'], 6),
  ]);
  cachedIP = { ipv4, ipv6, at: Date.now() };
  return cachedIP;
}

function cpuName() {
  const c = (os.cpus() || [])[0];
  if (c && c.model && !/^unknown$/i.test(c.model.trim())) return c.model.trim();
  const info = readText('/proc/cpuinfo');
  for (const key of ['model name', 'Hardware', 'cpu model', 'Processor']) {
    const m = info.match(new RegExp(`^${key}\\s*:\\s*(.+)$`, 'mi'));
    if (m && !/^\d+$/.test(m[1].trim())) return m[1].trim();
  }
  return `${goArch()} CPU`;
}

async function basicInfo() {
  const cpus = os.cpus() || [];
  const mem = memInfo(), disk = diskInfo(), ip = await fetchIP();
  return {
    cpu_name: cpuName(), cpu_cores: cpus.length || 1, cpu_physical_cores: 0,
    arch: goArch(), os: osName(), kernel_version: os.release(), ipv4: ip.ipv4, ipv6: ip.ipv6,
    mem_total: mem.total, swap_total: mem.swapTotal, disk_total: disk.total, gpu_name: '',
    virtualization: virtualization(), version: KOMARI_VERSION,
  };
}

function buildReport() {
  const mem = memInfo(), disk = diskInfo(), load = os.loadavg();
  return {
    cpu: { usage: cpuUsage() },
    ram: { total: mem.total, used: mem.used },
    swap: { total: mem.swapTotal, used: mem.swapUsed },
    load: { load1: load[0] || 0, load5: load[1] || 0, load15: load[2] || 0 },
    disk: { total: disk.total, used: disk.used },
    network: netInfo(),
    connections: connCount(),
    uptime: Math.floor(os.uptime()),
    process: procCount(),
    message: '',
  };
}

// ---------- 通信 ----------
function rpcMsg(method, params, id) {
  const m = { jsonrpc: '2.0', method, params };
  if (id !== undefined) m.id = id;
  return m;
}

async function postRpc(msg, timeout = 30000) {
  const r = await axios.post(`${komariEndpoint}/api/clients/v2/rpc?token=${encodeURIComponent(KOMARI_TOKEN)}`, msg, {
    timeout, proxy: false, headers: { 'Content-Type': 'application/json' }, validateStatus: () => true,
  });
  if (r.status !== 200) throw new Error(`HTTP ${r.status}`);
  const data = typeof r.data === 'string' && r.data.trim() ? JSON.parse(r.data) : r.data;
  if (data && data.error) throw new Error(`rpc error ${data.error.code}: ${data.error.message}`);
  return data;
}

// 优先走已连上的 WS，否则走 POST
async function sendRpc(msg) {
  if (komariWsAlive && komariWs && komariWs.readyState === WebSocket.OPEN) {
    try { komariWs.send(JSON.stringify(msg)); return; } catch (e) { }
  }
  try { await postRpc(msg); } catch (e) { logErr('[Komari] POST 失败:', e.message); }
}

async function uploadBasicInfo() {
  try { await postRpc(rpcMsg('agent.basicInfo', { info: await basicInfo() }, 'basic-info')); log('[Komari] 基础信息上报成功'); return true; }
  catch (e) { logErr('[Komari] 基础信息上报失败:', e.message); return false; }
}

function markSeen(id) {
  if (!id) return true;
  const now = Date.now();
  for (const [k, t] of seenEvents) if (now - t > 600000) seenEvents.delete(k);
  if (seenEvents.has(id)) return false;
  seenEvents.set(id, now);
  return true;
}

function handleEvent(method, params, eventId) {
  if (!markSeen(eventId)) return true;
  params = params || {};
  switch (method) {
    case 'agent.exec': runExecTask(params.task_id, params.command); return true;
    case 'agent.ping': runPingTask(params.ping_task_id, params.ping_type, params.ping_target); return true;
    case 'agent.terminal.request': if (params.request_id) startTerminal(params.request_id); return true;
    case 'agent.message': case 'agent.event': log('[Komari] 收到消息:', JSON.stringify(params)); return true;
    default: log('[Komari] 不支持的任务:', method); return false;
  }
}

function processEvents(resp) {
  const events = resp && resp.result && resp.result.events;
  if (!Array.isArray(events)) return;
  for (const ev of events) if (handleEvent(ev.method, ev.params, ev.id) && ev.id) ackIds.push(ev.id);
}

// ---------- 远程命令 ----------
function runExecTask(taskId, command) {
  if (!taskId) return;
  let sent = false;
  const done = (result, code) => { if (sent) return; sent = true; sendRpc(rpcMsg('agent.taskResult', { task_id: taskId, result, exit_code: code, finished_at: new Date().toISOString() })); };
  if (!String(command || '').trim()) return done('No command provided', 0);
  if (!KOMARI_SSH) return done('Remote control is disabled.', -1);
  let out = '', err = '';
  let child;
  try {
    child = process.platform === 'win32'
      ? spawn('powershell', ['-NoProfile', '-Command', command])
      : spawn('sh', ['-s'], { stdio: ['pipe', 'pipe', 'pipe'] });
  } catch (e) { return done(e.message, -1); }
  child.stdout.on('data', d => out += d);
  child.stderr.on('data', d => err += d);
  child.on('error', e => done(e.message, -1));
  child.on('close', code => done((err ? (out ? out + '\n' + err : err) : out).replace(/\r\n/g, '\n'), code === null ? -1 : code));
  if (process.platform !== 'win32') { child.stdin.write(command); child.stdin.end(); }
}

// ---------- 延迟检测 ----------
function tcpPing(target, timeout) {
  return new Promise((resolve) => {
    let host = target, port = 80;
    const m = target.match(/^\[?([^\]]+?)\]?:(\d+)$/);
    if (m && !net.isIPv6(target)) { host = m[1]; port = Number(m[2]); }
    dns.lookup(host.replace(/^\[|\]$/g, ''), (e, addr) => {
      if (e) return resolve(-1);
      const start = Date.now();
      const s = net.connect({ host: addr, port, timeout });
      s.on('connect', () => { resolve(Date.now() - start); s.destroy(); });
      s.on('timeout', () => { resolve(-1); s.destroy(); });
      s.on('error', () => resolve(-1));
    });
  });
}

function httpPing(target, timeout) {
  return new Promise((resolve) => {
    let url = target;
    if (net.isIPv6(url)) url = `[${url}]`;
    if (!/^https?:\/\//.test(url)) url = 'http://' + url;
    const start = Date.now();
    axios.get(url, { timeout, maxRedirects: 0, validateStatus: s => s >= 200 && s < 400 })
      .then(() => resolve(Date.now() - start)).catch(() => resolve(-1));
  });
}

function icmpPing(target, timeout) {
  return new Promise((resolve) => {
    try {
      const args = process.platform === 'win32' ? ['-n', '1', '-w', String(timeout), target] : ['-c', '1', '-W', String(Math.ceil(timeout / 1000)), target];
      const c = spawn('ping', args);
      let out = '';
      c.stdout.on('data', d => out += d);
      c.on('error', () => resolve(null));          // 没有 ping 命令
      c.on('close', () => { const m = out.match(/time[=<]\s*([\d.]+)\s*ms/i); resolve(m ? Math.round(Number(m[1])) : -1); });
    } catch (e) { resolve(null); }
  });
}

async function runPingTask(taskId, type, target) {
  if (!taskId || !target) return;
  const timeout = 3000;
  let value = -1;
  if (type === 'tcp') value = await tcpPing(target, timeout);
  else if (type === 'http') value = await httpPing(target, timeout);
  else if (type === 'icmp') { const v = await icmpPing(target, timeout); value = v === null ? await tcpPing(target, timeout) : v; } // 容器没有 ping 权限时用 TCP 80 代替
  sendRpc(rpcMsg('agent.pingResult', { task_id: taskId, ping_type: type, value, finished_at: new Date().toISOString() }));
}

// ---------- 网页终端 ----------
function spawnShell() {
  const shell = process.env.SHELL || (process.platform === 'win32' ? 'powershell.exe' : (fs.existsSync('/bin/bash') ? '/bin/bash' : '/bin/sh'));
  const env = { ...process.env, TERM: 'xterm-256color' };
  const cwd = process.env.HOME || process.cwd();
  try {
    const pty = require('node-pty');
    const p = pty.spawn(shell, [], { name: 'xterm-256color', cols: 80, rows: 30, cwd, env });
    return { write: d => p.write(d), onData: cb => p.onData(d => cb(Buffer.from(d))), resize: (c, r) => p.resize(c, r), kill: () => p.kill(), onExit: cb => p.onExit(() => cb()) };
  } catch (e) { }
  // 没有 node-pty 时降级：script / python pty / 普通 shell
  const tries = process.platform === 'win32' ? [[shell, []]] : [
    ['script', ['-qfc', `${shell} -i`, '/dev/null']],
    ['python3', ['-c', 'import pty,os;pty.spawn([os.environ.get("SHELL","/bin/sh"),"-i"])']],
    ['python', ['-c', 'import pty,os;pty.spawn([os.environ.get("SHELL","/bin/sh"),"-i"])']],
    [shell, ['-i']],
  ];
  for (const [cmd, args] of tries) {
    try {
      const r = spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd], { stdio: 'ignore' });
      if (r.status !== 0 && !cmd.startsWith('/')) continue;
      const c = spawn(cmd, args, { cwd, env: { ...env, SHELL: shell }, stdio: ['pipe', 'pipe', 'pipe'], detached: process.platform !== 'win32' });
      if (!c.pid) continue;
      return {
        write: d => { try { c.stdin.write(d); } catch (e) { } },
        onData: cb => { c.stdout.on('data', cb); c.stderr.on('data', cb); },
        resize: () => { },
        kill: () => { try { process.kill(-c.pid, 'SIGKILL'); } catch (e) { } try { c.kill('SIGKILL'); } catch (e) { } },
        onExit: cb => { c.on('exit', cb); c.on('error', cb); },
      };
    } catch (e) { }
  }
  return null;
}

function startTerminal(requestId) {
  const url = `${komariEndpoint.replace(/^http/i, 'ws')}/api/clients/terminal?token=${encodeURIComponent(KOMARI_TOKEN)}&id=${encodeURIComponent(requestId)}`;
  const ws = new WebSocket(url, { handshakeTimeout: 15000 });
  let term = null, closed = false, hb = null;
  const close = () => {
    if (closed) return; closed = true;
    if (hb) clearInterval(hb);
    if (term) term.kill();
    try { ws.close(); } catch (e) { }
  };
  ws.on('open', () => {
    if (!KOMARI_SSH || !(term = spawnShell())) {
      try { ws.send(JSON.stringify({ type: 'terminate' })); } catch (e) { }
      logErr('[Komari] 网页终端不可用（已关闭或无法创建 shell）');
      return close();
    }
    log('[Komari] 网页终端已连接:', requestId);
    term.onData(d => { if (!closed && ws.readyState === WebSocket.OPEN) ws.send(d, { binary: true }); });
    term.onExit(() => { try { ws.send(JSON.stringify({ type: 'terminate' })); } catch (e) { } close(); });
    hb = setInterval(() => { try { ws.ping(); } catch (e) { } }, 30000);
  });
  ws.on('message', (data, isBinary) => {
    if (!term) return;
    if (isBinary) return term.write(data);
    let cmd = null;
    try { cmd = JSON.parse(data.toString()); } catch (e) { }
    if (!cmd || !cmd.type) return term.write(data);
    switch (cmd.type) {
      case 'resize': if (cmd.cols > 0 && cmd.rows > 0) { try { term.resize(cmd.cols, cmd.rows); } catch (e) { } } break;
      case 'input': if (cmd.input) term.write(cmd.input); break;
      case 'terminate': case 'close': case 'abort': close(); break;
      case 'heartbeat': if (cmd.id) { try { ws.send(JSON.stringify({ type: 'heartbeat', id: cmd.id })); } catch (e) { } } break;
    }
  });
  ws.on('close', close);
  ws.on('error', (e) => { logErr('[Komari] 终端连接错误:', e.message); close(); });
}

// ---------- 主循环 ----------
function connectWs() {
  return new Promise((resolve) => {
    const url = `${komariEndpoint.replace(/^http/i, 'ws')}/api/clients/v2/rpc?token=${encodeURIComponent(KOMARI_TOKEN)}`;
    const ws = new WebSocket(url, { handshakeTimeout: 15000 });
    let opened = false;
    ws.once('open', () => { opened = true; resolve(ws); });
    ws.once('error', (e) => { if (!opened) { logErr('[Komari] WS 连接失败:', e.message); resolve(null); } });
    ws.once('unexpected-response', (req, res) => { if (!opened) { logErr('[Komari] WS 连接失败: HTTP', res.statusCode); resolve(null); try { req.destroy(); } catch (e) { } } });
  });
}

async function runWsSession(ws) {
  komariWs = ws; komariWsAlive = true;
  console.log('komari agent is running...');
  ws.on('message', (raw) => {
    try { const m = JSON.parse(raw.toString()); if (m && m.jsonrpc === '2.0' && m.method) handleEvent(m.method, m.params, ''); } catch (e) { }
  });
  await new Promise((resolve) => {
    let lastPong = Date.now();
    ws.on('pong', () => lastPong = Date.now());
    const report = setInterval(() => {
      try { ws.send(JSON.stringify(rpcMsg('agent.report', { report: buildReport() }))); }
      catch (e) { ws.terminate(); }
    }, REPORT_INTERVAL);
    const heart = setInterval(() => {
      if (Date.now() - lastPong > 90000) { logErr('[Komari] 心跳超时'); return ws.terminate(); }
      try { ws.ping(); } catch (e) { ws.terminate(); }
    }, 30000);
    const finish = () => { clearInterval(report); clearInterval(heart); resolve(); };
    ws.on('close', finish);
    ws.on('error', (e) => { logErr('[Komari] WS 错误:', e.message); try { ws.terminate(); } catch (_) { } });
  });
  komariWsAlive = false; komariWs = null;
}

// WS 用不了时：POST 上报 + 拉取任务，每 30 秒试一次恢复 WS
async function runPostFallback() {
  log('[Komari] 进入 POST 上报模式');
  let stop = false;
  const pull = (async () => {
    while (!stop) {
      try {
        const ids = ackIds.splice(0);
        processEvents(await postRpc(rpcMsg('agent.pull', { capabilities: ['exec', 'ping', 'message', 'event', 'terminal'], ack_event_ids: ids }, `pull-${Date.now()}`), 40000));
      } catch (e) { if (!stop) await sleep(RETRY_DELAY); }
    }
  })();
  let nextWsTry = Date.now() + 30000;
  while (true) {
    try {
      const ids = ackIds.splice(0);
      processEvents(await postRpc(rpcMsg('agent.report', { report: buildReport(), ack_event_ids: ids }, `report-${Date.now()}`)));
    } catch (e) { logErr('[Komari] POST 上报失败:', e.message); }
    if (Date.now() >= nextWsTry) {
      nextWsTry = Date.now() + 30000;
      const ws = await connectWs();
      if (ws) { stop = true; pull.catch(() => { }); return ws; }
    }
    await sleep(REPORT_INTERVAL);
  }
}

async function startKomariAgent() {
  if (!KOMARI_SERVER || !KOMARI_TOKEN) {
    console.log('[Komari] KOMARI_SERVER 或 KOMARI_TOKEN 未配置，跳过 komari agent');
    return;
  }
  komariEndpoint = (/^https?:\/\//i.test(KOMARI_SERVER) ? KOMARI_SERVER : `https://${KOMARI_SERVER}`).replace(/\/+$/, '');
  log('[Komari] 面板:', komariEndpoint);
  cpuUsage(); netInfo();   // 先取一次基准值，第一次上报的 CPU 和网速才准确

  setInterval(() => { uploadBasicInfo(); }, INFO_INTERVAL);
  let fails = 0;
  while (true) {
    try {
      await uploadBasicInfo();
      let ws = await connectWs();
      if (!ws && ++fails >= 3) { ws = await runPostFallback(); }
      if (ws) { fails = 0; await runWsSession(ws); log('[Komari] WS 已断开'); }
    } catch (e) { logErr('[Komari] 连接异常:', e.message); }
    await sleep(RETRY_DELAY);
  }
}

// pm2 常驻：USE_PM2=true 时，若当前不是 pm2 启动的，就交给 pm2 托管自己后退出
function hasCmd(cmd, args = ['-v']) {
  try { return !spawnSync(cmd, args, { stdio: 'ignore', timeout: 60000, shell: process.platform === 'win32' }).error; } catch (_) { return false; }
}
function handoffToPm2() {
  if (!USE_PM2 || process.env.pm_id !== undefined) return false;
  let pm2 = null;
  if (hasCmd('pm2')) pm2 = ['pm2'];
  else {
    console.log('[PM2] 未安装，尝试 npm i -g pm2 ...');
    spawnSync('npm', ['i', '-g', 'pm2'], { stdio: SHOW_LOG ? 'inherit' : 'ignore', timeout: 180000, shell: process.platform === 'win32' });
    if (hasCmd('pm2')) pm2 = ['pm2'];
    else if (hasCmd('npx', ['--yes', 'pm2', '-v'])) pm2 = ['npx', '--yes', 'pm2'];
  }
  if (!pm2) { console.error('[PM2] 装不上 pm2，改为直接运行'); return false; }
  const [cmd, ...pre] = pm2;
  const run = (a) => spawnSync(cmd, [...pre, ...a], { stdio: SHOW_LOG ? 'inherit' : 'ignore', shell: process.platform === 'win32' });
  run(['delete', PM2_NAME]);
  const r = run(['start', __filename, '--name', PM2_NAME, '--cwd', __dirname, '--update-env']);
  if (r.status !== 0) { console.error('[PM2] pm2 启动失败，改为直接运行'); return false; }
  run(['save']);
  console.log(`[PM2] 已交给 pm2 常驻（名称 ${PM2_NAME}），可用 pm2 logs ${PM2_NAME} 查看`);
  return true;
}

// ==================== Telegram WEB Proxy ====================
// 统一说明：TG 的 secret 直接复用上面的 UUID（通信时即 32 位 hex）。
const CFG = { dnPack: 32 * 1024, upPack: 20 * 1024, dnMs: 1 };
const txt = new TextEncoder()
const dec = new TextDecoder();
const nil = Buffer.alloc(0);
const badHead = new Set(['HEAD', 'POST', 'GET ', 'OPTI']);

// UUID（含短横线）-> 纯 hex；其余格式原样返回（交给 getKey 校验）
function normalizeSecret(v) {
  const str = String(v || '').trim().toLowerCase();
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(str)) {
    return str.replace(/-/g, '');
  }
  return str;
}

const macKeys = new Map();
const leases = new Map();

// ==================== 工具函数 ====================
function u8(v) {
  if (Buffer.isBuffer(v)) return v;
  if (v instanceof Uint8Array) return Buffer.from(v);
  if (v instanceof ArrayBuffer) return Buffer.from(v);
  if (ArrayBuffer.isView(v)) return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
  throw new TypeError('Invalid buffer');
}

const dup = v => Buffer.from(u8(v));
function cat(...args) {
  return Buffer.concat(args.filter(v => v?.byteLength).map(u8));
}
const hex = v => Buffer.from(v, 'hex');
function b64(v) {
  const b = Buffer.isBuffer(v) ? v : Buffer.from(v);
  return b.toString('base64url');
}
const un64 = v => Buffer.from(v.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const rand = n => crypto.randomBytes(n);
const wake = st => { const { wake: ok } = st; st.wake = null; ok?.(); };
const isType = t => t === 1 || t === 2 || t === 3 || t === 4 || t === 17;

function reply(res, body = null, status = 404, headers = {}) {
  res.writeHead(status, headers);
  res.end(body);
  return true; // 已处理：tgRoute 的返回值用于融合处理器的路由判断
}

// ==================== 帧编码/解析 ====================
function enc(type, sid, data = nil) {
  const body = u8(data);
  if (!isType(type)) throw new RangeError('Invalid type');
  if (!Number.isInteger(sid) || sid < 0 || sid > 0xffffff) throw new RangeError('Invalid sid');
  if (body.byteLength > 1024 * 1024) throw new RangeError('Body too large');
  const frame = Buffer.alloc(8 + body.byteLength);
  frame[0] = type;
  frame[1] = sid >>> 16;
  frame[2] = sid >>> 8;
  frame[3] = sid;
  frame.writeUInt32BE(body.byteLength, 4);
  frame.set(body, 8);
  return frame;
}

function getFrame(b, o) {
  if (b.byteLength - o < 8) return null;
  const type = b[o];
  if (!isType(type)) throw new Error('Invalid frame type');
  const sid = (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  const n = b.readUInt32BE(o + 4);
  if (n > 1024 * 1024) throw new Error('Frame too large');
  const total = 8 + n;
  if (b.byteLength - o < total) return null;
  return {
    frame: { type, sid, payload: b.subarray(o + 8, o + total) },
    consumed: total,
  };
}

function frames(v) {
  const src = u8(v), out = [];
  for (let o = 0; o < src.byteLength;) {
    const part = getFrame(src, o);
    if (!part) throw new Error('Incomplete frame');
    if (out.length >= 4096) throw new Error('Too many frames');
    out.push(part.frame);
    o += part.consumed;
  }
  return out;
}

function win(data) {
  const body = u8(data);
  if (body.byteLength !== 4) throw new Error('Invalid window');
  const n = body.readUInt32BE(0);
  if (!n) throw new Error('Zero window');
  return n;
}

function check(frame) {
  const { type, payload: data } = frame;
  if (type === 1 || type === 3) { if (data.byteLength) throw new Error('Empty expected'); return 0; }
  if (type === 2) { if (!data.byteLength) throw new Error('Non-empty expected'); return 0; }
  if (type === 4) return win(data);
  throw new Error('Invalid type');
}

// ==================== 头部处理 ====================
const i16 = (b, o) => (b[o] | (b[o + 1] << 8)) << 16 >> 16;

function headOf(head) {
  const tag = head.readUInt32LE(56);
  const mode = tag === 0xefefefef ? 0xef : tag === 0xeeeeeeee ? 0xee : tag === 0xdddddddd ? 0xdd : 0;
  if (!mode) throw new Error('Invalid mode');
  const dc = i16(head, 60);
  const target = Math.abs(dc) - 1;
  if (target < 0 || target >= 5) throw new Error('Invalid DC');
  return { mode, target, media: dc < 0 };
}

function mkHead(mode, target, media) {
  const head = Buffer.alloc(64);
  do {
    crypto.randomFillSync(head);
  } while (
    head[0] === 0xef ||
    badHead.has(dec.decode(head.subarray(0, 4))) ||
    head.subarray(4, 8).every(v => v === 0)
  );
  head.fill(mode, 56, 60);
  head.writeInt16LE((target + 1) * (media ? -1 : 1), 60);
  return head;
}

// ==================== 密钥/主机 ====================
function getKey(v, keepTag = false) {
  const str = String(v || '').trim().toLowerCase();
  if (!/^(?:[0-9a-f]{32}|(?:dd|ee|ef)[0-9a-f]{32})$/.test(str)) throw new Error('Invalid key');
  return hex(keepTag && str.length === 34 && str.startsWith('dd') ? str : str.slice(-32));
}

function hostOf(v) {
  const host = String(v || '').trim().toLowerCase().replace(/\.$/, '');
  const labels = host.split('.');
  if (!host.includes('.') || host.length > 253 || host.includes(':') ||
      labels.some(label => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
    throw new Error('Invalid host');
  }
  return host;
}

// 从 SECRET 用带标签的 HMAC-SHA256 确定性派生。
function deriveBoot(secretRaw) {
  const master = crypto.createHmac('sha256', 'tg-webproxy-master-v1')
    .update(String(secretRaw).trim().toLowerCase())
    .digest();
  return crypto.createHmac('sha256', 'tg-webproxy-boot-v1')
    .update(master)
    .digest('hex'); // 64 位 hex 字符串
}

// ==================== HMAC / MAC ====================
function macKey(raw, id) {
  // Cache the raw key material, not an Hmac instance: newer Node versions
  // dropped Hmac#copy, so sign() must build a fresh HMAC per call.
  let key = macKeys.get(id);
  if (!key) macKeys.set(id, key = Buffer.from(u8(raw)));
  return key;
}

function sign(key, v) {
  const h = crypto.createHmac('sha256', key);
  h.update(u8(v));
  return h.digest();
}

async function mac(boot, kind, body) {
  const prefix = txt.encode(`${kind}\n`);
  const msg = Buffer.concat([Buffer.from(prefix), Buffer.from(body)]);
  const key = macKey(Buffer.from(txt.encode(boot)), `token:${boot}`);
  return sign(key, msg).subarray(0, 16);
}

async function mkToken(boot, kind, expAt, nonce) {
  const body = Buffer.alloc(16);
  const exp = Math.ceil(expAt / 1000);
  body.writeUInt32BE(exp, 0);
  body.set(nonce, 4);
  const token = Buffer.alloc(32);
  token.set(body);
  token.set(await mac(boot, kind, body), body.byteLength);
  return b64(token);
}

const mkBoot = async boot => mkToken(boot, 'bootstrap', Date.now() + 2 * 60 * 1000, rand(12));

async function verify(v, boot, kind) {
  if (typeof v !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(v)) return false;
  let token;
  try { token = un64(v); } catch { return false; }
  if (token.byteLength !== 32 || b64(token) !== v) return false;
  const body = token.subarray(0, 16);
  const sig = token.subarray(16);
  const exp = body.readUInt32BE(0);
  if (exp <= Math.floor(Date.now() / 1000)) return false;
  const want = await mac(boot, kind, body);
  let diff = sig.byteLength ^ want.byteLength;
  for (let i = 0; i < want.length; i++) diff |= sig[i] ^ want[i];
  return diff === 0;
}

const mkSess = async boot => mkToken(boot, 'session', Date.now() + 5 * 60 * 1000, rand(12));
const authBoot = async (v, boot) => v === boot || verify(v, boot, 'bootstrap');
const mkLease = token => ({
  expires: un64(token).readUInt32BE(0) * 1000,
  active: new Set(),
  used: new Set(),
  deleted: false,
});
const bearer = v => /^Bearer ([^\s]+)$/.exec(v || '')?.[1] ?? null;
const binary = req => req.headers['content-type']?.trim().toLowerCase() === 'application/octet-stream';

// ==================== Hello 协议 ====================
function hello(body) {
  if (body.byteLength !== 9 || body[0] !== 0x10 || body[1] !== 0 || body[2] !== 0 ||
      body[3] !== 0 || body.readUInt32BE(4) !== 1 || body[8] !== 1) {
    throw new Error('Invalid hello');
  }
}

const protos = req => (req.headers['sec-websocket-protocol'] ?? '').split(',').map(v => v.trim()).filter(Boolean);

// ==================== 配置（启动时构造一次） ====================
let CFG_CACHE = null;
function mkTgCfg(secret) {
  if (CFG_CACHE) return CFG_CACHE;
  if (!secret) throw new Error('TG secret required');
  CFG_CACHE = {
    secret,
    key: getKey(secret),
    boot: deriveBoot(secret),   // 从 SECRET 派生
  };
  return CFG_CACHE;
}

// ==================== Bridge ====================
async function mkCap(secret, host) {
  const key = macKey(getKey(secret, true), `bridge:${String(secret).trim().toLowerCase()}`);
  const sig = sign(key, txt.encode(`tdesktop-web-proxy-bridge-v1\n${hostOf(host)}`));
  return b64(sig);
}

async function bridge(url, secret) {
  if (url.pathname !== '/' || url.search.length !== 51) return null;
  const cand = url.search.slice(8);
  if (url.search !== `?bridge=${cand}` || !/^[A-Za-z0-9_-]{43}$/.test(cand)) return null;
  const host = hostOf(url.hostname);
  const want = await mkCap(secret, host);
  if (cand.length !== want.length) return null;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= cand.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0 ? host : null;
}

// ==================== 加密 ====================
const sha = v => crypto.createHash('sha256').update(u8(v)).digest();

function step(ctr, n) {
  let carry = n;
  for (let i = ctr.length - 1; i >= 0 && carry; i--) {
    const next = ctr[i] + (carry & 0xff);
    ctr[i] = next & 0xff;
    carry = Math.floor(carry / 256) + Math.floor(next / 256);
  }
  if (carry) throw new Error('Counter overflow');
}

function mkCtr(key, ctr) {
  let iv = dup(ctr), tail = nil;
  const crypt = async (v) => {
    const b = u8(v);
    if (!b.byteLength) return Buffer.alloc(0);
    if (!tail.byteLength && !(b.byteLength % 16)) {
      const cipher = crypto.createCipheriv(key.length === 32 ? 'aes-256-ctr' : 'aes-128-ctr', key, iv);
      const raw = Buffer.concat([cipher.update(b), cipher.final()]);
      step(iv, b.byteLength / 16);
      return raw;
    }
    if (b.byteLength <= tail.byteLength) {
      const out = Buffer.alloc(b.byteLength);
      for (let i = 0; i < b.byteLength; i++) out[i] = b[i] ^ tail[i];
      tail = tail.subarray(b.byteLength);
      return out;
    }
    const skip = tail.byteLength ? 16 - tail.byteLength : 0;
    const ctrCopy = Buffer.from(iv);
    if (skip) {
      for (let i = ctrCopy.length - 1; i >= 0; i--) if (ctrCopy[i]--) break;
    }
    const end = skip + b.byteLength;
    const block = Buffer.alloc(Math.ceil(end / 16) * 16);
    block.set(b, skip);
    const cipher = crypto.createCipheriv(key.length === 32 ? 'aes-256-ctr' : 'aes-128-ctr', key, ctrCopy);
    const raw = Buffer.concat([cipher.update(block), cipher.final()]);
    tail = raw.subarray(end);
    step(iv, block.byteLength / 16 - (skip ? 1 : 0));
    return raw.subarray(skip, end);
  };
  return { crypt };
}

async function cipher(head, secret, reverse) {
  const mat = dup(u8(head).subarray(8, 56));
  if (reverse) mat.reverse();
  const key = secret.byteLength ? sha(cat(mat.subarray(0, 32), secret)) : mat.subarray(0, 32);
  return mkCtr(key, mat.subarray(32, 48));
}

async function wireHead(head) {
  const ctr = await cipher(head, nil, false);
  const raw = await ctr.crypt(head);
  raw.set(u8(head).subarray(0, 56));
  return { wire: raw, cipher: ctr };
}

// ==================== Wire (WebSocket) ====================
const hosts = (dc, media) => [
  `kws${dc}${media ? '-1' : ''}.web.telegram.org`,
  `kws${dc}${media ? '' : '-1'}.web.telegram.org`,
];

function mkWire(ws, ms, signal) {
  const q = [], wait = [];
  let h = 0, qBytes = 0, closed = false, dead = false, up = false, fault = null;
  let pWake = null, pNeed, openTimer, readyOk, readyBad;

  const ready = new Promise((ok, bad) => { readyOk = ok; readyBad = bad; });

  const onAbort = () => { end(new Error('Aborted')); close(); };

  ws.binaryType = 'arraybuffer';
  ws.on('open', () => {
    if (closed) return;
    up = true;
    clearTimeout(openTimer);
    readyOk(api);
  });

  ws.on('message', (data) => {
    if (closed) return;
    const b = Buffer.from(data);
    if (!b.byteLength) return;
    const waiter = wait.shift();
    if (waiter) waiter.resolve(b);
    else {
      q.push(b);
      qBytes += b.byteLength;
      if (pWake && (qBytes >= pNeed || b.byteLength >= CFG.dnPack)) pWake();
    }
  });

  const end = (err = null) => {
    if (closed) return;
    closed = true;
    fault = err;
    clearTimeout(openTimer);
    signal?.removeEventListener('abort', onAbort);
    if (!up) readyBad(err || new Error('Closed'));
    pWake?.();
    for (const waiter of wait.splice(0)) err ? waiter.reject(err) : waiter.resolve(null);
  };

  ws.on('error', () => end(new Error('WS error')));
  ws.on('close', (code) => end(code && code !== 1000 ? new Error(`Closed ${code}`) : null));

  openTimer = setTimeout(() => { end(new Error('Timeout')); close(); }, ms);
  signal?.addEventListener('abort', onAbort, { once: true });
  if (signal?.aborted) onAbort();

  const write = async (v) => {
    await ready;
    if (closed) throw fault || new Error('Closed');
    ws.send(u8(v));
  };

  const take = async () => {
    await ready;
    if (h < q.length) {
      const msg = q[h];
      q[h++] = null;
      qBytes -= msg.byteLength;
      trim();
      return msg;
    }
    if (fault) throw fault;
    if (closed) return null;
    return new Promise((ok, bad) => wait.push({ resolve: ok, reject: bad }));
  };

  const pack = async () => {
    const first = await take();
    if (dead) return null;
    if (!first || first.byteLength >= CFG.dnPack) return first;
    if (!closed && qBytes < CFG.dnPack - first.byteLength) {
      await new Promise(ok => {
        pNeed = CFG.dnPack - first.byteLength;
        const timer = setTimeout(() => pWake?.(), CFG.dnMs);
        pWake = () => { clearTimeout(timer); pWake = null; ok(); };
      });
    }
    if (dead) return null;
    let n = first.byteLength, end = h;
    while (end < q.length && n + q[end].byteLength <= CFG.dnPack) {
      n += q[end++].byteLength;
    }
    if (end === h) return first;
    const b = Buffer.alloc(n);
    b.set(first);
    let o = first.byteLength;
    while (h < end) {
      const part = q[h];
      q[h++] = null;
      b.set(part, o);
      o += part.byteLength;
      qBytes -= part.byteLength;
    }
    trim();
    return b;
  };

  const trim = () => {
    if (h === q.length) { q.length = 0; h = 0; }
    else if (h >= 256 && h * 2 >= q.length) { q.splice(0, h); h = 0; }
  };

  const close = () => {
    if (dead) return;
    dead = true;
    if (!closed) end();
    q.length = h = qBytes = 0;
    try { ws.close(1000); } catch {}
  };

  const api = { ready, write, readPack: pack, close, get closed() { return closed; } };
  return api;
}

async function dial({ target, media, signal }) {
  for (const host of hosts(target + 1, media)) {
    if (signal?.aborted) throw new Error('Aborted');
    const url = `wss://${host}/apiws`;
    let kws;
    try {
      const ws = new WebSocket(url, 'binary');
      kws = mkWire(ws, 7500, signal);
      await kws.ready;
      if (signal?.aborted) throw new Error('Aborted');
      return kws;
    } catch (err) {
      kws?.close();
      if (signal?.aborted) throw err;
    }
  }
  throw new Error('All DCs failed');
}

// ==================== 数据包解析 ====================
function mkPkt(mode) {
  let tail = nil;
  const push = (v) => {
    const b = u8(v);
    if (b.byteLength) tail = tail.byteLength ? cat(tail, b) : b;
    const pkts = [];
    let o = 0;
    for (;;) {
      const avail = tail.byteLength - o;
      let hLen, pLen;
      if (mode === 0xef) {
        if (avail < 1) break;
        let words = tail[o] & 0x7f;
        if (words === 0x7f) {
          if (avail < 4) break;
          words = tail[o + 1] | (tail[o + 2] << 8) | (tail[o + 3] << 16);
          hLen = 4;
        } else hLen = 1;
        pLen = words * 4;
      } else {
        if (avail < 4) break;
        pLen = tail.readUInt32LE(o) & 0x7fffffff;
        hLen = 4;
      }
      if (!pLen || pLen > 8 * 1024 * 1024) throw new Error('Invalid packet length');
      const total = hLen + pLen;
      if (avail < total) break;
      pkts.push(tail.subarray(o, o + total));
      o += total;
    }
    if (o) tail = o === tail.byteLength ? nil : tail.subarray(o);
    if (tail.byteLength > 8 * 1024 * 1024 + 4) throw new Error('Tail overflow');
    return pkts;
  };
  const clear = () => { tail = nil; };
  return { push, clear };
}

// ==================== 流管理 ====================
function mkStream({ secret, emit, onClose }) {
  let hdr = nil, cIn = null, cOut = null, kIn = null, kOut = null, peer = null, pkt = null;
  let init = false, closed = false, chain = Promise.resolve();
  const ac = new AbortController();
  const uq = new Set();

  const push = (v) => {
    if (closed) return Promise.reject(new Error('Closed'));
    const job = { bytes: u8(v) };
    uq.add(job);
    chain = chain.then(async () => {
      if (closed) throw new Error('Closed');
      if (!job.bytes) return job.result;
      const jobs = [job];
      let n = job.bytes.byteLength;
      for (const next of uq) {
        if (next === job) continue;
        if (n >= CFG.upPack || n + next.bytes.byteLength > CFG.upPack) break;
        n += next.bytes.byteLength;
        jobs.push(next);
      }
      const b = jobs.length === 1 ? job.bytes : cat(...jobs.map(x => x.bytes));
      for (const item of jobs) { uq.delete(item); item.bytes = null; }
      const out = await feed(b);
      for (const item of jobs) item.result = out;
      return out;
    });
    return chain;
  };

  const feed = async (b) => {
    if (closed) throw new Error('Closed');
    if (init && peer.closed) return false;
    if (!b.byteLength) return;
    if (!init) {
      const need = 64 - hdr.byteLength;
      if (b.byteLength < need) { hdr = cat(hdr, b); return; }
      hdr = cat(hdr, b.subarray(0, need));
      await start();
      const rest = b.subarray(need);
      if (rest.byteLength) return write(rest);
      return;
    }
    return write(b);
  };

  const start = async () => {
    const raw = hdr;
    const cr = await cipher(raw, secret, false);
    const plain = await cr.crypt(raw);
    if (closed) return;
    const info = headOf(plain);
    const head = mkHead(info.mode, info.target, info.media);
    const [cw, out, kr] = await Promise.all([
      cipher(raw, secret, true),
      wireHead(head),
      cipher(head, nil, true),
    ]);
    if (closed) return;
    const kws = await dial({ target: info.target, media: info.media, signal: ac.signal });
    if (closed) { kws.close(); return; }
    peer = kws;
    cIn = cr; cOut = cw; kOut = out.cipher; kIn = kr;
    pkt = mkPkt(info.mode);
    await kws.write(out.wire);
    if (closed) return;
    hdr = nil;
    init = true;
    pump().catch(() => close());
  };

  const write = async (raw) => {
    if (closed || peer.closed) return false;
    const plain = await cIn.crypt(raw);
    if (closed || peer.closed) return false;
    const pkts = pkt.push(plain);
    for (let start = 0; start < pkts.length;) {
      let end = start + 1, n = pkts[start].byteLength;
      while (end < pkts.length && n + pkts[end].byteLength <= CFG.upPack) {
        n += pkts[end++].byteLength;
      }
      const first = pkts[start];
      const b = end === start + 1 ? first : Buffer.from(first.buffer, first.byteOffset, n);
      if (closed || peer.closed) return false;
      const wire = await kOut.crypt(b);
      for (let o = 0; start < end; start++) {
        if (closed || peer.closed) return false;
        const n = pkts[start].byteLength;
        try { await peer.write(wire.subarray(o, o + n)); } catch (err) {
          if (closed || peer.closed) return false;
          throw err;
        }
        o += n;
      }
    }
  };

  const pump = async () => {
    while (!closed) {
      const b = await peer.readPack();
      if (closed) return;
      if (!b) return close();
      const plain = await kIn.crypt(b);
      if (closed) return;
      const raw = await cOut.crypt(plain);
      if (closed) return;
      await emit(raw);
    }
  };

  const close = () => {
    if (closed) return;
    closed = true;
    ac.abort();
    try { peer?.close(); } catch {}
    for (const job of uq) job.bytes = null;
    uq.clear();
    hdr = nil;
    pkt?.clear();
    cIn = cOut = kIn = kOut = peer = null;
    try { onClose(); } catch {}
  };

  return { push, close };
}

// ==================== 会话管理 ====================
function mkSession({ secret, sid, onClose, lease }) {
  let sock = null, closed = false, tx = Promise.resolve(), cur = null;

  const attach = (ws) => {
    if (sock || closed) throw new Error('Already attached');
    sock = ws;
    ws.on('message', (data) => {
      if (closed) return;
      try { onData(Buffer.from(data)); } catch { close(1008); }
    });
    ws.on('close', () => close());
    ws.on('error', () => close());
  };

  const onData = (b) => {
    if (closed) return;
    if (lease?.deleted) return close(1000);
    if (!b.byteLength || b.byteLength > 2 * 1024 * 1024) throw new Error('Bad data');
    for (const frame of frames(b)) {
      if (closed) return;
      const delta = check(frame);
      if (frame.sid !== sid) throw new Error('SID mismatch');
      if (!cur && frame.type !== 1) throw new Error('No stream');
      if (frame.type !== 1 && cur?.closed) continue;
      if (frame.type === 1) open();
      else if (frame.type === 2) write(frame.payload);
      else if (frame.type === 4) grant(delta);
      else if (frame.type === 3) end(false);
      else throw new Error('Bad type');
    }
  };

  const send = (type, data = nil) => {
    const out = enc(type, sid, data);
    const st = type === 2 || type === 4 ? cur : null;
    tx = tx.then(() => {
      if (closed) throw new Error('Closed');
      if ((type === 2 || type === 4) && (!st || st.closed)) return;
      sock.send(out);
    });
    return tx;
  };

  const open = () => {
    if (closed) return;
    if (cur) throw new Error('Already open');
    const st = { in: 4 * 1024 * 1024, out: 4 * 1024 * 1024, wake: null, closed: false, proxy: null, pItems: 0 };
    st.proxy = mkStream({
      secret,
      emit: b => emitDn(st, b),
      onClose: () => { if (!closed && !st.closed) end(true); },
    });
    cur = st;
  };

  const write = (data) => {
    if (closed || cur?.closed) return;
    const st = cur;
    if (!st || st.closed) throw new Error('No stream');
    const n = data.byteLength;
    if (n > st.in) throw new Error('Window exceeded');
    if (st.pItems >= 16384) throw new Error('Too many items');
    st.in -= n;
    st.pItems++;
    st.proxy.push(data).then(accepted => {
      freeUp(st);
      if (closed || st.closed || accepted === false) return;
      st.in += n;
      const delta = Buffer.alloc(4);
      delta.writeUInt32BE(n, 0);
      send(4, delta).catch(() => close());
    }, () => {
      freeUp(st);
      if (!closed && !st.closed) st.proxy.close();
    }).catch(() => close());
  };

  const freeUp = (st) => { if (st.closed) return; st.pItems--; };

  const emitDn = async (st, b) => {
    for (let o = 0; o < b.byteLength;) {
      while (!closed && !st.closed && st.out === 0) {
        await new Promise(ok => { st.wake = ok; });
      }
      if (closed || st.closed) throw new Error('Closed');
      const n = Math.min(64 * 1024, b.byteLength - o, st.out);
      st.out -= n;
      await send(2, b.subarray(o, o + n));
      o += n;
    }
  };

  const grant = (n) => {
    if (closed || cur?.closed) return;
    const st = cur;
    if (!st || st.closed) throw new Error('No stream');
    st.out = Math.min(0xffffffff, st.out + n);
    wake(st);
  };

  const stop = (st) => { st.closed = true; st.pItems = 0; wake(st); st.proxy.close(); };

  const end = (notify) => {
    if (closed || cur?.closed) return;
    const st = cur;
    if (!st) throw new Error('No stream');
    stop(st);
    if (notify) send(3).then(() => close(), () => close());
    else close();
  };

  const close = (code = 1000, reason = '') => {
    if (closed) return;
    closed = true;
    if (cur) stop(cur);
    cur = null;
    try { sock?.close(code, reason); } catch {}
    onClose?.();
    onClose = null;
  };

  return { attach, close };
}

// ==================== 页面生成 ====================
function mkPage(host, boot) {
  const nonce = b64(rand(18));
  const body = `<script nonce="__NONCE__">
(()=>{'use strict'; const origin=__ORIGIN__,boot=__BOOTSTRAP__;
const aNonce=/^#android=([A-Za-z0-9_-]{43})$/.exec(location.hash)?.[1]??''; history.replaceState(null,'',location.pathname);
let init=false,closed=false,port=null,token='',started=false,delSent=false; let qBytes=0,qItems=0;
const lanes=new Map(),used=new Set(),qMax=33554432,iMax=16384,msgMax=2097152; const laneMax=8388608,laneItems=1024;
const state=st=>port&&!closed&&port.postMessage({t:'status',state:st});
const opts=(method,token,body,keepalive)=>({ method,body,keepalive:!!keepalive,mode:'same-origin',credentials:'omit',cache:'no-store',redirect:'error',referrerPolicy:'no-referrer', headers:{...(token&&{Authorization:'Bearer '+token}),...(body&&{'Content-Type':'application/octet-stream'})} });
function check(v){ if(!(v instanceof ArrayBuffer)||!v.byteLength||v.byteLength>msgMax)throw Error(); const view=new DataView(v);let o=0,frames=0; while(o<v.byteLength){ if(v.byteLength-o<8||frames++>=4096)throw Error(); const type=view.getUint8(o),n=view.getUint32(o+4),end=o+8+n; if(n>1048576||end>v.byteLength||(type===2&&!n))throw Error(); o=end; } return v; }
function split(v){ check(v);const view=new DataView(v),out=[];let o=0; while(o<v.byteLength){ const end=o+8+view.getUint32(o+4); out.push(o===0&&end===v.byteLength?v:v.slice(o,end));o=end; } return out; }
function sid(v){const b=new Uint8Array(v);return (b[1]<<16)|(b[2]<<8)|b[3];}
function hold(lane,v){ let buffered=0;for(const {ws} of lanes.values())buffered+=ws?.bufferedAmount??0; const own=lane.ws?.bufferedAmount??0; if(qBytes+buffered>qMax-v.byteLength||qItems>=iMax ||lane.bytes+own>laneMax-v.byteLength||lane.items>=laneItems)return false; qBytes+=v.byteLength;qItems++;lane.bytes+=v.byteLength;lane.items++;return true; }
function free(lane,v){qBytes-=v.byteLength;qItems--;lane.bytes-=v.byteLength;lane.items--;}
function fail(){ if(closed)return;state('failed');port?.postMessage({t:'close'});close(true); }
function drop(){ if(delSent||!token)return;delSent=true; fetch(origin+'/api/v1/session',opts('DELETE',token,null,true)).catch(()=>{}); }
function pump(lane){ const ws=lane.ws; if(closed||lane.done||!ws||ws.readyState!==WebSocket.OPEN||!lane.pending.length)return; if(ws.bufferedAmount>=msgMax){lane.timer ||= setTimeout(()=>{lane.timer=0;pump(lane);},10);return;} try{ const v=lane.pending.shift();ws.send(v);free(lane,v); port.postMessage({t:'traffic',up:v.byteLength,down:0}); if(lane.pending.length)queueMicrotask(()=>pump(lane)); }catch{fail();} }
function push(v){ try{for(const frame of split(v))pushLane(frame);} catch{fail();} }
function end(lane,notify){ if(lane.done)return;lane.done=true;if(lane.timer)clearTimeout(lane.timer); qBytes-=lane.bytes;qItems-=lane.items;lane.bytes=lane.items=0;lane.pending.length=0;lanes.delete(lane.id); try{lane.ws?.close();}catch{} if(notify&&port&&!closed){const frame=new ArrayBuffer(8),b=new Uint8Array(frame);b[0]=3;b[1]=lane.id>>>16;b[2]=lane.id>>>8;b[3]=lane.id;port.postMessage(frame,[frame]);} }
function open(lane){ const target=origin.replace(/^https:/,'wss:')+'/api/v1/ws'; const ws=lane.ws=new WebSocket(target,'tproxy-lane-v1.'+token+'.'+lane.id);ws.binaryType='arraybuffer'; ws.onopen=()=>{if(closed||lane.done){ws.close();return;}lane.opened=true;state('connected');pump(lane);}; ws.onmessage=e=>{ if(closed||lane.done)return; try{ const frames=split(e.data); if(frames.some(frame=>sid(frame)!==lane.id))throw Error(); const ended=frames.some(frame=>new Uint8Array(frame)[0]===3); if(ended)lane.rClosed=true; port.postMessage({t:'traffic',up:0,down:e.data.byteLength});port.postMessage(e.data,[e.data]);state('connected'); if(ended)end(lane,false); }catch{fail();} }; ws.onerror=()=>{}; ws.onclose=()=>{if(closed||lane.done)return;if(!lane.opened){fail();return;}end(lane,!lane.lClosed&&!lane.rClosed);}; }
function pushLane(v){ const id=sid(v),type=new Uint8Array(v)[0];let lane=lanes.get(id); if(!id)throw Error(); if(!lane&&(type===2||type===3||type===4))return; if(!lane){ if(type!==1||used.has(id)||lanes.size>=128||used.size>=4096)throw Error(); used.add(id);lane={id,ws:null,pending:[],bytes:0,items:0,timer:0,opened:false,done:false,lClosed:false,rClosed:false};lanes.set(id,lane); } if(lane.lClosed)return; if(type===3&&!lane.opened){end(lane,false);return;} if(!hold(lane,v))throw Error(); lane.pending.push(v);if(type===3)lane.lClosed=true; if(token){if(!lane.ws)open(lane);else pump(lane);} }
async function create(first){ try{ state('connecting'); const res=await fetch(origin+'/api/v1/session',opts('POST',boot,first)); if(res.status!==200||res.headers.get('X-Carrier-Mode')!=='websocket-lanes')throw Error(); token=res.headers.get('X-Session-Token')??''; if(!token)throw Error(); const welcome=await res.arrayBuffer();check(welcome); if(closed){drop();return;} port.postMessage(welcome,[welcome]);state('connected'); for(const lane of lanes.values())if(!lane.ws)open(lane); }catch{fail();} }
function close(notify){ if(closed)return;closed=true; for(const lane of [...lanes.values()])end(lane,false);used.clear(); if(notify)drop(); port?.close(); }
function start(next){ init=true;port=next; port.onmessage=msg=>{ const data=msg.data; if(data instanceof ArrayBuffer){ if(!started){ try{check(data);}catch{fail();return;} started=true;create(data); }else push(data); }else if(data&&data.t==='close')close(true); }; port.start();state('connecting'); }
addEventListener('message',e=>{ if(init||e.source!==parent||e.data===null||typeof e.data!=='object')return; const keys=Object.keys(e.data).sort(); if(keys.length!==2||keys[0]!=='t'||keys[1]!=='v'||e.data.t!=='tproxy-init'||e.data.v!==1||e.ports.length!==1)return; let src;try{src=new URL(e.origin);}catch{return;} if(src.protocol!=='http:'||src.hostname!=='127.0.0.1'||!src.port||src.origin!==e.origin)return; start(e.ports[0]); }); const android=globalThis.TelegramWebProxy;
if(!init&&aNonce&&android&&typeof android.postMessage==='function'){ const aPort={onmessage:null,start(){},close(){android.onmessage=null;},postMessage(v){ if(v instanceof ArrayBuffer){for(const frame of split(v))android.postMessage(frame);} else android.postMessage(JSON.stringify(v)); }}; android.onmessage=e=>{ let data=e.data;if(typeof data==='string'){try{data=JSON.parse(data);}catch{return;}} aPort.onmessage?.({data}); }; start(aPort);android.postMessage(JSON.stringify({t:'tproxy-android-init',v:1,nonce:aNonce})); } addEventListener('pagehide',()=>close(true),{once:true}); })();
</script>`.replaceAll('__NONCE__', nonce)
    .replace('__ORIGIN__', JSON.stringify(`https://${host}`))
    .replace('__BOOTSTRAP__', JSON.stringify(String(boot)));

  const csp = [
    "default-src 'none'", "base-uri 'none'", "child-src 'none'",
    `connect-src 'self' wss://${host}`, "font-src 'none'", "form-action 'none'",
    'frame-ancestors http://127.0.0.1:*', "frame-src 'none'", "img-src 'none'",
    "manifest-src 'none'", "media-src 'none'", "object-src 'none'",
    `script-src 'nonce-${nonce}'`, "style-src 'none'", "worker-src 'none'",
    'sandbox allow-same-origin allow-scripts',
  ].join('; ');

  return { body, csp };
}


const tgWss = new WebSocket.Server({
  noServer: true,
  handleProtocols: (protocols) => protocols.values().next().value ?? false,
});

async function tgRoute(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method;
  const headers = req.headers;

    let cfg;
  try { cfg = mkTgCfg(uuid); } catch {
    if (['/', '/health', '/api/v1/session', '/api/v1/ws'].includes(path)) {
      return reply(res, null, 500);
    }
    return reply(res, null, 404);
  }

  // 根路径
  if (path === '/' && (method === 'GET' || method === 'HEAD')) {
    let host = null;
    if (method === 'GET') {
      try { host = await bridge(url, cfg.secret); } catch {}
    }
    if (host) {
      const boot = await mkBoot(cfg.boot);
      const page = mkPage(host, boot);
      return reply(res, method === 'HEAD' ? null : page.body, 200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': page.csp,
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
        'Permissions-Policy': [
          'accelerometer=()', 'autoplay=()', 'camera=()',
          'clipboard-read=()', 'clipboard-write=()', 'display-capture=()',
          'encrypted-media=()', 'fullscreen=()', 'geolocation=()',
          'gyroscope=()', 'hid=()', 'idle-detection=()', 'magnetometer=()',
          'microphone=()', 'midi=()', 'payment=()', 'picture-in-picture=()',
          'publickey-credentials-create=()', 'publickey-credentials-get=()',
          'screen-wake-lock=()', 'serial=()', 'usb=()', 'web-share=()',
          'xr-spatial-tracking=()',
        ].join(', '),
      });
    }
    return false; 
  }

  // 健康检查
  if (path === '/health') {
    return reply(res, '{"ok":true}', 200, { 'Content-Type': 'application/json; charset=utf-8' });
  }

  // 会话 API
  if (path === '/api/v1/session') {
    const auth = bearer(headers['authorization']);
    if (method === 'DELETE') {
      if (!auth || !(await verify(auth, cfg.boot, 'session'))) return reply(res, null, 404);
      let lease = leases.get(auth);
      if (!lease) leases.set(auth, lease = mkLease(auth));
      lease.deleted = true;
      return reply(res, null, 204);
    }
    if (method !== 'POST' || !auth || !binary(req)) return reply(res, null, 404);
    if (!(await authBoot(auth, cfg.boot))) return reply(res, null, 404);
    try {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      hello(body);
      const token = await mkSess(cfg.boot);
      return reply(res, enc(0x11, 0), 200, {
        'Content-Type': 'application/octet-stream',
        'Cache-Control': 'no-store',
        'X-Session-Token': token,
        'X-Carrier-Mode': 'websocket-lanes',
      });
    } catch { return reply(res, null, 404); }
  }

  return false;
}


async function tgWsUpgrade(req, socket, head) {
  const headers = req.headers;
  const cfg = mkTgCfg(uuid);
  if (req.method !== 'GET' || (req.headers.origin &&
      req.headers.origin !== `https://${headers.host}` &&
      req.headers.origin !== `http://${headers.host}`)) { try { socket.destroy(); } catch {} return; }
  const offers = protos(req);
  const proto = offers.length === 1 ? offers[0] : null;
  const parts = proto?.split('.') ?? [];
  const [kind, token = '', id] = parts;
  const sid = Number(id);
  if (parts.length !== 3 || kind !== 'tproxy-lane-v1' ||
      !/^[1-9][0-9]{0,7}$/.test(id) || sid > 0xffffff ||
      !(await verify(token, cfg.boot, 'session'))) {
    return reply(res, null, 404);
  }

  const now = Date.now();
  for (const [key, v] of leases) {
    if (v.expires <= now && !v.active.size) leases.delete(key);
  }
  let lease = leases.get(token);
  if (!lease) {
    if (leases.size >= 4096) return reply(res, null, 503);
    leases.set(token, lease = mkLease(token));
  }
  if (lease.deleted || lease.used.has(sid) || lease.active.size >= 128 || lease.used.size >= 4096) {
    return reply(res, null, 409);
  }
  lease.used.add(sid);
  lease.active.add(sid);

  const sess = mkSession({
    secret: cfg.key,
    sid,
    lease,
    onClose: () => lease.active.delete(sid),
  });

  tgWss.handleUpgrade(req, socket, head, (ws) => {
    try {
      sess.attach(ws);
    } catch {
      sess.close();
      try { ws.close(); } catch {}
    }
  });
}

// 启动服务
if (handoffToPm2()) process.exit(0);


// ==================== TLS（可选，TLS=true 开启） ====================
// 同一个端口同时接受 HTTP 和 HTTPS：首字节 0x16 是 TLS 握手，交给 https；否则交给 http
// 这样平台的健康检查、AUTO_ACCESS 用 http 访问也不受影响
let tlsSelfSigned = false;

function readPem(v) {
  if (!v) return '';
  if (v.includes('-----BEGIN')) return v.replace(/\\n/g, '\n');
  try { return fs.readFileSync(v, 'utf8'); } catch (e) { return ''; }
}

// 纯 JS 生成自签证书（EC P-256 + SHA256），不依赖 openssl 或其他包
function derLen(n) {
  if (n < 0x80) return Buffer.from([n]);
  const b = []; while (n > 0) { b.unshift(n & 0xff); n >>= 8; }
  return Buffer.from([0x80 | b.length, ...b]);
}
function der(tag, ...parts) { const body = Buffer.concat(parts); return Buffer.concat([Buffer.from([tag]), derLen(body.length), body]); }
const derSeq = (...p) => der(0x30, ...p);
function derOid(oid) {
  const a = oid.split('.').map(Number), out = [40 * a[0] + a[1]];
  for (const n of a.slice(2)) { const t = [n & 0x7f]; let v = n >> 7; while (v > 0) { t.unshift((v & 0x7f) | 0x80); v >>= 7; } out.push(...t); }
  return der(0x06, Buffer.from(out));
}
function derInt(buf) { if (buf[0] & 0x80) buf = Buffer.concat([Buffer.from([0]), buf]); return der(0x02, buf); }
function derTime(d) { const s = d.toISOString().replace(/[-:T]/g, '').slice(0, 14) + 'Z'; return d.getUTCFullYear() < 2050 ? der(0x17, Buffer.from(s.slice(2))) : der(0x18, Buffer.from(s)); }

function ipv6Bytes(ip) {
  const [l, r = ''] = ip.split('::');
  const L = l ? l.split(':') : [], R = r ? r.split(':') : [];
  const parts = ip.includes('::') ? [...L, ...Array(8 - L.length - R.length).fill('0'), ...R] : L;
  const b = Buffer.alloc(16); parts.forEach((h, i) => b.writeUInt16BE(parseInt(h, 16) || 0, i * 2)); return b;
}

function genSelfSigned(host) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const sigAlg = derSeq(derOid('1.2.840.10045.4.3.2'));
  const name = derSeq(der(0x31, derSeq(derOid('2.5.4.3'), der(0x0c, Buffer.from(host)))));
  const now = new Date(Date.now() - 86400000), end = new Date(Date.now() + 3650 * 86400000);
  const san = net.isIP(host)
    ? der(0x87, net.isIPv4(host) ? Buffer.from(host.split('.').map(Number)) : ipv6Bytes(host))
    : der(0x82, Buffer.from(host));
  const ext = der(0xa3, derSeq(derSeq(derOid('2.5.29.17'), der(0x04, derSeq(san)))));
  const tbs = derSeq(der(0xa0, derInt(Buffer.from([2]))), derInt(crypto.randomBytes(16)), sigAlg, name, derSeq(derTime(now), derTime(end)), name, spki, ext);
  const sig = crypto.sign('sha256', tbs, privateKey);
  const cert = derSeq(tbs, sigAlg, der(0x03, Buffer.concat([Buffer.from([0]), sig])));
  const pem = '-----BEGIN CERTIFICATE-----\n' + cert.toString('base64').match(/.{1,64}/g).join('\n') + '\n-----END CERTIFICATE-----\n';
  return { cert: pem, key: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
}

function loadTlsOptions(host) {
  const cert = readPem(TLS_CERT), key = readPem(TLS_KEY);
  if (cert && key) { tlsSelfSigned = false; log('[TLS] 使用自备证书'); return { cert, key }; }
  tlsSelfSigned = true;
  const dir = path.join(__dirname, '.tls'), cf = path.join(dir, 'cert.pem'), kf = path.join(dir, 'key.pem'), hf = path.join(dir, 'host');
  try { if (readText(hf).trim() === host) { const c = fs.readFileSync(cf, 'utf8'), k = fs.readFileSync(kf, 'utf8'); if (c && k) return { cert: c, key: k }; } } catch (e) { }
  const pair = genSelfSigned(host);
  try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(cf, pair.cert); fs.writeFileSync(kf, pair.key, { mode: 0o600 }); fs.writeFileSync(hf, host); } catch (e) { } // 只读目录就只放内存
  log('[TLS] 已生成自签证书:', host);
  return pair;
}

async function startServer() {
  if (!TLS_MODE) return httpServer.listen(PORT, onListening);
  await getip();
  let opts;
  try { opts = loadTlsOptions(CurrentDomain); } catch (e) { logErr('[TLS] 证书失败，改为不加密:', e.message); return httpServer.listen(PORT, onListening); }
  const httpsServer = https.createServer(opts, requestHandler);
  httpsServer.on('upgrade', upgradeHandler);
  httpsServer.on('tlsClientError', () => { });
  const front = net.createServer((socket) => {
    socket.once('error', () => socket.destroy());
    socket.once('readable', () => {
      const head = socket.read(1);
      if (!head) return socket.destroy();
      socket.unshift(head);
      (head[0] === 0x16 ? httpsServer : httpServer).emit('connection', socket);
    });
  });
  front.listen(PORT, onListening);
}

function onListening() {
  startKomariAgent().catch(err => console.error('error', err));
  addAccessTask();
  console.log(`Server is running on ${PORT}${TLS_MODE ? ' (http + tls)' : ''}`);
}

startServer().catch(e => console.error('start error', e));
