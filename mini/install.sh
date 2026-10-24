#!/bin/sh
# aimili-mini 一键安装（单出口版，适合 NAT 小鸡）
#   VPNGate(OpenVPN) 单条隧道 -> Xray VLESS+WS+TLS(自签证书 + 指纹固定) -> 一条订阅链接
#   系统：Alpine / Debian / Ubuntu（POSIX sh，无需 bash）。自动保活：systemd / OpenRC / 兜底守护。
#
# 用法（root）：
#   NODE_PORT=20001 SUB_PORT=20002 sh install.sh
#
# 变量：
#   NODE_PORT      节点监听端口(容器内)        默认 8443
#   SUB_PORT       订阅监听端口(容器内)        默认 8080
#   PUB_NODE_PORT  节点对外端口(NAT 映射后)     默认 = NODE_PORT
#   PUB_SUB_PORT   订阅对外端口(NAT 映射后)     默认 = SUB_PORT
#   HOST           对外 IP 或域名               默认自动探测
#   COUNTRIES      只要这些国家，如 "JP,KR"     默认不限
#   ONLY_RESIDENTIAL=1  只保留非机房出口
#   ROTATE_MINUTES 每隔多少分钟主动换出口      默认 0=不换
# 卸载：sh install.sh uninstall
set -eu

BASE=/opt/aimili-mini
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/fnosnas/Argo/main/mini}"
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /nonexistent)"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; N='\033[0m'
say() { printf "%b\n" "$*"; }
die() { say "${R}$*${N}"; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 运行"

HAS_SYSTEMD=0; [ -d /run/systemd/system ] && HAS_SYSTEMD=1
HAS_OPENRC=0;  command -v rc-service >/dev/null 2>&1 && command -v openrc-run >/dev/null 2>&1 && HAS_OPENRC=1

stop_all() {
  if [ "$HAS_SYSTEMD" = 1 ]; then systemctl disable --now aimili-mini >/dev/null 2>&1 || true; fi
  if [ "$HAS_OPENRC" = 1 ]; then rc-service aimili-mini stop >/dev/null 2>&1 || true; rc-update del aimili-mini >/dev/null 2>&1 || true; fi
  [ -f "$BASE/guard.pid" ] && kill "$(cat "$BASE/guard.pid")" >/dev/null 2>&1 || true
  pkill -f "$BASE/manager.py" >/dev/null 2>&1 || true
  pkill -f "$BASE/bin/xray" >/dev/null 2>&1 || true
  pkill -f "openvpn --config $BASE" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "uninstall" ]; then
  stop_all
  rm -f /etc/systemd/system/aimili-mini.service /etc/init.d/aimili-mini
  [ "$HAS_SYSTEMD" = 1 ] && systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then crontab -l 2>/dev/null | grep -v "$BASE" | crontab - 2>/dev/null || true; fi
  ip rule del pref 10001 >/dev/null 2>&1 || true
  ip link del vg1 >/dev/null 2>&1 || true
  rm -rf "$BASE"
  say "${G}已卸载${N}"; exit 0
fi

# ------------------------------------------------------------ 端口参数
NODE_PORT="${NODE_PORT:-}"; SUB_PORT="${SUB_PORT:-}"
if [ -z "$NODE_PORT" ] || [ -z "$SUB_PORT" ]; then
  if [ -r /dev/tty ]; then   # 没传变量就交互询问
    [ -n "$NODE_PORT" ] || { printf "节点端口(容器内监听) [8443]: " >/dev/tty; read -r NODE_PORT </dev/tty || true; }
    [ -n "$SUB_PORT" ]  || { printf "订阅端口(容器内监听) [8080]: " >/dev/tty; read -r SUB_PORT </dev/tty || true; }
  fi
fi
NODE_PORT="${NODE_PORT:-8443}"; SUB_PORT="${SUB_PORT:-8080}"
PUB_NODE_PORT="${PUB_NODE_PORT:-$NODE_PORT}"; PUB_SUB_PORT="${PUB_SUB_PORT:-$SUB_PORT}"
for v in "$NODE_PORT" "$SUB_PORT" "$PUB_NODE_PORT" "$PUB_SUB_PORT"; do
  case "$v" in ''|*[!0-9]*) die "端口必须是数字：$v" ;; esac
  [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || die "端口超出范围：$v"
done
[ "$NODE_PORT" != "$SUB_PORT" ] || die "节点端口和订阅端口不能相同"

# ------------------------------------------------------------ 系统
OS_ID=""; [ -f /etc/os-release ] && OS_ID=$(. /etc/os-release && echo "${ID:-}")
case "$(uname -m)" in
  x86_64|amd64)  XARCH=64 ;;
  aarch64|arm64) XARCH=arm64-v8a ;;
  *) die "不支持的架构 $(uname -m)" ;;
esac

