#!/usr/bin/env bash
# Komari + Cloudflare Tunnel 管理脚本 | Alpine/Debian/Ubuntu | amd64/arm64/arm
VER="2.1"
CONF="/etc/komari-cf.conf"
DIR="/opt/komari"
KBIN="$DIR/komari"
CBIN="/usr/bin/cloudflared"
WD="/usr/local/bin/komari-watchdog.sh"
KLOG="/var/log/komari.log"
CLOG="/var/log/cloudflared.log"

R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
info(){ printf "${C}[*]${N} %s\n" "$1"; }
ok(){   printf "${G}[+]${N} %s\n" "$1"; }
warn(){ printf "${Y}[!]${N} %s\n" "$1"; }
err(){  printf "${R}[x]${N} %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }

DOMAIN=""; CF_TOKEN=""; TPORT="25774"; KPORT="25774"
BIND="0.0.0.0"; AUSER="admin"; APASS="admin"
[ -f "$CONF" ] && . "$CONF"

save_conf(){
  cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
CF_TOKEN="$CF_TOKEN"
TPORT="$TPORT"
KPORT="$KPORT"
BIND="$BIND"
AUSER="$AUSER"
APASS="$APASS"
EOF
  chmod 600 "$CONF"
}

ask(){
  local p="$1" d="$2" v=""
  if [ -n "$d" ]; then printf "${B}%s${N} [回车默认: %s]: " "$p" "$d"
  else printf "${B}%s${N}: " "$p"; fi
  if [ -r /dev/tty ]; then read -r v < /dev/tty; else read -r v; fi
  [ -z "$v" ] && v="$d"
  REPLY_VAL="$v"
}

anykey(){
  printf "\n${Y}按任意键返回主菜单...${N}"
  if [ -r /dev/tty ]; then read -n 1 -s -r < /dev/tty; else read -r _; fi
  echo ""
}

if [ -f /etc/alpine-release ]; then OS="alpine"; PKG="apk"
elif command -v apt-get >/dev/null 2>&1; then OS="debian"; PKG="apt"
elif command -v apk >/dev/null 2>&1; then OS="alpine"; PKG="apk"
else err "仅支持 Alpine/Debian/Ubuntu"; exit 1; fi

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT="systemd"; else INIT="openrc"; fi

case "$(uname -m)" in
  x86_64|amd64)       ARCH="amd64" ;;
  aarch64|arm64)      ARCH="arm64" ;;
  armv7l|armv7|armhf) ARCH="arm"   ;;
  i386|i686)          ARCH="386"   ;;
  *) err "不支持架构 $(uname -m)"; exit 1 ;;
esac

PKGUP=0
pkg_add(){
  if [ "$PKGUP" -eq 0 ]; then
    info "刷新软件源"
    if [ "$PKG" = "apk" ]; then apk update >/dev/null 2>&1
    else DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; fi
    PKGUP=1
  fi
  info "安装依赖: $*"
  if [ "$PKG" = "apk" ]; then apk add --no-cache "$@" >/dev/null 2>&1 || warn "部分
