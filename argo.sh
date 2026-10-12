#!/bin/sh
# 兼容入口：Alpine 默认没有 bash，这里先装好 bash 再用 bash 重新执行本脚本
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash >/dev/null 2>&1 && command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1
    fi
    command -v bash >/dev/null 2>&1 || { echo "❌ 需要 bash，请先安装: apk add bash 或 apt install bash"; exit 1; }
    exec bash "$0" "$@"
fi
# Argo 隧道管理脚本（修复版）
# 注意：不使用 set -e —— 这是交互式菜单脚本，任何一个命令失败都不应该把整个脚本带崩

### ===== 配置参数 =====
TAG="ARGO"
WORKDIR="/etc/argo-proxy"
XRAY_BIN="/usr/local/bin/xray"
ARGO_BIN="/usr/local/bin/cloudflared"
XRAY_CONF="$WORKDIR/config.json"
INFO_FILE="$WORKDIR/info.txt"
TMPD="$WORKDIR/tmp"   # 下载临时目录：放磁盘，不用 /tmp(可能是 tmpfs 内存盘)
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt-get >/dev/null 2>&1; then
    OS="debian"
else
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}"
    exit 1
fi

# 架构判断
detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)           ARCH_XRAY="64";    ARCH_ARGO="amd64" ;;
        aarch64|arm64)    ARCH_XRAY="arm64-v8a"; ARCH_ARGO="arm64" ;;
        armv7l)           ARCH_XRAY="arm32-v7a"; ARCH_ARGO="arm"   ;;
        *)
            echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"
            return 1
        ;;
    esac
}

# ---------- 服务控制 ----------
svc() {  # svc <start|stop|restart> <name>
    if [ "$OS" = "alpine" ]; then
        rc-service "$2" "$1" >/dev/null 2>&1 || true
    else
        systemctl "$1" "$2" >/dev/null 2>&1 || true
    fi
}
restart_service() { svc restart xray; svc restart cloudflared; }

# 安装依赖
install_deps() {
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl ca-certificates bash unzip wget jq 2>/dev/null || true
    else
        apt-get update -qq
        apt-get install -y -qq curl openssl ca-certificates unzip wget jq 2>/dev/null || true
    fi
}

# ---------- 输入清洗（修复的核心） ----------
# 去掉 Windows 回车符、首尾空白
trim() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# 从任意文本中提取 Cloudflare Token（以 eyJ 开头的 base64 串）
# 用户常常把 "cloudflared.exe service install eyJ..." 整条命令粘贴进来，这里自动提取
extract_token() { printf '%s' "$1" | tr -d '\r' | grep -oE 'eyJ[A-Za-z0-9=_-]+' | head -1; }

