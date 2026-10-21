#!/usr/bin/env python3
"""aimili-lite manager

VPNGate 公共 OpenVPN 节点  ->  每条隧道一个 fwmark 策略路由  ->  Xray(VLESS+WS) 按 UUID 分流
->  Caddy 提供 TLS(443) 与订阅文件。

只依赖 python3 标准库。需要 root（创建 tun、策略路由、SO_MARK）。
"""
import base64
import csv
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

BASE = os.environ.get("AIMILI_BASE", "/opt/aimili-lite")
CFG = json.load(open(os.path.join(BASE, "config.json"), encoding="utf-8"))
RUN = os.path.join(BASE, "run")
WEB = os.path.join(BASE, "web")
os.makedirs(RUN, exist_ok=True)
os.makedirs(WEB, exist_ok=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S",
                    stream=sys.stdout)
log = logging.getLogger("aimili")


def C(key, default=None):
    v = CFG.get(key)
    return default if v is None else v


OPENVPN = C("openvpn_bin", "openvpn")
MAX_NODES = int(C("max_nodes", 30))
BATCH = int(C("batch", 12))
REFRESH = int(C("refresh", 600))
CHECK_EVERY = int(C("check_interval", 45))
CONNECT_TIMEOUT = int(C("connect_timeout", 35))
LIST_URLS = C("list_urls", ["http://www.vpngate.net/api/iphone/"])
PROBE = C("probe", {"host": "www.cloudflare.com", "path": "/cdn-cgi/trace", "port": 80})
INFO_URL = C("info_probe", {"host": "ip-api.com",
                            "path": "/json/?fields=status,country,countryCode,isp,hosting,proxy,mobile,query",
                            "port": 80})
ONLY_RESI = bool(C("only_residential", False))
COUNTRIES = [c.upper() for c in C("countries", [])]
XRAY_RESTART = C("xray_restart_cmd", ["systemctl", "restart", "aimili-xray"])
SO_MARK = 36
MARK_BASE = 1000      # fwmark / route table = MARK_BASE + slot
PREF_BASE = 10000     # ip rule priority = PREF_BASE + slot


