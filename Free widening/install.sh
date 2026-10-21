#!/usr/bin/env bash
# aimili-lite 一键安装：VPNGate(OpenVPN) 出口  ->  Xray VLESS+WS+TLS 入口  ->  一条订阅链接
#
# 用法（root）：
#   DOMAIN=你的域名 bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/Free%20widening/install.sh)
#   bash install.sh                         # 无域名：自签证书，客户端需“允许不安全”(脚本已写进链接)
#   DOMAIN=vpn.example.com bash install.sh  # 有域名(A记录指向本机，若走CF小云朵也可)：自动申请证书
#   MAX_NODES=50 bash install.sh            # 最多同时保持多少个节点(默认30)
#   ONLY_RESIDENTIAL=1 bash install.sh      # 只保留 ip-api 判定为非机房的出口
#   COUNTRIES="JP,KR,US" bash install.sh    # 只要这些国家
#   bash install.sh uninstall               # 卸载
set -euo pipefail

BASE=/opt/aimili-lite
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; N='\033[0m'

[ "$(id -u)" = 0 ] || { echo -e "${R}请用 root 运行${N}"; exit 1; }

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now aimili-lite aimili-caddy aimili-xray 2>/dev/null || true
  rm -f /etc/systemd/system/aimili-{lite,caddy,xray}.service
  systemctl daemon-reload
  # 清理策略路由
  ip rule show | awk -F: '$1>=10000 && $1<11000 {print $1}' | while read -r p; do ip rule del pref "$p" || true; done
  for i in $(seq 1 250); do ip link del "vg$i" 2>/dev/null || true; done
  rm -rf "$BASE"
  echo -e "${G}已卸载${N}"; exit 0
fi

# ---------------------------------------------------------------- 环境检查
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net && mknod /dev/net/tun c 10 200 2>/dev/null && chmod 600 /dev/net/tun || true
fi
if [ ! -c /dev/net/tun ] || ! (exec 3<>/dev/net/tun) 2>/dev/null; then
  echo -e "${R}本机没有可用的 TUN 设备（OpenVZ/部分 LXC 常见）。请在 VPS 后台开启 TUN/TAP，或换 KVM 机型。${N}"; exit 1
fi
case "$(uname -m)" in
  x86_64|amd64)  XARCH=64;          CARCH=amd64 ;;
  aarch64|arm64) XARCH=arm64-v8a;   CARCH=arm64 ;;
  *) echo -e "${R}不支持的架构 $(uname -m)${N}"; exit 1 ;;
esac

echo -e "${Y}[1/6] 安装依赖${N}"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq openvpn curl unzip python3 iproute2 ca-certificates openssl >/dev/null
elif command -v dnf >/dev/null || command -v yum >/dev/null; then
  PM=$(command -v dnf || command -v yum)
  $PM install -y epel-release >/dev/null 2>&1 || true
  $PM install -y openvpn curl unzip python3 iproute ca-certificates openssl >/dev/null
else
  echo -e "${R}仅支持 apt / dnf / yum 系统${N}"; exit 1
fi
command -v openvpn >/dev/null || { echo -e "${R}openvpn 安装失败${N}"; exit 1; }

mkdir -p "$BASE"/{bin,run,web}
# 本地有 manager.py 就用本地的；通过 bash <(curl ...) 运行时则从仓库下载
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/fnosnas/Argo/main/Free%20widening}"
if [ -f "$SRC_DIR/manager.py" ]; then
  cp "$SRC_DIR/manager.py" "$BASE/manager.py"
else
  curl -fsSL "$RAW_BASE/manager.py" -o "$BASE/manager.py" || { echo -e "${R}下载 manager.py 失败：$RAW_BASE/manager.py${N}"; exit 1; }
fi
python3 -m py_compile "$BASE/manager.py" || { echo -e "${R}manager.py 校验失败${N}"; exit 1; }

# ---------------------------------------------------------------- 下载 xray / caddy
echo -e "${Y}[2/6] 下载 Xray 与 Caddy${N}"
if [ ! -x "$BASE/bin/xray" ]; then
  curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XARCH}.zip"
  unzip -qo /tmp/xray.zip xray -d "$BASE/bin"; rm -f /tmp/xray.zip
fi
if [ ! -x "$BASE/bin/caddy" ]; then
  CV=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
  curl -fsSL -o /tmp/caddy.tgz "https://github.com/caddyserver/caddy/releases/download/v${CV}/caddy_${CV}_linux_${CARCH}.tar.gz"
  tar -xzf /tmp/caddy.tgz -C "$BASE/bin" caddy; rm -f /tmp/caddy.tgz
fi
chmod +x "$BASE/bin/xray" "$BASE/bin/caddy"

# ---------------------------------------------------------------- 配置
echo -e "${Y}[3/6] 生成配置${N}"
PUBIP=$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || true)
DOMAIN="${DOMAIN:-}"
HOST="${DOMAIN:-$PUBIP}"
[ -n "$HOST" ] || { echo -e "${R}取不到公网 IP，请用 DOMAIN=xxx 指定${N}"; exit 1; }

