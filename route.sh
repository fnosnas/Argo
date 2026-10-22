#!/usr/bin/env bash
# ============================================================
#  VPS 去程 / 回程 线路检测脚本（中文）
#  用法: bash <(curl -sL https://raw.githubusercontent.com/你的用户名/你的仓库/main/route.sh)
#  说明: 所有下载内容只放在 /tmp/.routecheck，菜单 3 可一键清理
# ============================================================

export LC_ALL=C.UTF-8 2>/dev/null
[[ -n "$ROUTE_TEST" || -t 0 ]] || exec < /dev/tty

WORK="/tmp/.routecheck"
NT="$WORK/nexttrace"
JQ="jq"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'

# ---------------- 通用小工具 ----------------

# 按显示宽度补空格（中文占2格）
pad() {
  local s="$1" w="$2" chars bytes cur i
  chars=${#s}
  bytes=$(printf '%s' "$s" | LC_ALL=C wc -c)
  cur=$(( chars + (bytes - chars) / 2 ))
  printf '%s' "$s"
  for ((i = cur; i < w; i++)); do printf ' '; done
}

pause() {
  echo
  local k
  printf '%s' "${Y}按任意键返回主菜单...${N}"
  IFS= read -rsn1 k
  read -rsn8 -t 0.1 _ 2>/dev/null   # 吃掉方向键等多字节按键的残留
}

# 带重试的下载: 地址 保存路径
dl() {
  local url="$1" out="$2" i
  for i in 1 2 3 4; do
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$out" "$url" && return 0
    sleep 2
  done
  rm -f "$out"
  return 1
}

ARCH=""
ensure_env() {
  mkdir -p "$WORK"
  if ! command -v curl >/dev/null 2>&1; then
    echo "${R}缺少 curl，请先安装: apt install -y curl  或  yum install -y curl${N}"
    return 1
  fi
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7*|armv6*) ARCH=armv7 ;;
    i?86) ARCH=386 ;;
    *) echo "${R}不支持的CPU架构: $(uname -m)${N}"; return 1 ;;
  esac

  if [[ ! -x "$NT" ]]; then
    echo "正在下载 NextTrace 到 $WORK ..."
    if ! dl "https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_$ARCH" "$NT"; then
      echo "${R}NextTrace 下载失败(多次重试)，可能是这台机器访问 github.com 不稳定，稍后再试${N}"
      return 1
    fi
    chmod +x "$NT"
  fi
  return 0
}

# 只有去程(选项1)才需要 jq
ensure_jq() {
  if command -v jq >/dev/null 2>&1; then JQ="jq"; return 0; fi
  JQ="$WORK/jq"
  [[ -x "$JQ" ]] && return 0
  local ja="$ARCH"
  [[ "$ARCH" == "386" ]] && ja="i386"
  [[ "$ARCH" == "armv7" ]] && ja="armhf"
  echo "正在下载 jq 到 $WORK ..."
  if ! dl "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$ja" "$JQ"; then
    echo "${R}jq 下载失败(多次重试)，去程检测暂时无法使用；回程检测不受影响${N}"
    return 1
  fi
  chmod +x "$JQ"
  return 0
}

