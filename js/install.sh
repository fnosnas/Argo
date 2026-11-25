#!/usr/bin/env bash
# =====================================================================
#  node-ws (Komari 版) 一键安装：全程无交互，一路装到底
#  用法（变量写在命令前面）：
#    KOMARI_SERVER=https://km.xxx.com KOMARI_TOKEN=xxxx DOMAIN=xxx.xxx.com PORT=3000 \
#    bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)
#  没有 curl 时：
#    KOMARI_SERVER=... KOMARI_TOKEN=... DOMAIN=... PORT=... \
#    bash <(wget -qO- https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)
#
#  可选变量（不写就用默认）：
#    RUN_MODE=auto|systemd|pm2|nohup|fg  运行方式，默认 auto 自动判断
#    APP_DIR=安装目录（默认 root 为 /opt/node-ws，普通用户为 ~/node-ws）
#    NODE_VER=20.18.1  需要自动安装 Node 时的版本
#    NODE_MIRROR=https://npmmirror.com/mirrors/node  国内机器下载 Node 慢时用
#    以及 index.js 支持的其它变量：UUID NAME SUB_PATH TLS USE_PM2 SHOW_LOG ...
# =====================================================================
set -u
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/fnosnas/Argo/main/js}"
SVC_NAME="${PM2_NAME:-node-ws}"
RUN_MODE="${RUN_MODE:-auto}"
NODE_VER="${NODE_VER:-20.18.1}"
NODE_MIRROR="${NODE_MIRROR:-https://nodejs.org/dist}"
ENV_KEYS="KOMARI_SERVER KOMARI_TOKEN DOMAIN PORT UUID NAME SUB_PATH WSPATH AUTO_ACCESS TLS TLS_CERT TLS_KEY KOMARI_DISABLE_SSH SHOW_LOG"

info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[提示]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

# ---------------- 1. 检测权限 ----------------
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=1; PRIV="root"
elif has sudo && sudo -n true >/dev/null 2>&1; then
  IS_ROOT=1; SUDO="sudo -n"; PRIV="普通用户（有免密 sudo）"
else
  IS_ROOT=0; PRIV="普通用户（无 root，装到用户目录）"
fi

# ---------------- 2. 检测系统 ----------------
OS_ID="unknown"; OS_LIKE=""; OS_NAME="$(uname -s)"
if [ -r /etc/os-release ]; then
  # 在子 shell 里读取，避免 os-release 里的 NAME 等字段覆盖用户变量
  OS_ID="$(. /etc/os-release; echo "${ID:-unknown}")"
  OS_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
  OS_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-${ID:-Linux}}")"
fi
[ "$(uname -s)" = "Linux" ] || die "只支持 Linux，当前是 $(uname -s)"

PKG=""
if   has apt-get; then PKG=apt
elif has apk;     then PKG=apk
elif has dnf;     then PKG=dnf
elif has yum;     then PKG=yum
elif has pacman;  then PKG=pacman
elif has zypper;  then PKG=zypper
fi

IS_MUSL=0
if [ -f /etc/alpine-release ] || (ldd --version 2>&1 | grep -qi musl); then IS_MUSL=1; fi

# ---------------- 3. 检测架构 ----------------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)   NODE_ARCH=x64 ;;
  aarch64|arm64)  NODE_ARCH=arm64 ;;
  armv7l|armv7*)  NODE_ARCH=armv7l ;;
  ppc64le)        NODE_ARCH=ppc64le ;;
  s390x)          NODE_ARCH=s390x ;;
  *)              NODE_ARCH="" ;;
esac

# ---------------- 4. 检测是否在容器里 ----------------
IN_CONTAINER=0
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${KUBERNETES_SERVICE_HOST:-}" ] || [ -n "${P_SERVER_UUID:-}" ] \
   || grep -qaE 'docker|kubepods|containerd|podman' /proc/1/cgroup 2>/dev/null; then
  IN_CONTAINER=1
fi
HAS_SYSTEMD=0
[ -d /run/systemd/system ] && has systemctl && HAS_SYSTEMD=1

