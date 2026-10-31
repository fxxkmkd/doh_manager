#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] 必须使用 root 权限运行此脚本。"
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ================= 1. 严格架构与系统检测 =================
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
if [ "$OS_TYPE" != "linux" ]; then
  echo -e "${RED}[-] 本脚本仅支持 Linux 系统，当前为: $OS_TYPE${PLAIN}"
  exit 1
fi

RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
  x86_64|amd64)
    SYS_ARCH="amd64"
    ARCH_MATCH_REGEX="(amd64|x86_64)"
    ;;
  aarch64|arm64)
    SYS_ARCH="arm64"
    ARCH_MATCH_REGEX="(arm64|aarch64)"
    ;;
  armv7*|armhf)
    SYS_ARCH="armv7"
    ARCH_MATCH_REGEX="(armv7|armhf)"
    ;;
  i386|i686)
    SYS_ARCH="386"
    ARCH_MATCH_REGEX="(386|x86)"
    ;;
  *)
    echo -e "${RED}[-] 无法识别的系统架构: $RAW_ARCH${PLAIN}"
    exit 1
    ;;
esac

echo -e "${GREEN}[+] 系统识别完成 -> OS: Linux | CPU 架构: ${RAW_ARCH} (匹配标签: ${SYS_ARCH})${PLAIN}"

install_deps() {
  echo -e "${YELLOW}[*] 安装基础工具 (curl, tar, lsof, file, dnsutils)...${PLAIN}"
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq curl tar bzip2 xz-utils lsof file dnsutils &>/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y curl tar bzip2 xz lsof file bind-utils &>/dev/null
  fi
}

get_github_asset_url() {
  local repo="$1"
  local bin_name="$2"

  local latest_loc
  latest_loc=$(curl -sSI -m 6 "https://github.com/${repo}/releases/latest" 2>/dev/null | grep -i "^location:" | awk '{print $2}' | tr -d '\r\n')
  
  if [ -z "$latest_loc" ]; then
    echo ""
    return 1
  fi

  local tag="${latest_loc##*/}"
  local assets_page="https://github.com/${repo}/releases/expanded_assets/${tag}"

  local matched_path
  matched_path=$(curl -sSL -m 8 "$assets_page" 2>/dev/null \
    | grep -oE "/${repo}/releases/download/[^\"]+" \
    | grep -Ei "linux" \
    | grep -Ei "$ARCH_MATCH_REGEX" \
    | grep -Eiv "(darwin|windows|freebsd|openbsd|\.sha|\.sig|\.asc|\.deb|\.rpm|\.apk|\.txt)" \
    | head -n 1)

  if [ -n "$matched_path" ]; then
    echo "https://github.com${matched_path}"
  else
    echo ""
    return 1
  fi
}

universal_download_and_install() {
  local download_url="$1"
  local target_bin_name="$2"
  local test_args="$3"
  local tmp_file="/tmp/doh_pkg_temp"
  local extract_dir="/tmp/doh_ext_temp"

  rm -rf "$tmp_file" "$extract_dir"
  mkdir -p "$extract_dir"

  echo -e "${YELLOW}[*] 正在下载针对 [Linux-${SYS_ARCH}] 的专属发布包:${PLAIN}"
  echo -e "    ${download_url}"

  if ! curl -fL --retry 3 --connect-timeout 8 -m 120 -o "$tmp_file" "$download_url"; then
    echo -e "${RED}[-] 下载失败，请检查网络。${PLAIN}"
    return 1
  fi

  local file_type
  file_type=$(file "$tmp_file" 2>/dev/null || true)

  if echo "$file_type" | grep -Ei -q "(gzip|bzip2|xz|tar|archive)"; then
    tar -xf "$tmp_file" -C "$extract_dir" >/dev/null
    local found_bin
    found_bin=$(find "$extract_dir" -type f -name "$target_bin_name" | head -n 1)
    if [ -z "$found_bin" ]; then
      found_bin=$(find "$extract_dir" -type f -executable | head -n 1)
    fi
    mv "$found_bin" "/usr/local/bin/${target_bin_name}"
  elif echo "$file_type" | grep -qi "executable"; then
    mv "$tmp_file" "/usr/local/bin/${target_bin_name}"
  else
    echo -e "${RED}[-] 下载的内容不是有效的可执行文件格式: ${file_type}${PLAIN}"
    rm -rf "$tmp_file" "$extract_dir"
    return 1
  fi

  chmod +x "/usr/local/bin/${target_bin_name}"
  rm -rf "$tmp_file" "$extract_dir"

  echo -e "${YELLOW}[*] 校验二进制与当前 CPU 架构兼容性...${PLAIN}"
  if ! "/usr/local/bin/${target_bin_name}" ${test_args} &>/dev/null; then
    echo -e "${RED}[FATAL] 二进制文件无法正常执行，属性如下：${PLAIN}"
    file "/usr/local/bin/${target_bin_name}"
    rm -f "/usr/local/bin/${target_bin_name}"
    return 1
  fi

  echo -e "${GREEN}[+] 校验通过！/usr/local/bin/${target_bin_name} 架构完全匹配。${PLAIN}"
}

