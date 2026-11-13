#!/bin/sh
# =====================================================================
#  Komari 监控面板 + Nginx 反向代理(certbot 自动 HTTPS) 一键管理脚本  v5.0
#  不使用 Cloudflare Tunnel: 域名 A 记录直接指向本 VPS, certbot 申请并自动续期证书
#  系统: Alpine(OpenRC) / Debian / Ubuntu (systemd)
#  架构: amd64 arm64 arm 386
#  兼容: POSIX sh (dash / busybox ash / bash 均可运行)
#
#  用法 (全新精简系统没有 curl, 需先装 curl):
#    Debian/Ubuntu: apt-get update && apt-get install -y curl && bash <(curl -fsSL https://ae86.ccwu.cc/komari)
#    Alpine:        apk add curl && curl -fsSL https://ae86.ccwu.cc/komari -o k.sh && sh k.sh
# =====================================================================

VER="5.0"
SELF_URL="https://ae86.ccwu.cc/komari"      # 用于安装快捷命令 komari-menu, 不需要可留空
CONF="/etc/komari-proxy.conf"
DIR="/opt/komari"
KBIN="$DIR/komari"
WEBROOT="/var/www/certbot"
VHOST_NAME="komari.conf"
KRUN="$DIR/run-komari.sh"
KLOG="/var/log/komari.log"
SVC_K="komari"
OLD_SVCS="komari-cf komari-caddy"           # 旧版 (CF 隧道 / Caddy) 服务名, 安装时自动清理
KREPO="https://github.com/komari-monitor/komari/releases/latest/download"

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
EMAIL=""
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
      echo "EMAIL='$EMAIL'"
      echo "KPORT='$KPORT'"
      echo "BIND='$BIND'"
      echo "AUSER='$AUSER'"
      echo "APASS='$APASS'"
    } > "$CONF"
  )
  chmod 600 "$CONF"
}

# 读一行输入到 REPLY_VAL: 优先 /dev/tty, 没有终端则读 stdin
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
    INIT="openrc"
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

  if [ "$OS" = "alpine" ] || [ -d /etc/nginx/http.d ]; then
    NGX_DIR="/etc/nginx/http.d"
  else
    NGX_DIR="/etc/nginx/conf.d"
  fi
  VHOST="$NGX_DIR/$VHOST_NAME"
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
    _need="$_need gcompat libc6-compat"
  else
    command -v ss >/dev/null 2>&1 || _need="$_need iproute2"
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
#  下载 (直连 -> GitHub 镜像), 带大小校验, 先下到 .part 再替换
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

# ---------------------------------------------------------------------
#  Nginx + certbot
# ---------------------------------------------------------------------
install_nginx(){
  if command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; then
    ok "nginx 与 certbot 已安装"
  else
    info "安装 nginx 和 certbot (需要一点时间)"
    if [ "$PKG" = "apk" ]; then
      apk add --no-cache nginx certbot openssl >/dev/null 2>&1
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot openssl >/dev/null 2>&1
    fi
  fi
  if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
    err "nginx / certbot 安装失败, 请手动安装后重试"; return 1
  fi
  mkdir -p "$NGX_DIR" "$WEBROOT"
  if [ "$INIT" = "systemd" ]; then
    systemctl enable nginx >/dev/null 2>&1
  else
    openrc_prep
    rc-update add nginx default >/dev/null 2>&1
  fi
  return 0
}