echo "=============================================="
info "系统：$OS_NAME（包管理：${PKG:-无}$( [ $IS_MUSL = 1 ] && echo '，musl' )）"
info "架构：$ARCH_RAW"
info "权限：$PRIV"
info "环境：$( [ $IN_CONTAINER = 1 ] && echo 容器 || echo 'VPS/实体机' )，systemd：$( [ $HAS_SYSTEMD = 1 ] && echo 有 || echo 无 )"
echo "=============================================="

# ---------------- 5. 检查四个主要变量 ----------------
[ -z "${KOMARI_SERVER:-}" ] && warn "没填 KOMARI_SERVER，探针不会上报"
[ -z "${KOMARI_TOKEN:-}" ]  && warn "没填 KOMARI_TOKEN，探针不会上报"
[ -z "${DOMAIN:-}" ]        && warn "没填 DOMAIN，订阅里会用自动检测的 IP"
PORT="${PORT:-3000}"
case "$PORT" in ''|*[!0-9]*) die "PORT 必须是数字，当前：$PORT" ;; esac

# ---------------- 6. 安装系统工具（缺什么装什么） ----------------
PKG_UPDATED=0
pkg_install() {   # 用法：pkg_install 包名...
  [ "$IS_ROOT" = 1 ] && [ -n "$PKG" ] || return 1
  case "$PKG" in
    apt)
      [ $PKG_UPDATED = 0 ] && { $SUDO apt-get update -y >/dev/null 2>&1 || true; PKG_UPDATED=1; }
      $SUDO apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >/dev/null 2>&1 ;;
    apk)    $SUDO apk add --no-cache "$@" >/dev/null 2>&1 ;;
    dnf)    $SUDO dnf install -y "$@" >/dev/null 2>&1 ;;
    yum)    $SUDO yum install -y "$@" >/dev/null 2>&1 ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) $SUDO zypper -n install "$@" >/dev/null 2>&1 ;;
  esac
}

need_tool() {     # 用法：need_tool 命令 包名
  if has "$1"; then info "已有 $1，跳过"; return 0; fi
  info "缺少 $1，正在安装..."
  pkg_install $2 && has "$1" && { info "$1 安装完成"; return 0; }
  warn "$1 安装失败"; return 1
}

# 下载工具：curl 或 wget 至少一个
if ! has curl && ! has wget; then
  need_tool curl curl || need_tool wget wget || die "没有 curl 也没有 wget，且无法安装（非 root），请先装其中一个"
else
  info "已有下载工具 $(has curl && echo curl || echo wget)，跳过"
fi
need_tool tar tar || true
if [ "$IS_ROOT" = 1 ] && [ "$PKG" = apt ] && [ ! -d /etc/ssl/certs ] ; then pkg_install ca-certificates || true; fi
[ "$PKG" = apk ] && [ "$IS_ROOT" = 1 ] && pkg_install ca-certificates libstdc++ >/dev/null 2>&1 || true

dl() {  # dl URL 文件
  local i
  for i in 1 2 3; do
    if has curl; then curl -fsSL --connect-timeout 15 --retry 2 "$1" -o "$2" && return 0
    else wget -q -T 15 -O "$2" "$1" && return 0; fi
    sleep 2
  done
  return 1
}

# ---------------- 7. Node.js / npm ----------------
node_ok() {
  has node && has npm || return 1
  local major; major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  [ "${major:-0}" -ge 16 ] 2>/dev/null
}

