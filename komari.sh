#!/bin/sh
# =====================================================================
#  Komari 监控面板 + Cloudflare Tunnel 一键管理脚本  v3.0
#  系统: Alpine(OpenRC) / Debian / Ubuntu (systemd)
#  架构: amd64 arm64 arm 386
#  兼容: POSIX sh (dash / busybox ash / bash 均可运行)
#
#  用法:
#    bash <(curl -fsSL https://ae86.ccwu.cc/komari)          # 有 bash 时
#    curl -fsSL https://ae86.ccwu.cc/komari -o k.sh && sh k.sh   # Alpine 无 bash 时
# =====================================================================

VER="3.0"
SELF_URL="https://ae86.ccwu.cc/komari"      # 用于安装快捷命令 komari-cf, 不需要可留空
CONF="/etc/komari-cf.conf"
DIR="/opt/komari"
KBIN="$DIR/komari"
CBIN="/usr/local/bin/cloudflared"
KRUN="$DIR/run-komari.sh"
CRUN="$DIR/run-cloudflared.sh"
KLOG="/var/log/komari.log"
CLOG="/var/log/cloudflared.log"
SVC_K="komari"
SVC_C="komari-cf"
KREPO="https://github.com/komari-monitor/komari/releases/latest/download"
CREPO="https://github.com/cloudflare/cloudflared/releases/latest/download"

ESC=$(printf '\033')
R="${ESC}[31m"; G="${ESC}[32m"; Y="${ESC}[33m"; C="${ESC}[36m"; B="${ESC}[1m"; N="${ESC}[0m"
info(){ printf '%s[*]%s %s\n' "$C" "$N" "$1"; }
ok(){   printf '%s[+]%s %s\n' "$G" "$N" "$1"; }
warn(){ printf '%s[!]%s %s\n' "$Y" "$N" "$1"; }
err(){  printf '%s[x]%s %s\n' "$R" "$N" "$1"; }

# ---------------------------------------------------------------------
#  配置
# ---------------------------------------------------------------------
DOMAIN=""
CF_TOKEN=""
KPORT="25774"
BIND="127.0.0.1"
AUSER="admin"
APASS=""

load_conf(){
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
  return 0
}

save_conf(){
  (
    umask 077
    {
      echo "DOMAIN='$DOMAIN'"
      echo "CF_TOKEN='$CF_TOKEN'"
      echo "KPORT='$KPORT'"
      echo "BIND='$BIND'"
      echo "AUSER='$AUSER'"
      echo "APASS='$APASS'"
    } > "$CONF"
  )
  chmod 600 "$CONF"
}

# 读一行输入到 REPLY_VAL: 优先 /dev/tty (curl | sh 时 stdin 是脚本本身), 没有终端则读 stdin
readline(){
  if (: < /dev/tty) 2>/dev/null; then
    read -r REPLY_VAL < /dev/tty
  else
    read -r REPLY_VAL
  fi
}

# 提示并读取 -> REPLY_VAL ; 读不到输入(EOF)返回 1
ask(){
  while :; do
    if [ -n "$2" ]; then
      printf '%s%s%s [回车默认: %s]: ' "$B" "$1" "$N" "$2"
    else
      printf '%s%s%s: ' "$B" "$1" "$N"
    fi
    if ! readline; then
      echo ""
      return 1
    fi
    [ -z "$REPLY_VAL" ] && REPLY_VAL="$2"
    case "$REPLY_VAL" in
      *\'*) warn "输入不能包含单引号 ' ，请重新输入"; continue ;;
    esac
    return 0
  done
}

anykey(){
  printf '\n%s按回车返回主菜单...%s' "$Y" "$N"
  readline
  echo ""
}

gen_pass(){
  tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16
}

# ---------------------------------------------------------------------
#  环境识别
# ---------------------------------------------------------------------
detect_env(){
  if [ -f /etc/alpine-release ] || { ! command -v apt-get >/dev/null 2>&1 && command -v apk >/dev/null 2>&1; }; then
    OS="alpine"; PKG="apk"
  elif command -v apt-get >/dev/null 2>&1; then
    OS="debian"; PKG="apt"
  else
    err "仅支持 Alpine / Debian / Ubuntu"; exit 1
  fi

  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
  elif command -v rc-service >/dev/null 2>&1 || [ -x /sbin/openrc-run ]; then
    INIT="openrc"
  elif [ "$OS" = "alpine" ]; then
    INIT="openrc"   # 稍后 check_deps 会安装 openrc
  else
    err "未检测到 systemd 或 OpenRC，无法注册服务"; exit 1
  fi

  case "$(uname -m)" in
    x86_64|amd64)       ARCH="amd64" ;;
    aarch64|arm64)      ARCH="arm64" ;;
    armv7l|armv7|armhf|armv6l) ARCH="arm" ;;
    i386|i686)          ARCH="386" ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------