# 写 nginx 站点配置: 阶段 1 = 仅 HTTP (用于签证书), 阶段 2 = HTTP 跳转 + HTTPS 反代
write_vhost(){
  _stage="$1"
  _v6=0
  [ -f /proc/net/if_inet6 ] && _v6=1
  _l80="    listen 80;"
  _l443="    listen 443 ssl http2;"
  if [ "$_v6" -eq 1 ]; then
    _l80="$_l80
    listen [::]:80;"
    _l443="$_l443
    listen [::]:443 ssl http2;"
  fi

  _proxy="        proxy_pass http://127.0.0.1:${KPORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$komari_conn_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;"

  {
    echo "# Komari 反代 - 由 komari 脚本生成, 请勿手动修改 (重新运行脚本会覆盖)"
    echo "map \$http_upgrade \$komari_conn_upgrade {"
    echo "    default upgrade;"
    echo "    ''      close;"
    echo "}"
    echo ""
    echo "server {"
    echo "$_l80"
    echo "    server_name $DOMAIN;"
    echo ""
    echo "    location /.well-known/acme-challenge/ {"
    echo "        root $WEBROOT;"
    echo "    }"
    echo ""
    echo "    location / {"
    if [ "$_stage" = "1" ]; then
      echo "$_proxy"
    else
      echo "        return 301 https://\$host\$request_uri;"
    fi
    echo "    }"
    echo "}"
    if [ "$_stage" = "2" ]; then
      echo ""
      echo "server {"
      echo "$_l443"
      echo "    server_name $DOMAIN;"
      echo ""
      echo "    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;"
      echo "    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_session_cache shared:komari_ssl:10m;"
      echo "    ssl_session_timeout 1d;"
      echo ""
      echo "    client_max_body_size 50m;"
      echo ""
      echo "    location / {"
      echo "$_proxy"
      echo "    }"
      echo "}"
    fi
  } > "$VHOST" || { err "无法写入站点配置: $VHOST"; return 1; }
}

nginx_reload(){
  if ! nginx -t >/dev/null 2>&1; then
    err "nginx 配置检测失败:"
    nginx -t 2>&1 | tail -n 8
    return 1
  fi
  if svc_active nginx; then
    svc reload nginx
  else
    svc restart nginx
  fi
  return 0
}

issue_cert(){
  mkdir -p "$WEBROOT"
  if [ -n "$EMAIL" ]; then
    _mail="-m $EMAIL"
  else
    _mail="--register-unsafely-without-email"
  fi
  info "向 Let's Encrypt 申请证书 (需要 80 端口能被外网访问)"
  # shellcheck disable=SC2086
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --agree-tos \
    $_mail --keep-until-expiring 2>&1 | tail -n 12
  [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]
}

# 证书自动续期 (systemd 定时器 / Alpine periodic)
setup_renew(){
  _cb=$(command -v certbot)
  if [ "$INIT" = "systemd" ]; then
    cat > /etc/systemd/system/komari-certbot.service <<EOF
[Unit]
Description=Renew Let's Encrypt certificates (komari)

[Service]
Type=oneshot
ExecStart=$_cb renew --quiet --deploy-hook "systemctl reload nginx"
EOF
    cat > /etc/systemd/system/komari-certbot.timer <<EOF
[Unit]
Description=Daily certificate renewal (komari)

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now komari-certbot.timer >/dev/null 2>&1
  else
    mkdir -p /etc/periodic/daily
    cat > /etc/periodic/daily/komari-certbot <<EOF
#!/bin/sh
$_cb renew --quiet --deploy-hook "rc-service nginx reload"
EOF
    chmod +x /etc/periodic/daily/komari-certbot
    openrc_prep
    rc-update add crond default >/dev/null 2>&1
    rc-service crond start >/dev/null 2>&1
  fi
}

remove_renew(){
  if [ "$INIT" = "systemd" ]; then
    systemctl disable --now komari-certbot.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/komari-certbot.service /etc/systemd/system/komari-certbot.timer
    systemctl daemon-reload
  else
    rm -f /etc/periodic/daily/komari-certbot
  fi
}

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
  chmod 700 "$KRUN"
}

# ---------------------------------------------------------------------
#  服务管理 (systemd / OpenRC 统一封装)
# ---------------------------------------------------------------------
openrc_prep(){
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

svc_exists(){
  if [ "$INIT" = "systemd" ]; then
    [ -f "/etc/systemd/system/${1}.service" ]
  else
    [ -f "/etc/init.d/${1}" ]
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
  svc restart "$SVC_K"
  nginx_reload
}

# ---------------------------------------------------------------------
#  检测
# ---------------------------------------------------------------------
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null
}

# 端口是否被占用 (ss 优先, 退回 netstat, 再退回 /proc/net/tcp)
port_in_use(){
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
  else
    _hex=$(printf '%04X' "$1")
    grep -qiE ":${_hex} [0-9A-F:]+ 0A" /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}

