#!/bin/sh
# TUIC v5 代理管理脚本（内核: sing-box）
# 兼容 Alpine / Debian / Ubuntu，自动保活（崩溃自动重启 + 开机自启）
#
# 兼容入口：Alpine 默认没有 bash，这里先装好 bash 再用 bash 重新执行本脚本
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash >/dev/null 2>&1 && command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1
    fi
    command -v bash >/dev/null 2>&1 || { echo "❌ 需要 bash，请先安装: apk add bash 或 apt install bash"; exit 1; }
    exec bash "$0" "$@"
fi

### ===== 配置参数 =====
TAG="TUIC"
SVC="tuic-proxy"                       # 服务名
WORKDIR="/etc/tuic-proxy"
SB_BIN="$WORKDIR/sing-box"             # 内核放在自己目录，不和系统里别的 sing-box 冲突
CONF="$WORKDIR/config.json"
INFO_FILE="$WORKDIR/info.txt"
CERT_DIR="$WORKDIR/cert"
TMPD="$WORKDIR/tmp"                    # 下载临时目录：放磁盘，不用 /tmp(可能是内存盘)
SYSTEMD_DIR="/etc/systemd/system"
INITD_DIR="/etc/init.d"
LOG_FILE="/var/log/tuic-proxy.log"     # 仅 Alpine 使用
SYSCTL_FILE="/etc/sysctl.d/99-tuic-proxy.conf"
# 已有自签证书的候选位置（格式 证书:私钥）。Argo 脚本生成的证书就在这里
CERT_CANDIDATES=("/etc/argo-proxy/cert.pem:/etc/argo-proxy/key.pem")
### =====================

GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; CYAN='\e[36m'; NC='\e[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# ---------- 系统判断 ----------
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt-get >/dev/null 2>&1; then
    OS="debian"      # Debian / Ubuntu
else
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}"; exit 1
fi

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH_SB="amd64" ;;
        aarch64|arm64)  ARCH_SB="arm64" ;;
        armv7l|armv7)   ARCH_SB="armv7" ;;
        i386|i686)      ARCH_SB="386"   ;;
        *) echo -e "${RED}❌ 不支持的架构: $(uname -m)${NC}"; return 1 ;;
    esac
}

# ---------- 服务控制 ----------
svc() {  # svc <start|stop|restart> —— 出错不退出，由调用方自行验证
    if [ "$OS" = "alpine" ]; then rc-service "$SVC" "$1" >/dev/null 2>&1 || true
    else systemctl "$1" "$SVC" >/dev/null 2>&1 || true; fi
}
service_active() {
    if [ "$OS" = "alpine" ]; then rc-service "$SVC" status >/dev/null 2>&1
    else systemctl is-active --quiet "$SVC" 2>/dev/null; fi
}
service_enabled() {
    if [ "$OS" = "alpine" ]; then rc-update show default 2>/dev/null | grep -qw "$SVC"
    else systemctl is-enabled --quiet "$SVC" 2>/dev/null; fi
}
check_init_system() {
    if [ "$OS" = "alpine" ]; then
        command -v rc-service >/dev/null 2>&1 || { echo -e "${RED}❌ 未检测到 OpenRC，无法注册开机自启服务${NC}"; return 1; }
    else
        [ -d /run/systemd/system ] || { echo -e "${RED}❌ 未检测到 systemd 正在运行（容器/精简系统？），无法注册开机自启服务${NC}"; return 1; }
    fi
}
show_logs() {  # show_logs <行数>
    if [ "$OS" = "alpine" ]; then tail -n "$1" "$LOG_FILE" 2>/dev/null
    elif command -v journalctl >/dev/null 2>&1; then journalctl -u "$SVC" --no-pager -n "$1" 2>/dev/null
    fi | sed 's/^/     /'
}