get_local() {
  local j f
  j=$(curl -s --max-time 8 "http://ip-api.com/json/?lang=zh-CN&fields=query,country,regionName,city,isp")
  f() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' <<<"$j"; }
  MYIP=$(f query)
  MYLOC="$(f country) $(f regionName) $(f city)"
  MYISP=$(f isp)
  [[ -z "$MYIP" ]] && MYIP="未知"
  MYLOC=$(echo $MYLOC)
  [[ -z "$MYLOC" ]] && MYLOC="未知位置"

  # IPv6 出口(如果有)。IPv4和IPv6的出口位置可能完全不同
  MYIP6=$(curl -s6 --max-time 6 https://api6.ipify.org 2>/dev/null)
  MYLOC6=""; MYISP6=""
  if [[ "$MYIP6" == *:* ]]; then
    j=$(curl -s --max-time 8 "http://ip-api.com/json/$MYIP6?lang=zh-CN&fields=country,regionName,city,isp")
    MYLOC6=$(echo "$(f country) $(f regionName) $(f city)")
    MYISP6=$(f isp)
  else
    MYIP6=""
  fi
}

# 起点描述: 目标是IPv6就用VPS的IPv6出口信息
start_desc() {
  if [[ "$1" == *:* && -n "$MYIP6" ]]; then echo "VPS ${MYLOC6:-位置未知} ($MYIP6)"
  else echo "VPS $MYLOC ($MYIP)"; fi
}

# ---------------- 线路识别 ----------------

tag_asn() {
  case "$1" in
    4809)  echo "CN2" ;;
    4134)  echo "电信163" ;;
    23764) echo "电信CTG" ;;
    9929)  echo "联通9929" ;;
    10099) echo "联通10099" ;;
    4837)  echo "联通169" ;;
    58807) echo "移动CMIN2" ;;
    58453) echo "移动CMI" ;;
    9808)  echo "移动骨干" ;;
    4538)  echo "教育网" ;;
    4812)  echo "电信上海" ;;
    17621) echo "联通上海" ;;
    4808)  echo "联通北京" ;;
    56040) echo "移动广东" ;;
    13335) echo "Cloudflare" ;;
    1299)  echo "Arelion" ;;
    3356)  echo "Lumen" ;;
    174)   echo "Cogent" ;;
    2914)  echo "NTT" ;;
    3257)  echo "GTT" ;;
    6453)  echo "TATA" ;;
    5511)  echo "Orange" ;;
    *)     echo "" ;;
  esac
}

# 当地理库没给出ASN时，用IP段兜底
ip2asn() {
  case "$1" in
    59.43.*) echo 4809 ;;
    202.97.*) echo 4134 ;;
    218.105.*|210.51.*) echo 9929 ;;
    219.158.*) echo 4837 ;;
    *) echo "" ;;
  esac
}

has_asn() { [[ " $P_ASNS " == *" $1 "* ]]; }

# 根据整条路径的ASN判断线路，结果放 LINE / GRADE
classify() {
  local isp="$1"
  LINE="未识别"; GRADE="未知"
  if [[ "$isp" == "联通" || "$isp" == "任意" ]]; then
    if has_asn 9929; then LINE="联通 9929(A网)"; GRADE="精品"; return; fi
    if has_asn 10099; then LINE="联通 10099(国际)"; GRADE="精品"; return; fi
  fi
  if [[ "$isp" == "移动" || "$isp" == "任意" ]]; then
    if has_asn 58807; then LINE="移动 CMIN2"; GRADE="精品"; return; fi
  fi
  if [[ "$isp" == "电信" || "$isp" == "任意" ]]; then
    if has_asn 4809; then
      if [[ "$P_GT" == "1" ]]; then LINE="电信 CN2 GT"; GRADE="普通"
      else LINE="电信 CN2 GIA"; GRADE="精品"; fi
      return
    fi
    if has_asn 23764; then LINE="电信 CTGNet"; GRADE="普通"; return; fi
    if has_asn 4134 || has_asn 4812; then LINE="电信 163骨干"; GRADE="普通"; return; fi
  fi
  if [[ "$isp" == "联通" || "$isp" == "任意" ]]; then
    if has_asn 4837 || has_asn 17621 || has_asn 4808; then LINE="联通 169骨干/省网"; GRADE="普通"; return; fi
  fi
  if [[ "$isp" == "移动" || "$isp" == "任意" ]]; then
    if has_asn 58453; then LINE="移动 CMI"; GRADE="普通"; return; fi
    if has_asn 9808 || has_asn 56040; then LINE="移动 CMNET骨干"; GRADE="普通"; return; fi
  fi
}

# ---------------- 逐跳分析 ----------------
is_private() {
  case "$1" in
    fc*|fd*|fe80*|::1) return 0 ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}