port_owner(){
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep ":$1 "
  else
    netstat -ltnp 2>/dev/null | grep ":$1 "
  fi
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

# 不依赖 DNS: 直接把域名解析到本机, 测试证书 + 反代是否正常
wait_https(){
  _i=0
  while [ "$_i" -lt 60 ]; do
    case "$(http_code --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/")" in
      2*|3*|4*) return 0 ;;
    esac
    _i=$((_i + 1)); sleep 1
  done
  return 1
}

# 本机公网 IP 与域名解析结果对比 (只提示, 不强制)
dns_check(){
  _pub=$(curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null)
  [ -z "$_pub" ] && _pub=$(curl -s4 --max-time 6 https://ifconfig.me 2>/dev/null)
  _res=""
  command -v getent >/dev/null 2>&1 && _res=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  echo "  本机公网 IP : ${_pub:-未知}"
  echo "  域名解析到  : ${_res:-未解析}"
  if [ -z "$_res" ]; then
    warn "域名当前没有解析! 请到 DNS 添加 A 记录: $DOMAIN -> ${_pub:-本机IP}"
  elif [ -n "$_pub" ] && ! echo "$_res" | grep -q "$_pub"; then
    warn "域名没有解析到本机。如果用的是 Cloudflare, 请把这条记录改成「仅 DNS(灰云)」,"
    warn "否则申请证书可能失败。DNS 刚改过的话, 生效需要几分钟。"
  else
    ok "域名已正确解析到本机"
  fi
}

open_firewall(){
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ok "已在 ufw 放行 80/443"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http --add-service=https >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "已在 firewalld 放行 80/443"
  fi
}

# 停掉 komari 后, 确认 Komari 端口没被占用, 且 80/443 只被 nginx (或空闲) 使用
ensure_ports_free(){
  svc stop "$SVC_K"
  sleep 1
  while port_in_use "$KPORT"; do
    err "端口 $KPORT 已被其他程序占用:"
    port_owner "$KPORT"
    warn "可能是旧的 Komari / Docker 容器。请换一个端口, 或先停掉占用者"
    ask "请输入新的 Komari 端口" "$((KPORT + 1))" || return 1
    case "$REPLY_VAL" in
      ''|*[!0-9]*) warn "端口必须是数字" ;;
      *) KPORT="$REPLY_VAL" ;;
    esac
  done
  for _p in 80 443; do
    if port_in_use "$_p"; then
      _o=$(port_owner "$_p")
      if [ -n "$_o" ] && ! echo "$_o" | grep -q nginx; then
        err "端口 $_p 已被非 nginx 程序占用:"
        echo "$_o"
        warn "常见原因: apache / caddy 在运行。可执行: systemctl disable --now apache2 caddy"
        return 1
      fi
    fi
  done
  return 0
}

# ---------------------------------------------------------------------
#  交互收集配置
# ---------------------------------------------------------------------
collect_conf(){
  [ -z "$APASS" ] && APASS="$(gen_pass)"

  while :; do
    ask "访问域名 (如 status.example.com, 需已解析到本机)" "$DOMAIN" || return 1
    DOMAIN=$(printf '%s' "$REPLY_VAL" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')
    [ -n "$DOMAIN" ] && break
    warn "域名不能为空"
  done

  ask "邮箱 (Let's Encrypt 证书到期提醒, 可留空)" "$EMAIL" || return 1
  EMAIL="$REPLY_VAL"

  while :; do
    ask "Komari 本地端口" "$KPORT" || return 1
    case "$REPLY_VAL" in
      ''|*[!0-9]*) warn "端口必须是数字" ;;
      *) if [ "$REPLY_VAL" -ge 1 ] && [ "$REPLY_VAL" -le 65535 ]; then KPORT="$REPLY_VAL"; break; fi
         warn "端口范围 1-65535" ;;
    esac
  done

  ask "Komari 仅本机监听 127.0.0.1 (推荐: 只能经域名访问, 更安全) y/n" "y" || return 1
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
install_shortcut(){
  [ -z "$SELF_URL" ] && return 0
  _t="/usr/local/bin/komari-menu.part"
  if curl -fsSL --max-time 20 -o "$_t" "$SELF_URL" 2>/dev/null && head -n 1 "$_t" | grep -q '^#!/bin/sh'; then
    mv -f "$_t" /usr/local/bin/komari-menu
    chmod +x /usr/local/bin/komari-menu
  else
    rm -f "$_t"
  fi
  return 0
}

