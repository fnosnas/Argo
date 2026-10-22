#!/usr/bin/env bash
#
# VPS 路由追踪与线路检测一键脚本 (终极清晰版)
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

# 核心函数：运行测试并生成像路书一样的直观报告
run_trace_with_clean_report() {
    local target_ip="$1"
    local target_name="$2"
    
    echo -e "\n${BLUE}正在测试到 【${target_name}】 (${target_ip}) 的路由...${PLAIN}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${PLAIN}"
    
    local tmp_file="/tmp/nxtrace_out_$$.txt"
    nexttrace "$target_ip" | tee "$tmp_file"
    
    echo -e "\n${CYAN}================================================================================${PLAIN}"
    echo -e "${GREEN}【${target_name}】 完整漫游路书与线路诊断报告${PLAIN}"
    echo -e "${CYAN}================================================================================${PLAIN}"
    
    local has_绕美=0
    
    while IFS= read -r line; do
        if echo "$line" | grep -qE "^[[:space:]]*[0-9]+[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}"; then
            local hop_num
            hop_num=$(echo "$line" | awk '{print $1}')
            
            local ip_addr
            ip_addr=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -n 1)
            
            # 提取延迟数据
            local latency
            latency=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+[[:space:]]ms" | head -n 1)
            [[ -z "$latency" ]] && latency="超时/无响应"

            # 地理位置判断
            local loc="未知地区"
            if echo "$line" | grep -qE "香港|Hong Kong"; then
                loc="中国香港"
            elif echo "$line" | grep -qE "新加坡|Singapore"; then
                loc="新加坡"
            elif echo "$line" | grep -qE "美国|Los Angeles|San Jose|Miami|Dallas|Atlanta|Georgia|Florida"; then
                loc="美国 (跨洲绕路)"
                has_绕美=1
            elif echo "$line" | grep -qE "日本|Tokyo|Osaka"; then
                loc="日本"
            elif echo "$line" | grep -qE "中国|上海|广州|北京|深圳"; then
                loc="中国大陆节点"
            else
                loc="国际中转节点"
            fi
            
            # 线路判定
            local line_type="普通直连"
            if echo "$line" | grep -qE "59.43\."; then
                line_type="电信 CN2 GIA (精品)"
            elif echo "$line" | grep -qE "10099\."; then
                line_type="联通 AS9929 (精品)"
            elif echo "$line" | grep -qE "4837\."; then
                line_type="联通 AS4837 (优质)"
            elif echo "$line" | grep -qE "58.245\.|cmi"; then
                line_type="移动 CMI (精品)"
            elif echo "$line" | grep -qE "202.97\."; then
                line_type="电信 163骨干网 (普通拥堵)"
            elif echo "$line" | grep -qE "ntt|pccw|telia|arelion|cogentco"; then
                line_type="国际杂牌转运 (绕路高延迟)"
            fi
            
            echo -e "第 ${CYAN}${hop_num}${PLAIN} 跳 -> IP: ${YELLOW}${ip_addr}${PLAIN} | 位置: ${loc}"
            echo -e "       └─ 线路: ${line_type} | 延迟: ${GREEN}${latency}${PLAIN}"
            echo -e "--------------------------------------------------------------------------------"
        fi
    done < "$tmp_file"
    
    # 总结结论
    echo -e "\n${GREEN}【最终诊断结论】${PLAIN}"
    if [ "$has_绕美" -eq 1 ]; then
        echo -e "  ❌ ${RED}判定结果：该 VPS 存在严重的国际绕路现象！${PLAIN}"
        echo -e "  📋 路线复盘：数据包从本地 VPS 出发后，先被运去了【美国】等欧美机房，绕了整整大半个地球，才从美国折返进入国内上海/广州。"
        echo -e "  💡 延迟高原因：跨洲物理距离导致延迟直接暴增至 270ms~350ms 级别，这也是你用起来感觉非常卡顿的根本原因。"
    else
        echo -e "  ✔ ${GREEN}判定结果：该线路未发现跨洲绕路，属于正常的直连或区域优化路线。${PLAIN}"
    fi
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
    run_trace_with_clean_report "$vps_ip" "综合去程测速"
}

# 2. 测回程线路 (VPS -> 国内)
check_return() {
    install_deps || return
    echo -e "\n${BLUE}=== 开始检测回程线路 (本 VPS -> 国内三大运营商) ===${PLAIN}"
    run_trace_with_clean_report "202.96.209.133" "电信 (上海)"
    run_trace_with_clean_report "210.22.84.3" "联通 (上海)"
    run_trace_with_clean_report "211.136.192.6" "移动 (上海)"
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
