#!/bin/bash
# setup_proxy.sh - 多节点轮询解析与 sing-box 启动 (终极无懈可击版)
export LC_ALL=C
set -e

export NODE_LINK=${NODE_LINK:-''}

set_env() {
  local key=$1
  local value=$2
  if [ -n "$GITHUB_ENV" ]; then
    echo "${key}=${value}" >> "$GITHUB_ENV"
  else
    export "${key}=${value}"
  fi
}

if [ -z "$NODE_LINK" ]; then
  echo "[INFO] 未配置代理，直连模式"
  set_env "IS_PROXY" "false"
  set_env "USE_PROXY" "false"
  set_env "PROXY_STATUS" "直连"
  exit 0
fi

# 智能检测包管理器安装必需依赖
for pkg in jq curl base64; do
  if ! command -v $pkg &> /dev/null; then
    echo "[WARN] $pkg 未安装，正在尝试安装..."
    if command -v apt-get &> /dev/null; then
      sudo apt-get update -q && sudo apt-get install -y $pkg coreutils
    elif command -v apk &> /dev/null; then
      sudo apk add $pkg coreutils
    elif command -v yum &> /dev/null; then
      sudo yum install -y $pkg coreutils
    else
      echo "[ERROR] 找不到支持的包管理器安装 $pkg，请手动安装后重试。"
      exit 1
    fi
  fi
done

echo "[INFO] 获取 sing-box 最新版本..."
tag_name=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // ""' 2>/dev/null || echo "")
latest_version="${tag_name#v}"
if [ -z "$latest_version" ]; then
  echo "[WARN] 无法获取 sing-box 最新版本(可能触发 API 限制)，将默认使用 1.13.14"
  latest_version="1.13.14"
fi
echo "[INFO] 最新稳定版本: v${latest_version}"

ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64')  ARCH='amd64' ;;
    'x86' | 'i686' | 'i386') ARCH='386' ;;
    'aarch64' | 'arm64') ARCH='arm64' ;;
    'armv7l')  ARCH='armv7' ;;
    's390x')   ARCH='s390x' ;;
    *) echo "[ERROR] 不支持的架构: ${ARCH_RAW}"; exit 1 ;;
esac

if [ ! -f "./sing-box" ]; then
  echo "[INFO] 正在下载 sing-box 二进制文件..."
  curl -sLo "sing-box-${latest_version}-linux-${ARCH}.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz" || true
  if [ -f "sing-box-${latest_version}-linux-${ARCH}.tar.gz" ]; then
    tar -xzf "sing-box-${latest_version}-linux-${ARCH}.tar.gz" 2>/dev/null || true
    if [ -f "sing-box-${latest_version}-linux-${ARCH}/sing-box" ]; then
      mv "sing-box-${latest_version}-linux-${ARCH}/sing-box" ./
    fi
    rm -rf "sing-box-${latest_version}-linux-${ARCH}.tar.gz" "sing-box-${latest_version}-linux-${ARCH}" 2>/dev/null || true
  fi
  if [ ! -f "./sing-box" ]; then echo "[ERROR] sing-box 下载或解压失败！"; exit 1; fi
  chmod +x sing-box
fi

# ----------------- 核心安全助手函数 -----------------

# JSON 安全转义函数 (彻底杜绝 JSON 注入崩溃)
json_esc() {
  [ -z "$1" ] && return
  jq -n -c --arg str "$1" '$str' | sed 's/^"//;s/"$//'
}

# 终极安全 URL 解码 (修复原生反斜杠被吞咽的问题)
url_decode() {
  local encoded="${1//+/ }"
  encoded="${encoded//\\/\\\\}"
  printf '%b' "${encoded//%/\\x}"
}