release_port_53() {
  echo -e "${YELLOW}[*] 清理本地 53 端口占用与旧服务...${PLAIN}"
  if lsof -i :53 2>/dev/null | grep -qi "systemd-resolve"; then
    echo -e "${YELLOW}[!] 停用 systemd-resolved 53 端口 stub 监听...${PLAIN}"
    if [ -f /etc/resolv.conf ]; then
      sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf 2>/dev/null || true
    fi
    mkdir -p /etc/systemd/resolved.conf.d/
    echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/disable-stub.conf
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  systemctl stop dnsproxy cloudflared-dns 2>/dev/null || true
}

setup_resolv() {
  echo -e "${YELLOW}[*] 配置系统 DNS 指向 127.0.0.1...${PLAIN}"
  chattr -i /etc/resolv.conf 2>/dev/null || true
  [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
  cat << RESOLV_EOF > /etc/resolv.conf
nameserver 127.0.0.1
options timeout:2 attempts:3
RESOLV_EOF
  echo -e "${GREEN}[+] /etc/resolv.conf 已锁定指向 127.0.0.1${PLAIN}"
}

# ================= 13 个 DoH 节点配置 =================
declare -A DOH_URLS=(
  [1]="https://8.8.8.8/dns-query"
  [2]="https://8.8.4.4/dns-query"
  [3]="https://1.1.1.1/dns-query"
  [4]="https://1.0.0.1/dns-query"
  [5]="https://cloudflare-dns.com/dns-query"
  [6]="https://dns.cloudflare.com/dns-query"
  [7]="https://dns.quad9.net/dns-query"
  [8]="https://dns9.quad9.net/dns-query"
  [9]="https://doh.opendns.com/dns-query"
  [10]="https://dns.opendns.com/dns-query"
  [11]="https://doh.umbrella.com/dns-query"
  [12]="https://dns.umbrella.com/dns-query"
  [13]="https://dns.sse.cisco.com/dns-query"
)

declare -A DOH_DESCS=(
  [1]="Google DNS (主IP)               -> https://8.8.8.8/dns-query"
  [2]="Google DNS (备IP)               -> https://8.8.4.4/dns-query"
  [3]="Cloudflare DNS (主IP)           -> https://1.1.1.1/dns-query"
  [4]="Cloudflare DNS (备IP)           -> https://1.0.0.1/dns-query"
  [5]="Cloudflare 官方域名             -> https://cloudflare-dns.com/dns-query"
  [6]="Cloudflare 备用域名             -> https://dns.cloudflare.com/dns-query"
  [7]="Quad9 官方主域名 (安全拦截)     -> https://dns.quad9.net/dns-query"
  [8]="Quad9 备用域名 (带ECS/无过滤)   -> https://dns9.quad9.net/dns-query"
  [9]="Cisco OpenDNS (官方DoH域名)     -> https://doh.opendns.com/dns-query"
  [10]="Cisco OpenDNS (备用DoH域名)     -> https://dns.opendns.com/dns-query"
  [11]="Cisco Umbrella (企业主DoH域名)  -> https://doh.umbrella.com/dns-query"
  [12]="Cisco Umbrella (企业备DoH域名)  -> https://dns.umbrella.com/dns-query"
  [13]="Cisco SSE 专用 DoH 域名        -> https://dns.sse.cisco.com/dns-query"
)

CONFIG_FILE="/etc/doh_custom.env"

select_dns_pair() {
  while true; do
    echo -e "\n${CYAN}================== 可选 DoH 节点列表 (共 13 个) ==================${PLAIN}"
    for i in {1..13}; do
      printf " ${GREEN}%2d.${PLAIN} %s\n" "$i" "${DOH_DESCS[$i]}"
    done
    echo -e "${CYAN}================================================================${PLAIN}"
    echo -e "${YELLOW}请选择您要用的 DNS 序号，支持 2 个，中间用英文逗号隔开（例如：1,3）${PLAIN}"
    read -rp "请输入序号 [默认 1,3]: " input_val
    input_val=${input_val:-"1,3"}

    clean_val=$(echo "$input_val" | tr -d ' ')
    idx1=$(echo "$clean_val" | cut -d',' -f1)
    idx2=$(echo "$clean_val" | cut -d',' -f2)
    extra=$(echo "$clean_val" | cut -d',' -f3)

    if [[ -n "$idx1" && -n "$idx2" && -z "$extra" && -n "${DOH_URLS[$idx1]}" && -n "${DOH_URLS[$idx2]}" ]]; then
      NODE1="${DOH_URLS[$idx1]}"
      NODE2="${DOH_URLS[$idx2]}"
      echo -e "\n${GREEN}[+] 成功选定以下 2 个 DoH 上游：${PLAIN}"
      echo -e "  - 节点 1: ${CYAN}${NODE1}${PLAIN}"
      echo -e "  - 节点 2: ${CYAN}${NODE2}${PLAIN}"

      mkdir -p $(dirname "$CONFIG_FILE")
      cat << CONF_EOF > "$CONFIG_FILE"
NODE1="${NODE1}"
NODE2="${NODE2}"
ACTIVE_SERVICE="${CURRENT_SERVICE}"
CONF_EOF
      break
    else
      echo -e "${RED}[-] 输入格式有误！必须是 1 到 13 之间的两个序号且用逗号隔开（如 1,3）。${PLAIN}"
    fi
  done
}

# ================= 1. 部署 dnsproxy =================
deploy_dnsproxy() {
  CURRENT_SERVICE="dnsproxy"
  select_dns_pair
  release_port_53

  echo -e "${YELLOW}[*] 正在抓取 AdguardTeam/dnsproxy Linux-${SYS_ARCH} 官方包...${PLAIN}"
  local target_url
  target_url=$(get_github_asset_url "AdguardTeam/dnsproxy" "dnsproxy")

  if [ -z "$target_url" ]; then
    target_url="https://github.com/AdguardTeam/dnsproxy/releases/download/v0.74.2/dnsproxy-linux-${SYS_ARCH}-v0.74.2.tar.gz"
  fi

  universal_download_and_install "$target_url" "dnsproxy" "--version"

  cat << SERVICE_EOF > /etc/systemd/system/dnsproxy.service
[Unit]
Description=dnsproxy DoH Client
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/dnsproxy -l 127.0.0.1 -p 53 -u ${NODE1} -u ${NODE2} -b 1.1.1.1:53 -b 1.0.0.1:53 -b 8.8.8.8:53 -b 8.8.4.4:53 -b 9.9.9.9:53 -b 208.67.222.222:53 --cache --cache-size=4096 --upstream-mode=parallel
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

  systemctl daemon-reload
  systemctl enable --now dnsproxy
  setup_resolv
  echo -e "${GREEN}[+] dnsproxy 启动成功！${PLAIN}"
}

# ================= 2. 部署 cloudflared =================
deploy_cloudflared() {
  CURRENT_SERVICE="cloudflared-dns"
  select_dns_pair
  release_port_53

  echo -e "${YELLOW}[*] 正在拉取支持 proxy-dns 功能的 cloudflared 稳定版本 (2024.12.0)...${PLAIN}"
  local target_url="https://github.com/cloudflare/cloudflared/releases/download/2024.12.0/cloudflared-linux-${SYS_ARCH}"

  rm -f /usr/local/bin/cloudflared
  if ! curl -fL --retry 3 --connect-timeout 8 -m 120 -o /usr/local/bin/cloudflared "$target_url"; then
    echo -e "${RED}[-] cloudflared 下载失败，请检查网络。${PLAIN}"
    return 1
  fi
  chmod +x /usr/local/bin/cloudflared

  echo -e "${YELLOW}[*] 校验 cloudflared 执行能力...${PLAIN}"
  if ! /usr/local/bin/cloudflared --version &>/dev/null; then
    echo -e "${RED}[FATAL] cloudflared 二进制执行失败，架构可能不兼容。${PLAIN}"
    file /usr/local/bin/cloudflared
    return 1
  fi

  echo -e "${YELLOW}[*] 配置上游域名直连映射，防止 Bootstrap 死锁...${PLAIN}"
  grep -q "cloudflare-dns.com" /etc/hosts || echo "1.1.1.1 cloudflare-dns.com" >> /etc/hosts
  grep -q "dns.cloudflare.com" /etc/hosts || echo "1.1.1.1 dns.cloudflare.com" >> /etc/hosts
  grep -q "dns.quad9.net" /etc/hosts || echo "9.9.9.9 dns.quad9.net" >> /etc/hosts
  grep -q "dns9.quad9.net" /etc/hosts || echo "9.9.9.9 dns9.quad9.net" >> /etc/hosts
  grep -q "doh.opendns.com" /etc/hosts || echo "208.67.222.222 doh.opendns.com" >> /etc/hosts
  grep -q "dns.opendns.com" /etc/hosts || echo "208.67.222.222 dns.opendns.com" >> /etc/hosts
  grep -q "doh.umbrella.com" /etc/hosts || echo "208.67.222.222 doh.umbrella.com" >> /etc/hosts
  grep -q "dns.umbrella.com" /etc/hosts || echo "208.67.222.222 dns.umbrella.com" >> /etc/hosts
  grep -q "dns.sse.cisco.com" /etc/hosts || echo "208.67.222.222 dns.sse.cisco.com" >> /etc/hosts

  cat << SERVICE_EOF > /etc/systemd/system/cloudflared-dns.service
[Unit]
Description=cloudflared DoH Proxy DNS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared proxy-dns --port 53 --address 127.0.0.1 --upstream ${NODE1} --upstream ${NODE2}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared-dns
  sleep 1
  setup_resolv
  echo -e "${GREEN}[+] cloudflared 部署成功并已启动！${PLAIN}"
}

# ================= 3. 批量测试全部 13 个 DoH 节点延迟 =================
benchmark_all_doh() {
  clear
  echo -e "${CYAN}======================================================================${PLAIN}"
  echo -e "${CYAN}            全部 13 个主流 DoH 节点批量连通性与延迟测速               ${PLAIN}"
  echo -e "${CYAN}======================================================================${PLAIN}"
  
  local DNS_QUERY="AAABAAABAAAAAAAABmdvb2dsZQNjb20AAAEAAQ"

  printf "%-4s %-22s %-11s %-11s %-13s %-10s\n" "序号" "节点标识" "TCP握手" "TLS握手" "总响应(TTFB)" "状态"
  echo "----------------------------------------------------------------------"

  for i in {1..13}; do
    local url="${DOH_URLS[$i]}"
    local name
    case "$i" in
      1) name="Google-Primary" ;;
      2) name="Google-Secondary" ;;
      3) name="Cloudflare-Primary" ;;
      4) name="Cloudflare-Secondary" ;;
      5) name="Cloudflare-Domain" ;;
      6) name="Cloudflare-AltDomain" ;;
      7) name="Quad9-Main" ;;
      8) name="Quad9-Alt" ;;
      9) name="OpenDNS-Main" ;;
      10) name="OpenDNS-Alt" ;;
      11) name="Umbrella-Main" ;;
      12) name="Umbrella-Alt" ;;
      13) name="Cisco-SSE" ;;
    esac

    local metrics
    metrics=$(curl -s -m 4 -o /dev/null \
      -H "accept: application/dns-message" \
      -w "%{time_connect} %{time_appconnect} %{time_total} %{http_code}" \
      "${url}?dns=${DNS_QUERY}" 2>/dev/null || echo "0 0 0 000")

    local t_tcp t_tls t_total code
    read -r t_tcp t_tls t_total code <<< "$metrics"

    local tcp_str tls_str total_str status_str
    if [ "$code" = "200" ]; then
      tcp_str=$(awk "BEGIN {printf \"%.1f ms\", $t_tcp * 1000}")
      tls_str=$(awk "BEGIN {printf \"%.1f ms\", ($t_tls - $t_tcp) * 1000}")
      total_str=$(awk "BEGIN {printf \"%.1f ms\", $t_total * 1000}")
      status_str="${GREEN}200 OK${PLAIN}"
    elif [ "$code" = "000" ]; then
      tcp_str="--"
      tls_str="--"
      total_str="超时/阻断"
      status_str="${RED}FAIL${PLAIN}"
    else
      tcp_str="--"
      tls_str="--"
      total_str=$(awk "BEGIN {printf \"%.1f ms\", $t_total * 1000}")
      status_str="${YELLOW}HTTP $code${PLAIN}"
    fi

    printf " %2d. %-22s %-11s %-11s %-13s " "$i" "$name" "$tcp_str" "$tls_str" "$total_str"
    echo -e "$status_str"
  done
  echo "----------------------------------------------------------------------"
  echo -e "${YELLOW}[*] 提示: 可根据上方测速结果，记住延迟最低的 2 个序号，在选项 1 或 2 部署时直接输入。${PLAIN}"
  echo ""
  read -rp "按回车键返回主菜单..." dummy
}