do_install(){
  check_deps
  collect_conf || { err "未获取到输入，已取消"; return 1; }

  echo ""
  dns_check
  echo ""

  # 从旧版 (Cloudflare Tunnel / Caddy) 迁移: 清理旧服务, 释放 80/443
  for _old in $OLD_SVCS; do
    if svc_exists "$_old"; then
      info "发现旧版服务 $_old, 正在停用并移除"
      svc_remove "$_old"
    fi
  done
  rm -f /usr/local/bin/cloudflared "$DIR/run-cloudflared.sh" "$DIR/caddy" "$DIR/run-caddy.sh" "$DIR/Caddyfile"

  install_nginx || return 1
  ensure_ports_free || { err "已取消"; return 1; }

  _had_db=0
  [ -f "$DIR/data/komari.db" ] && _had_db=1

  get_komari || return 1

  save_conf
  write_wrappers
  svc_install "$SVC_K" "Komari Monitor" "$KRUN" ""
  open_firewall
  install_shortcut

  info "启动 Komari"
  svc restart "$SVC_K"
  if wait_komari; then
    ok "Komari 已在 127.0.0.1:${KPORT} 正常响应"
  else
    err "Komari 未能启动，日志如下:"
    tail -n 20 "$KLOG" 2>/dev/null
  fi

  # 阶段 1: 先只开 HTTP, 供 Let's Encrypt 验证域名
  write_vhost 1 || return 1
  nginx_reload || return 1

  if issue_cert; then
    ok "证书已就绪"
    write_vhost 2 || return 1
    nginx_reload || return 1
    setup_renew
    ok "已配置证书自动续期"
  else
    err "证书申请失败, 站点目前只能通过 HTTP 访问: http://$DOMAIN"
    warn "常见原因: 1) 域名没解析到本机  2) 80 端口被防火墙/安全组拦截"
    warn "         3) Cloudflare 记录是橙云 (改成灰云再试)"
    warn "处理好后, 回到菜单选 1 重新安装即可"
  fi

  if wait_https; then
    ok "HTTPS 反代正常: https://$DOMAIN"
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
  echo "  日志: $KLOG  /  /var/log/nginx/error.log"
  echo "  站点配置: $VHOST"
  [ -x /usr/local/bin/komari-menu ] && echo "  之后可直接运行: komari-menu  打开本菜单"
  echo ""
  echo "${Y}若从旧版迁移: 已有探针填的面板地址要和现在的域名一致,${N}"
  echo "${Y}端点是 https://$DOMAIN 即可, 不需要重新安装探针。${N}"
  echo "${B}==========================================${N}"
}

do_status(){
  load_conf
  echo ""
  for _s in "$SVC_K" nginx; do
    if svc_active "$_s"; then ok "服务 $_s : 运行中"; else err "服务 $_s : 未运行"; fi
  done
  _c=$(http_code "http://127.0.0.1:${KPORT}/")
  case "$_c" in
    2*|3*|4*) ok "本地面板 127.0.0.1:${KPORT} : HTTP $_c" ;;
    *)        err "本地面板 127.0.0.1:${KPORT} : 无响应" ;;
  esac
  for _p in 80 443; do
    if port_in_use "$_p"; then ok "端口 $_p : 正在监听"; else err "端口 $_p : 未监听"; fi
  done
  if [ -n "$DOMAIN" ]; then
    if [ -f "$VHOST" ]; then ok "站点配置: $VHOST"; else err "站点配置不存在: $VHOST"; fi
    _cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    if [ -f "$_cert" ]; then
      if command -v openssl >/dev/null 2>&1; then
        ok "证书: $(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null)"
      else
        ok "证书: 已签发"
      fi
    else
      err "证书: 未签发"
    fi
    _c=$(http_code --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/")
    case "$_c" in
      2*|3*|4*) ok "本机 HTTPS 反代 (绕过 DNS) : HTTP $_c" ;;
      *)        err "本机 HTTPS 反代 : 失败 (证书未签发? 看日志)" ;;
    esac
    _c=$(http_code "https://${DOMAIN}/")
    case "$_c" in
      2*|3*|4*) ok "公网 https://$DOMAIN : HTTP $_c" ;;
      *)        err "公网 https://$DOMAIN : 无法连接 (DNS 未生效或被拦截)" ;;
    esac
    echo ""
    dns_check
  fi
  echo ""
  echo "  监听地址 : ${BIND}:${KPORT}"
  echo "  管理员   : $AUSER / $APASS"
}