install_node_binary() {   # 下载官方二进制包，不需要 root
  [ -n "$NODE_ARCH" ] || return 1
  local ver="$NODE_VER" base="$NODE_MIRROR" suffix="$NODE_ARCH"
  # glibc 低于 2.28 的老系统（CentOS 7 等）只能跑 Node 16
  if [ $IS_MUSL = 0 ] && has ldd; then
    local g; g="$(ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+$')"
    if [ -n "$g" ] && [ "$(printf '%s\n2.28\n' "$g" | sort -V | head -n1)" != "2.28" ]; then
      warn "glibc $g 太旧，改装 Node 16"; ver=16.20.2
    fi
  fi
  if [ $IS_MUSL = 1 ]; then
    base="https://unofficial-builds.nodejs.org/download/release"; suffix="${NODE_ARCH}-musl"
  fi
  [ "$NODE_ARCH" = armv7l ] && [ "${ver%%.*}" -ge 24 ] 2>/dev/null && ver=22.12.0
  local dir; if [ "$IS_ROOT" = 1 ]; then dir=/usr/local/lib/nodejs; else dir="$HOME/.local/nodejs"; fi
  local pkg="node-v${ver}-linux-${suffix}"
  info "下载 Node v$ver（$suffix）..."
  local tmp; tmp="$(mktemp -d)"
  dl "$base/v$ver/$pkg.tar.gz" "$tmp/node.tgz" || { rm -rf "$tmp"; return 1; }
  $SUDO mkdir -p "$dir" && $SUDO rm -rf "$dir/$pkg" && $SUDO tar -xzf "$tmp/node.tgz" -C "$dir" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  if [ "$IS_ROOT" = 1 ]; then
    for b in node npm npx; do $SUDO ln -sf "$dir/$pkg/bin/$b" "/usr/local/bin/$b"; done
  else
    mkdir -p "$HOME/.local/bin"
    for b in node npm npx; do ln -sf "$dir/$pkg/bin/$b" "$HOME/.local/bin/$b"; done
    grep -q '.local/bin' "$HOME/.profile" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
  fi
  export PATH="$dir/$pkg/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
  hash -r; node_ok
}

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
if node_ok; then
  info "已有 Node $(node -v)、npm $(npm -v)，跳过"
else
  has node && warn "现有 Node $(node -v 2>/dev/null) 版本过低或缺 npm，重新安装"
  ok=0
  # 系统源里的 node 版本够新就用系统源（Alpine/Arch/Fedora 一般够新）
  if [ "$IS_ROOT" = 1 ] && { [ "$PKG" = apk ] || [ "$PKG" = pacman ] || [ "$PKG" = dnf ]; }; then
    pkg_install nodejs npm && node_ok && ok=1
  fi
  [ $ok = 0 ] && install_node_binary && ok=1
  [ $ok = 0 ] && [ "$IS_ROOT" = 1 ] && pkg_install nodejs npm && node_ok && ok=1
  [ $ok = 0 ] && die "Node.js 安装失败（架构 $ARCH_RAW）。可加 NODE_MIRROR=https://npmmirror.com/mirrors/node 再试"
  info "Node $(node -v)、npm $(npm -v) 安装完成"
fi

# ---------------- 8. 拉取代码 ----------------
if [ -z "${APP_DIR:-}" ]; then
  if [ "$IS_ROOT" = 1 ] && [ -z "$SUDO" ]; then APP_DIR=/opt/node-ws; else APP_DIR="$HOME/node-ws"; fi
fi
mkdir -p "$APP_DIR" || die "无法创建目录 $APP_DIR"
cd "$APP_DIR" || die "无法进入 $APP_DIR"
info "拉取 index.js、package.json 到 $APP_DIR"
dl "$REPO_RAW/index.js" index.js.new         || die "下载 index.js 失败：$REPO_RAW/index.js"
dl "$REPO_RAW/package.json" package.json.new || die "下载 package.json 失败：$REPO_RAW/package.json"
grep -q "KOMARI_SERVER" index.js.new || die "下载到的 index.js 内容不对（可能被墙或仓库路径错）"
mv -f index.js.new index.js; mv -f package.json.new package.json

# ---------------- 9. 保存配置 ----------------
touch .env; chmod 600 .env
for k in $ENV_KEYS; do
  v="${!k:-}"
  if [ -n "$v" ]; then
    grep -v "^$k=" .env > .env.tmp 2>/dev/null || true; mv -f .env.tmp .env
    printf '%s=%q\n' "$k" "$v" >> .env
  fi
done
chmod 600 .env
info "配置已写入 $APP_DIR/.env（重装时没传的变量会保留）"

# ---------------- 10. 安装依赖 ----------------
info "npm install 安装依赖（ws、axios；node-pty 为可选，装不上不影响）..."
npm config set fund false >/dev/null 2>&1 || true
if ! npm install --omit=dev --no-audit --no-fund >npm-install.log 2>&1; then
  warn "带可选依赖安装失败，改为跳过 node-pty 重装"
  npm install --omit=dev --omit=optional --no-audit --no-fund >npm-install.log 2>&1 \
    || npm install --no-optional --no-audit --no-fund >>npm-install.log 2>&1 \
    || die "npm install 失败，日志：$APP_DIR/npm-install.log"