# ================= 4. 检测本机 DNS 解析连通性 =================
test_dns_connectivity() {
  clear
  echo -e "${CYAN}=======================================================${PLAIN}"
  echo -e "${CYAN}             实时 DNS 连通性与测速体检                 ${PLAIN}"
  echo -e "${CYAN}=======================================================${PLAIN}"

  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi

  echo -e "${YELLOW}[1/3] 检测当前上游 DoH 节点握手连通性 (TCP:443)...${PLAIN}"
  test_upstream() {
    local target_url=$1
    if [ -z "$target_url" ]; then return; fi
    echo -n "  - 探测节点 [${target_url}]: "

    HTTP_CODE=$(curl -s -m 4 -o /dev/null -w "%{http_code}" \
      -H "accept: application/dns-message" \
      "${target_url}?dns=AAABAAABAAAAAAAABmdvb2dsZQNjb20AAAEAAQ" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" == "200" ]; then
      echo -e "${GREEN}连接畅通${PLAIN} (HTTP 200 OK)"
    elif [ "$HTTP_CODE" == "000" ]; then
      echo -e "${RED}超时或连接被阻断！${PLAIN}"
    else
      echo -e "${YELLOW}响应异常${PLAIN} (HTTP: ${HTTP_CODE})"
    fi
  }

  if [ -n "$NODE1" ] && [ -n "$NODE2" ]; then
    test_upstream "$NODE1"
    test_upstream "$NODE2"
  else
    test_upstream "https://8.8.8.8/dns-query"
    test_upstream "https://1.1.1.1/dns-query"
  fi

  echo -e "\n${YELLOW}[2/3] 测试本地 127.0.0.1:53 多域名实际解析与延迟...${PLAIN}"
  local test_domains=("google.com" "cloudflare.com" "github.com" "apple.com")

  for domain in "${test_domains[@]}"; do
    echo -n "  - 解析 [${domain}]: "
    if command -v dig &>/dev/null; then
      DIG_RES=$(dig @127.0.0.1 "${domain}" +time=2 +tries=1 +stats 2>/dev/null || true)
      Q_TIME=$(echo "$DIG_RES" | grep "Query time:" | awk '{print $4, $5}')
      R_IP=$(echo "$DIG_RES" | grep -A 1 "ANSWER SECTION:" | tail -n 1 | awk '{print $NF}')

      if [ -n "$R_IP" ] && [[ "$R_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}成功${PLAIN} -> IP: ${CYAN}${R_IP}${PLAIN} | 延迟: ${YELLOW}${Q_TIME}${PLAIN}"
      else
        echo -e "${RED}失败！未能返回有效 A 记录${PLAIN}"
      fi
    else
      NS_RES=$(nslookup "${domain}" 127.0.0.1 2>/dev/null || true)
      if echo "$NS_RES" | grep -q "Address"; then
        echo -e "${GREEN}成功${PLAIN}"
      else
        echo -e "${RED}失败！${PLAIN}"
      fi
    fi
  done

  echo -e "\n${YELLOW}[3/3] 验证系统全局网络访问状态...${PLAIN}"
  if curl -s -m 4 --head https://www.cloudflare.com &>/dev/null; then
    echo -e "  - 外网访问: ${GREEN}完全畅通${PLAIN}"
  else
    echo -e "  - 外网访问: ${RED}失败，外网通信受阻${PLAIN}"
  fi
  echo -e "${CYAN}=======================================================${PLAIN}"
}

# ================= 5. 综合服务诊断 =================
check_connection() {
  clear
  echo -e "${CYAN}=======================================================${PLAIN}"
  echo -e "${CYAN}            DoH 服务全面连通性与故障诊断               ${PLAIN}"
  echo -e "${CYAN}=======================================================${PLAIN}"

  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi

  echo -n "[1/4] 检查本地 127.0.0.1:53 监听状态: "
  PORT_INFO=$(ss -tulpn 2>/dev/null | grep -E ":53\b" || lsof -i :53 -n -P 2>/dev/null || true)
  if [ -n "$PORT_INFO" ]; then
    RUN_NAME=$(echo "$PORT_INFO" | grep -oE "dnsproxy|cloudflared" | head -n 1)
    RUN_NAME=${RUN_NAME:-"本地DNS服务"}
    echo -e "${GREEN}正常${PLAIN} (正在由 ${CYAN}${RUN_NAME}${PLAIN} 提供服务)"
  else
    echo -e "${RED}异常！未检测到 DoH 服务监听 53 端口${PLAIN}"
  fi

  echo -e "\n[2/4] 诊断上游 DoH 节点连通性 (针对 HTTPS 443 探测):"
  test_upstream() {
    local target_url=$1
    if [ -z "$target_url" ]; then return; fi
    echo -n "  - 探测 [${target_url}]: "

    HTTP_CODE=$(curl -s -m 4 -o /dev/null -w "%{http_code}" \
      -H "accept: application/dns-message" \
      "${target_url}?dns=AAABAAABAAAAAAAABmdvb2dsZQNjb20AAAEAAQ" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" == "200" ]; then
      echo -e "${GREEN}连接畅通${PLAIN} (HTTP 200 OK)"
    elif [ "$HTTP_CODE" == "000" ]; then
      echo -e "${RED}超时或连接被阻断！${PLAIN}"
    else
      echo -e "${YELLOW}响应异常${PLAIN} (HTTP: ${HTTP_CODE})"
    fi
  }

  if [ -n "$NODE1" ] && [ -n "$NODE2" ]; then
    test_upstream "$NODE1"
    test_upstream "$NODE2"
  else
    test_upstream "https://8.8.8.8/dns-query"
    test_upstream "https://1.1.1.1/dns-query"
  fi

  echo -e "\n[3/4] 诊断本地 DNS 解析能力 (通过 127.0.0.1:53 查询):"
  TEST_DOMAIN="google.com"

  if command -v dig &>/dev/null; then
    DIG_RESULT=$(dig @127.0.0.1 ${TEST_DOMAIN} +time=3 +tries=1 +stats 2>/dev/null || true)
    QUERY_TIME=$(echo "$DIG_RESULT" | grep "Query time:" | awk '{print $4, $5}')
    RESOLVED_IP=$(echo "$DIG_RESULT" | grep -A 1 "ANSWER SECTION:" | tail -n 1 | awk '{print $NF}')

    if [ -n "$RESOLVED_IP" ] && [[ "$RESOLVED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo -e "  - 解析状态: ${GREEN}成功${PLAIN}"
      echo -e "  - 解析域名: ${CYAN}${TEST_DOMAIN}${PLAIN} -> ${GREEN}${RESOLVED_IP}${PLAIN}"
      echo -e "  - 解析延迟: ${YELLOW}${QUERY_TIME}${PLAIN}"
    else
      echo -e "  - 解析状态: ${RED}失败！本地未能正确返回有效 IP${PLAIN}"
    fi
  else
    NS_RESULT=$(nslookup ${TEST_DOMAIN} 127.0.0.1 2>/dev/null || true)
    if echo "$NS_RESULT" | grep -q "Address"; then
      echo -e "  - 解析状态: ${GREEN}成功${PLAIN}"
    else
      echo -e "  - 解析状态: ${RED}失败！${PLAIN}"
    fi
  fi

  echo -e "\n[4/4] 验证系统全局网络访问 (直接访问外网):"
  if curl -s -m 4 --head https://www.cloudflare.com &>/dev/null; then
    echo -e "  - 外网访问: ${GREEN}完全畅通${PLAIN}"
  else
    echo -e "  - 外网访问: ${RED}失败，外网通信受阻${PLAIN}"
  fi
  echo -e "${CYAN}=======================================================${PLAIN}"
}

# ================= 6. 卸载与清理 =================
uninstall_all() {
  echo -e "${YELLOW}[*] 正在停止服务并清理残留...${PLAIN}"
  systemctl disable --now dnsproxy cloudflared-dns 2>/dev/null || true
  rm -f /etc/systemd/system/dnsproxy.service
  rm -f /etc/systemd/system/cloudflared-dns.service
  rm -f "$CONFIG_FILE"
  systemctl daemon-reload
  rm -f /usr/local/bin/dnsproxy /usr/local/bin/cloudflared

  cat << RESOLV_EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV_EOF
  echo -e "${GREEN}[+] 卸载完成，系统 DNS 已重置为 1.1.1.1 / 8.8.8.8。${PLAIN}"
}

clear
echo -e "${CYAN}=======================================================${PLAIN}"
echo -e "${CYAN}          低内存 DoH 客户端集成部署管理脚本          ${PLAIN}"
echo -e "${CYAN}=======================================================${PLAIN}"
echo " 1. 部署 dnsproxy    [最推荐 / 内存~10MB / 并发竞速模式]"
echo " 2. 部署 cloudflared [官方客户端 / 内存~25MB / 稳定直链已锁版]"
echo " -----------------------------------------------------"
echo " 3. 批量测试全部 13 个 DoH 节点延迟 (基准跑分)"
echo " 4. 检测本机 DNS 连通性与测速 (多域名梯队延迟)"
echo " 5. 深度检测 DoH 综合服务状态 (端口/上游/系统全面排错)"
echo " 6. 卸载全部 DoH 工具并恢复默认配置"
echo " 0. 退出脚本"
echo -e "${CYAN}=======================================================${PLAIN}"
read -rp "请选择模式 [0-6]: " main_choice

install_deps

case "$main_choice" in
  1)
    deploy_dnsproxy
    sleep 1
    test_dns_connectivity
    ;;
  2)
    deploy_cloudflared
    sleep 1
    test_dns_connectivity
    ;;
  3)
    benchmark_all_doh
    ;;
  4)
    test_dns_connectivity
    ;;
  5)
    check_connection
    ;;
  6)
    uninstall_all
    ;;
  0)
    exit 0
    ;;
  *)
    echo -e "${RED}[-] 无效输入，退出。${PLAIN}"
    exit 1
    ;;
esac