# 容错 Base64 解码 (支持 URL-Safe 且自动补齐 =)
safe_base64_decode() {
  local input="$1"
  input=$(echo "$input" | tr -d '[:space:]' | tr '-_' '+/')
  local mod=$(( ${#input} % 4 ))
  if [ $mod -eq 2 ]; then input="${input}=="; elif [ $mod -eq 3 ]; then input="${input}="; fi
  echo "$input" | base64 -d 2>/dev/null || echo ""
}

# 安全参数提取 (原值)
get_query_param() {
  local query="$1"
  local key="$2"
  echo "&${query}" | grep -io "&${key}=[^&]*" | cut -d= -f2- || true
}

# 安全参数提取 (强制小写)
get_query_param_lc() {
  get_query_param "$1" "$2" | tr '[:upper:]' '[:lower:]'
}

# 智能解析 Host 和 Port (修复裸 IPv6 冒号切割 Bug)
parse_host_port() {
  local input="$1"
  local default_port="$2"
  
  if [[ "$input" =~ ^\[([a-fA-F0-9:]+)\]:([0-9]+)$ ]]; then
    outbound_server="${BASH_REMATCH[1]}"
    outbound_port="${BASH_REMATCH[2]}"
  elif [[ "$input" =~ ^\[([a-fA-F0-9:]+)\]$ ]]; then
    outbound_server="${BASH_REMATCH[1]}"
    outbound_port="$default_port"
  elif [[ "$input" == *":"* ]]; then
    local colons="${input//[^:]/}"
    if [ "${#colons}" -gt 1 ]; then
      outbound_server="$input"
      outbound_port="$default_port"
    else
      outbound_server="${input%:*}"
      outbound_port="${input##*:}"
    fi
  else
    outbound_server="$input"
    outbound_port="$default_port"
  fi
}

# ----------------- 节点与订阅解析 -----------------

# 智能识别并解码 Base64 整体订阅链接
if ! echo "$NODE_LINK" | grep -q "://"; then
  echo "[INFO] 未检测到明文协议，尝试解析为 Base64 订阅..."
  decoded_sub=$(safe_base64_decode "$NODE_LINK")
  if echo "$decoded_sub" | grep -q "://"; then
    NODE_LINK="$decoded_sub"
    echo "[INFO] ✅ 成功解码 Base64 订阅链接"
  fi
fi

# 兼容 macOS/旧版 Bash 的行数组读取方式 (取代 mapfile)
NODE_ARRAY=()
while IFS= read -r line || [ -n "$line" ]; do
  line=$(echo "$line" | tr -d '[:space:]')
  [ -n "$line" ] && NODE_ARRAY+=("$line")
done <<< "$NODE_LINK"

total_nodes=${#NODE_ARRAY[@]}
echo "[INFO] 共检测到 ${total_nodes} 个代理节点配置行，准备轮询测试..."

node_idx=0
CURRENT_SB_PID=""

for single_node in "${NODE_ARRAY[@]}"; do
  node_idx=$((node_idx + 1))
  echo "----------------------------------------"
  echo "[INFO] 正在尝试节点 [$node_idx / $total_nodes] ..."

  proto=$(echo "$single_node" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  content="${single_node#*://}"
  content="${content%%#*}" # 剔除 #节点名称 尾巴

  # 重置变量
  outbound_type=""
  outbound_server=""
  outbound_port=""
  outbound_uuid=""
  outbound_flow=""
  outbound_transport_type="tcp"
  outbound_path="/"
  outbound_host=""
  outbound_security="none"
  outbound_sni=""
  outbound_fingerprint="chrome"
  outbound_reality_pbk=""
  outbound_reality_sid=""
  outbound_password=""
  outbound_up_mbps=100
  outbound_down_mbps=100
  outbound_obfs_password=""
  outbound_auth=""
  outbound_congestion="bbr"
  outbound_udp_over_stream="true"
  outbound_zerortt="false"
  outbound_username=""
  outbound_password2=""
  outbound_version="5"
  outbound_insecure="false"
  outbound_alpn=""

  case "$proto" in
    vless)
      uuid_host="$content"
      uuid="${uuid_host%%@*}"
      rest="${uuid_host#*@}"
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%"?"*}"; query="${rest#*"?"}"; else host_port="$rest"; query=""; fi
      
      parse_host_port "$host_port" "443"
      outbound_uuid="$uuid"
      outbound_type="vless"

      if [ -n "$query" ]; then
        flow=$(get_query_param "$query" "flow"); [ -n "$flow" ] && outbound_flow="$flow"
        ttype=$(get_query_param_lc "$query" "type"); [ -n "$ttype" ] && outbound_transport_type="$ttype"
        path_raw=$(get_query_param "$query" "path")
        if [ -n "$path_raw" ]; then path_decoded=$(url_decode "$path_raw"); outbound_path="${path_decoded%%"?"*}"; fi
        host=$(get_query_param "$query" "host"); [ -n "$host" ] && outbound_host="$host"
        sec=$(get_query_param_lc "$query" "security"); [ -n "$sec" ] && outbound_security="$sec"
        sni=$(get_query_param "$query" "sni"); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(get_query_param_lc "$query" "fp"); [ -n "$fp" ] && outbound_fingerprint="$fp"
        pbk=$(get_query_param "$query" "pbk"); [ -n "$pbk" ] && outbound_reality_pbk="$pbk"
        sid=$(get_query_param "$query" "sid"); [ -n "$sid" ] && outbound_reality_sid="$sid"
        
        ins=$(get_query_param_lc "$query" "insecure")
        alins=$(get_query_param_lc "$query" "allowinsecure")
        if [ "$ins" = "1" ] || [ "$ins" = "true" ] || [ "$alins" = "1" ] || [ "$alins" = "true" ]; then outbound_insecure="true"; fi
      fi
      if [ -z "$outbound_host" ]; then outbound_host="$outbound_server"; fi
      if [ -z "$outbound_sni" ]; then outbound_sni="$outbound_server"; fi
      ;;

    vmess)
      decoded=$(safe_base64_decode "$content")
      if [ -z "$decoded" ]; then echo "[WARN] VMess Base64 解码失败"; continue; fi
      
      add=$(echo "$decoded" | jq -r '.add // ""' 2>/dev/null || echo "")
      if [ -z "$add" ]; then echo "[WARN] VMess JSON 解析失败"; continue; fi
      
      outbound_type="vmess"
      outbound_server="$add"
      outbound_port=$(echo "$decoded" | jq -r '.port // 443' 2>/dev/null || echo "443")
      outbound_uuid=$(echo "$decoded" | jq -r '.id // ""' 2>/dev/null || echo "")
      outbound_transport_type=$(echo "$decoded" | jq -r '.net // "tcp"' 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "tcp")
      outbound_security=$(echo "$decoded" | jq -r '.tls // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
      outbound_sni=$(echo "$decoded" | jq -r '.sni // ""' 2>/dev/null || echo "")
      host_raw=$(echo "$decoded" | jq -r '.host // ""' 2>/dev/null || echo "")
      
      path_raw=$(echo "$decoded" | jq -r '.path // "/"' 2>/dev/null || echo "/")
      path_decoded=$(url_decode "$path_raw")
      outbound_path="${path_decoded%%"?"*}"
      
      outbound_host="${host_raw:-$add}"
      outbound_sni="${outbound_sni:-$add}"
      outbound_fingerprint=$(echo "$decoded" | jq -r '.fp // "chrome"' 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "chrome")
      ;;

    trojan)
      pass_rest="$content"
      password="${pass_rest%%@*}"
      rest="${pass_rest#*@}"
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%"?"*}"; query="${rest#*"?"}"; else host_port="$rest"; query=""; fi
      
      parse_host_port "$host_port" "443"
      outbound_password="$password"
      outbound_type="trojan"

      if [ -n "$query" ]; then
        ttype=$(get_query_param_lc "$query" "type"); [ -n "$ttype" ] && outbound_transport_type="$ttype"
        path_raw=$(get_query_param "$query" "path")
        if [ -n "$path_raw" ]; then path_decoded=$(url_decode "$path_raw"); outbound_path="${path_decoded%%"?"*}"; fi
        host=$(get_query_param "$query" "host"); [ -n "$host" ] && outbound_host="$host"
        sni=$(get_query_param "$query" "sni"); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(get_query_param_lc "$query" "fp"); [ -n "$fp" ] && outbound_fingerprint="$fp"
        
        ins=$(get_query_param_lc "$query" "insecure")
        alins=$(get_query_param_lc "$query" "allowinsecure")
        if [ "$ins" = "1" ] || [ "$ins" = "true" ] || [ "$alins" = "1" ] || [ "$alins" = "true" ]; then outbound_insecure="true"; fi
      fi
      if [ -z "$outbound_host" ]; then outbound_host="$outbound_server"; fi
      if [ -z "$outbound_sni" ]; then outbound_sni="$outbound_server"; fi
      ;;

    hysteria2|hy2)
      if [[ "$content" == *"@"* ]]; then auth="${content%%@*}"; host_port="${content#*@}"; else auth=""; host_port="$content"; fi
      if [[ "$host_port" == *"?"* ]]; then hp="${host_port%%"?"*}"; query="${host_port#*"?"}"; else hp="$host_port"; query=""; fi
      hp="${hp%/}"
      
      parse_host_port "$hp" "443"
      outbound_type="hysteria2"
      outbound_auth="$auth"

      if [ -n "$query" ]; then
        obfs=$(get_query_param "$query" "obfs"); [ -n "$obfs" ] && outbound_obfs_password="$obfs"
        sni=$(get_query_param "$query" "sni"); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(get_query_param_lc "$query" "fp"); [ -n "$fp" ] && outbound_fingerprint="$fp"
        
        ins=$(get_query_param_lc "$query" "insecure")
        alins=$(get_query_param_lc "$query" "allowinsecure")
        if [ "$ins" = "1" ] || [ "$ins" = "true" ] || [ "$alins" = "1" ] || [ "$alins" = "true" ]; then outbound_insecure="true"; fi
        
        if [ -z "$outbound_auth" ]; then
          q_pass=$(get_query_param "$query" "password")
          if [ -z "$q_pass" ]; then q_pass=$(get_query_param "$query" "auth"); fi
          if [ -n "$q_pass" ]; then outbound_auth="$q_pass"; fi
        fi
      fi
      if [ -z "$outbound_sni" ]; then outbound_sni="$outbound_server"; fi
      ;;

    tuic)
      uuid_pass="${content%%@*}"
      rest="${content#*@}"
      uuid_pass_clean=$(echo "$uuid_pass" | sed 's/%3A/:/g')
      if [[ "$uuid_pass_clean" == *":"* ]]; then outbound_uuid="${uuid_pass_clean%:*}"; outbound_password2="${uuid_pass_clean#*:}"; else outbound_uuid="$uuid_pass_clean"; outbound_password2=""; fi
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%"?"*}"; query="${rest#*"?"}"; else host_port="$rest"; query=""; fi
      
      parse_host_port "$host_port" "8443"
      outbound_type="tuic"

      if [ -n "$query" ]; then
        sni=$(get_query_param "$query" "sni"); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(get_query_param_lc "$query" "fp"); [ -n "$fp" ] && outbound_fingerprint="$fp"
        cc=$(get_query_param_lc "$query" "congestion_control"); [ -n "$cc" ] && outbound_congestion="$cc"
        alpn=$(get_query_param_lc "$query" "alpn"); [ -n "$alpn" ] && outbound_alpn="$alpn"
        
        ins=$(get_query_param_lc "$query" "insecure")
        alins=$(get_query_param_lc "$query" "allowinsecure")
        if [ "$ins" = "1" ] || [ "$ins" = "true" ] || [ "$alins" = "1" ] || [ "$alins" = "true" ]; then outbound_insecure="true"; fi
      fi
      if [ -z "$outbound_sni" ]; then outbound_sni="$outbound_server"; fi
      ;;

    anytls)
      password="${content%%@*}"
      rest="${content#*@}"
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%"?"*}"; query="${rest#*"?"}"; else host_port="$rest"; query=""; fi
      
      parse_host_port "$host_port" "443"
      outbound_password="$password"
      outbound_type="anytls"

      if [ -n "$query" ]; then
        sni=$(get_query_param "$query" "sni"); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(get_query_param_lc "$query" "fp"); [ -n "$fp" ] && outbound_fingerprint="$fp"
        ins=$(get_query_param_lc "$query" "insecure")
        alins=$(get_query_param_lc "$query" "allowinsecure")
        if [ "$ins" = "1" ] || [ "$ins" = "true" ] || [ "$alins" = "1" ] || [ "$alins" = "true" ]; then outbound_insecure="true"; fi
      fi
      if [ -z "$outbound_sni" ]; then outbound_sni="$outbound_server"; fi
      ;;

    socks5|socks)
      if [[ "$content" == *"@"* ]]; then
        user_pass="${content%%@*}"
        host_port="${content#*@}"
        if [[ "$user_pass" == *":"* ]]; then
          outbound_username="${user_pass%:*}"
          outbound_password2="${user_pass#*:}"
        else
          outbound_username="$user_pass"
          outbound_password2=""
        fi
      else
        host_port="$content"
      fi
      parse_host_port "$host_port" "1080"
      outbound_type="socks"
      ;;

    *)
      echo "[WARN] 不支持的协议类型: $proto，跳过"
      continue
      ;;
  esac

  if [ -z "$outbound_server" ] || [ -z "$outbound_port" ] || ! [[ "$outbound_port" =~ ^[0-9]+$ ]]; then
    echo "[WARN] 无法解析到有效的服务器地址或数字端口，跳过"
    continue
  fi

  # ----------------- 生成防注入 JSON 配置 -----------------
  
  # 对所有可能包含特俗符号的变量执行彻底转义，杜绝 JSON 注入
  J_SVR=$(json_esc "$outbound_server")
  J_UID=$(json_esc "$outbound_uuid")
  J_PWD=$(json_esc "$outbound_password")
  J_PW2=$(json_esc "$outbound_password2")
  J_PTH=$(json_esc "$outbound_path")
  J_HST=$(json_esc "$outbound_host")
  J_SNI=$(json_esc "$outbound_sni")
  J_ATH=$(json_esc "$outbound_auth")
  J_OBF=$(json_esc "$outbound_obfs_password")
  J_UNM=$(json_esc "$outbound_username")
  J_PBK=$(json_esc "$outbound_reality_pbk")
  J_SID=$(json_esc "$outbound_reality_sid")

  jq_outbound="{\"type\":\"$outbound_type\",\"tag\":\"proxy\",\"server\":\"$J_SVR\",\"server_port\":$outbound_port"
  case "$outbound_type" in
    vless)
      jq_outbound="$jq_outbound,\"uuid\":\"$J_UID\""
      if [ -n "$outbound_flow" ]; then jq_outbound="$jq_outbound,\"flow\":\"$outbound_flow\""; fi
      if [ "$outbound_transport_type" != "tcp" ]; then 
        jq_outbound="$jq_outbound,\"transport\":{\"type\":\"$outbound_transport_type\",\"path\":\"$J_PTH\",\"headers\":{\"Host\":\"$J_HST\"}}"
      fi
      tls_enabled="false"; if [ "$outbound_security" = "tls" ] || [ "$outbound_security" = "reality" ]; then tls_enabled="true"; fi
      tls_json="{\"enabled\":$tls_enabled,\"server_name\":\"$J_SNI\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}"
      if [ "$outbound_security" = "reality" ]; then tls_json="$tls_json,\"reality\":{\"enabled\":true,\"public_key\":\"$J_PBK\",\"short_id\":\"$J_SID\"}"; fi
      tls_json="$tls_json}"
      jq_outbound="$jq_outbound,\"tls\":$tls_json"
      ;;
    vmess)
      jq_outbound="$jq_outbound,\"uuid\":\"$J_UID\",\"security\":\"auto\""
      if [ "$outbound_transport_type" != "tcp" ]; then
        jq_outbound="$jq_outbound,\"transport\":{\"type\":\"$outbound_transport_type\",\"path\":\"$J_PTH\",\"headers\":{\"Host\":\"$J_HST\"}}"
      fi
      tls_enabled="false"; if [ "$outbound_security" = "tls" ]; then tls_enabled="true"; fi
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":$tls_enabled,\"server_name\":\"$J_SNI\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}}"
      ;;
    trojan)
      jq_outbound="$jq_outbound,\"password\":\"$J_PWD\""
      if [ "$outbound_transport_type" != "tcp" ]; then
        jq_outbound="$jq_outbound,\"transport\":{\"type\":\"$outbound_transport_type\",\"path\":\"$J_PTH\",\"headers\":{\"Host\":\"$J_HST\"}}"
      fi
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":true,\"server_name\":\"$J_SNI\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}}"
      ;;
    hysteria2)
      jq_outbound="$jq_outbound,\"up_mbps\":$outbound_up_mbps,\"down_mbps\":$outbound_down_mbps"
      if [ -n "$outbound_obfs_password" ]; then jq_outbound="$jq_outbound,\"obfs\":{\"type\":\"salamander\",\"password\":\"$J_OBF\"}"; fi
      if [ -n "$outbound_auth" ]; then jq_outbound="$jq_outbound,\"password\":\"$J_ATH\""; fi
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":true,\"server_name\":\"$J_SNI\",\"insecure\":$outbound_insecure}"
      ;;
    tuic)
      jq_outbound="$jq_outbound,\"uuid\":\"$J_UID\""
      if [ -n "$outbound_password2" ]; then jq_outbound="$jq_outbound,\"password\":\"$J_PW2\""; fi
      jq_outbound="$jq_outbound,\"congestion_control\":\"$outbound_congestion\",\"udp_over_stream\":$outbound_udp_over_stream,\"zero_rtt_handshake\":$outbound_zerortt"
      tls_json="{\"enabled\":true,\"server_name\":\"$J_SNI\",\"insecure\":$outbound_insecure"
      if [ -n "$outbound_alpn" ]; then tls_json="$tls_json,\"alpn\":[\"$outbound_alpn\"]"; fi
      tls_json="$tls_json}"
      jq_outbound="$jq_outbound,\"tls\":$tls_json"
      ;;
    anytls)
      jq_outbound="$jq_outbound,\"password\":\"$J_PWD\""
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":true,\"server_name\":\"$J_SNI\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}}"
      ;;
    socks)
      if [ -n "$outbound_username" ]; then jq_outbound="$jq_outbound,\"username\":\"$J_UNM\""; fi
      if [ -n "$outbound_password2" ]; then jq_outbound="$jq_outbound,\"password\":\"$J_PW2\""; fi
      jq_outbound="$jq_outbound,\"version\":\"$outbound_version\""
      ;;
  esac
  jq_outbound="$jq_outbound}"

  cat << EOF > sing-box-config.json
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 1080},
    {"type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": 1081}
  ],
  "outbounds": [$jq_outbound]
}
EOF

  # 进程深度清理
  if [ -n "$CURRENT_SB_PID" ]; then
    kill -9 "$CURRENT_SB_PID" 2>/dev/null || true
  fi
  pkill -f sing-box 2>/dev/null || true
  if command -v fuser &>/dev/null; then
    fuser -k 1080/tcp 2>/dev/null || true
    fuser -k 1081/tcp 2>/dev/null || true
  fi
  sleep 1

  ./sing-box run -c sing-box-config.json > sing-box.log 2>&1 &
  CURRENT_SB_PID=$!
  sleep 2

  if ! kill -0 $CURRENT_SB_PID 2>/dev/null; then
    echo "[WARN] ❌ sing-box 启动失败 (配置参数校验不通过)，尝试下一个..."
    if [ -f sing-box.log ]; then tail -n 5 sing-box.log; fi
    continue
  fi

  echo "[INFO] 测试节点连接性..."
  ip_info=$(curl -x socks5://127.0.0.1:1080 -s --max-time 8 https://ipinfo.io/json || true)

  if [ -n "$ip_info" ] && echo "$ip_info" | jq -e '.ip' > /dev/null 2>&1; then
    ip_addr=$(echo "$ip_info" | jq -r '.ip // "Unknown"' 2>/dev/null || echo "Unknown")
    country=$(echo "$ip_info" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown")

    echo "[INFO] ✅ 节点 [$node_idx] 连接成功！ | 📍 IP: $ip_addr | 🌍 国家: $country"
    
    set_env "IS_PROXY" "true"
    set_env "USE_PROXY" "true"
    set_env "PROXY_SERVER" "socks5://127.0.0.1:1080"
    set_env "PROXY_STATUS" "代理: $ip_addr ($country)"
    exit 0
  else
    echo "[WARN] ❌ 节点 [$node_idx] 无法连接或超时，尝试下一个..."
    if [ -s sing-box.log ]; then tail -n 3 sing-box.log; fi
  fi
done

echo "[WARN] ❌ 所有配置的代理节点均测试失败，自动切换为直连模式！"
set_env "USE_PROXY" "false"
set_env "PROXY_STATUS" "直连 (代理全部失效)"
exit 0