#  依赖
# ---------------------------------------------------------------------
check_deps(){
  info "检测依赖"
  _need=""
  command -v curl >/dev/null 2>&1 || _need="$_need curl"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || _need="$_need ca-certificates"
  if [ "$OS" = "alpine" ]; then
    command -v rc-service >/dev/null 2>&1 || _need="$_need openrc"
    [ -d /usr/share/zoneinfo ] || _need="$_need tzdata"
    # 精简系统下兼容 glibc 程序, 无害
    _need="$_need gcompat libc6-compat"
  else
    [ -d /usr/share/zoneinfo ] || _need="$_need tzdata"
  fi

  if [ -n "$_need" ]; then
    info "安装依赖:$_need"
    if [ "$PKG" = "apk" ]; then
      apk update >/dev/null 2>&1
      # shellcheck disable=SC2086
      apk add --no-cache $_need >/dev/null 2>&1 || warn "部分依赖安装失败"
    else
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $_need >/dev/null 2>&1 || warn "部分依赖安装失败"
    fi
  else
    ok "依赖已齐全"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    err "curl 安装失败，请手动安装后重试"; exit 1
  fi
  if [ "$INIT" = "openrc" ] && ! command -v rc-service >/dev/null 2>&1; then
    err "OpenRC 不可用，请手动安装 openrc"; exit 1
  fi
  command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------
#  下载 (直连 -> 镜像), 带大小校验, 先下到 .part 再替换, 避免半截文件
# ---------------------------------------------------------------------
fetch_bin(){
  _url="$1"; _out="$2"; _tmp="${_out}.part"
  for _u in "$_url" "https://ghfast.top/$_url"; do
    rm -f "$_tmp"
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 -o "$_tmp" "$_u" 2>/dev/null; then
      _sz=$(wc -c < "$_tmp" 2>/dev/null | tr -d ' ')
      if [ "${_sz:-0}" -gt 1000000 ]; then
        chmod +x "$_tmp"
        mv -f "$_tmp" "$_out"
        return 0
      fi
    fi
    warn "下载失败: $_u"
  done
  rm -f "$_tmp"
  return 1
}

get_komari(){
  info "下载 Komari (linux-$ARCH)"
  mkdir -p "$DIR/data"
  if fetch_bin "$KREPO/komari-linux-${ARCH}" "$KBIN"; then
    ok "Komari 已安装: $KBIN"
  else
    err "Komari 下载失败 (网络问题, 或官方未提供 $ARCH 架构)"; return 1
  fi
}

get_cfd(){
  info "下载 cloudflared (linux-$ARCH)"
  if fetch_bin "$CREPO/cloudflared-linux-${ARCH}" "$CBIN"; then
    ok "cloudflared 已安装: $CBIN"
  else
    err "cloudflared 下载失败"; return 1
  fi
}

# ---------------------------------------------------------------------
#  启动包装脚本 (运行时读取配置, 改配置后只需重启服务)
# ---------------------------------------------------------------------
write_wrappers(){
  mkdir -p "$DIR/data"

  cat > "$KRUN" <<EOF
#!/bin/sh
. "$CONF"
export ADMIN_USERNAME="\$AUSER"
export ADMIN_PASSWORD="\$APASS"
cd "$DIR" || exit 1
[ -f "$KLOG" ] && [ "\$(wc -c < "$KLOG")" -gt 5242880 ] && : > "$KLOG"
exec "$KBIN" server -l "\${BIND}:\${KPORT}" >> "$KLOG" 2>&1
EOF

  cat > "$CRUN" <<EOF
#!/bin/sh
. "$CONF"
export TUNNEL_TOKEN="\$CF_TOKEN"
[ -f "$CLOG" ] && [ "\$(wc -c < "$CLOG")" -gt 5242880 ] && : > "$CLOG"
exec "$CBIN" tunnel --no-autoupdate --protocol http2 run >> "$CLOG" 2>&1
EOF

  chmod 700 "$KRUN" "$CRUN"
}

# ---------------------------------------------------------------------
#  服务管理 (systemd / OpenRC 统一封装)
# ---------------------------------------------------------------------
openrc_prep(){
  # 容器/精简 Alpine 里 OpenRC 未完整启动时, rc-service 会报错, 这里补一个运行时目录
  rc-status >/dev/null 2>&1 || { mkdir -p /run/openrc; touch /run/openrc/softlevel; }
}

# svc_install 名称 描述 启动脚本 [依赖服务]
svc_install(){
  _n="$1"; _d="$2"; _x="$3"; _after="$4"
  if [ "$INIT" = "systemd" ]; then
    cat > "/etc/systemd/system/${_n}.service" <<EOF
[Unit]
Description=$_d
After=network-online.target $_after
Wants=network-online.target

[Service]
Type=simple
ExecStart=$_x
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$_n" >/dev/null 2>&1
  else
    if command -v supervise-daemon >/dev/null 2>&1; then
      _mode='supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0'
    else
      _mode='command_background=true'
    fi
    cat > "/etc/init.d/${_n}" <<EOF
#!/sbin/openrc-run
description="$_d"
command="$_x"
pidfile="/run/${_n}.pid"
$_mode

depend() {
    need net
    after firewall $_after
}
EOF
    chmod +x "/etc/init.d/${_n}"
    openrc_prep
    rc-update add "$_n" default >/dev/null 2>&1
  fi
}

svc(){   # svc 动作 名称
  if [ "$INIT" = "systemd" ]; then
    systemctl "$1" "$2" >/dev/null 2>&1
  else
    openrc_prep
    rc-service "$2" "$1" >/dev/null 2>&1
  fi
}

svc_active(){
  if [ "$INIT" = "systemd" ]; then
    systemctl is-active --quiet "$1"
  else
    rc-service "$1" status >/dev/null 2>&1
  fi
}

svc_remove(){
  svc stop "$1"
  if [ "$INIT" = "systemd" ]; then
    systemctl disable "$1" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${1}.service"
    systemctl daemon-reload
  else
    rc-update del "$1" default >/dev/null 2>&1
    rm -f "/etc/init.d/${1}" "/run/${1}.pid"
  fi
}

restart_all(){
  : > "$CLOG" 2>/dev/null
  svc restart "$SVC_K"
  svc restart "$SVC_C"
}

# ---------------------------------------------------------------------
#  检测
# ---------------------------------------------------------------------
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null
}

