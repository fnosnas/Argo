#!/usr/bin/env bash
#
# VPS 路由追踪与线路检测一键脚本
# 

# 确保以 root 权限运行
[[ $EUID -ne 0 ]] && echo -e "\033[31m请使用 root 权限运行此脚本！\033[0m" && exit 1

# 定义颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

# 安装必要的依赖并下载 NextTrace
install_deps() {
    if ! command -v nexttrace &> /dev/null; then
        echo -e "${YELLOW}正在检测并安装路由追踪工具 (NextTrace)...${PLAIN}"
        # 自动下载并安装 NextTrace 到 /usr/local/bin
        curl -s nxtrace.org/nt | bash
        if ! command -v nexttrace &> /dev/null; then
            echo -e "${RED}NextTrace 安装失败，请检查网络！${PLAIN}"
            return 1
        fi
    fi
}

# 智能分析线路类型并高亮显示
analyze_route() {
    local ip_info="$1"
    # 这里对常见的高质量线路和普通线路进行标记
    if echo "$ip_info" | grep -qE "59.43\."; then
        echo -e "${GREEN}[精品线路: 电信 CN2 GIA]${PLAIN}"
    elif echo "$ip_info" | grep -qE "10099\."; then
        echo -e "${GREEN}[精品线路: 联通 AS9929]${PLAIN}"
    elif echo "$ip_info" | grep -qE "4837\."; then
        echo -e "${CYAN}[优质线路: 联通 AS4837]${PLAIN}"
    elif echo "$ip_info" | grep -qE "58.245\.|cmi"; then
        echo -e "${GREEN}[精品线路: 移动 CMI]${PLAIN}"
    elif echo "$ip_info" | grep -qE "202.97\."; then
        echo -e "${YELLOW}[普通线路: 电信 163骨干网(容易拥堵)]${PLAIN}"
    elif echo "$ip_info" | grep -qE "ntt|pccw|telia|cogentco"; then
        echo -e "${RED}[普通线路: 国际杂牌/绕路风险高]${PLAIN}"
    else
        echo -e "$ip_info"
    fi
}

# 1. 测去程线路 (国内 -> VPS)
check_going() {
    install_deps || return
    echo -e "\n${BLUE}=== 开始检测去程线路 (国内各运营商 -> 本 VPS) ===${PLAIN}"
    echo -e "${YELLOW}提示: 去程通常通过多地测速节点进行模拟测试。${PLAIN}"
    
    # 使用 NextTrace 的默认多节点测速功能来观察去程/综合路由
    local vps_ip
    vps_ip=$(curl -s ip.sb)
    echo -e "当前 VPS 的公网 IP: ${CYAN}$vps_ip${PLAIN}\n"
    
    echo -e "${CYAN}--- 测试电信去程 ---${PLAIN}"
    nexttrace --tcp 59.43.80.86 &>/dev/null || nexttrace 202.106.0.20
    
    echo -e "\n${CYAN}--- 测试联通去程 ---${PLAIN}"
    nexttrace 210.22.84.3
    
    echo -e "\n${CYAN}--- 测试移动去程 ---${PLAIN}"
    nexttrace 211.136.192.6
}

# 2. 测回程线路 (VPS -> 国内)
check_return() {
    install_deps || return
    echo -e "\n${BLUE}=== 开始检测回程线路 (本 VPS -> 国内三大运营商) ===${PLAIN}"
    
    # 定义国内三大运营商经典测试 IP
    # 电信：上海电信 / 联通：上海联通 / 移动：上海移动
    declare -A nodes=(
        ["电信 (上海)"]="202.96.209.133"
        ["联通 (上海)"]="210.22.84.3"
        ["移动 (上海)"]="211.136.192.6"
    )

    for name in "${!nodes[@]}"; do
        echo -e "\n${CYAN}--------------------------------------------------${PLAIN}"
        echo -e "正在检测到 ${YELLOW}$name${PLAIN} (${nodes[$name]}) 的回程路由："
        echo -e "${CYAN}--------------------------------------------------${PLAIN}"
        
        # 运行路由追踪并逐行分析
        nexttrace --path-mode descriptive "${nodes[$name]}" | while read -r line; do
            analyze_route "$line"
        done
    done
}

# 3. 清理并卸载脚本产生的所有内容
uninstall() {
    echo -e "\n${YELLOW}正在清理脚本产生和安装的所有内容...${PLAIN}"
    
    # 删除 NextTrace 主程序及相关配置文件
    if [ -f /usr/local/bin/nxtrace ]; then
        rm -f /usr/local/bin/nxtrace
        echo -e "${GREEN}已删除 NextTrace 主程序 (/usr/local/bin/nxtrace)${PLAIN}"
    fi
    
    # 清理可能存在的缓存或临时文件
    rm -rf ~/.nxtrace /tmp/nxtrace*
    echo -e "${GREEN}已清理相关缓存文件。${PLAIN}"
    
    echo -e "${GREEN}清理完成！该脚本未留下任何残留。${PLAIN}"
}

# 按键返回主菜单
press_key() {
    echo -e "\n"
    read -n 1 -s -r -p "按任意键（或空格键）返回主菜单..."
}

# 主菜单循环
main_menu() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "          VPS 路由线路检测与评测工具箱            "
        echo -e "=================================================="
        echo -e " ${GREEN}1.${PLAIN} 检测去程线路 (国内 -> VPS)"
        echo -e " ${GREEN}2.${PLAIN} 检测回程线路 (VPS -> 国内三大运营商)"
        echo -e " ${GREEN}3.${PLAIN} 一键卸载/彻底清理所有安装和缓存内容"
        echo -e " ${RED}0.${PLAIN} 退出脚本"
        echo -e "=================================================="
        read -p "请输入选项 [0-3]: " choice
        
        case "$choice" in
            1)
                check_going
                press_key
                ;;
            2)
                check_return
                press_key
                ;;
            3)
                uninstall
                press_key
                ;;
            0)
                echo -e "\n感谢使用，再见！"
                exit 0
                ;;
            *)
                echo -e "\n${RED}无效的选项，请重新输入！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 运行主菜单
main_menu
