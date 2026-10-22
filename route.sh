#!/usr/bin/env bash
#
# VPS 路由追踪与线路检测一键脚本 (稳定修复版)
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
        curl -s nxtrace.org/nt | bash
        if ! command -v nexttrace &> /dev/null; then
            echo -e "${RED}NextTrace 安装失败，请检查网络！${PLAIN}"
            return 1
        fi
    fi
}

# 智能分析线路类型
analyze_route_type() {
    local text="$1"
    if echo "$text" | grep -qE "59.43\."; then
        echo "电信 CN2 GIA (精品)"
    elif echo "$text" | grep -qE "10099\."; then
        echo "联通 AS9929 (精品)"
    elif echo "$text" | grep -qE "4837\."; then
        echo "联通 AS4837 (优质)"
    elif echo "$text" | grep -qE "58.245\.|cmi"; then
        echo "移动 CMI (精品)"
    elif echo "$text" | grep -qE "202.97\."; then
        echo "电信 163 (普通)"
    elif echo "$text" | grep -qE "ntt|pccw|telia|cogentco"; then
        echo "国际杂牌/绕路"
    else
        echo "直连/普通"
    fi
}

# 核心函数：运行测试并生成精简中文表格
run_trace_with_summary() {
    local target_ip="$1"
    local target_name="$2"
    
    echo -e "\n${BLUE}正在测试到 【${target_name}】 (${target_ip}) 的路由...${PLAIN}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${PLAIN}"
    
    local tmp_file="/tmp/nxtrace_out_$$.txt"
    
    # 纯净运行 NextTrace，不加多余参数，确保 100% 成功
    nexttrace "$target_ip" | tee "$tmp_file"
    
    echo -e "\n${CYAN}================================================================================${PLAIN}"
    echo -e "${GREEN}【${target_name}】 路由简化总结报告：${PLAIN}"
    echo -e "${CYAN}================================================================================${PLAIN}"
    printf "%-6s | %-25s | %-20s | %-22s\n" "跳数" "节点位置/国家" "IP地址" "线路评估"
    echo -e "--------------------------------------------------------------------------------"

    # 逐行读取并清洗打印
    while IFS=read -r line; do
        # 筛选包含IP地址的有效路由行
        if echo "$line" | grep -qE "([0-9]{1,3}\.){3}[0-9]{1,3}"; then
            # 提取跳数 (行首数字)
            local hop_num
            hop_num=$(echo "$line" | awk '{print $1}' | tr -cd '0-9')
            [[ -z "$hop_num" ]] && hop_num="-"

            # 提取IP地址
            local ip_addr
            ip_addr=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -n 1)

            # 评估线路
            local route_type
            route_type=$(analyze_route_type "$line")

            # 提取地理位置粗略判断
            local loc="未知地区"
            if echo "$line" | grep -qE "Hong Kong|香港"; then
                loc="中国香港"
            elif echo "$line" | grep -qE "Singapore|新加坡"; then
                loc="新加坡"
            elif echo "$line" | grep -qE "United States|美国|Los Angeles|San Jose"; then
                loc="美国 (绕路)"
            elif echo "$line" | grep -qE "Japan|日本|Tokyo|Osaka"; then
                loc="日本"
            elif echo "$line" | grep -qE "China|中国|Shanghai|Guangzhou|Beijing|Shenzhen"; then
                loc="中国大陆节点"
            else
                loc="国际中转节点"
            fi

            if [[ -n "$ip_addr" ]]; then
                printf "%-6s | %-25s | %-20s | %-22s\n" "$hop_num" "$loc" "$ip_addr" "$route_type"
            fi
        fi
    done < "$tmp_file"
    
    echo -e "${CYAN}================================================================================${PLAIN}"
    rm -f "$tmp_file"
}

# 1. 测去程线路 (国内 -> VPS)
check_going() {
    install_deps || return
    echo -e "\n${BLUE}=== 开始检测去程线路 (国内各运营商 -> 本 VPS) ===${PLAIN}"
    local vps_ip
    vps_ip=$(curl -s ip.sb)
    echo -e "当前 VPS 的公网 IP: ${CYAN}$vps_ip${PLAIN}"
    
    run_trace_with_summary "$vps_ip" "综合去程测速"
}

# 2. 测回程线路 (VPS -> 国内)
check_return() {
    install_deps || return
    echo -e "\n${BLUE}=== 开始检测回程线路 (本 VPS -> 国内三大运营商) ===${PLAIN}"
    
    # 三大运营商代表性测试 IP
    run_trace_with_summary "202.96.209.133" "电信 (上海)"
    run_trace_with_summary "210.22.84.3" "联通 (上海)"
    run_trace_with_summary "211.136.192.6" "移动 (上海)"
}

# 3. 清理并卸载脚本产生的所有内容
uninstall() {
    echo -e "\n${YELLOW}正在清理脚本产生和安装的所有内容...${PLAIN}"
    if [ -f /usr/local/bin/nxtrace ]; then
        rm -f /usr/local/bin/nxtrace
        echo -e "${GREEN}已删除 NextTrace 主程序 (/usr/local/bin/nxtrace)${PLAIN}"
    fi
    rm -rf ~/.nxtrace /tmp/nxtrace*
    echo -e "${GREEN}已清理相关缓存文件。清理完成！${PLAIN}"
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