wait_komari(){
  _i=0
  while [ "$_i" -lt 25 ]; do
    case "$(http_code "http://127.0.0.1:${KPORT}/")" in
      2*|3*|4*) return 0 ;;
    esac
    _i=$((_i + 1)); sleep 1
  done
  return 1
}

wait_tunnel(){
  _i=0
  while [ "$_i" -lt 40 ]; do
    grep -q "Registered tunnel connection" "$CLOG" 2>/dev/null && return 0
    _i=$((_i + 1)); sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------
#  交互收集配置
# ---------------------------------------------------------------------
collect_conf(){
  [ -z "$APASS" ] && APASS="$(gen_pass)"

  while :; do
    ask "Tunnel 对应的访问域名 (如 status.example.com)" "$DOMAIN" || return 1
    DOMAIN=$(printf '%s' "$REPLY_VAL" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')
    [ -n "$DOMAIN" ] && break
    warn "域名不能为空"
  done

  echo ""
  echo "  Token 获取: Cloudflare Zero Trust -> Networks -> Tunnels -> 创建 Tunnel(Cloudflared)"
  echo "  复制那串 eyJ 开头的 token (整条安装命令一起粘贴也可以, 脚本会自动提取)"
  while :; do
    if [ -n "$CF_TOKEN" ]; then
      ask "Tunnel Token" "$CF_TOKEN" || return 1
    else
      ask "Tunnel Token" "" || return 1
    fi
    CF_TOKEN=$(printf '%s' "$REPLY_VAL" | awk '{print $NF}')
    case "$CF_TOKEN" in
      ey*) [ "${#CF_TOKEN}" -ge 60 ] && break ;;
    esac
    warn "这看起来不是有效的 Tunnel Token (应以 eyJ 开头且较长)"
    CF_TOKEN=""
  done

  while :; do
    ask "Komari 本地端口" "$KPORT" || return 1
    case "$REPLY_VAL" in
      ''|*[!0-9]*) warn "端口必须是数字" ;;
      *) if [ "$REPLY_VAL" -ge 1 ] && [ "$REPLY_VAL" -le 65535 ]; then KPORT="$REPLY_VAL"; break; fi
         warn "端口范围 1-65535" ;;
    esac
  done

  ask "仅本机监听 127.0.0.1 (推荐: 只能经隧道访问, 更安全) y/n" "y" || return 1
  case "$REPLY_VAL" in
    n|N|no|NO) BIND="0.0.0.0" ;;
    *) BIND="127.0.0.1" ;;
  esac

  ask "管理员用户名" "$AUSER" || return 1
  AUSER="$REPLY_VAL"
  ask "管理员密码 (默认随机生成)" "$APASS" || return 1
  APASS="$REPLY_VAL"
  [ -z "$AUSER" ] && AUSER="admin"
  [ -z "$APASS" ] && APASS="$(gen_pass)"
  return 0
}