def sh(*args, check=False):
    r = subprocess.run(list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if check and r.returncode != 0:
        raise RuntimeError("%s -> %s" % (" ".join(args), r.stderr.strip()))
    return r


# --------------------------------------------------------------------------- 网络辅助
def openvpn_version():
    try:
        out = sh(OPENVPN, "--version").stdout.splitlines()[0]
        m = re.search(r"OpenVPN (\d+)\.(\d+)", out)
        return (int(m.group(1)), int(m.group(2)))
    except Exception:
        return (2, 4)


OVPN_VER = openvpn_version()


def cleanup_net():
    """删除本程序遗留的策略路由。"""
    out = sh("ip", "rule", "show").stdout
    tables = set()
    for line in out.splitlines():
        m = re.match(r"\s*(\d+):.*lookup (\d+)", line)
        if m and PREF_BASE <= int(m.group(1)) < PREF_BASE + 1000:
            sh("ip", "rule", "del", "pref", m.group(1))
            tables.add(m.group(2))
    for t in tables:
        sh("ip", "route", "flush", "table", t)


def set_rp_filter(dev=None):
    # 回包从 tun 进来，严格 rp_filter 会丢包
    for name in ("all", "default") if dev is None else (dev,):
        p = "/proc/sys/net/ipv4/conf/%s/rp_filter" % name
        try:
            with open(p, "w") as f:
                f.write("0")
        except Exception:
            pass


def iface_ip(dev):
    out = sh("ip", "-4", "-o", "addr", "show", "dev", dev).stdout
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else None


def http_get(host, path, mark=None, port=80, timeout=10):
    """通过 SO_MARK 指定走哪条隧道的最小 HTTP/1.0 GET。"""
    ip = socket.gethostbyname(host)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if mark:
            s.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
        s.settimeout(timeout)
        s.connect((ip, port))
        s.sendall(("GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: curl/8.5\r\nConnection: close\r\n\r\n"
                   % (path, host)).encode())
        buf = b""
        while len(buf) < 65536:
            d = s.recv(4096)
            if not d:
                break
            buf += d
    finally:
        s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status = int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/") else 0
    return status, body.decode("utf-8", "replace")


def probe_exit(mark):
    """返回 (出口IP, 国家码) 或 None。"""
    try:
        st, body = http_get(PROBE["host"], PROBE["path"], mark, PROBE.get("port", 80), 10)
        if st != 200:
            return None
        kv = dict(re.findall(r"^(\w+)=(.*)$", body, re.M))
        if kv.get("ip"):
            return kv["ip"].strip(), (kv.get("loc") or "").strip().upper()
    except Exception:
        pass
    return None


def probe_info(mark):
    if not INFO_URL:
        return {}
    for _ in range(2):
        try:
            st, body = http_get(INFO_URL["host"], INFO_URL["path"], mark, INFO_URL.get("port", 80), 10)
            d = json.loads(body)
            if d.get("status") == "success":
                return d
        except Exception:
            pass
        time.sleep(1)
    return {}


# --------------------------------------------------------------------------- VPNGate
def fetch_vpngate():
    raw = None
    for u in LIST_URLS:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
            raw = urllib.request.urlopen(req, timeout=40).read()
            if len(raw) > 2000:
                open(os.path.join(RUN, "vpngate.csv"), "wb").write(raw)
                break
        except Exception as e:
            log.info("获取列表失败 %s: %s", u, e)
            raw = None
    if raw is None:
        p = os.path.join(RUN, "vpngate.csv")
        if os.path.exists(p):
            log.info("使用本地缓存的节点列表")
            raw = open(p, "rb").read()
        else:
            return []
    lines = [l for l in raw.decode("utf-8", "replace").splitlines() if l and not l.startswith("*")]
    if not lines:
        return []
    lines[0] = lines[0].lstrip("#")
    out = []
    for r in csv.DictReader(lines):
        try:
            b64 = r.get("OpenVPN_ConfigData_Base64")
            ip = r.get("IP")
            if not b64 or not ip:
                continue
            cfg = base64.b64decode(b64).decode("utf-8", "replace")
            cc = (r.get("CountryShort") or "").upper()
            if COUNTRIES and cc not in COUNTRIES:
                continue
            out.append({"ip": ip, "cc": cc, "score": int(r.get("Score") or 0), "config": cfg})
        except Exception:
            continue
    # 按国家轮询交叉排序（每国内部按 score），让节点尽量分散
    groups = {}
    for c in sorted(out, key=lambda x: -x["score"]):
        groups.setdefault(c["cc"], []).append(c)
    mixed = []
    while groups:
        for k in list(groups):
            mixed.append(groups[k].pop(0))
            if not groups[k]:
                del groups[k]
    return mixed


_DROP = re.compile(r"^\s*(dev|dev-type|redirect-gateway|route|route-nopull|route-gateway|script-security|up|down|"
                   r"user|group|daemon|log|log-append|status|writepid|resolv-retry|persist-tun|persist-key|"
                   r"auth-user-pass|ping|ping-exit|ping-restart|keepalive|data-ciphers|data-ciphers-fallback|"
                   r"ncp-ciphers|tls-cert-profile|connect-retry-max|verb|http-proxy|http-proxy-retry)\b", re.I)


def make_ovpn(text, dev):
    keep, inblock = [], False
    for line in text.splitlines():
        s = line.strip()
        if re.match(r"^<[a-z0-9-]+>$", s):
            inblock = True
        if inblock or not _DROP.match(line):
            keep.append(line)
        if re.match(r"^</[a-z0-9-]+>$", s):
            inblock = False
    extra = ["", "dev %s" % dev, "dev-type tun", "route-nopull",
             'pull-filter ignore "redirect-gateway"', 'pull-filter ignore "route"',
             'pull-filter ignore "dhcp-option"', 'pull-filter ignore "block-outside-dns"',
             "script-security 0", "resolv-retry 0", "connect-retry-max 1",
             "ping 5", "ping-exit 30", "verb 3"]
    if OVPN_VER >= (2, 5):
        extra += ["data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305",
                  "tls-cert-profile insecure"]
    return "\n".join(keep + extra) + "\n"


# --------------------------------------------------------------------------- 隧道
class Tunnel:
    def __init__(self, slot, cand):
        self.slot = slot
        self.cand = cand
        self.dev = "vg%d" % slot
        self.mark = MARK_BASE + slot
        self.table = MARK_BASE + slot
        self.pref = PREF_BASE + slot
        self.proc = None
        self.fails = 0
        self.exit_ip = ""
        self.loc = cand["cc"]
        self.hosting = None
        self.isp = ""
        self.vpn_ip = cand["ip"]
        self.uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, "%s:%s" % (CFG["secret"], self.vpn_ip)))
        self.logf = os.path.join(RUN, "%s.log" % self.dev)

    def _route(self):
        sh("ip", "route", "replace", "default", "dev", self.dev, "table", str(self.table))
        sh("ip", "rule", "del", "pref", str(self.pref))
        sh("ip", "rule", "add", "fwmark", str(self.mark), "lookup", str(self.table), "pref", str(self.pref))
        set_rp_filter(self.dev)

    def bring_up(self):
        path = os.path.join(RUN, "%s.ovpn" % self.dev)
        with open(path, "w") as f:
            f.write(make_ovpn(self.cand["config"], self.dev))
        lf = open(self.logf, "w")
        try:
            self.proc = subprocess.Popen([OPENVPN, "--config", path], stdout=lf, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, start_new_session=True)
        finally:
            lf.close()
        deadline = time.time() + CONNECT_TIMEOUT
        ok = False
        while time.time() < deadline:
            if self.proc.poll() is not None:
                return False
            try:
                if "Initialization Sequence Completed" in open(self.logf, errors="replace").read():
                    ok = True
                    break
            except Exception:
                pass
            time.sleep(1)
        if not ok or not iface_ip(self.dev):
            return False
        self._route()
        res = probe_exit(self.mark)
        if not res:
            return False
        self.exit_ip, loc = res
        if loc:
            self.loc = loc
        info = probe_info(self.mark)
        if info:
            self.hosting = bool(info.get("hosting"))
            self.isp = info.get("isp", "")
            if info.get("countryCode"):
                self.loc = info["countryCode"].upper()
        if ONLY_RESI and self.hosting:
            log.info("[%s] %s 是机房IP，按设置丢弃", self.dev, self.exit_ip)
            return False
        return True

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def healthy(self):
        if not self.alive():
            return False
        if probe_exit(self.mark):
            self.fails = 0
            return True
        self.fails += 1
        return self.fails < 3

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=5)
            except Exception:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except Exception:
                    pass
        sh("ip", "rule", "del", "pref", str(self.pref))
        sh("ip", "route", "flush", "table", str(self.table))
        sh("ip", "link", "del", self.dev)