# ---------- 依赖：缺什么装什么，已有的跳过 ----------
pkg_install() {  # pkg_install <包名...>
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache "$@" >/dev/null 2>&1
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
    fi
}
ensure_deps() {
    echo -e "${CYAN}🔍 检查所需软件...${NC}"
    local APT_UPDATED="" c pkg
    local need=(curl openssl tar gzip)
    for c in "${need[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ $c 已安装，跳过${NC}"
        else
            echo -e "  ${YELLOW}⬇️  $c 未安装，正在安装...${NC}"
            if [ "$OS" = "debian" ] && [ -z "$APT_UPDATED" ]; then apt-get update -qq >/dev/null 2>&1; APT_UPDATED=1; fi
            pkg_install "$c"
            command -v "$c" >/dev/null 2>&1 || { echo -e "  ${RED}❌ $c 安装失败${NC}"; return 1; }
            echo -e "  ${GREEN}✅ $c 安装完成${NC}"
        fi
    done
    # CA 证书（精简系统的 curl 可能没有，会导致 https 下载失败）
    if [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ]; then
        echo -e "  ${GREEN}✅ ca-certificates 已安装，跳过${NC}"
    else
        echo -e "  ${YELLOW}⬇️  ca-certificates 未安装，正在安装...${NC}"
        if [ "$OS" = "debian" ] && [ -z "$APT_UPDATED" ]; then apt-get update -qq >/dev/null 2>&1; APT_UPDATED=1; fi
        pkg_install ca-certificates || { echo -e "  ${RED}❌ ca-certificates 安装失败${NC}"; return 1; }
    fi
    # 端口检测工具（ss 或 netstat 任意一个即可；Alpine 的 busybox 自带 netstat）
    if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ 端口检测工具已安装，跳过${NC}"
    else
        echo -e "  ${YELLOW}⬇️  端口检测工具未安装，正在安装...${NC}"
        if [ "$OS" = "debian" ] && [ -z "$APT_UPDATED" ]; then apt-get update -qq >/dev/null 2>&1; APT_UPDATED=1; fi
        if [ "$OS" = "debian" ]; then pkg_install iproute2 || pkg_install net-tools; else pkg_install iproute2; fi
        command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || { echo -e "  ${RED}❌ 端口检测工具安装失败${NC}"; return 1; }
    fi
    echo -e "${GREEN}✅ 依赖检查完成${NC}\n"
}

# ---------- 端口 ----------
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
port_in_use() {  # UDP 端口是否被占用
    { ss -lnu 2>/dev/null || netstat -lnu 2>/dev/null; } | grep -qE "[:.]$1[[:space:]]"
}
# ask_port [允许使用的当前端口]：回车=随机；输入的端口被占用会要求重输
ask_port() {
    local allow="$1" input p i
    while true; do
        read -r -p "请输入监听端口 (UDP，留空=随机 10000-60000): " input
        input=$(printf '%s' "$input" | tr -d '[:space:]\r')
        if [[ -z "$input" ]]; then
            for i in $(seq 1 100); do
                p=$(( ( (RANDOM << 15) | RANDOM ) % 50001 + 10000 ))
                port_in_use "$p" || break
            done
            PORT="$p"
            echo -e "${GREEN}🎲 已随机选择端口: $PORT${NC}"
            return 0
        fi
        if ! valid_port "$input"; then echo -e "${RED}❌ 端口无效，请输入 1-65535 的数字${NC}"; continue; fi
        if [[ "$input" != "$allow" ]] && port_in_use "$input"; then
            echo -e "${RED}❌ UDP 端口 $input 已被占用，请换一个${NC}"; continue
        fi
        PORT="$input"; return 0
    done
}

# 防火墙放行（尽力而为；云厂商的安全组需要你自己在网页控制台放行）
fw_open() {
    local p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "status: active"; then
        ufw allow "$p"/udp >/dev/null 2>&1 && echo -e "  ${GREEN}✅ ufw 已放行 UDP $p${NC}"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$p"/udp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✅ firewalld 已放行 UDP $p${NC}"
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | head -1 | grep -q -- '-P INPUT DROP'; then
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
        echo -e "  ${YELLOW}⚠️  iptables 默认策略为 DROP，已临时放行 UDP $p（重启后失效，请自行持久化）${NC}"
    fi
}
fw_close() {
    local p="$1"
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "status: active" && ufw delete allow "$p"/udp >/dev/null 2>&1
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 && \
        { firewall-cmd --permanent --remove-port="$p"/udp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; }
    command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1
    return 0
}

