#!/usr/bin/env bash
# =====================================================================
#  Komari 面板 + Cloudflare Tunnel 管理脚本  v2.2
#  Alpine(OpenRC) / Debian / Ubuntu  |  amd64 arm64 arm 386
# =====================================================================

VER="2.2"
CONF="/etc/komari-cf.conf"
DIR="/opt/komari"
KBIN="$DIR/komari"
CBIN="/usr/local/bin/cloudflared"
WD="/usr/local/bin/komari-watchdog.sh"
KLOG="/var/log/komari.log"
CLOG="/var/log/cloudflared.log"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
info(){ printf "%s[*]%s %s\n" "$C" "$N" "$1"; }
ok(){   printf "%s[+]%s %s\n" "$G" "$N" "$1"; }
warn(){ printf "%s[!]%s %s\n" "$Y" "$N" "$1"; }
err(){  printf "%s[x]%s %s\n" "$R" "$N" "$1"; }

if [ "$(id -u)" -ne 0 ]; then
  err "请用 root 运行"
  exit 1
fi

DOMAIN=""
CF_TOKEN=""
TPORT="25774"
KPORT="25774"
BIND="0.0.0.0"
AUSER="admin"
APASS="admin"
[ -f "$CONF" ] && . "$CONF"

save_conf(){
  umask 077
  {
    echo "DOMAIN=\"$DOMAIN\""
    echo "CF_TOKEN=\"$CF_TOKEN\""
    echo "TPORT=\"$TPORT\""
    echo "KPORT=\"$KPORT\""
    echo "BIND=\"$BIND\""
    echo "AUSER=\"$AUSER\""
    echo "APASS=\"$APASS\""
  } > "$CONF"
  chmod 600 "$CONF"
}

ask(){
  local p="$1" d="$2" v=""
  if [ -n "$d" ]; then
    printf "%s%s%s [回车默认: %s]: " "$B" "$p" "$N" "$d"
  else
    printf "%s%s%s: " "$B" "$p" "$N"
  fi
  if [ -r /dev/tty ]; then read -r v < /dev/tty; else read -r v; fi
  [ -z "$v" ] && v="$d"
  REPLY_VAL="$v"
}

anykey(){
  printf "\n%s按任意键返回主菜单...%s" "$Y" "$N"
  if [ -r /dev/tty ]; then read -n 1 -s -r < /dev/tty; else read -r _; fi
  echo ""
}

# ---------- 环境识别 ----------
if [ -f /etc/alpine-release ]; then
  OS="alpine"; PKG="apk"
elif command -v apt-get >/dev/null 2>&1; then
  OS="debian"; PKG="apt"
elif command -v apk >/dev/null 2>&1; then
  OS="alpine"; PKG="apk"
else
  err "仅支持 Alpine / Debian / Ubuntu"
  exit 1
fi

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  INIT="systemd"
else
  INIT="openrc"
fi

case "$(uname -m)" in
  x86_64|amd64)       ARCH="amd64" ;;
  aarch64|arm64)      ARCH="arm64" ;;
  armv7l|armv7|armhf) ARCH="arm" ;;
  i386|i686)          ARCH="386" ;;
  *) err "不支持架构 $(uname -m)"; exit 1 ;;
esac

# ---------- 依赖 ----------
PKGUP=0
pkg_add(){
  if [ "$PKGUP" -eq 0 ]; then
    info "刷新软件源"
    if [ "$PKG" = "apk" ]; then
      apk update >/dev/null 2>&1
    else
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    fi
    PKGUP=1
  fi
  info "安装依赖: $*"
  if [ "$PKG" = "apk" ]; then
    apk add --no-cache "$@" >/dev/null 2>&1 || warn "部分依赖安装失败"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || warn "部分依赖安装失败"
  fi
}

check_deps(){
  info "检测精简系统缺失的工具"
  local need=""
  command -v curl >/dev/null 2>&1 || need="$need curl"
  command -v tar  >/dev/null 2>&1 || need="$need tar"
  command -v gzip >/dev/null 2>&1 || need="$need gzip"
  command -v unzip >/dev/null 2>&1 || need="$need unzip"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || need="$need ca-certificates"
  if [ "$OS" = "alpine" ]; then
    command -v rc-update >/dev/null 2>&1 || need="$need openrc"
    command -v crond >/dev/null 2>&1 || need="$need busybox-initscripts"
    need="$need gcompat libc6-compat tzdata procps"
  else
    command -v crontab >/dev/null 2>&1 || need="$need cron"
    command -v ss >/dev/null 2>&1 || need="$need iproute2"
    need="$need tzdata procps"
  fi
  if [ -n "$need" ]; then
    pkg_add $need
  else
    ok "依赖已齐全"
  fi
  command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1
  return 0
}

dl(){
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 -o "$out" "$url" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" && return 0
  fi
  return 1
}

# ---------- 安装二进制 ----------
get_komari(){
  info "下载 Komari ($ARCH)"
  mkdir -p "$DIR/data"
  local u1="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${ARCH}"
  local u2="https://ghfast.top/${u1}"
  if ! dl "$u1" "$KBIN"; then
    warn "直连失败，尝试镜像"
    dl "$u2" "$KBIN" || { err "Komari 下载失败"; return 1; }
  fi
  chmod +x "$KBIN"
  ok "Komari 已安装到 $KBIN"
  return 0
}

get_cfd(){
  info "下载 cloudflared ($ARCH)"
  local u1="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
  local u2="https://ghfast.top/${u1}"
  if ! dl "$u1" "$CBIN"; then
    warn "直连失败，尝试镜像"
    dl "$u2" "$CBIN" || { err "cloudflared 下载失败"; return 1; }
  fi
  chmod