# --------------------------------------------------------------------------- 输出：xray 配置 + 订阅
def flag(cc):
    if len(cc) == 2 and cc.isalpha():
        return "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc.upper())
    return "🌐"


def build_xray(nodes):
    clients, outbounds, rules = [], [{"tag": "block", "protocol": "blackhole"}], []
    for t in nodes:
        email = "n%d@aimili" % t.slot
        clients.append({"id": t.uuid, "email": email})
        outbounds.append({"tag": "o%d" % t.slot, "protocol": "freedom",
                          "settings": {"domainStrategy": "UseIPv4"},
                          "streamSettings": {"sockopt": {"mark": t.mark}}})
        rules.append({"type": "field", "user": [email], "outboundTag": "o%d" % t.slot})
    if not clients:   # xray 不接受空 clients，放一个占位用户（路由到 block）
        clients.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, CFG["secret"] + ":placeholder")),
                        "email": "none@aimili"})
    rules.append({"type": "field", "network": "tcp,udp", "outboundTag": "block"})
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "in", "listen": "127.0.0.1", "port": int(CFG["xray_port"]), "protocol": "vless",
            "settings": {"clients": clients, "decryption": "none"},
            "streamSettings": {"network": "ws", "wsSettings": {"path": CFG["ws_path"]}},
        }],
        "outbounds": outbounds,
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


def vless_link(t):
    host = CFG["host"]
    q = [("encryption", "none"), ("security", "tls")]
    if CFG.get("domain"):
        q.append(("sni", host))
    q += [("fp", "chrome"), ("type", "ws"), ("host", host), ("path", CFG["ws_path"])]
    if CFG.get("insecure"):
        q.append(("allowInsecure", "1"))
    kind = "" if t.hosting is None else (" 机房" if t.hosting else " 住宅")
    name = "%s%s %s%s" % (flag(t.loc), t.loc or "??", t.exit_ip, kind)
    return "vless://%s@%s:%s?%s#%s" % (t.uuid, host, CFG.get("port", 443),
                                        urllib.parse.urlencode(q, quote_via=urllib.parse.quote),
                                        urllib.parse.quote(name))