do_logs(){
  echo "${B}--- komari 最近 40 行 ($KLOG) ---${N}"
  tail -n 40 "$KLOG" 2>/dev/null || echo "(无日志)"
  echo ""
  echo "${B}--- nginx 错误日志最近 30 行 ---${N}"
  tail -n 30 /var/log/nginx/error.log 2>/dev/null || echo "(无日志)"
}

do_reconfig(){
  [ -f "$CONF" ] || { err "尚未安装"; return 1; }
  _olddomain="$DOMAIN"
  collect_conf || return 1
  ensure_ports_free || return 1
  save_conf
  write_wrappers
  open_firewall
  svc restart "$SVC_K"
  wait_komari && ok "Komari 正常" || err "Komari 未响应, 请看日志"
  if [ "$DOMAIN" != "$_olddomain" ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    write_vhost 1
    nginx_reload || return 1
    if issue_cert; then
      write_vhost 2
      setup_renew
    else
      err "新域名证书申请失败, 当前仅 HTTP 可用"
    fi
  else
    write_vhost 2
  fi
  nginx_reload
  wait_https && ok "HTTPS 反代正常" || warn "HTTPS 尚未就绪, 请看日志"
  warn "管理员账号密码只在数据库首次初始化时生效, 之后请在面板内修改"
}

do_update(){
  [ -f "$CONF" ] || { err "尚未安装"; return 1; }
  check_deps
  get_komari || return 1
  info "重启 Komari"
  svc restart "$SVC_K"
  wait_komari && ok "更新完成 (nginx 与 certbot 请用系统包管理器更新)" || err "Komari 未响应, 请看日志"
}

do_uninstall(){
  ask "确定卸载 Komari 并移除其 nginx 站点? 输入 yes 确认" "no" || return 1
  [ "$REPLY_VAL" = "yes" ] || { info "已取消"; return 0; }
  svc_remove "$SVC_K"
  rm -f "$VHOST" "$KBIN" "$KRUN" "$KLOG" /usr/local/bin/komari-menu
  remove_renew
  nginx -t >/dev/null 2>&1 && { svc_active nginx && svc reload nginx; }
  ask "是否同时删除证书 ($DOMAIN)? y/n" "n" || return 1
  case "$REPLY_VAL" in
    y|Y|yes) certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1; ok "已删除证书" ;;
  esac
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
  ok "卸载完成 (nginx 本身未卸载, 其他站点不受影响)"
}

# ---------------------------------------------------------------------
#  主菜单
# ---------------------------------------------------------------------
menu(){
  while :; do
    clear 2>/dev/null
    echo "${B}${C}=== Komari + Nginx 反代 管理 v$VER ===${N}"
    echo "  系统: $OS/$INIT  架构: $ARCH"
    echo ""
    echo "  1) 安装 / 重装"
    echo "  2) 查看状态"
    echo "  3) 重启服务"
    echo "  4) 停止服务"
    echo "  5) 查看日志"
    echo "  6) 修改配置 (域名/邮箱/端口/账号)"
    echo "  7) 更新 Komari"
    echo "  8) 卸载"
    echo "  0) 退出"
    echo ""
    ask "请选择" "" || exit 0
    load_conf
    case "$REPLY_VAL" in
      1) do_install ;;
      2) do_status ;;
      3) restart_all; ok "已重启" ;;
      4) svc stop "$SVC_K"; ok "已停止 Komari (nginx 保持运行, 不影响其他站点)" ;;
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
  check_deps
  load_conf
  menu
}

# 必须放在文件最后一行: 脚本下载不完整时 main 不会被调用, 不会执行半截逻辑
main "$@"