# ---------------------------------------------------------------------
#  功能
# ---------------------------------------------------------------------
do_install(){
  check_deps
  collect_conf || { err "未获取到输入，已取消"; return 1; }

  _had_db=0
  [ -f "$DIR/data/komari.db" ] && _had_db=1

  get_komari || return 1
  get_cfd || return 1

  save_conf
  write_wrappers
  svc_install "$SVC_K" "Komari Monitor" "$KRUN" ""
  svc_install "$SVC_C" "Cloudflare Tunnel for Komari" "$CRUN" "${SVC_K}.service"
  install_shortcut

  info "启动服务"
  restart_all

  if wait_komari; then
    ok "Komari 已在 127.0.0.1:${KPORT} 正常响应"
  else
    err "Komari 未能启动，日志如下:"
    tail -n 20 "$KLOG" 2>/dev/null
  fi

  info "等待隧道连接 (最多 40 秒)"
  if wait_tunnel; then
    ok "Cloudflare Tunnel 已连接"
  else
    err "隧道未连接成功，日志如下:"
    tail -n 20 "$CLOG" 2>/dev/null
    warn "请确认 Token 正确, 且 VPS 能访问 Cloudflare (出站 7844 端口)"
  fi

  echo ""
  echo "${B}================ 安装完成 ================${N}"
  echo "  访问地址 : https://$DOMAIN"
  echo "  用户名   : $AUSER"
  echo "  密码     : $APASS"
  if [ "$_had_db" -eq 1 ]; then
    warn "检测到已有数据库, 账号密码以原有的为准 (环境变量只在首次初始化时生效)"
  fi
  echo ""
  echo "${Y}重要: 还需在 Cloudflare 后台为隧道添加 Public Hostname:${N}"
  echo "  Zero Trust -> Networks -> Tunnels -> 你的隧道 -> Public Hostname -> Add"
  echo "    Hostname : $DOMAIN"
  echo "    Service  : HTTP   URL: 127.0.0.1:${KPORT}"
  echo "  (Service 类型必须选 HTTP, 不是 HTTPS)"
  echo ""
  echo "  日志: $KLOG  /  $CLOG"
  echo "  之后可直接运行: komari-cf  打开本菜单"
  echo "${B}==========================================${N}"
}

install_shortcut(){
  [ -z "$SELF_URL" ] && return 0
  _t="/usr/local/bin/komari-cf.part"
  if curl -fsSL --max-time 20 -o "$_t" "$SELF_URL" 2>/dev/null && head -n 1 "$_t" | grep -q '^#!/bin/sh'; then
    mv -f "$_t" /usr/local/bin/komari-cf
    chmod +x /usr/local/bin/komari-cf
  else
    rm -f "$_t"
  fi
  return 0
}