# 校验域名格式：只允许字母数字、点、连字符，且至少含一个点
valid_domain() { [[ "$1" != *.exe ]] && [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# 规范化域名：去协议头、路径、转小写
normalize_domain() {
    # 只去掉协议头、路径、首尾空白；中间含空格的内容原样保留，交给 valid_domain 拒绝
    printf '%s' "$1" | tr -d '\r' | sed -E 's#^[[:space:]]*https?://##; s#/.*$##; s/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z'
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# 读取 info 文件（所有值都带引号写入，source 不会再把空格当命令）
load_info() {
    [ -f "$INFO_FILE" ] || return 1
    . "$INFO_FILE"
    # 临时隧道：cloudflared 每次重启(含自动保活重启)域名都会变，这里始终取日志里最新的一个
    if [ "$TUNNEL_TYPE" = "temp" ]; then
        local NEWD
        NEWD=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$WORKDIR/argo.log" 2>/dev/null | sed 's#https://##' | tail -1)
        if [ -n "$NEWD" ] && [ "$NEWD" != "$ARGO_DOMAIN" ]; then
            ARGO_DOMAIN="$NEWD"
            sed -i "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=\"$NEWD\"|" "$INFO_FILE"
        fi
    fi
}

# 获取公网IP
get_ip() {
    IP4=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
}

# 显示信息
show_info() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ Argo 代理节点未安装${NC}"
        return 1
    fi
    load_info
    echo -e "\n${GREEN}========== Argo 隧道代理配置信息 ==========${NC}"
    echo -e "📌 UUID:         ${YELLOW}$UUID${NC}"
    echo -e "🌐 Argo 域名:    ${YELLOW}$ARGO_DOMAIN${NC}"
    echo -e "🔌 本地XRAY端口: ${YELLOW}$XRAY_PORT${NC}"
    echo -e "🔐 隧道类型:     ${YELLOW}$TUNNEL_TYPE${NC}"

    if [[ -z "$ARGO_DOMAIN" || "$ARGO_DOMAIN" == "<"* ]]; then
        echo -e "${RED}⚠️  没有可用的域名，无法生成节点链接，请检查 $WORKDIR/argo.log${NC}"
        return 1
    fi

    local LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless#${TAG}"
    echo -e "\n${GREEN}📎 VLESS 节点链接 (通过Argo隧道):${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "\n${CYAN}💡 v2rayN / Clash Meta / Shadowrocket 直接导入以上链接即可${NC}"
    if [[ "$TUNNEL_TYPE" == "fixed" ]]; then
        echo -e "${CYAN}💡 固定隧道：请确认 Cloudflare 面板里该隧道的 Public Hostname 已配置：${NC}"
        echo -e "${CYAN}   域名 = ${ARGO_DOMAIN}   服务类型 = HTTP   URL = 127.0.0.1:${XRAY_PORT}${NC}"
    fi
    echo -e "${GREEN}=============================================${NC}\n"
}

# 诊断：逐环检查 本机服务 -> Xray 端口 -> cloudflared 隧道 -> Cloudflare 公网访问
diagnose() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ 未安装${NC}"; return 1
    fi
    load_info
    echo -e "\n${GREEN}========== 链路诊断 ==========${NC}"

    echo -e "${CYAN}[1] 服务运行状态${NC}"
    local s st
    for s in xray cloudflared; do
        if [ "$OS" = "alpine" ]; then
            rc-service "$s" status >/dev/null 2>&1 && st="运行中" || st="未运行"
        else
            systemctl is-active --quiet "$s" && st="运行中" || st="未运行"
        fi
        [[ "$st" == "运行中" ]] && echo -e "  ${GREEN}✅ $s: $st${NC}" || echo -e "  ${RED}❌ $s: $st${NC}"
    done

    echo -e "${CYAN}[2] Xray 端口 $XRAY_PORT 是否在监听${NC}"
    if (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -q ":$XRAY_PORT "; then
        echo -e "  ${GREEN}✅ 正在监听${NC}"
    else
        echo -e "  ${RED}❌ 没有监听。Xray 配置有误或端口被占用，请运行: $XRAY_BIN run -c $XRAY_CONF${NC}"
    fi

    echo -e "${CYAN}[3] 本机直连 Xray${NC}"
    local LOCAL_CODE CF_CODE
    LOCAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$XRAY_PORT/vless" 2>/dev/null)
    if [[ "$LOCAL_CODE" == "000" || -z "$LOCAL_CODE" ]]; then
        echo -e "  ${RED}❌ 连不上 Xray (返回 000)${NC}"
    else
        echo -e "  ${GREEN}✅ Xray 有响应 (HTTP $LOCAL_CODE，普通请求被拒绝属正常现象)${NC}"
    fi

    echo -e "${CYAN}[4] cloudflared 隧道连接情况${NC}"
    if [ "$OS" != "alpine" ] && command -v journalctl >/dev/null 2>&1; then
        local LOGS
        LOGS=$(journalctl -u cloudflared --no-pager -n 40 2>/dev/null)
        local REG
        REG=$(echo "$LOGS" | grep -c "Registered tunnel connection")
        if [[ "$REG" -gt 0 ]]; then
            echo -e "  ${GREEN}✅ 已向 Cloudflare 注册 $REG 条隧道连接${NC}"
        else
            echo -e "  ${RED}❌ 日志中没有成功注册记录，最近的错误：${NC}"
            echo "$LOGS" | grep -iE "err|fail|unauthorized|invalid" | tail -5 | sed 's/^/     /'
        fi
    else
        tail -n 8 "$WORKDIR/argo.log" 2>/dev/null | sed 's/^/     /'
    fi

    echo -e "${CYAN}[5] 经 Cloudflare 公网访问 https://$ARGO_DOMAIN/vless${NC}"
    CF_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$ARGO_DOMAIN/vless" 2>/dev/null)
    case "$CF_CODE" in
        000|"")
            echo -e "  ${RED}❌ 无法访问（域名解析失败/证书错误/超时）${NC}"
            echo -e "  ${YELLOW}→ 检查域名 DNS 是否托管在 Cloudflare，且 $ARGO_DOMAIN 有指向隧道的 CNAME 记录（橙色云朵）${NC}" ;;
        502|503)
            echo -e "  ${RED}❌ HTTP $CF_CODE：Cloudflare 找到了隧道，但隧道连不上本机 Xray${NC}"
            echo -e "  ${YELLOW}→ 面板 Public Hostname 的 Type 必须是 HTTP（不是 HTTPS），URL 必须是 127.0.0.1:$XRAY_PORT${NC}" ;;
        530|1033)
            echo -e "  ${RED}❌ HTTP $CF_CODE：隧道没有连上 Cloudflare${NC}"
            echo -e "  ${YELLOW}→ 看上面第 [4] 项；Token 可能已失效/被重置，或 VPS 屏蔽了出站 7844 端口${NC}" ;;
        *)
            if [[ "$CF_CODE" == "$LOCAL_CODE" ]]; then
                echo -e "  ${GREEN}✅ HTTP $CF_CODE，与本机 Xray 响应一致：服务端整条链路是通的！${NC}"
                echo -e "  ${YELLOW}→ 若客户端仍不通，问题在客户端/本地网络（见下方提示）${NC}"
            else
                echo -e "  ${RED}❌ HTTP $CF_CODE，与本机 Xray 的 $LOCAL_CODE 不一致：请求没有到达你的 Xray${NC}"
                echo -e "  ${YELLOW}→ 面板里没有给 $ARGO_DOMAIN 添加 Public Hostname，或绑定在了另一条隧道上${NC}"
            fi ;;
    esac
    echo -e "${GREEN}==============================${NC}\n"
}