# 把 NextTrace 文本输出转成 tsv: ttl|ip|asn|国家|省|城市|owner|rtt
parse_text() {
  tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | LC_ALL=C awk '
  function flush() {
    if (ttl != "") printf "%s|%s|%s|%s|%s|%s||%s\n", ttl, ip, asn, c1, c2, c3, rtt
  }
  /^[0-9]+[ \t]+/ {
    flush()
    ttl = $1; ip = $2; asn = ""; c1 = ""; c2 = ""; c3 = ""; rtt = "0"; n = 0
    for (i = 3; i <= NF; i++) {
      t = $i
      if (t ~ /^AS[0-9]+$/) { asn = substr(t, 3); continue }
      if (t ~ /^\[.*\]$/ || t == "*" || t == "RFC1918") continue
      if (t !~ /[ -~]/) {
        n++
        if (n == 1) c1 = t; else if (n == 2) c2 = t; else if (n == 3) c3 = t
      } else if (n > 0) break
    }
    next
  }
  ttl != "" && rtt == "0" && match($0, /[0-9]+\.[0-9]+ ms/) { rtt = substr($0, RSTART, RLENGTH - 3) }
  END { flush() }'
}

analyze() {
  local f="$1" show="$2"
  P_ASNS=""; P_COUNTRIES=""; P_PATH=""; P_RTT="-"; P_GT=0
  P_ENTRY="未进入中国网络"; P_LASTIP=""; P_LASTPLACE=""
  local lastc="" lastasn="" lastseg="" idx=0 first202=0 first5943=0 entry_set=0
  local ttl ip asn country prov city owner rtt tag seg place mark

  while IFS='|' read -r ttl ip asn country prov city owner rtt; do
    idx=$((idx + 1))
    if [[ -z "$ip" || "$ip" == "*" ]]; then
      [[ "$show" == "1" ]] && printf ' %2s  %s\n' "$ttl" "${Y}*  请求超时(该路由器不回应)${N}"
      continue
    fi
    P_LASTIP="$ip"
    if is_private "$ip"; then
      [[ "$show" == "1" ]] && printf ' %2s  %-16s %s  %s ms\n' "$ttl" "$ip" "内网/私有地址" "$rtt"
      continue
    fi
    [[ "$asn" == "null" ]] && asn=""
    [[ -z "$asn" ]] && asn=$(ip2asn "$ip")
    tag=$(tag_asn "$asn")

    [[ "$ip" == 202.97.* && $first202 -eq 0 ]] && first202=$idx
    [[ "$ip" == 59.43.*  && $first5943 -eq 0 ]] && first5943=$idx

    if [[ -n "$asn" && "$asn" != "$lastasn" ]]; then
      P_ASNS="$P_ASNS $asn"; lastasn="$asn"
    fi
    if [[ -n "$country" && "$country" != "$lastc" ]]; then
      P_COUNTRIES="${P_COUNTRIES:+$P_COUNTRIES → }$country"; lastc="$country"
    fi

    place="$country${prov:+ $prov}${city:+ $city}"
    [[ -z "$place" ]] && place="位置未知"
    seg="$place"
    if [[ -n "$tag" ]]; then seg="$seg[$tag]"
    elif [[ -n "$asn" ]]; then seg="$seg[AS$asn]"; fi
    if [[ "$seg" != "$lastseg" ]]; then
      P_PATH="${P_PATH:+$P_PATH → }$seg"; lastseg="$seg"
    fi

    [[ "$rtt" != "0" && -n "$rtt" ]] && P_RTT="$rtt"
    P_LASTPLACE="$place${tag:+[$tag]}"

    if [[ "$country" == "中国" && $entry_set -eq 0 ]]; then
      P_ENTRY="第${ttl}跳 $ip $place${tag:+[$tag]}，延迟 ${rtt}ms"
      entry_set=1
    fi

    if [[ "$show" == "1" ]]; then
      mark=""; [[ -n "$tag" ]] && mark="${G}[$tag]${N}"
      printf ' %2s  %-16s %s%s  %s  %s ms\n' "$ttl" "$ip" "${asn:+AS$asn }" "$mark" "$place" "$rtt"
    fi
  done < "$f"

  if [[ $first202 -gt 0 && $first5943 -gt 0 && $first202 -lt $first5943 ]]; then P_GT=1; fi
}

rate() {
  awk -v r="$1" 'BEGIN{
    if (r == "-" || r == "") print "-";
    else if (r < 100) print "优秀";
    else if (r < 180) print "良好";
    else if (r < 250) print "一般";
    else print "偏高(疑似绕路)";
  }'
}

# ---------------- 汇总 ----------------
reset_summary() {
  S_NAME=(); S_LINE=(); S_GRADE=(); S_RTT=(); S_COUNTRY=(); S_PATH=(); S_START=(); S_ENTRY=(); S_REACH=()
}