# QUIC 需要较大的 UDP 缓冲区，否则内核会打警告且吞吐受限（失败不影响使用）
tune_udp_buffer() {
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null
    printf 'net.core.rmem_max=7500000\nnet.core.wmem_max=7500000\n' > "$SYSCTL_FILE" 2>/dev/null
    sysctl -w net.core.rmem_max=7500000 net.core.wmem_max=7500000 >/dev/null 2>&1 || true
}

# ---------- 证书：已有就复用，没有才生成 ----------
cert_pair_ok() {  # cert key —— 文件存在、未过期、公钥匹配
    [ -s "$1" ] && [ -s "$2" ] || return 1
    openssl x509 -noout -checkend 86400 -in "$1" >/dev/null 2>&1 || return 1
    local a b
    a=$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null | sha256sum | awk '{print $1}')
    b=$(openssl pkey -pubout -in "$2" 2>/dev/null | sha256sum | awk '{print $1}')
    [ -n "$a" ] && [ "$a" = "$b" ]
}
prepare_cert() {
    mkdir -p "$CERT_DIR"
    local pair c k found=""
    echo -e "${CYAN}🔐 检查自签证书...${NC}"
    if cert_pair_ok "$CERT_DIR/cert.pem" "$CERT_DIR/key.pem"; then
        echo -e "  ${GREEN}♻️  本脚本已有可用证书，直接复用${NC}"
        found=1
    else
        for pair in "${CERT_CANDIDATES[@]}"; do
            c="${pair%%:*}"; k="${pair##*:}"
            if cert_pair_ok "$c" "$k"; then
                echo -e "  ${GREEN}♻️  检测到系统已有自签证书: $c${NC}"
                echo -e "  ${GREEN}   直接复用（复制一份到 $CERT_DIR，以后卸载 Argo 也不影响本服务）${NC}"
                cp -f "$c" "$CERT_DIR/cert.pem" && cp -f "$k" "$CERT_DIR/key.pem" && found=1
                break
            fi
        done
    fi
    if [ -z "$found" ]; then
        echo -e "  ${YELLOW}未发现可用证书，正在生成自签证书（EC P-256，有效期10年）...${NC}"
        openssl ecparam -genkey -name prime256v1 -noout -out "$CERT_DIR/key.pem" 2>/dev/null || { echo -e "${RED}❌ 生成私钥失败${NC}"; return 1; }
        openssl req -new -x509 -days 3650 -key "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
            -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1 \
        || openssl req -new -x509 -days 3650 -key "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
            -subj "/CN=www.bing.com" >/dev/null 2>&1 \
        || { echo -e "${RED}❌ 生成证书失败${NC}"; return 1; }
        echo -e "  ${GREEN}✅ 证书生成完成${NC}"
    fi
    chmod 600 "$CERT_DIR/key.pem"
    CERT_PATH="$CERT_DIR/cert.pem"; KEY_PATH="$CERT_DIR/key.pem"
    SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p' | head -1 | tr -d '[:space:]')
    [[ -z "$SNI" ]] && SNI="www.bing.com"
    CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT_PATH" 2>/dev/null | sed 's/.*=//' | tr 'a-f' 'A-F')
    echo -e "  🔏 证书 SHA256 指纹: ${YELLOW}$CERT_SHA256${NC}\n"
}

