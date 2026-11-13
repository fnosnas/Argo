#!/bin/sh
# =====================================================================
#  Komari 面板 + Cloudflare Tunnel 一键管理脚本（菜单交互版）
#  系统: Alpine(OpenRC) / Debian / Ubuntu    架构: amd64/arm64/arm/386
#  菜单: 1.安装  2.更改变量  3.全部卸载  4.健康检查排错  0.退出
# =====================================================================

VERSION="2.0"
CONF="/etc/komari-cf.conf"
INSTALL_DIR="/opt/komari"
KOMARI_BIN="$INSTALL_DIR/komari"
CFD_BIN="/usr/bin/cloudflared"
WATCHDOG="/usr/local/bin/komari-watchdog.sh"
KLOG="/var/log/komari.log"
CLOG="/var/log/cloudflared.log"
GH="https://github.com"
GH_MIRROR="https://ghfast.top/https://github.com"

R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
info(){ printf "${C}[*]${N} %s\n" "$1"; }
ok(){   printf "${G}[+]${N} %s\n" "$1"; }
warn(){ printf "${Y}[!]${N} %s\n" "$1"; }
err(){  printf "${R}[x]${N} %s\n" "$1"; }
die(){  err "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行此脚本"

# ---------- 默认变量 ----------
DOMAIN=""; CF_TOKEN=""; TUNNEL_PORT="25774"; KOMARI_PORT="25774"
BIND_ADDR="0.0.0.0"; ADMIN_USER="admin"; ADMIN_PASS="admin"
[ -f "$CONF" ] && . "$CONF"

save_conf(){
  cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
CF_TOKEN="$CF_TOKEN"
TUNNEL_PORT="$TUNNEL_PORT"
KOMARI_PORT="$KOMARI_PORT"
BIND_ADDR="$BIND_ADDR"
ADMIN_USER="$ADMIN_USER"
ADMIN_PASS="$ADMIN_PASS"
EOF
  chmod 600 "$CONF"
}

# ---------- 交互读取（兼容 curl | sh 一键执行） ----------
ask(){   # ask "提示文字" "默认值"  -> 结果在 REPLY_VAL
  _p="$1"; _d="$2"
  if [ -n "$_d" ]; then printf "${B}%s${N} [默认: %s]: " "$_p" "$_d"
  else printf "${B}%s${N}: " "$_p"; fi
  if [ -r /dev/tty ]; then read -r _v < /dev/tty; else read -r _v; fi
  [ -z "$_v" ] && _v="$_d"
  REPLY_VAL="$_v"
}
anykey(){
  printf "\n${Y}按任意键返回主菜单...${N}"
  if [ -r /dev/tty ]; then
    _old=$(stty -g < /dev/tty 2>/dev/null)
    if [ -n "$_old" ]; then
      stty raw -echo < /dev/tty 2>/dev/null
      dd bs=1 count=1 < /dev/tty > /dev/null 2>&1
      stty "$_old" < /dev/tty 2>/dev/null
    else read -r _ < /dev/tty; fi
  else read -r _; fi
  echo ""
}

# ---------- 环境识别 ----------
if [ -f /etc/alpine-release ]; then OS="alpine"; PKG="apk"
elif [ -f /etc/os-release ] && grep -qiE 'debian|ubuntu|devuan|raspbian|armbian' /etc/os-release; then OS="debian"; PKG="apt"
elif command -v apk >/dev/null 2>&1; then OS="alpine"; PKG="apk"
elif command -v apt-get >/dev/null 2>&1; then OS="debian"; PKG="apt"
else die "仅支持 Alpine / Debian / Ubuntu"; fi

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT="systemd"; else INIT="openrc"; fi

case "$(uname -m)" in
  x86_64|amd64)       ARCH="amd64" ;;
  aarch64|arm64)      ARCH="arm64" ;;
  armv7l|armv7|armhf) ARCH="arm"   ;;
  i386|i686)          ARCH="386"   ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac

# ---------- 包管理 ----------
PKG_UPDATED=0
pkg_update(){
  [ "$PKG_UPDATED" = 1 ] && return 0
  info "刷新软件源索引..."
  if [ "$PKG" = apk ]; then apk update >/dev/null 2>&1 || true
  else DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true; fi
  PKG_UPDATED=1
}
pkg_add(){
  pkg_update; info "安装依赖: $*"
  if [ "$PKG" = apk ]; then apk add --no-cache $* >/dev/null 2>&1 || warn "部分依赖安装失败: $*"
  else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::="--force-confold" $* >/dev/null 2>&1 || warn "部分依赖安装失败: $*"; fi
}

check_deps(){
  info "检测精简系统缺失的工具..."
  NEED=""
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || NEED="$NEED curl"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || NEED="$NEED ca-certificates"
  command -v tar   >/dev/null 2>&1 || NEED="$NEED tar"
  command -v gzip  >/dev/null 2>&1 || NEED="$NEED gzip"
  command -v grep  >/dev/null 2>&1 || NEED="$NEED grep"
  command -v sed   >/dev/null 2>&1 || NEED="$NEED sed"
  command -v awk   >/dev/null 2>&1 || NEED="$NEED gawk"
  command -v unzip >/dev/null 2>&1 || NEED="$NEED unzip"
  command -v pgrep >/dev/null 2>&1 || NEED="$NEED procps"
  if [ "$OS" = alpine ]; then
    command -v rc-update >/dev/null 2>&1 || NEED="$NEED openrc"
    ls /lib/ld-musl-* >/dev/null 2>&1 && NEED="$NEED gcompat libc6-compat"
    command -v crond >/dev/null 2>&1 || NEED="$NEED busybox-initscripts"
    NEED="$NEED tzdata"
  else
    command -v crontab >/dev/null 2>&1 || NEED="$NEED cron"
    command -v ss      >/dev/null 2>&1 || NEED="$NEED iproute2"
    NEED="$NEED tzdata"
  fi
  NEED=$(printf '%s' "$NEED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
  if [ -n "$NEED" ]; then pkg_add $NEED; else ok "依赖已齐全"; fi
  command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || true
}

dl(){ # dl <url> <目标文件>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" && return 0
  fi
  command -v wget >/d