add_summary() { # 名称 isp 起点 是否到达(1/0)
  classify "$2"
  S_NAME+=("$1"); S_LINE+=("$LINE"); S_GRADE+=("$GRADE")
  S_RTT+=("$P_RTT"); S_COUNTRY+=("$P_COUNTRIES"); S_PATH+=("$P_PATH"); S_START+=("$3")
  S_ENTRY+=("$P_ENTRY")
  if [[ "$4" == "1" ]]; then S_REACH+=("已到达目标")
  else S_REACH+=("未收到目标本机回应(家宽/防火墙常见)，最后可见节点: ${P_LASTPLACE:-未知}，延迟 ${P_RTT}ms"); fi
}

add_fail() {
  S_NAME+=("$1"); S_LINE+=("检测失败"); S_GRADE+=("-")
  S_RTT+=("-"); S_COUNTRY+=("-"); S_PATH+=("-"); S_START+=("$2"); S_ENTRY+=("-"); S_REACH+=("-")
}

print_summary() { # 标题
  echo
  echo "${B}══════════════════════ $1 ══════════════════════${N}"
  printf '%s %s %s %s %s %s\n' "$(pad 目的地 14)" "$(pad 线路类型 22)" "$(pad 等级 6)" "$(pad 延迟 9)" "$(pad 评价 18)" "途经国家"
  echo "------------------------------------------------------------------------------------------"
  local i col rtt
  for i in "${!S_NAME[@]}"; do
    case "${S_GRADE[$i]}" in
      精品) col="$G" ;;
      普通) col="$Y" ;;
      *) col="$R" ;;
    esac
    rtt="${S_RTT[$i]}"; [[ "$rtt" != "-" ]] && rtt="${rtt}ms"
    printf '%s %s %s %s %s %s\n' "$(pad "${S_NAME[$i]}" 14)" "$(pad "${S_LINE[$i]}" 22)" \
      "${col}$(pad "${S_GRADE[$i]}" 6)${N}" "$(pad "$rtt" 9)" "$(pad "$(rate "${S_RTT[$i]}")" 18)" "${S_COUNTRY[$i]}"
  done
  echo
  echo "${B}—— 各线路完整经过的地方 ——${N}"
  for i in "${!S_NAME[@]}"; do
    echo
    echo "【${S_NAME[$i]}】 ${S_LINE[$i]} (${S_GRADE[$i]})   延迟: ${S_RTT[$i]}ms"
    echo "  起点: ${S_START[$i]}"
    echo "  入境点: ${S_ENTRY[$i]}"
    echo "  路径: ${S_PATH[$i]}"
    echo "  终点: ${S_REACH[$i]}"
  done
  echo
  echo "说明:"
  echo " 1) 精品=CN2 GIA / 联通9929、10099 / 移动CMIN2；其余(含CN2 GT)按普通处理。"
  echo " 2) 评价只按延迟估计(<100优秀 <180良好 <250一般 其余偏高)，请结合VPS所在地判断是否绕路。"
  echo " 3) 国家/城市来自IP库，骨干网设备的位置偶尔不准，以延迟和ASN为主。"
  if [[ "$MYISP" == *Cloudflare* ]]; then
    echo " 4) 这台机器IPv4出口属于Cloudflare，测到的是Cloudflare出口线路。"
  fi
}

# ---------------- 2. 回程 ----------------
trace_one() { # 名称 isp 目标
  local name="$1" isp="$2" target="$3" reached=0
  echo
  echo "${B}━━━ 回程: $name ($target) ━━━${N}"
  if [[ "$target" == *:* && -z "$MYIP6" ]]; then
    echo "${R}这台VPS没有可用的IPv6，无法测到IPv6目标。${N}"
    echo "请改输入你的IPv4地址，或直接回车测三网九节点。"
    add_fail "$name" "$(start_desc "$target")"
    return
  fi
  "$NT" -q 1 -m 30 -g cn "$target" > "$WORK/raw.txt" 2>&1
  parse_text < "$WORK/raw.txt" > "$WORK/t.tsv"

  if [[ ! -s "$WORK/t.tsv" ]]; then
    echo "${R}追踪失败，NextTrace 返回的信息如下:${N}"
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$WORK/raw.txt" | head -n 8
    add_fail "$name" "$(start_desc "$target")"
    return
  fi
  analyze "$WORK/t.tsv" 1
  [[ "$P_LASTIP" == "$target" ]] && reached=1
  add_summary "$name" "$isp" "$(start_desc "$target") → 目标 $target" "$reached"
}