# ---------- 下载 sing-box ----------
get_latest_version() {  # 只取稳定版（/releases/latest 不会指向预发布版）
    local url ver
    url=$(curl -4 -sIL -o /dev/null -w '%{url_effective}' --max-time 15 "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null)
    ver="${url##*/}"
    if ! [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ver=$(curl -4 -sfL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
              | grep -m1 '"tag_name"' | sed -E 's/.*"(v[^"]+)".*/\1/')
    fi
    [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    echo "$ver"
}
# 取官方发布页里每个文件的 sha256 摘要；取不到就返回空（由调用方跳过校验）
# 优先读 release 网页片段（不受 API 限流影响），失败再退回 GitHub API
get_asset_digest() {  # <tag> <文件名>
    local d
    d=$(curl -4 -sfL --max-time 25 "https://github.com/SagerNet/sing-box/releases/expanded_assets/$1" 2>/dev/null \
        | grep -F "digest for $2\"" | sed -n 's/.*value="sha256:\([0-9a-fA-F]*\)".*/\1/p' | head -1)
    if [[ -z "$d" ]]; then
        d=$(curl -4 -sfL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/$1" 2>/dev/null \
            | awk -v want="\"name\": \"$2\"" '
                /"name":/ { hit = (index($0, want) > 0) }
                hit && /"digest":/ { sub(/.*sha256:/, ""); sub(/[^0-9a-fA-F].*/, ""); print; exit }')
    fi
    printf '%s' "$d"
}
download_singbox() {
    echo -e "${CYAN}⬇️  正在获取 sing-box 最新稳定版本号...${NC}"
    SB_VER=$(get_latest_version) || { echo -e "${RED}❌ 无法获取版本号，请检查能否访问 github.com${NC}"; return 1; }
    echo -e "${GREEN}✅ 最新版本: $SB_VER${NC}"
    mkdir -p "$TMPD"

    # 先试通用静态包；若在本系统上跑不起来，再换 musl(Alpine) / glibc(Debian系) 包
    local sfxs=("") sfx file url ok="" attempt expected actual bin
    if [ "$OS" = "alpine" ]; then sfxs+=("-musl"); else sfxs+=("-glibc"); fi

    for sfx in "${sfxs[@]}"; do
        file="sing-box-${SB_VER#v}-linux-${ARCH_SB}${sfx}.tar.gz"
        url="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${file}"
        echo -e "${CYAN}⬇️  正在下载 $file ...${NC}"
        rm -f "$TMPD/sb.tar.gz"
        for attempt in 1 2; do
            [[ $attempt -gt 1 ]] && echo -e "${YELLOW}   ⚠️ 第 $attempt 次尝试...${NC}"
            if curl -4 -fL --progress-bar --retry 2 --retry-delay 2 --connect-timeout 10 -o "$TMPD/sb.tar.gz" "$url" \
               && tar -tzf "$TMPD/sb.tar.gz" >/dev/null 2>&1; then
                ok=1; break
            fi
            rm -f "$TMPD/sb.tar.gz"
        done
        [ -z "$ok" ] && { echo -e "${YELLOW}   ⚠️ $file 下载失败，尝试下一种包${NC}"; continue; }
        ok=""

        expected=$(get_asset_digest "$SB_VER" "$file")
        if [[ -n "$expected" ]]; then
            actual=$(sha256sum "$TMPD/sb.tar.gz" | awk '{print $1}')
            if [[ "${expected,,}" != "${actual,,}" ]]; then
                echo -e "${RED}   ❌ SHA256 校验不一致，文件可能被篡改或损坏，已丢弃${NC}"
                rm -f "$TMPD/sb.tar.gz"; continue
            fi
            echo -e "${GREEN}   ✅ SHA256 校验通过${NC}"
        else
            echo -e "${YELLOW}   ⚠️ 未能获取官方摘要，跳过哈希校验（已做压缩包完整性校验）${NC}"
        fi

        rm -rf "$TMPD/x"; mkdir -p "$TMPD/x"
        tar -xzf "$TMPD/sb.tar.gz" -C "$TMPD/x" || { echo -e "${RED}   ❌ 解压失败${NC}"; continue; }
        bin=$(find "$TMPD/x" -type f -name sing-box 2>/dev/null | head -1)
        [ -n "$bin" ] || { echo -e "${RED}   ❌ 压缩包里没找到 sing-box${NC}"; continue; }
        chmod +x "$bin"
        if ! "$bin" version >/dev/null 2>&1; then
            echo -e "${YELLOW}   ⚠️ 该包在本系统上无法运行，尝试下一种包${NC}"; continue
        fi
        rm -f "$SB_BIN"                      # 先删再放，避免 Text file busy
        mv -f "$bin" "$SB_BIN" && chmod +x "$SB_BIN"
        rm -rf "$TMPD"
        echo -e "${GREEN}✅ 内核安装完成: $("$SB_BIN" version 2>/dev/null | head -1)${NC}\n"
        return 0
    done
    rm -rf "$TMPD"
    echo -e "${RED}❌ sing-box 下载/安装失败${NC}"
    return 1
}

# ---------- 配置 ----------
write_config() {
    local LISTEN="0.0.0.0"
    # 系统启用了 IPv6 就双栈监听，否则只监听 IPv4（避免 "::" 绑定失败）
    if [ -f /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "0" ]; then LISTEN="::"; fi
    cat > "$CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "$LISTEN",
      "listen_port": $PORT,
      "users": [
        { "name": "user", "uuid": "$UUID", "password": "$PASSWORD" }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT_PATH",
        "key_path": "$KEY_PATH"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    chmod 600 "$CONF"
}
check_config() { "$SB_BIN" check -c "$CONF" 2>&1; }

write_info() {
    cat > "$INFO_FILE" <<EOF
UUID="$UUID"
PASSWORD="$PASSWORD"
PORT="$PORT"
IP="$IP"
SNI="$SNI"
CERT_PATH="$CERT_PATH"
KEY_PATH="$KEY_PATH"
CERT_SHA256="$CERT_SHA256"
SB_VER="$SB_VER"
EOF
    chmod 600 "$INFO_FILE"
}
load_info() { [ -f "$INFO_FILE" ] && . "$INFO_FILE"; }

# ---------- 保活：注册服务（崩溃自动重启 + 开机自启） ----------
register_service() {
    if [ "$OS" = "alpine" ]; then
        # OpenRC + supervise-daemon：进程挂掉 3 秒后自动重启，无次数上限
        cat > "$INITD_DIR/$SVC" <<EOF
#!/sbin/openrc-run
name="$SVC"
description="TUIC (sing-box)"
export GOGC=50 GOMEMLIMIT=96MiB
command="$SB_BIN"
command_args="run -c $CONF"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="/run/$SVC.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"
depend() {
    need net
    after firewall
}
EOF
        chmod +x "$INITD_DIR/$SVC"
        rc-update add "$SVC" default >/dev/null 2>&1
    else
        # systemd：Restart=always 崩溃自动拉起；StartLimitIntervalSec=0 永不放弃；enable 开机自启
        cat > "$SYSTEMD_DIR/$SVC.service" <<EOF
[Unit]
Description=TUIC (sing-box)
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=GOGC=50
Environment=GOMEMLIMIT=96MiB
ExecStart=$SB_BIN run -c $CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SVC" >/dev/null 2>&1
    fi
}

start_and_verify() {
    svc stop; svc start
    local i
    for i in $(seq 1 10); do
        sleep 1
        if service_active && port_in_use "$PORT"; then return 0; fi
    done
    echo -e "${RED}❌ 服务启动失败或端口未监听。配置检查结果和最近日志：${NC}"
    check_config | sed 's/^/     /'
    show_logs 15
    return 1
}

# ---------- 公网 IP ----------
get_ip() {
    local u ip
    for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ip.sb; do
        ip=$(curl -4 -s --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then IP="$ip"; return 0; fi
    done
    for u in https://api64.ipify.org https://ifconfig.me; do
        ip=$(curl -6 -s --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then IP="$ip"; return 0; fi
    done
    return 1
}

# ---------- 显示节点信息 ----------
show_info() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ TUIC 代理未安装，请先选 1 安装${NC}"; return 1
    fi
    load_info
    local OLD_IP="$IP"
    get_ip || IP="$OLD_IP"
    if [[ -n "$IP" && "$IP" != "$OLD_IP" ]]; then sed -i "s|^IP=.*|IP=\"$IP\"|" "$INFO_FILE"; fi

    local HOST="$IP"
    [[ "$HOST" == *:* ]] && HOST="[$HOST]"
    [[ -z "$HOST" ]] && HOST="<服务器IP>"
    local LINK="tuic://${UUID}:${PASSWORD}@${HOST}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}&allow_insecure=1&insecure=1#${TAG}"

    echo -e "\n${GREEN}============ TUIC 代理配置信息 ============${NC}"
    echo -e "📌 UUID:        ${YELLOW}$UUID${NC}"
    echo -e "🔑 密码:        ${YELLOW}$PASSWORD${NC}"
    echo -e "🌐 服务器 IP:   ${YELLOW}${IP:-获取失败}${NC}"
    echo -e "🔌 端口(UDP):   ${YELLOW}$PORT${NC}"
    echo -e "🔤 SNI:         ${YELLOW}$SNI${NC}"
    echo -e "🧩 内核:        ${YELLOW}sing-box $SB_VER${NC}"
    echo -e "🔏 证书 SHA256: ${YELLOW}$CERT_SHA256${NC}"
    echo -e "\n${GREEN}📎 TUIC 节点链接:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "\n${CYAN}💡 v2rayN(sing-box 内核) / NekoBox / Shadowrocket / sing-box 客户端可直接导入链接${NC}"
    echo -e "${CYAN}💡 证书是自签的：链接已带 allow_insecure=1；支持证书指纹校验的客户端可填入上面的 SHA256${NC}"
    echo -e "${CYAN}💡 TUIC 走 UDP：请确认云厂商安全组/防火墙已放行 UDP ${PORT}${NC}"
    echo -e "${GREEN}============================================${NC}\n"
}

# ---------- 1. 安装 ----------
install_tuic() {
    detect_arch      || return 1
    check_init_system || return 1
    ensure_deps      || return 1

    # —— 依赖装好后，唯一一次停下来问端口；回车=随机，之后全自动 ——
    local OLD_PORT=""
    [ -f "$INFO_FILE" ] && { . "$INFO_FILE"; OLD_PORT="$PORT"; }
    svc stop                                  # 重装时先停旧服务，释放端口和文件
    ask_port "$OLD_PORT"
    echo

    mkdir -p "$WORKDIR"
    prepare_cert     || return 1
    download_singbox || return 1

    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    [[ -z "$UUID" ]] && UUID=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    PASSWORD=$(openssl rand -hex 16)

    write_config
    echo -e "${CYAN}🧪 校验配置...${NC}"
    if ! check_config >/tmp/tuic_check.log 2>&1; then
        echo -e "${RED}❌ 配置校验失败：${NC}"; sed 's/^/     /' /tmp/tuic_check.log; rm -f /tmp/tuic_check.log; return 1
    fi
    rm -f /tmp/tuic_check.log
    echo -e "${GREEN}✅ 配置有效${NC}"

    echo -e "${CYAN}🛡️  注册服务（崩溃自动重启 + 开机自启）...${NC}"
    register_service
    [ -n "$OLD_PORT" ] && [ "$OLD_PORT" != "$PORT" ] && fw_close "$OLD_PORT"
    fw_open "$PORT"
    tune_udp_buffer

    echo -e "${CYAN}🚀 启动服务...${NC}"
    start_and_verify || return 1

    get_ip || IP=""
    write_info
    echo -e "\n${GREEN}✅ TUIC 代理安装完成！服务已设置开机自启，崩溃/宕机重启后自动拉起${NC}"
    show_info
}

# ---------- 3. 修改端口 ----------
change_port() {
    if [ ! -f "$INFO_FILE" ]; then echo -e "${RED}❌ 请先安装 TUIC 代理${NC}"; return 1; fi
    load_info
    local OLD_PORT="$PORT"
    echo -e "${YELLOW}当前端口: $OLD_PORT (UDP)${NC}"
    ask_port "$OLD_PORT"
    if [[ "$PORT" == "$OLD_PORT" ]]; then echo -e "${YELLOW}端口未变化${NC}"; return 0; fi

    write_config
    if ! check_config >/dev/null 2>&1; then
        echo -e "${RED}❌ 新配置校验失败，已回滚${NC}"; PORT="$OLD_PORT"; write_config; return 1
    fi
    sed -i "s/^PORT=.*/PORT=\"$PORT\"/" "$INFO_FILE"
    fw_close "$OLD_PORT"; fw_open "$PORT"
    start_and_verify || return 1
    echo -e "${GREEN}✅ 端口已更改为 $PORT${NC}"
    show_info
}

# ---------- 4. 卸载 ----------
uninstall_tuic() {
    local ans
    read -r -p "确定卸载 TUIC 代理？(y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}已取消${NC}"; return 0; }
    echo -e "${YELLOW}正在卸载 TUIC 代理...${NC}"
    [ -f "$INFO_FILE" ] && { . "$INFO_FILE"; [ -n "$PORT" ] && fw_close "$PORT"; }
    svc stop
    if [ "$OS" = "alpine" ]; then
        rc-update del "$SVC" default >/dev/null 2>&1 || true
        rm -f "$INITD_DIR/$SVC" "$LOG_FILE"
    else
        systemctl disable "$SVC" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DIR/$SVC.service"
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR"
    rm -f "$SYSCTL_FILE"
    echo -e "${GREEN}✅ 卸载完成（Argo 的证书 /etc/argo-proxy 未被触碰）${NC}"
}

# ---------- 5. 诊断 ----------
diagnose() {
    if [ ! -f "$INFO_FILE" ]; then echo -e "${RED}❌ 未安装${NC}"; return 1; fi
    load_info
    echo -e "\n${GREEN}============== TUIC 状态诊断 ==============${NC}"

    echo -e "${CYAN}[1] 服务状态 / 保活${NC}"
    if service_active; then echo -e "  ${GREEN}✅ 服务运行中${NC}"; else echo -e "  ${RED}❌ 服务未运行（可尝试: 重新选 1 安装，或查看下面的日志）${NC}"; fi
    if service_enabled; then echo -e "  ${GREEN}✅ 已设置开机自启（VPS 重启后自动拉起）${NC}"; else echo -e "  ${RED}❌ 未设置开机自启${NC}"; fi

    echo -e "${CYAN}[2] UDP 端口 $PORT 是否在监听${NC}"
    if port_in_use "$PORT"; then echo -e "  ${GREEN}✅ 正在监听${NC}"; else echo -e "  ${RED}❌ 没有监听${NC}"; fi

    echo -e "${CYAN}[3] 配置文件检查${NC}"
    local R; R=$(check_config)
    if [ -z "$R" ]; then echo -e "  ${GREEN}✅ 配置有效${NC}"; else echo -e "  ${RED}❌ 配置有问题:${NC}"; echo "$R" | sed 's/^/     /'; fi

    echo -e "${CYAN}[4] 证书${NC}"
    if cert_pair_ok "$CERT_PATH" "$KEY_PATH"; then
        echo -e "  ${GREEN}✅ 证书有效，$(openssl x509 -noout -enddate -in "$CERT_PATH" 2>/dev/null)${NC}"
    else
        echo -e "  ${RED}❌ 证书缺失/已过期/与私钥不匹配${NC}"
    fi

    echo -e "${CYAN}[5] 防火墙${NC}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "status: active"; then
        ufw status 2>/dev/null | grep -q "$PORT/udp" && echo -e "  ${GREEN}✅ ufw 已放行 $PORT/udp${NC}" || echo -e "  ${RED}❌ ufw 已启用但没有放行 $PORT/udp${NC}"
    else
        echo -e "  ${GREEN}✅ 本机 ufw 未启用${NC}"
    fi
    echo -e "  ${YELLOW}→ 云厂商网页控制台的安全组/防火墙需自行确认已放行 UDP $PORT（脚本无法检测）${NC}"

    echo -e "${CYAN}[6] 最近日志${NC}"
    show_logs 8
    echo -e "${YELLOW}提示：服务端都正常但客户端仍连不上，多半是 UDP 被运营商/云防火墙拦截，可换一个端口再试（选 3）${NC}"
    echo -e "${GREEN}============================================${NC}\n"
}

pause_return() {
    echo -e "\n${CYAN}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
}

# 允许被 source 做单元测试：TUIC_TEST=1 时不进入菜单
if [[ "$TUIC_TEST" == "1" ]]; then return 0 2>/dev/null || exit 0; fi

# ========== 菜单 ==========
while true; do
    clear
    echo -e "${GREEN}TUIC 代理管理脚本 (sing-box 内核)${NC}"
    echo "1. 安装 TUIC"
    echo "2. 查看信息"
    echo "3. 修改端口"
    echo "4. 卸载"
    echo "5. 状态诊断"
    echo "0. 退出脚本"
    read -r -p "选择: " choice
    case $choice in
        1) install_tuic   ; pause_return ;;
        2) show_info      ; pause_return ;;
        3) change_port    ; pause_return ;;
        4) uninstall_tuic ; pause_return ;;
        5) diagnose       ; pause_return ;;
        0) echo -e "${GREEN}已退出脚本${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}"; pause_return ;;
    esac
done