def atomic_write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
    os.replace(tmp, path)


_last_xray = None


def publish(active):
    global _last_xray
    nodes = sorted(active.values(), key=lambda t: (t.loc, t.exit_ip))
    xc = json.dumps(build_xray(nodes), indent=1)
    if xc != _last_xray:
        atomic_write(os.path.join(BASE, "xray.json"), xc)
        r = sh(*XRAY_RESTART)
        if r.returncode != 0:
            log.info("重启 xray 失败: %s", r.stderr.strip())
        _last_xray = xc
    links = [vless_link(t) for t in nodes]
    atomic_write(os.path.join(WEB, "sub.txt"), base64.b64encode("\n".join(links).encode()).decode())
    atomic_write(os.path.join(BASE, "nodes.json"), json.dumps(
        [{"slot": t.slot, "country": t.loc, "exit_ip": t.exit_ip, "vpn_server": t.vpn_ip,
          "hosting": t.hosting, "isp": t.isp, "link": vless_link(t)} for t in nodes],
        ensure_ascii=False, indent=1))
    log.info("订阅已更新：%d 个节点", len(nodes))


# --------------------------------------------------------------------------- 主循环
STOP = threading.Event()


def main():
    cleanup_net()
    set_rp_filter()
    active = {}          # slot -> Tunnel
    bad = {}             # vpn ip -> 重试时间
    candidates, last_fetch = [], 0
    publish(active)
    log.info("openvpn %s.%s, 目标节点数 %d", OVPN_VER[0], OVPN_VER[1], MAX_NODES)

    def shutdown(*_):
        STOP.set()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    last_check = time.time()
    while not STOP.is_set():
        changed = False
        now = time.time()

        # 1) 健康检查 / 剔除坏隧道
        if now - last_check >= CHECK_EVERY and active:
            last_check = now
            ts = list(active.values())
            with ThreadPoolExecutor(max_workers=16) as ex:
                res = list(ex.map(lambda t: t.healthy(), ts))
            for t, ok in zip(ts, res):
                if not ok:
                    log.info("[%s] %s 失效，移除", t.dev, t.exit_ip or t.vpn_ip)
                    t.stop()
                    bad[t.vpn_ip] = now + 1200
                    del active[t.slot]
                    changed = True

        # 2) 补充节点
        if len(active) < MAX_NODES:
            if not candidates or now - last_fetch > REFRESH:
                got = fetch_vpngate()
                if got:
                    candidates, last_fetch = got, now
                    log.info("VPNGate 列表：%d 条候选", len(got))
                else:
                    last_fetch = now - REFRESH + 60   # 1 分钟后重试
            used = {t.vpn_ip for t in active.values()}
            pool = [c for c in candidates if c["ip"] not in used and bad.get(c["ip"], 0) < now]
            batch = pool[:min(BATCH, max(MAX_NODES - len(active), 1) * 2)]
            if batch:
                free = [s for s in range(1, 250) if s not in active]
                tunnels = [Tunnel(free[i], c) for i, c in enumerate(batch)]
                with ThreadPoolExecutor(max_workers=len(tunnels)) as ex:
                    results = list(ex.map(lambda t: t.bring_up(), tunnels))
                for t, ok in zip(tunnels, results):
                    if ok and len(active) < MAX_NODES:
                        active[t.slot] = t
                        changed = True
                        log.info("[%s] 上线 %s %s -> 出口 %s %s", t.dev, t.loc, t.vpn_ip, t.exit_ip,
                                 "" if t.hosting is None else ("机房" if t.hosting else "住宅"))
                    else:
                        t.stop()
                        bad[t.cand["ip"]] = time.time() + (3600 if ok else 1200)
                if changed:
                    publish(active)
                    changed = False
                continue   # 立即进入下一批

        if changed:
            publish(active)
        STOP.wait(5)

    log.info("正在停止…")
    for t in list(active.values()):
        t.stop()
    cleanup_net()


if __name__ == "__main__":
    main()