if [ -f "$BASE/config.json" ]; then   # 重装时保留 secret / token，订阅链接不变
  SECRET=$(python3 -c "import json;print(json.load(open('$BASE/config.json'))['secret'])")
  TOKEN=$(python3 -c "import json;print(json.load(open('$BASE/config.json'))['token'])")
  WSPATH=$(python3 -c "import json;print(json.load(open('$BASE/config.json'))['ws_path'])")
else
  SECRET=$(openssl rand -hex 16); TOKEN=$(openssl rand -hex 12); WSPATH="/$(openssl rand -hex 6)"
fi

python3 - "$BASE/config.json" <<PY
import json, sys, os
cc = [c.strip().upper() for c in os.environ.get("COUNTRIES", "").split(",") if c.strip()]
cfg = {
  "secret": "$SECRET", "token": "$TOKEN", "ws_path": "$WSPATH",
  "host": "$HOST", "domain": "$DOMAIN", "port": 443,
  "insecure": not bool("$DOMAIN"),
  "xray_port": 10808,
  "max_nodes": int(os.environ.get("MAX_NODES", 30)),
  "only_residential": os.environ.get("ONLY_RESIDENTIAL", "") == "1",
  "countries": cc,
  "openvpn_bin": "$(command -v openvpn)",
}
json.dump(cfg, open(sys.argv[1], "w"), indent=1)
PY
chmod 600 "$BASE/config.json"

if [ -n "$DOMAIN" ]; then
  SITE="$DOMAIN"; TLS=""
else
  SITE="https://$HOST"; TLS="tls internal"
fi
cat > "$BASE/Caddyfile" <<EOF
{
  admin off
  auto_https disable_redirects
}
$SITE {
  $TLS
  @ws path $WSPATH
  handle @ws {
    reverse_proxy 127.0.0.1:10808
  }
  handle /sub/$TOKEN {
    root * $BASE/web
    rewrite * /sub.txt
    header Content-Type "text/plain; charset=utf-8"
    file_server
  }
  handle {
    respond "Not Found" 404
  }
}
EOF

# ---------------------------------------------------------------- systemd
echo -e "${Y}[4/6] 写入服务${N}"
cat > /etc/systemd/system/aimili-xray.service <<EOF
[Unit]
Description=aimili-lite xray
After=network-online.target
ConditionPathExists=$BASE/xray.json
[Service]
ExecStart=$BASE/bin/xray run -c $BASE/xray.json
Restart=always
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/aimili-caddy.service <<EOF
[Unit]
Description=aimili-lite caddy (TLS + 订阅)
After=network-online.target
[Service]
Environment=XDG_DATA_HOME=$BASE/caddy-data XDG_CONFIG_HOME=$BASE/caddy-conf
ExecStart=$BASE/bin/caddy run --config $BASE/Caddyfile --adapter caddyfile
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/aimili-lite.service <<EOF
[Unit]
Description=aimili-lite manager (VPNGate tunnels)
After=network-online.target
Wants=aimili-xray.service
[Service]
ExecStart=/usr/bin/env python3 -u $BASE/manager.py
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=30
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ---------------------------------------------------------------- 防火墙（只开 443 / 80）
echo -e "${Y}[5/6] 放行端口 443/80${N}"
for p in 80 443; do
  if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow ${p}/tcp >/dev/null || true; fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${p}/tcp >/dev/null && firewall-cmd --reload >/dev/null || true; fi
  if command -v iptables >/dev/null && iptables -S INPUT | grep -qE '^-P INPUT (DROP|REJECT)|-j (REJECT|DROP)'; then
    iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport $p -j ACCEPT; fi
done

echo -e "${Y}[6/6] 启动${N}"
systemctl enable --now aimili-caddy aimili-lite >/dev/null 2>&1
systemctl enable aimili-xray >/dev/null 2>&1 || true
systemctl restart aimili-lite

SUB="https://$HOST/sub/$TOKEN"
echo "$SUB" > "$BASE/订阅链接.txt"
echo
echo -e "${G}==================== 安装完成 ====================${N}"
echo -e "订阅链接(填进 v2rayN → 订阅分组 → 添加，然后“更新订阅”)："
echo -e "${G}$SUB${N}"
[ -z "$DOMAIN" ] && echo -e "${Y}无域名模式：证书为自签，v2rayN 订阅设置里请勾选“允许不安全证书”(链接里已带 allowInsecure=1)。${N}"
echo
echo "节点是后台逐步测出来的，刚装完先等 1~3 分钟再更新订阅。"
echo "看进度:   journalctl -u aimili-lite -f"
echo "节点清单: cat $BASE/nodes.json"
echo "再看链接: cat $BASE/订阅链接.txt"
echo "卸载:     bash install.sh uninstall"
