#!/bin/sh
# =====================================================================
#  Komari 面板 + Cloudflare Tunnel 全自动安装脚本
#  支持: Alpine(OpenRC) / Debian / Ubuntu, amd64 / arm64 / armv7
#  特性: 依赖自检补装 + 架构自识别 + 服务自启 + 看门狗保活
# =====================================================================
set -e

#==================== 变量区（按需修改） ====================#
DOMAIN="${DOMAIN:-komari.example.com}"     # 1. 隧道域名
CF_TOKEN="${CF_TOKEN:-}"                   # 2. 隧道 Token (eyJhIjoi...)
TUNNEL_PORT="${TUNNEL_PORT:-25774}"        # 3. 隧道回源端口
KOMARI_PORT="${KOMARI_PORT:-25774}"        # Komari 监听端口
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"          # 仅走隧道可改 127.0.0.1
ADMIN_USER="${ADMIN_USER:-admin}"          # 面板初始账号
ADMIN_PASS="${ADMIN_PASS:-}"               # 留空自动生成
INSTALL_DIR="/opt/komari"
#===========================================================#

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain) DOMAIN="$2"; shift 2 ;;
    -t|--token)  CF_TOKEN="$2"; shift 2 ;;
    -p|--port)   TUNNEL_PORT="$2"; KOMARI_PORT="$2"; shift 2 ;;
    -u|--user)   ADMIN_USER="$2"; shift 2 ;;
    -w|--pass)   ADMIN_PASS="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) shift ;;
  esac
done

R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
info() { printf "${C}[*]${N} %s\n" "$1"; }
ok()   { printf "${G}[+]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
die()  { printf "${R}[x]${N} %s\n" "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 用户运行：sudo sh $0"

# ---------------- 1. 识别系统 / init ----------------
if [ -f /etc/alpine-release ]; then
  OS="alpine"; PKG="apk"
elif [ -f /etc/os-release ] && grep -qiE 'debian|ubuntu|devuan|raspbian' /etc/os-release; then
  OS="debian"; PKG="apt"
else
  OS="unknown"
  command -v apk >/dev/null 2>&1 && { OS="alpine"; PKG="apk"; }
  command -v apt-get >/dev/null 2>&1 && { OS="debian"; PKG="apt"; }
  [ "$OS" = "unknown" ] && die "不支持的系统，仅支持 Alpine / Debian / Ubuntu"
fi

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  INIT="systemd"
else
  INIT="openrc"
fi

# ---------------- 2. 识别架构 ----------------
case "$(uname -m)" in
  x86_64|amd64)       KARCH="amd64"; CARCH="amd64" ;;
  aarch64|arm64)      KARCH="arm64"; CARCH="arm64" ;;
  armv7l|armv7|armhf) KARCH="arm";   CARCH="arm"   ;;
  i386|i686)          KARCH="386";   CARCH="386"   ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac
info "系统: $OS | 初始化: $INIT | 架构: $KARCH"

# ---------------- 3. 卸载分支 ----------------
if [ "$UNINSTALL" = "1" ]; then
  if [ "$INIT" = "systemd" ]; then
    for s in komari cloudflared; do
      systemctl disable --now "$s" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$s.service"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    for s in komari cloudflared; do
      rc-service "$s" stop >/dev/null 2>&1 || true
      rc-update del "$s" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$s" "/etc/conf.d/$s"
    done
  fi
  rm -f /usr/local/bin/komari-watchdog.sh /etc/cron.d/komari-watchdog /usr/bin/cloudflared
  crontab -l 2>/dev/null | grep -v komari-watchdog | crontab - 2>/dev/null || true
  warn "数据目录 $INSTALL_DIR 已保留，如需彻底删除：rm -rf $INSTALL_DIR"
  ok "卸载完成"; exit 0
fi

# ---------------- 4. 依赖自检与补装 ----------------
PKG_UPDATED=0
pkg_update() {
  [ "$PKG_UPDATED" = "1" ] && return 0
  info "刷新软件源索引..."
  if [ "$PKG" = "apk" ]; then apk update >/dev/null 2>&1 || true
  else DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true; fi
  PKG_UPDATED=1
}
pkg_install() {
  pkg_update
  info "安装依赖包: $*"
  if [ "$PKG" = "apk" ]; then
    apk add --no-cache $* >/dev/null 2>&1 || warn "部分包安装失败: $*"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      -o Dpkg::Options::="--force-confold" $* >/dev/null 2>&1 || warn "部分包安装失败: $*"
  fi
}