# 更改端口（本地Xray监听端口）
change_port() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ 请先安装 Argo 代理${NC}"; return 1
    fi
    load_info
    echo -e "${YELLOW}当前本地端口: $XRAY_PORT${NC}"
    read -r -p "请输入新本地端口 (回车则随机 10000-60000): " NEW_PORT
    NEW_PORT=$(trim "$NEW_PORT")
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    if ! valid_port "$NEW_PORT"; then
        echo -e "${RED}❌ 端口无效${NC}"; return 1
    fi

    sed -i "s/\"port\": $XRAY_PORT/\"port\": $NEW_PORT/" "$XRAY_CONF"

    if [ "$TUNNEL_TYPE" == "temp" ]; then
        if [ "$OS" = "alpine" ]; then
            sed -i "s|127.0.0.1:$XRAY_PORT|127.0.0.1:$NEW_PORT|g" /etc/init.d/cloudflared
        else
            sed -i "s|127.0.0.1:$XRAY_PORT|127.0.0.1:$NEW_PORT|g" /etc/systemd/system/cloudflared.service
            systemctl daemon-reload
        fi
    fi
    # 固定隧道(token模式)的转发地址保存在 Cloudflare 面板，脚本无法修改

    sed -i "s/^XRAY_PORT=.*/XRAY_PORT=\"$NEW_PORT\"/" "$INFO_FILE"
    restart_service

    if [ "$TUNNEL_TYPE" == "temp" ]; then
        # 临时隧道重启后域名会变，需要重新获取
        : > "$WORKDIR/argo.log"
        svc restart cloudflared
        get_temp_domain
        sed -i "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=\"$DOMAIN\"|" "$INFO_FILE"
    else
        echo -e "${YELLOW}⚠️  请到 Cloudflare 面板把 Public Hostname 的 URL 改为 127.0.0.1:$NEW_PORT，否则节点不通！${NC}"
    fi
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 安装 Xray
install_xray() {
    echo -e "${CYAN}⬇️  正在获取 Xray 最新版本号...${NC}"
    XRAY_VER=$(curl -4 -sfL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' 2>/dev/null || true)
    if [[ -z "$XRAY_VER" || "$XRAY_VER" == "null" ]]; then
        echo -e "${RED}❌ 无法获取 Xray 最新版本号，请检查能否访问 api.github.com${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ 最新版本: $XRAY_VER${NC}"

    mkdir -p "$TMPD"
    local XRAY_ZIP="Xray-linux-${ARCH_XRAY}.zip"
    local DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}"
    local DGST_URL="${DOWNLOAD_URL}.dgst"

    echo -e "${CYAN}⬇️  正在下载 Xray ($XRAY_ZIP)...${NC}"
    local OK="" attempt
    for attempt in 1 2 3; do
        [[ $attempt -gt 1 ]] && echo -e "${YELLOW}   ⚠️ 第 $attempt 次尝试...${NC}"

        if ! curl -4 -Lfs --retry 2 --retry-delay 2 --connect-timeout 10 -o $TMPD/xray.zip "$DOWNLOAD_URL"; then
            echo -e "${YELLOW}   ⚠️ 下载请求失败，重试${NC}"
            rm -f $TMPD/xray.zip; continue
        fi
        if ! unzip -tq $TMPD/xray.zip >/dev/null 2>&1; then
            echo -e "${YELLOW}   ⚠️ 下载内容不是有效 zip，重试${NC}"
            rm -f $TMPD/xray.zip; continue
        fi

        # 修复：.dgst 是 GitHub 302 重定向资源，必须加 -L；且字段名是 SHA2-256= 而不是 SHA256=
        local EXPECTED ACTUAL
        EXPECTED=$(curl -4 -sfL "$DGST_URL" 2>/dev/null | tr -d '\r' | grep -iE '^SHA2?-?256=' | head -1 | sed 's/^[^=]*=[[:space:]]*//')
        if [[ -n "$EXPECTED" ]]; then
            ACTUAL=$(sha256sum $TMPD/xray.zip | awk '{print $1}')
            if [[ "${EXPECTED,,}" != "${ACTUAL,,}" ]]; then
                echo -e "${YELLOW}   ⚠️ SHA256 校验不一致，重试${NC}"
                rm -f $TMPD/xray.zip; continue
            fi
            echo -e "${GREEN}   ✅ SHA256 校验通过${NC}"
        else
            echo -e "${YELLOW}   ⚠️ 未能获取官方校验文件，跳过哈希校验（已做 zip 完整性校验）${NC}"
        fi
        OK="1"; break
    done

    if [[ -z "$OK" ]]; then
        echo -e "${RED}❌ 多次尝试后仍下载失败，Xray 安装终止${NC}"
        return 1
    fi

    rm -rf "$TMPD/xray_unz" && mkdir -p "$TMPD/xray_unz"
    unzip -oq $TMPD/xray.zip xray -d $TMPD/xray_unz || { echo -e "${RED}❌ 解压失败${NC}"; return 1; }
    rm -f "$XRAY_BIN"                      # 先删除再放入，避免 "Text file busy"
    mv -f $TMPD/xray_unz/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf "$TMPD"
}