do_back() {
  ensure_env || return
  get_local
  clear
  echo "${B}回程检测: VPS → 中国${N}"
  echo "VPS IPv4: $MYIP  $MYLOC  $MYISP"
  [[ -n "$MYIP6" ]] && echo "VPS IPv6: $MYIP6  $MYLOC6  $MYISP6"
  if [[ "$MYISP" == *Cloudflare* ]]; then
    echo "${Y}注意: IPv4出口属于Cloudflare(可能是WARP/隧道)，IPv4测到的是Cloudflare出口线路，位置也可能不是机器真实位置。${N}"
  fi
  [[ $EUID -ne 0 ]] && echo "${Y}提示: 非root运行可能无法发送ICMP，建议使用root${N}"
  echo
  read -rp "直接回车=测三网九节点；或输入你自己的IP/域名(测到你家): " custom
  reset_summary
  if [[ -n "$custom" ]]; then
    trace_one "自定义目标" 任意 "$custom"
    print_summary "回程线路统计 (VPS → 你)"
    return
  fi
  echo "共9个节点，预计2~5分钟，请耐心等待..."
  local list=(
    "北京电信|电信|219.141.140.10"
    "上海电信|电信|202.96.209.133"
    "广州电信|电信|58.60.188.222"
    "北京联通|联通|202.106.195.68"
    "上海联通|联通|210.22.97.1"
    "广州联通|联通|210.21.196.6"
    "北京移动|移动|221.179.155.161"
    "上海移动|移动|211.136.112.200"
    "广州移动|移动|120.196.165.24"
  )
  local item n i t
  for item in "${list[@]}"; do
    IFS='|' read -r n i t <<<"$item"
    trace_one "$n" "$i" "$t"
  done
  print_summary "回程线路统计 (VPS → 中国三网)"
}