say "${Y}[1/6] 安装依赖（$OS_ID）${N}"
case "$OS_ID" in
  alpine)
    apk add --no-cache openvpn curl unzip python3 iproute2 openssl ca-certificates procps >/dev/null ;;
  debian|ubuntu)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq openvpn curl unzip python3 iproute2 openssl ca-certificates procps cron >/dev/null ;;
  *)
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq openvpn curl unzip python3 iproute2 openssl ca-certificates procps >/dev/null
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache openvpn curl unzip python3 iproute2 openssl ca-certificates procps >/dev/null
    else die "仅支持 Alpine / Debian / Ubuntu"; fi ;;
esac
command -v openvpn >/dev/null 2>&1 || die "openvpn 安装失败"
command -v python3 >/dev/null 2>&1 || die "python3 安装失败"

# ------------------------------------------------------------ TUN / 路由能力自检
say "${Y}[2/6] 检测 TUN 虚拟网卡与策略路由${N}"
if [ ! -c /dev/net/tun ]; then mkdir -p /dev/net && mknod /dev/net/tun c 10 200 2>/dev/null && chmod 600 /dev/net/tun || true; fi
if ! openvpn --mktun --dev vgtest >/dev/null 2>&1; then
  die "无法创建 TUN 网卡。请到小鸡面板里开启 TUN/TAP（有的叫“TUN/TAP”或“开启 tun 模块”），开启后重启小鸡再运行本脚本。"
fi
openvpn --rmtun --dev vgtest >/dev/null 2>&1 || true
if ! { ip rule add fwmark 9 lookup 9 pref 19999 && ip rule del pref 19999; } >/dev/null 2>&1; then
  die "无法添加策略路由(ip rule)，容器缺少 NET_ADMIN 权限，本项目无法在这台小鸡上运行。"
fi

# ------------------------------------------------------------ 下载
mkdir -p "$BASE/bin" "$BASE/run" "$BASE/web"
stop_all
say "${Y}[3/6] 下载程序${N}"
if [ -f "$SELF_DIR/manager.py" ]; then cp "$SELF_DIR/manager.py" "$BASE/manager.py"
else curl -fsSL "$RAW_BASE/manager.py" -o "$BASE/manager.py" || die "下载 manager.py 失败：$RAW_BASE/manager.py"; fi
python3 -m py_compile "$BASE/manager.py" || die "manager.py 校验失败"
if [ ! -x "$BASE/bin/xray" ]; then
  curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XARCH}.zip" || die "下载 Xray 失败"
  unzip -qo /tmp/xray.zip xray -d "$BASE/bin"; rm -f /tmp/xray.zip; chmod +x "$BASE/bin/xray"
fi

# ------------------------------------------------------------ 配置 / 证书
say "${Y}[4/6] 生成配置与自签证书${N}"
if [ -z "${HOST:-}" ]; then
  for u in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
    HOST=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d ' \r\n' || true); [ -n "$HOST" ] && break
  done
fi
[ -n "${HOST:-}" ] || die "取不到公网 IP，请加 HOST=你的IP 再运行"

OLD="$BASE/config.json"
if [ -f "$OLD" ]; then   # 重装保持 UUID/token/路径/证书不变，订阅与节点不用重新导入
  eval "$(python3 -c "
import json,shlex
d=json.load(open('$OLD'))
for k in ('uuid','token','ws_path'): print('%s=%s' % (k.upper(), shlex.quote(d[k])))
")"
else
  UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
  TOKEN=$(openssl rand -hex 12); WS_PATH="/$(openssl rand -hex 6)"
fi
if [ ! -f "$BASE/cert.pem" ] || [ ! -f "$BASE/key.pem" ]; then
  SAN="DNS:localhost"; case "$HOST" in *[!0-9.]*) SAN="DNS:$HOST" ;; *) SAN="IP:$HOST" ;; esac
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$HOST" -addext "subjectAltName=$SAN" -keyout "$BASE/key.pem" -out "$BASE/cert.pem" >/dev/null 2>&1 \
    || die "生成证书失败"
  chmod 600 "$BASE/key.pem"