# 安装 cloudflared
install_cloudflared() {
    echo -e "${CYAN}⬇️  正在下载 cloudflared...${NC}"
    local CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_ARGO}"
    mkdir -p "$TMPD"
    local TMP_CF="$TMPD/cloudflared.new"
    local OK="" attempt

    for attempt in 1 2 3; do
        [[ $attempt -gt 1 ]] && echo -e "${YELLOW}   ⚠️ 第 $attempt 次尝试...${NC}"

        # 修复：先下载到临时文件，校验通过后再替换，不会再碰到 "Text file busy"
        if ! curl -4 -Lfs --retry 2 --retry-delay 2 --connect-timeout 10 -o "$TMP_CF" "$CF_URL"; then
            echo -e "${YELLOW}   ⚠️ 下载请求失败，重试${NC}"
            rm -f "$TMP_CF"; continue
        fi
        if [[ "$(head -c4 "$TMP_CF" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
            echo -e "${YELLOW}   ⚠️ 下载内容不是有效可执行文件，重试${NC}"
            rm -f "$TMP_CF"; continue
        fi
        OK="1"; break
    done

    if [[ -z "$OK" ]]; then
        echo -e "${RED}❌ 多次尝试后仍下载失败，cloudflared 安装终止${NC}"
        return 1
    fi
    rm -f "$ARGO_BIN"
    mv -f "$TMP_CF" "$ARGO_BIN"
    chmod +x "$ARGO_BIN"
}

# 注册服务（systemd / openrc）
register_services() {
    local XRAY_PORT="$1" TUNNEL_TYPE="$2" TUNNEL_TOKEN="$3"
    local ARGO_ARGS
    if [ "$TUNNEL_TYPE" == "fixed" ]; then
        ARGO_ARGS="tunnel --no-autoupdate --protocol http2 run --token $TUNNEL_TOKEN"
    else
        ARGO_ARGS="tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$XRAY_PORT --logfile $WORKDIR/argo.log"
    fi

    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
export GOGC=50 GOMEMLIMIT=48MiB
command="$XRAY_BIN"
command_args="run -c $XRAY_CONF"
command_background=true
pidfile="/run/xray.pid"
supervisor="supervise-daemon"
depend() { need net; }
EOF
        cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
name="cloudflared"
export GOGC=50 GOMEMLIMIT=64MiB
command="$ARGO_BIN"
command_args="$ARGO_ARGS"
command_background=true
pidfile="/run/cloudflared.pid"
supervisor="supervise-daemon"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray /etc/init.d/cloudflared
        rc-update add xray default >/dev/null 2>&1 || true
        rc-update add cloudflared default >/dev/null 2>&1 || true
    else
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Core
After=network.target

[Service]
Environment=GOGC=50
Environment=GOMEMLIMIT=48MiB
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
Environment=GOGC=50
Environment=GOMEMLIMIT=64MiB
ExecStart=$ARGO_BIN $ARGO_ARGS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray cloudflared >/dev/null 2>&1
    fi
}

# 获取临时隧道域名
get_temp_domain() {
    echo -e "${CYAN}⏳ 等待 Argo 临时域名生成（最多60秒）...${NC}"
    DOMAIN=""
    local i
    for i in $(seq 1 30); do
        sleep 2
        DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$WORKDIR/argo.log" 2>/dev/null | sed 's#https://##' | tail -1)
        if [[ -n "$DOMAIN" ]]; then
            echo -e "${GREEN}✅ 临时域名: $DOMAIN${NC}"
            return 0
        fi
    done
    echo -e "${RED}⚠️  未能自动获取临时域名，请查看日志: $WORKDIR/argo.log${NC}"
    DOMAIN="<临时域名未获取>"
    return 1
}

# 主安装函数
install_argo() {
    install_deps
    detect_arch || return 1
    mkdir -p "$WORKDIR"

    echo -e "\n${CYAN}======= Argo 隧道配置 =======${NC}"
    echo -e "${YELLOW}固定域名：填写域名和 Token；直接回车则使用免费临时域名${NC}"
    echo -e "${YELLOW}（Token 可直接粘贴整条 cloudflared 安装命令，脚本会自动提取）${NC}\n"

    local INPUT_DOMAIN INPUT_TOKEN TOKEN_FROM_DOMAIN
    read -r -p "请输入域名 (留空=临时域名): " INPUT_DOMAIN
    read -r -p "请输入 Token (留空=临时隧道): " INPUT_TOKEN

    # 用户可能把命令/Token 贴到了域名栏
    TOKEN_FROM_DOMAIN=$(extract_token "$INPUT_DOMAIN")
    if [[ -n "$TOKEN_FROM_DOMAIN" ]]; then
        [[ -z "$(extract_token "$INPUT_TOKEN")" ]] && INPUT_TOKEN="$TOKEN_FROM_DOMAIN"
        INPUT_DOMAIN=""
    fi

    TUNNEL_TOKEN=$(extract_token "$INPUT_TOKEN")
    if [[ -n "$(trim "$INPUT_TOKEN")" && -z "$TUNNEL_TOKEN" ]]; then
        echo -e "${RED}❌ Token 格式不正确（应以 eyJ 开头）${NC}"; return 1
    fi

    if [[ -n "$TUNNEL_TOKEN" ]]; then
        TUNNEL_TYPE="fixed"
        # 固定隧道必须有一个合法域名，否则无法生成节点链接
        while true; do
            ARGO_DOMAIN=$(normalize_domain "$INPUT_DOMAIN")
            if valid_domain "$ARGO_DOMAIN"; then break; fi
            echo -e "${RED}❌ 域名格式不正确：「$INPUT_DOMAIN」，请输入类似 argo.example.com 的域名${NC}"
            read -r -p "请重新输入域名: " INPUT_DOMAIN
        done
    else
        TUNNEL_TYPE="temp"
        ARGO_DOMAIN=""
    fi

    local PORT_IN
    read -r -p "请输入本地监听端口 (留空则随机): " PORT_IN
    XRAY_PORT=$(trim "$PORT_IN")
    [[ -z "$XRAY_PORT" ]] && XRAY_PORT=$(( ( RANDOM % 40000 ) + 10000 ))
    if ! valid_port "$XRAY_PORT"; then
        echo -e "${RED}❌ 端口无效${NC}"; return 1
    fi

    # 停掉旧服务（避免 Text file busy、端口占用）
    svc stop cloudflared; svc stop xray

    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    [[ -z "$UUID" ]] && UUID=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')

    # Xray 配置：VLESS + WS（TLS 由 Cloudflare 边缘负责，本地无需证书），只监听本机
    cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

    install_xray        || return 1
    install_cloudflared || return 1
    register_services "$XRAY_PORT" "$TUNNEL_TYPE" "$TUNNEL_TOKEN"

    echo -e "${CYAN}🚀 启动服务...${NC}"
    : > "$WORKDIR/argo.log"
    svc start xray
    svc start cloudflared

    if [[ "$TUNNEL_TYPE" == "temp" ]]; then
        get_temp_domain
        ARGO_DOMAIN="$DOMAIN"
    fi

    # 所有值加引号写入，source 时不会再把空格当成命令
    cat > "$INFO_FILE" <<EOF
UUID="$UUID"
XRAY_PORT="$XRAY_PORT"
ARGO_DOMAIN="$ARGO_DOMAIN"
TUNNEL_TYPE="$TUNNEL_TYPE"
TUNNEL_TOKEN="$TUNNEL_TOKEN"
EOF
    chmod 600 "$INFO_FILE"

    echo -e "\n${GREEN}✅ Argo 隧道代理安装完成！${NC}"
    show_info
}

# 卸载
uninstall_argo() {
    echo -e "${YELLOW}正在卸载 Argo 代理...${NC}"
    svc stop xray; svc stop cloudflared
    if [ "$OS" = "alpine" ]; then
        rc-update del xray        >/dev/null 2>&1 || true
        rc-update del cloudflared >/dev/null 2>&1 || true
        rm -f /etc/init.d/xray /etc/init.d/cloudflared
    else
        systemctl disable xray cloudflared >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR"
    rm -f "$XRAY_BIN" "$ARGO_BIN"
    echo -e "${GREEN}✅ 卸载完成${NC}"
}

pause_return() {
    echo -e "\n${CYAN}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
}

# ========== 菜单 ==========
# 允许被 source 做单元测试：ARGO_TEST=1 时不进入菜单
[[ "$ARGO_TEST" == "1" ]] && return 0 2>/dev/null

while true; do
    clear
    echo -e "${GREEN}Argo 隧道管理脚本${NC}"
    echo "1. 安装 Argo"
    echo "2. 查看信息"
    echo "3. 修改端口"
    echo "4. 卸载"
    echo "5. 链路诊断"
    echo "0. 退出脚本"
    read -r -p "选择: " choice
    case $choice in
        1) install_argo   ; pause_return ;;
        2) show_info      ; pause_return ;;
        3) change_port    ; pause_return ;;
        4) uninstall_argo ; pause_return ;;
        5) diagnose       ; pause_return ;;
        0) echo -e "${GREEN}已退出脚本${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}"; pause_return ;;
    esac
done