# ---------------- 1. 去程 ----------------
# 去程(国内→VPS)必须从国内发起，这里借助 Globalping 公共探针
do_forward() {
  ensure_env || return
  ensure_jq || return
  get_local
  clear
  echo "${B}去程检测: 中国 → 本VPS${N}   本机: $MYLOC  $MYIP"
  echo "说明: 去程需要从国内发起，本功能调用 Globalping 公共探针(免费、无需注册)。"
  echo "      国内探针数量有限，可能测不到某些运营商。"
  reset_summary

  local labels=("电信|china telecom" "联通|china unicom" "移动|china mobile")
  local item isp magic body resp id t ok
  for item in "${labels[@]}"; do
    IFS='|' read -r isp magic <<<"$item"
    echo
    echo "${B}━━━ 去程: 中国${isp} → 本VPS ━━━${N}"
    body="{\"type\":\"traceroute\",\"target\":\"$MYIP\",\"locations\":[{\"magic\":\"$magic\",\"limit\":1}]}"
    resp=$(curl -s --max-time 20 -X POST "https://api.globalping.io/v1/measurements" \
      -H 'Content-Type: application/json' -d "$body")
    id=$($JQ -r '.id // empty' <<<"$resp" 2>/dev/null)
    if [[ -z "$id" ]]; then
      echo "${R}没有可用的国内${isp}探针，跳过${N}"
      add_fail "中国${isp}" "国内${isp}探针(无)"
      continue
    fi
    ok=0
    for t in $(seq 1 40); do
      curl -s --max-time 15 "https://api.globalping.io/v1/measurements/$id" > "$WORK/gp.json"
      if [[ "$($JQ -r '.status // ""' "$WORK/gp.json" 2>/dev/null)" == "finished" ]]; then ok=1; break; fi
      sleep 2
    done
    if [[ $ok -ne 1 ]]; then
      echo "${R}等待结果超时${N}"; add_fail "中国${isp}" "国内${isp}探针"; continue
    fi

    local pinfo
    pinfo=$($JQ -r '.results[0].probe | "\(.country // "") \(.city // "") \(.network // "")"' "$WORK/gp.json" 2>/dev/null)
    $JQ -r '.results[0].result.hops // [] | to_entries[]
      | "\(.key + 1)|\(.value.resolvedAddress // "*")|\((.value.timings // [])[0].rtt // 0)"' \
      "$WORK/gp.json" > "$WORK/f_raw.txt" 2>/dev/null
    if [[ ! -s "$WORK/f_raw.txt" ]]; then
      echo "${R}探针没有返回路径${N}"; add_fail "中国${isp}" "$pinfo"; continue
    fi

    # 批量查询归属地
    local ips json geo
    ips=$(cut -d'|' -f2 "$WORK/f_raw.txt" | grep -v '^\*$' | sort -u)
    json=$(printf '%s\n' $ips | $JQ -R '{query: .}' | $JQ -s .)
    geo=$(curl -s --max-time 15 -X POST \
      "http://ip-api.com/batch?lang=zh-CN&fields=status,country,regionName,city,isp,as,query" -d "$json")
    declare -A GA GC GR GCI GO
    GA=(); GC=(); GR=(); GCI=(); GO=()
    local q a c r ci o
    while IFS='|' read -r q a c r ci o; do
      GA[$q]="$a"; GC[$q]="$c"; GR[$q]="$r"; GCI[$q]="$ci"; GO[$q]="$o"
    done < <($JQ -r '.[]? | select(.status == "success")
      | [.query, ((.as // "") | split(" ") | .[0] | ltrimstr("AS")), .country, .regionName, .city, .isp] | join("|")' <<<"$geo" 2>/dev/null)

    local ttl ip rtt
    : > "$WORK/t.tsv"
    while IFS='|' read -r ttl ip rtt; do
      rtt=$(awk -v x="$rtt" 'BEGIN{printf "%.2f", x}')
      echo "$ttl|$ip|${GA[$ip]}|${GC[$ip]}|${GR[$ip]}|${GCI[$ip]}|${GO[$ip]}|$rtt" >> "$WORK/t.tsv"
    done < "$WORK/f_raw.txt"

    echo "探针位置: $pinfo"
    analyze "$WORK/t.tsv" 1
    local reached=0
    [[ "$P_LASTIP" == "$MYIP" ]] && reached=1
    add_summary "中国${isp}→VPS" "$isp" "国内${isp}探针 $pinfo" "$reached"
  done
  print_summary "去程线路统计 (中国 → 本VPS)"
  echo "如需更准确的去程，可在你本地电脑安装 NextTrace 后执行: nexttrace $MYIP"
}

# ---------------- 3. 清理 ----------------
do_uninstall() {
  clear
  echo "${B}清理脚本产生的所有内容...${N}"
  local before
  before=$(du -sh "$WORK" 2>/dev/null | cut -f1)
  rm -rf "$WORK" "$HOME/.nexttrace" 2>/dev/null
  echo "已删除: $WORK (${before:-0})"
  echo "已删除: $HOME/.nexttrace (如果存在)"
  if [[ -f "$0" && "$0" != /dev/* && "$0" != /proc/* ]]; then
    rm -f "$0" && echo "已删除脚本文件: $0"
  fi
  echo "${G}清理完成。本脚本没有往系统安装任何软件包，无其他残留。${N}"
  echo "(如果之后再选择1或2，会重新下载所需工具)"
}

# ---------------- 主菜单 ----------------
main() {
while true; do
  clear
  echo "${B}╔══════════════════════════════════════╗${N}"
  echo "${B}║      VPS 线路检测脚本 (中文版)       ║${N}"
  echo "${B}╚══════════════════════════════════════╝${N}"
  echo "  1. 检测去程线路 (中国 → 本VPS)"
  echo "  2. 检测回程线路 (本VPS → 中国)"
  echo "  3. 删除本脚本产生的所有内容"
  echo "  0. 退出脚本"
  echo
  read -rp "请输入选项 [0-3]: " choice
  case "$choice" in
    1) do_forward; pause ;;
    2) do_back; pause ;;
    3) do_uninstall; pause ;;
    0) echo "已退出。"; exit 0 ;;
    *) echo "无效选项"; sleep 1 ;;
  esac
done
}

[[ -z "$ROUTE_TEST" ]] && main