do_status(){
  load_conf
  echo ""
  for _s in "$SVC_K" "$SVC_C"; do
    if svc_active "$_s"; then ok "服务 $_s : 运行中"; else err "服务 $_s : 未运行"; fi
  done
  _c=$(http_code "http://127.0.0.1:${KPORT}/")
  case "$_c" in
    2*|3*|4*) ok "本地面板 127.0.0.1:${KPORT} : HTTP $_c" ;;
    *)        err "本地面板 127.0.0.1:${KPORT} : 无响应" ;;
  esac
  if grep -q "Registered tunnel connection" "$CLOG" 2>/dev/null; then
    ok "隧道: 日志中有已注册的连接"
  else
    warn "隧道: 日志中暂无已注册连接 (查看日志确认)"
  fi
  if [ -n "$DOMAIN" ]; then
    _c=$(http_code "https://$DOMAIN/")
    case "$_c" in
      2*|3*) ok "公网 https://$DOMAIN : HTTP $_c" ;;
      000)   err "公网 https://$DOMAIN : 无法连接 (DNS 未生效 / 未添加 Public Hostname)" ;;
      *)     warn "公网 https://$DOMAIN : HTTP $_c (502/530 多半是 Public Hostname 的服务地址填错)" ;;
    esac
  fi
  echo ""
  echo "  监听地址 : ${BIND}:${KPORT}"
  echo "  管理员   : $AUSER / $APASS"
}

do_logs(){
  echo "${B}--- komari 最近 40 行 ($KLOG) ---${N}"
  tail -n 40 "$KLOG" 2>/dev/null || echo "(无日志)"
  echo ""
  echo "${B}--- cloudflared 最近 40 行 ($CLOG) ---${N}"
  tail -n 40 "$CLOG" 2>/dev/null || echo "(无日志)"
}

do_reconfig(){
  [ -f "$CONF" ] || { err "尚未安装"; return 1; }
  collect_conf || return 1
  save_conf
  info "重启服务使配置生效"
  restart_all
  wait_komari && ok "Komari 正常" || err "Komari 未响应, 请看日志"
  wait_tunnel && ok "隧道已连接" || warn "隧道尚未连接, 请看日志"
  warn "管理员账号密码只在数据库首次初始化时生效, 之后请在面板内修改"
}

do_update(){
  [ -f "$CONF" ] || { err "尚未安装"; return 1; }
  check_deps
  get_komari && get_cfd
  info "重启服务"
  restart_all
  wait_komari && ok "更新完成" || err "Komari 未响应, 请看日志"
}

do_uninstall(){
  ask "确定卸载 Komari 与 Tunnel 服务? 输入 yes 确认" "no" || return 1
  [ "$REPLY_VAL" = "yes" ] || { info "已取消"; return 0; }
  svc_remove "$SVC_K"
  svc_remove "$SVC_C"
  rm -f "$KBIN" "$KRUN" "$CRUN" "$CBIN" "$KLOG" "$CLOG" /usr/local/bin/komari-cf
  ask "是否同时删除面板数据 $DIR/data (监控历史、节点等, 不可恢复)? y/n" "n" || return 1
  case "$REPLY_VAL" in
    y|Y|yes) rm -rf "$DIR"; ok "已删除数据目录" ;;
    *) info "已保留数据: $DIR/data" ;;
  esac
  ask "是否删除配置文件 $CONF? y/n" "y" || return 1
  case "$REPLY_VAL" in
    n|N|no) ;;
    *) rm -f "$CONF" ;;
  esac
  ok "卸载完成"
}

# ---------------------------------------------------------------------
#  主菜单
# ---------------------------------------------------------------------
menu(){
  while :; do
    clear 2>/dev/null
    echo "${B}${C}=== Komari + Cloudflare Tunnel 管理 v$VER ===${N}"
    echo "  系统: $OS/$INIT  架构: $ARCH"
    echo ""
    echo "  1) 安装 / 重装"
    echo "  2) 查看状态"
    echo "  3) 重启服务"
    echo "  4) 停止服务"
    echo "  5) 查看日志"
    echo "  6) 修改配置 (域名/Token/端口/账号)"
    echo "  7) 更新 Komari 和 cloudflared"
    echo "  8) 卸载"
    echo "  0) 退出"
    echo ""
    ask "请选择" "" || exit 0
    load_conf
    case "$REPLY_VAL" in
      1) do_install ;;
      2) do_status ;;
      3) restart_all; ok "已重启" ;;
      4) svc stop "$SVC_C"; svc stop "$SVC_K"; ok "已停止" ;;
      5) do_logs ;;
      6) do_reconfig ;;
      7) do_update ;;
      8) do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
    anykey
  done
}

main(){
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行"; exit 1
  fi
  detect_env
  load_conf
  menu
}

# 必须放在文件最后一行: 脚本下载不完整时 main 不会被调用, 不会执行半截逻辑
main "$@"
