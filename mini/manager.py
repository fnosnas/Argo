#!/usr/bin/env python3
"""aimili-mini manager —— 单出口版

VPNGate(OpenVPN) 单条隧道(vg1)  ->  Xray VLESS+WS+TLS(自签证书, 指纹固定)  ->  HTTP 订阅
- 同一时间只保持 1 条隧道；挂了自动换下一个 VPNGate 节点，节点链接(UUID/端口)永远不变
- 隧道断开时出站走 unreachable，绝不会漏出 VPS 本机 IP
- 本进程同时负责拉起并守护 xray，所以只需要保活这一个服务
只依赖 python3 标准库。
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.environ.get("AIMILI_BASE", "/opt/aimili-mini")
CFG = json.load(open(os.path.join(BASE, "config.json"), encoding="utf-8"))
RUN = os.path.join(BASE, "run")
os.makedirs(RUN, exist_ok=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%m-%d %H:%M:%S",
                    stream=sys.stdout)
log = logging.getLogger("aimili")


def C(k, d=None):
    v = CFG.get(k)
    return d if v is None else v


OPENVPN = C("openvpn_bin", "openvpn")
XRAY = C("xray_bin", os.path.join(BASE, "bin", "xray"))
LIST_URLS = C("list_urls", ["http://www.vpngate.net/api/iphone/"])
PROBE = C("probe", {"host": "www.cloudflare.com", "path": "/cdn-cgi/trace", "port": 80})
INFO = C("info_probe", {"host": "ip-api.com",
                        "path": "/json/?fields=status,countryCode,isp,hosting", "port": 80})
COUNTRIES = [c.upper() for c in C("countries", [])]
ONLY_RESI = bool(C("only_residential", False))
PRECHECK = bool(C("precheck", True))
CONNECT_TIMEOUT = int(C("connect_timeout", 35))
CHECK_EVERY = int(C("check_interval", 30))
ROTATE = int(C("rotate_minutes", 0)) * 60   # 0 = 不主动轮换
SO_MARK = 36
DEV, MARK, TABLE, PREF = "vg1", 1001, 1001, 10001
STOP = threading.Event()
SUB_FILE = os.path.join(BASE, "web", "sub.txt")


def sh(*a):
    return subprocess.run(list(a), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)


# ------------------------------------------------------------------ 路由
def kill_leftovers():
    """上次被 kill -9 / 异常退出遗留的 openvpn、xray 子进程。"""
    me = os.getpid()
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            cmd = open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except Exception:
            continue
        if BASE in cmd and ("openvpn" in cmd or "/bin/xray" in cmd) and "manager.py" not in cmd:
            try:
                os.kill(int(d), signal.SIGKILL)
            except Exception:
                pass
    sh("ip", "link", "del", DEV)


def net_setup():
    """规则永久存在；表里先放一条 unreachable，隧道没起来时出站直接失败而不是走本机出口。"""
    sh("ip", "rule", "del", "pref", str(PREF))
    sh("ip", "rule", "add", "fwmark", str(MARK), "lookup", str(TABLE), "pref", str(PREF))
    sh("ip", "route", "flush", "table", str(TABLE))
    sh("ip", "route", "replace", "unreachable", "default", "table", str(TABLE), "metric", "9999")
    for n in ("all", "default"):
        try:
            open("/proc/sys/net/ipv4/conf/%s/rp_filter" % n, "w").write("0")
        except Exception:
            pass


def net_teardown():
    sh("ip", "rule", "del", "pref", str(PREF))
    sh("ip", "route", "flush", "table", str(TABLE))


def tun_route():
    sh("ip", "route", "replace", "default", "dev", DEV, "table", str(TABLE), "metric", "10")
    try:
        open("/proc/sys/net/ipv4/conf/%s/rp_filter" % DEV, "w").write("0")
    except Exception:
        pass


def tun_has_ip():
    return bool(re.search(r"inet \d", sh("ip", "-4", "-o", "addr", "show", "dev", DEV).stdout))


def ovpn_ver():
    try:
        m = re.search(r"OpenVPN (\d+)\.(\d+)", sh(OPENVPN, "--version").stdout)
        return int(m.group(1)), int(m.group(2))
    except Exception:
        return 2, 4


OVER = ovpn_ver()


# ------------------------------------------------------------------ 探测
def http_get(host, path, mark=None, port=80, timeout=10):
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
    st = int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/") else 0
    return st, body.decode("utf-8", "replace")


def probe_exit():
    try:
        st, body = http_get(PROBE["host"], PROBE["path"], MARK, PROBE.get("port", 80))
        if st == 200:
            kv = dict(re.findall(r"^(\w+)=(.*)$", body, re.M))
            if kv.get("ip"):
                return kv["ip"].strip(), (kv.get("loc") or "").upper()
    except Exception:
        pass
    return None


def probe_info():
    if not INFO:
        return {}
    for _ in range(2):
        try:
            st, body = http_get(INFO["host"], INFO["path"], MARK, INFO.get("port", 80))
            d = json.loads(body)
            if d.get("status") == "success":
                return d
        except Exception:
            pass
        time.sleep(1)
    return {}


# ------------------------------------------------------------------ VPNGate
def fetch_list():
    raw = None
    for u in LIST_URLS:
        try:
            raw = urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"}),
                                         timeout=40).read()
            if len(raw) > 2000:
                open(os.path.join(RUN, "vpngate.csv"), "wb").write(raw)
                break
            raw = None
        except Exception as e:
            log.info("获取 VPNGate 列表失败 %s: %s", u, e)
    if raw is None:
        p = os.path.join(RUN, "vpngate.csv")
        if not os.path.exists(p):
            return []
        log.info("使用本地缓存的节点列表")
        raw = open(p, "rb").read()
    lines = [l for l in raw.decode("utf-8", "replace").splitlines() if l and not l.startswith("*")]
    if not lines:
        return []
    lines[0] = lines[0].lstrip("#")
    out = []
    for r in csv.DictReader(lines):
        try:
            b64, ip = r.get("OpenVPN_ConfigData_Base64"), r.get("IP")
            if not b64 or not ip:
                continue
            cc = (r.get("CountryShort") or "").upper()
            if COUNTRIES and cc not in COUNTRIES:
                continue
            out.append({"ip": ip, "cc": cc, "score": int(r.get("Score") or 0),
                        "config": base64.b64decode(b64).decode("utf-8", "replace")})
        except Exception:
            continue
    out.sort(key=lambda x: -x["score"])
    return out


_DROP = re.compile(r"^\s*(dev|dev-type|redirect-gateway|route|route-nopull|route-gateway|script-security|up|down|"
                   r"user|group|daemon|log|log-append|status|writepid|resolv-retry|persist-tun|persist-key|"
                   r"auth-user-pass|ping|ping-exit|ping-restart|keepalive|data-ciphers|data-ciphers-fallback|"
                   r"ncp-ciphers|tls-cert-profile|connect-retry-max|verb|http-proxy|http-proxy-retry)\b", re.I)


def make_ovpn(text):
    keep, inblock = [], False
    for line in text.splitlines():
        s = line.strip()
        if re.match(r"^<[a-z0-9-]+>$", s):
            inblock = True
        if inblock or not _DROP.match(line):
            keep.append(line)
        if re.match(r"^</[a-z0-9-]+>$", s):
            inblock = False
    extra = ["", "dev %s" % DEV, "dev-type tun", "route-nopull",
             'pull-filter ignore "redirect-gateway"', 'pull-filter ignore "route"',
             'pull-filter ignore "dhcp-option"', 'pull-filter ignore "block-outside-dns"',
             "script-security 0", "resolv-retry 0", "connect-retry-max 1",
             "ping 5", "ping-exit 30", "verb 3"]
    if OVER >= (2, 5):
        extra += ["data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305",
                  "tls-cert-profile insecure"]
    return "\n".join(keep + extra) + "\n"


def tcp_alive(cfg):
    """TCP 型节点先做 4 秒握手预检，死节点不浪费 35 秒。UDP 无法预检，直接放行。"""
    m = re.search(r"^remote\s+(\S+)\s+(\d+)", cfg, re.M)
    p = re.search(r"^proto\s+(\w+)", cfg, re.M)
    if not m or (p and p.group(1).lower().startswith("udp")):
        return True
    try:
        socket.create_connection((m.group(1), int(m.group(2))), 4).close()
        return True
    except Exception:
        return False


# ------------------------------------------------------------------ 隧道
class Tunnel:
    def __init__(self, cand):
        self.cand = cand
        self.proc = None
        self.exit_ip = ""
        self.loc = cand["cc"]
        self.hosting = None
        self.fails = 0
        self.since = time.time()
        self.logf = os.path.join(RUN, "openvpn.log")

    def up(self):
        path = os.path.join(RUN, "vg1.ovpn")
        open(path, "w").write(make_ovpn(self.cand["config"]))
        with open(self.logf, "w") as lf:
            self.proc = subprocess.Popen([OPENVPN, "--config", path], stdout=lf, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, start_new_session=True)
        end = time.time() + CONNECT_TIMEOUT
        while time.time() < end and not STOP.is_set():
            if self.proc.poll() is not None:
                return False
            try:
                if "Initialization Sequence Completed" in open(self.logf, errors="replace").read():
                    break
            except Exception:
                pass
            time.sleep(1)
        else:
            return False
        if not tun_has_ip():
            return False
        tun_route()
        r = probe_exit()
        if not r:
            return False
        self.exit_ip, loc = r
        if loc:
            self.loc = loc
        info = probe_info()
        if info:
            self.hosting = bool(info.get("hosting"))
            if info.get("countryCode"):
                self.loc = info["countryCode"].upper()
        if ONLY_RESI and self.hosting:
            log.info("出口 %s 是机房 IP，按设置跳过", self.exit_ip)
            return False
        return True

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def healthy(self):
        if not self.alive():
            return False
        if probe_exit():
            self.fails = 0
            return True
        self.fails += 1
        return self.fails < 3

    def down(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=6)
            except Exception:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except Exception:
                    pass
        sh("ip", "link", "del", DEV)
        sh("ip", "route", "replace", "unreachable", "default", "table", str(TABLE), "metric", "9999")


# ------------------------------------------------------------------ xray / 订阅
def flag(cc):
    return "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc) if len(cc) == 2 and cc.isalpha() else "🌐"


def link(t):
    h, port = CFG["host"], CFG["pub_node_port"]
    q = [("encryption", "none"), ("security", "tls"), ("sni", h), ("alpn", "http/1.1"), ("fp", "chrome"),
         ("pcs", CFG["pin"]), ("type", "ws"), ("host", h), ("path", CFG["ws_path"])]
    kind = "" if t.hosting is None else (" 机房" if t.hosting else " 住宅")
    name = "%s%s %s%s" % (flag(t.loc), t.loc or "??", t.exit_ip, kind)
    return "vless://%s@%s:%s?%s#%s" % (CFG["uuid"], h, port,
                                        urllib.parse.urlencode(q, quote_via=urllib.parse.quote),
                                        urllib.parse.quote(name))


def publish(t):
    os.makedirs(os.path.dirname(SUB_FILE), exist_ok=True)
    if t is None:
        try:
            os.remove(SUB_FILE)
        except FileNotFoundError:
            pass
        return
    l = link(t)
    tmp = SUB_FILE + ".tmp"
    open(tmp, "w").write(base64.b64encode(l.encode()).decode())
    os.replace(tmp, SUB_FILE)
    open(os.path.join(BASE, "node.txt"), "w").write(l + "\n")
    log.info("订阅已更新 -> %s %s", t.loc, t.exit_ip)


def write_xray():
    cfg = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "in", "listen": "0.0.0.0", "port": int(CFG["node_port"]), "protocol": "vless",
            "settings": {"clients": [{"id": CFG["uuid"]}], "decryption": "none"},
            "streamSettings": {
                "network": "ws", "security": "tls",
                "tlsSettings": {"alpn": ["http/1.1"], "certificates": [
                    {"certificateFile": os.path.join(BASE, "cert.pem"), "keyFile": os.path.join(BASE, "key.pem")}]},
                "wsSettings": {"path": CFG["ws_path"]}}}],
        "outbounds": [{"tag": "vg", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"},
                       "streamSettings": {"sockopt": {"mark": MARK}}}],
    }
    p = os.path.join(BASE, "xray.json")
    open(p, "w").write(json.dumps(cfg, indent=1))
    return p


class SubHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path.split("?")[0] == "/" + CFG["token"]
        body, code = b"Not Found", 404
        if ok:
            try:
                body, code = open(SUB_FILE, "rb").read(), 200
            except FileNotFoundError:
                body, code = b"node not ready, retry in a minute", 503
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


# ------------------------------------------------------------------ 主循环
def main():
    kill_leftovers()
    net_setup()
    publish(None)
    xray_cfg = write_xray()
    srv = ThreadingHTTPServer(("0.0.0.0", int(CFG["sub_port"])), SubHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log.info("订阅端口 %s 已监听；节点端口 %s；openvpn %d.%d", CFG["sub_port"], CFG["node_port"], *OVER)

    def stop(*_):
        STOP.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    xp, xray_next = None, 0
    cur, bad, cands, fetched, last_chk = None, {}, [], 0, time.time()

    while not STOP.is_set():
        now = time.time()

        # xray 保活
        if xp is None or xp.poll() is not None:
            if xp is not None:
                log.info("xray 退出(%s)，重启", xp.returncode)
            if now >= xray_next:
                xp = subprocess.Popen([XRAY, "run", "-c", xray_cfg], stdout=sys.stdout, stderr=sys.stderr)
                xray_next = now + 3

        # 当前隧道巡检
        if cur and (not cur.alive() or now - last_chk >= CHECK_EVERY):
            last_chk = now
            expired = ROTATE and now - cur.since > ROTATE
            if expired or not cur.healthy():
                log.info("当前出口 %s %s，更换", cur.exit_ip, "到期轮换" if expired else "失效")
                bad[cur.cand["ip"]] = now + (60 if expired else 1800)
                cur.down()
                cur = None
                publish(None)

        # 没有隧道就找一个
        if cur is None and not STOP.is_set():
            if not cands or now - fetched > 900:
                got = fetch_list()
                if got:
                    cands, fetched = got, now
                    log.info("VPNGate 候选 %d 条", len(got))
                else:
                    fetched = now - 840
            pool = [c for c in cands if bad.get(c["ip"], 0) < time.time()]
            tried = 0
            for c in pool:
                if STOP.is_set() or tried >= 12:
                    break
                if PRECHECK and not tcp_alive(c["config"]):
                    bad[c["ip"]] = time.time() + 3600
                    continue
                tried += 1
                t = Tunnel(c)
                log.info("尝试 %s %s", c["cc"], c["ip"])
                if t.up():
                    cur, last_chk = t, time.time()
                    log.info("上线 %s -> 出口 %s %s", c["ip"], t.exit_ip,
                             "" if t.hosting is None else ("机房" if t.hosting else "住宅"))
                    publish(t)
                    break
                t.down()
                bad[c["ip"]] = time.time() + 3600
            if cur is None:
                log.info("本轮没有可用出口，20 秒后重试")
                STOP.wait(20)
                continue
        STOP.wait(3)

    log.info("正在停止…")
    if cur:
        cur.down()
    if xp and xp.poll() is None:
        xp.terminate()
        try:
            xp.wait(5)
        except Exception:
            xp.kill()
    net_teardown()
    srv.shutdown()


if __name__ == "__main__":
    main()
