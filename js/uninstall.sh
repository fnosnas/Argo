#!/usr/bin/env bash
# =====================================================================
#  node-ws 一键卸载：删除 install.sh 装的所有内容，全程无交互
#  用法：
#    bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/uninstall.sh)
#  可选：KEEP_NODE=1   保留脚本装的 Node.js（机器上还有别的 Node 程序时用）
#        APP_DIR=/路径  安装时自定义过目录才需要填
# =====================================================================
set -u
SVC_NAME="${PM2_NAME:-node-ws}"
has() { command -v "$1" >/dev/null 2>&1; }
info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -ne 0 ] && has sudo && sudo -n true >/dev/null 2>&1; then SUDO="sudo -n"; fi
IS_ROOT=0; { [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; } && IS_ROOT=1
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

DIRS="${APP_DIR:-} /opt/node-ws $HOME/node-ws"

# 1. systemd 服务
if [ "$IS_ROOT" = 1 ] && [ -f /etc/systemd/system/$SVC_NAME.service ]; then
  $SUDO systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
  $SUDO rm -f /etc/systemd/system/$SVC_NAME.service
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  info "已删除 systemd 服务 $SVC_NAME"
fi

# 2. pm2 进程
if has pm2; then
  pm2 delete "$SVC_NAME" >/dev/null 2>&1 && info "已删除 pm2 进程 $SVC_NAME"
  pm2 save --force >/dev/null 2>&1 || true
fi

# 3. 残留进程
for d in $DIRS; do
  [ -n "$d" ] || continue
  pkill -f "$d/index.js" >/dev/null 2>&1 || true
  pkill -f "$d/start.sh" >/dev/null 2>&1 || true
done

# 4. 开机自启（crontab）
if has crontab && crontab -l >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v 'node-ws/start.sh' | grep -v 'pm2 resurrect' | crontab - 2>/dev/null || true
  info "已清理 crontab 开机项"
fi

# 5. 程序目录（代码、.env 配置、依赖、自签证书）
for d in $DIRS; do
  [ -n "$d" ] && [ -d "$d" ] && [ -f "$d/index.js" ] || continue
  $SUDO rm -rf "$d" && info "已删除目录 $d"
done

# 6. 脚本装的 Node.js（系统包管理器装的不动）
if [ "${KEEP_NODE:-0}" != 1 ]; then
  if [ -d /usr/local/lib/nodejs ] && [ "$IS_ROOT" = 1 ]; then
    for b in node npm npx pm2 pm2-dev pm2-docker pm2-runtime corepack; do
      l="/usr/local/bin/$b"
      [ -L "$l" ] && readlink "$l" | grep -q '/usr/local/lib/nodejs/' && $SUDO rm -f "$l"
    done
    $SUDO rm -rf /usr/local/lib/nodejs
    info "已删除脚本安装的 Node.js（/usr/local/lib/nodejs）"
  fi
  if [ -d "$HOME/.local/nodejs" ]; then
    for b in node npm npx pm2 pm2-dev pm2-docker pm2-runtime corepack; do
      l="$HOME/.local/bin/$b"
      [ -L "$l" ] && rm -f "$l"
    done
    rm -rf "$HOME/.local/nodejs" "$HOME/.local/lib/node_modules/pm2"
    sed -i '/\.local\/bin:\$PATH/d' "$HOME/.profile" 2>/dev/null || true
    sed -i '/^prefix=/d' "$HOME/.npmrc" 2>/dev/null || true
    info "已删除用户目录里的 Node.js"
  fi
  hash -r
  if ! has pm2; then   # pm2 也随之删掉了，才清它的数据和开机服务
    rm -rf "$HOME/.pm2" 2>/dev/null || true
    if [ "$IS_ROOT" = 1 ] && ls /etc/systemd/system/pm2-*.service >/dev/null 2>&1; then
      for f in /etc/systemd/system/pm2-*.service; do $SUDO systemctl disable --now "$(basename "$f")" >/dev/null 2>&1; $SUDO rm -f "$f"; done
      $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
fi

echo "=============================================="
info "卸载完成"
has node && info "系统里还有 Node $(node -v)（不是本脚本装的，或你选了保留）"
echo "=============================================="