fi
PIN=$(openssl x509 -in "$BASE/cert.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}')
[ ${#PIN} -eq 64 ] || die "证书指纹计算失败"

OVPN_BIN=$(command -v openvpn)
AIMILI_UUID="$UUID" AIMILI_TOKEN="$TOKEN" AIMILI_WS="$WS_PATH" AIMILI_PIN="$PIN" AIMILI_HOST="$HOST" \
AIMILI_NP="$NODE_PORT" AIMILI_SP="$SUB_PORT" AIMILI_PNP="$PUB_NODE_PORT" AIMILI_PSP="$PUB_SUB_PORT" \
AIMILI_OVPN="$OVPN_BIN" python3 - "$BASE/config.json" <<'PY'
import json, os, sys
e = os.environ
cc = [c.strip().upper() for c in e.get("COUNTRIES", "").split(",") if c.strip()]
json.dump({
    "uuid": e["AIMILI_UUID"], "token": e["AIMILI_TOKEN"], "ws_path": e["AIMILI_WS"], "pin": e["AIMILI_PIN"],
    "host": e["AIMILI_HOST"], "node_port": int(e["AIMILI_NP"]), "sub_port": int(e["AIMILI_SP"]),
    "pub_node_port": int(e["AIMILI_PNP"]), "pub_sub_port": int(e["AIMILI_PSP"]),
    "countries": cc, "only_residential": e.get("ONLY_RESIDENTIAL", "") == "1",
    "rotate_minutes": int(e.get("ROTATE_MINUTES", "0") or 0),
    "openvpn_bin": e["AIMILI_OVPN"], "xray_bin": "/opt/aimili-mini/bin/xray",
}, open(sys.argv[1], "w"), indent=1)
PY
chmod 600 "$BASE/config.json"

# ------------------------------------------------------------ 防火墙（容器内多半没有，有就放行）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$NODE_PORT/tcp" >/dev/null 2>&1 || true; ufw allow "$SUB_PORT/tcp" >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
  for p in "$NODE_PORT" "$SUB_PORT"; do iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT || true; done
fi

# ------------------------------------------------------------ 保活
say "${Y}[5/6] 配置开机自启与自动保活${N}"
cat > "$BASE/guard.sh" <<EOF
#!/bin/sh
# 兜底守护：manager 退出就 5 秒后拉起
echo \$\$ > $BASE/guard.pid
while true; do
  python3 -u $BASE/manager.py >> $BASE/run/manager.log 2>&1
  sleep 5
done
EOF
chmod +x "$BASE/guard.sh"

MODE=""
if [ "$HAS_SYSTEMD" = 1 ]; then
  cat > /etc/systemd/system/aimili-mini.service <<EOF
[Unit]
Description=aimili-mini (VPNGate single exit -> Xray VLESS+WS+TLS)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/env python3 -u $BASE/manager.py
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=30
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable aimili-mini >/dev/null 2>&1 || true
  systemctl restart aimili-mini && MODE="systemd"
elif [ "$HAS_OPENRC" = 1 ]; then
  cat > /etc/init.d/aimili-mini <<EOF
#!/sbin/openrc-run
name="aimili-mini"
description="VPNGate single exit -> Xray VLESS+WS+TLS"
supervisor="supervise-daemon"
command="/usr/bin/python3"
command_args="-u $BASE/manager.py"
output_log="$BASE/run/manager.log"
error_log="$BASE/run/manager.log"
respawn_delay=5
respawn_max=0
depend() { need net; }
EOF
  chmod +x /etc/init.d/aimili-mini
  rc-update add aimili-mini default >/dev/null 2>&1 || true
  if rc-service aimili-mini restart >/dev/null 2>&1 || rc-service aimili-mini start >/dev/null 2>&1; then MODE="openrc"; fi
fi
if [ -z "$MODE" ]; then   # 容器里没有 init 或启动失败：nohup 守护 + cron @reboot
  nohup sh "$BASE/guard.sh" >/dev/null 2>&1 &
  if command -v crontab >/dev/null 2>&1; then
    { crontab -l 2>/dev/null | grep -v "$BASE"; echo "@reboot nohup sh $BASE/guard.sh >/dev/null 2>&1 &"; } | crontab - 2>/dev/null || true
    command -v crond >/dev/null 2>&1 && { pgrep crond >/dev/null 2>&1 || crond >/dev/null 2>&1 || true; }
    command -v cron  >/dev/null 2>&1 && { pgrep -x cron >/dev/null 2>&1 || cron >/dev/null 2>&1 || true; }
  fi
  MODE="guard(nohup+cron)"
fi

# ------------------------------------------------------------ 完成
say "${Y}[6/6] 完成${N}"
SUB="http://$HOST:$PUB_SUB_PORT/$TOKEN"
echo "$SUB" > "$BASE/订阅链接.txt"
say ""
say "${G}==================== 安装完成（保活方式：$MODE） ====================${N}"
say "订阅链接(v2rayN → 订阅分组 → 添加 → 更新订阅)："
say "${G}$SUB${N}"
say ""
say "${Y}请在小鸡面板的端口映射里确认（TCP）：${N}"
say "  外部 $PUB_NODE_PORT  ->  内部 $NODE_PORT   (节点)"
say "  外部 $PUB_SUB_PORT  ->  内部 $SUB_PORT   (订阅)"
say ""
say "出口是后台自动挑选的，装完等 1~2 分钟再更新订阅（更新到 503 说明还没选好）。"
say "看日志:   tail -f $BASE/run/manager.log   (systemd 用 journalctl -u aimili-mini -f)"
say "节点链接: cat $BASE/node.txt"
say "卸载:     sh install.sh uninstall"
