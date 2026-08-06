#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# ================== Base64 解码（修复 tr 问题） ==================
urlsafe_b64decode() {
    local input="$1"
    # 用 sed 替代 tr，彻底避免 tr 的选项解析歧义
    input=$(printf '%s' "$input" | sed 's/-/+/g; s/_/\//g')
    # 补齐 padding
    local len=${#input} pad=$(( (4 - len % 4) % 4 ))
    if [ $pad -ne 0 ]; then
        input+=$(printf '=%.0s' $(seq 1 $pad))
    fi
    printf '%s' "$input" | base64 -d 2>/dev/null
}

# ================== 安装 sing-box ==================
get_singbox() {
    info "获取 sing-box 最新版本..."
    local version
    version=$(curl -sL --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | grep -oP '"tag_name": "\K[^"]+' || true)
    version="${version:-v1.13.16}"
    info "最新稳定版本: $version"
    
    local ver_num="${version#v}" arch="linux-amd64"
    local url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${ver_num}-${arch}.tar.gz"
    
    info "正在下载 sing-box 二进制文件..."
    if ! curl -sL --max-time 60 "$url" | tar -xz -C /tmp "sing-box-${ver_num}-${arch}/sing-box" 2>/dev/null; then
        err "sing-box 下载失败"
        return 1
    fi
    mv "/tmp/sing-box-${ver_num}-${arch}/sing-box" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    info "sing-box 已安装: $(sing-box version | head -1)"
}

# ================== 解析 VMess 并生成完整配置 ==================
parse_and_gen_vmess() {
    local link="$1"
    local b64="${link#vmess://}"
    
    local json
    if ! json=$(urlsafe_b64decode "$b64"); then
        warn "VMess Base64 解码失败"
        return 1
    fi
    
    # 提取所有字段
    local server port uuid aid net path host tls sni
    server=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('add',''))" 2>/dev/null || true)
    port=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('port',''))" 2>/dev/null || true)
    uuid=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    aid=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('aid','0'))" 2>/dev/null || true)
    net=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('net','tcp'))" 2>/dev/null || true)
    path=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path','/'))" 2>/dev/null || true)
    host=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)
    tls=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tls',''))" 2>/dev/null || true)
    sni=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sni',''))" 2>/dev/null || true)
    
    if [ -z "$server" ] || [ -z "$port" ] || [ -z "$uuid" ]; then
        warn "VMess 字段解析不完整 (server=$server, port=$port)"
        return 1
    fi
    
    # 构建 transport 段
    local transport_json=''
    if [ "$net" = "ws" ]; then
        local ws_host="${host:-$server}"
        transport_json=$(cat <<EOF
      "transport": {
        "type": "ws",
        "path": "$path",
        "headers": {
          "Host": "$ws_host"
        }
      },
EOF
)
    fi
    
    # 构建 tls 段
    local tls_json=''
    if [ "$tls" = "tls" ]; then
        local tls_sni="${sni:-$host}"
        tls_sni="${tls_sni:-$server}"
        tls_json=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "$tls_sni",
        "insecure": false
      },
EOF
)
    fi
    
    cat > /tmp/sing-box-test.json <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "vmess",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid",
      "alter_id": ${aid:-0},
      "security": "auto",
$transport_json
$tls_json
      "tag": "proxy"
    }
  ]
}
EOF
    debug "配置已生成: $server:$port (net=$net, tls=$tls)"
}

# ================== 测试代理连通性 ==================
test_proxy() {
    local test_url="https://betadash.lunes.host/login"
    info "测试代理连通性..."
    
    local pid
    sing-box run -c /tmp/sing-box-test.json >/dev/null 2>&1 &
    pid=$!
    sleep 3
    
    local ok=1
    local http_code
    http_code=$(curl -s --socks5-hostname 127.0.0.1:1080 --max-time 10 \
         -o /dev/null -w "%{http_code}" "$test_url" || true)
    
    if echo "$http_code" | grep -qE "200|301|302|403"; then
        ok=0
    fi
    
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    return $ok
}

# ================== 主流程 ==================
main() {
    local NODE_LINK="${NODE_LINK:-}"
    
    if [ -z "$NODE_LINK" ]; then
        warn "未设置 NODE_LINK，使用直连模式"
        echo "PROXY_SERVER=" >> "$GITHUB_ENV"
        return 0
    fi
    
    if ! get_singbox; then
        warn "sing-box 安装失败，使用直连模式"
        echo "PROXY_SERVER=" >> "$GITHUB_ENV"
        return 0
    fi
    
    local -a lines=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        lines+=("$line")
    done <<< "$NODE_LINK"
    
    info "共检测到 ${#lines[@]} 个代理节点配置行，准备轮询测试..."
    
    local success=0
    for i in "${!lines[@]}"; do
        local line="${lines[$i]}"
        local idx=$((i + 1))
        echo "----------------------------------------"
        info "正在尝试节点 [$idx / ${#lines[@]}] ..."
        
        if [[ "$line" != vmess://* ]]; then
            warn "不支持的协议，跳过: ${line:0:30}..."
            continue
        fi
        
        if ! parse_and_gen_vmess "$line"; then
            warn "VMess 解析失败，跳过该节点"
            continue
        fi
        
        if test_proxy; then
            info "✅ 节点 [$idx] 测试通过"
            echo "PROXY_SERVER=socks5://127.0.0.1:1080" >> "$GITHUB_ENV"
            success=1
            break
        else
            warn "❌ 节点 [$idx] 连接失败"
        fi
    done
    
    if [ $success -eq 0 ]; then
        warn "❌ 所有配置的代理节点均测试失败，自动切换为直连模式！"
        echo "PROXY_SERVER=" >> "$GITHUB_ENV"
    fi
}

main "$@"