fi
[ -d node_modules/ws ] && [ -d node_modules/axios ] || die "依赖不完整，日志：$APP_DIR/npm-install.log"
info "依赖安装完成"

cat > start.sh <<'SH'
#!/usr/bin/env bash
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
set -a; [ -f .env ] && . ./.env; set +a
export USE_PM2=false
exec node "$PWD/index.js"
SH
chmod +x start.sh

# ---------------- 11. 停掉旧进程 ----------------
has pm2 && pm2 delete "$SVC_NAME" >/dev/null 2>&1 || true
[ $HAS_SYSTEMD = 1 ] && [ "$IS_ROOT" = 1 ] && $SUDO systemctl stop "$SVC_NAME" >/dev/null 2>&1 || true
pkill -f "$APP_DIR/index.js" >/dev/null 2>&1 || true
sleep 1

# ---------------- 12. 启动 ----------------
if [ "$RUN_MODE" = auto ]; then
  if   [ "$IS_ROOT" = 1 ] && [ $HAS_SYSTEMD = 1 ]; then RUN_MODE=systemd
  elif [ $IN_CONTAINER = 1 ]; then RUN_MODE=fg
  else RUN_MODE=pm2; fi
fi

SCHEME=http; [[ "${TLS:-true}" =~ ^(1|true|yes|on)$ ]] && SCHEME=https
HOST="${DOMAIN:-你的IP}"
show_done() {
  echo "=============================================="
  info "安装完成，运行方式：$1"
  info "目录：$APP_DIR"
  info "订阅：$SCHEME://$HOST:$PORT/${SUB_PATH:-sub}"
  info "看日志：重装时加 SHOW_LOG=1"
  echo "=============================================="
}

start_nohup() {
  nohup "$APP_DIR/start.sh" >/dev/null 2>&1 &
  if has crontab; then
    (crontab -l 2>/dev/null | grep -v "$APP_DIR/start.sh"; echo "@reboot $APP_DIR/start.sh >/dev/null 2>&1") | crontab - 2>/dev/null || true
  fi
  show_done "nohup 后台运行"
}

case "$RUN_MODE" in
  systemd)
    $SUDO tee /etc/systemd/system/$SVC_NAME.service >/dev/null <<EOF
[Unit]
Description=node-ws (Komari)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now "$SVC_NAME" >/dev/null 2>&1 || die "systemd 启动失败：systemctl status $SVC_NAME"
    show_done "systemd 服务（开机自启，systemctl status/restart $SVC_NAME）"
    ;;
  pm2)
    if ! has pm2; then
      info "安装 pm2..."
      if [ "$IS_ROOT" = 1 ]; then $SUDO env "PATH=$PATH" npm i -g pm2 >/dev/null 2>&1 || true
      else npm config set prefix "$HOME/.local" >/dev/null 2>&1; npm i -g pm2 >/dev/null 2>&1 || true; fi
      hash -r
    fi
    if has pm2 && pm2 start "$APP_DIR/start.sh" --name "$SVC_NAME" >/dev/null 2>&1; then
      pm2 save >/dev/null 2>&1 || true
      if [ "$IS_ROOT" = 1 ]; then $SUDO env "PATH=$PATH" pm2 startup >/dev/null 2>&1 || true
      elif has crontab; then (crontab -l 2>/dev/null | grep -v 'pm2 resurrect'; echo "@reboot $(command -v pm2) resurrect >/dev/null 2>&1") | crontab - 2>/dev/null || true; fi
      show_done "pm2（pm2 status / pm2 restart $SVC_NAME）"
    else
      warn "pm2 不可用，改用 nohup"; start_nohup
    fi
    ;;
  nohup) start_nohup ;;
  fg)
    show_done "前台运行（容器模式，本窗口保持即可）"
    exec "$APP_DIR/start.sh"
    ;;
  *) die "RUN_MODE 只能是 auto/systemd/pm2/nohup/fg" ;;
esac
