#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

b64decode() {
    local input="$1"
    # 关键修复：完全不用 tr，用 sed 做字符替换
    input=$(printf '%s' "$input" | sed 's/-/+/g; s/_/\//g')
    # 补齐 padding
    local len=${#input} pad=$(( (4 - len % 4) % 4 ))
    while [ $pad -gt 0 ]; do input="${input}="; pad=$((pad-1)); done
    printf '%s' "$input" | base64 -d 2>/dev/null
}

get_singbox() {
    info "获取 sing-box 最新版本..."
    local ver
    ver=$(curl -sL --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -oP '"tag_name": "\K[^"]+' || true)
    ver="${ver:-v1.13.16}"
    info "版本: $ver"
    local v="${ver#v}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${v}-linux-amd64.tar.gz"
    curl -sL --max-time 60 "$url" | tar -xz -C /tmp "sing-box-${v}-linux-amd64/sing-box" 2>/dev/null || return 1
    mv "/tmp/sing-box-${v}-linux-amd64/sing-box" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
}

parse_vmess() {
    local link="$1" b64="${link#vmess://}" json
    json=$(b64decode "$b64") || { warn "VMess Base64 解码失败"; return 1; }
    python3 -c "import sys,json; d=json.load(sys.stdin); print('\t'.join(str(d.get(k,'')) for k in ('add','port','id','aid','net','path','host','tls','sni')))" <<< "$json"
}

gen_config() {
    local srv="$1" port="$2" uuid="$3" aid="$4" net="$5" path="$6" host="$7" tls="$8" sni="$9"
    local trans='' tlsc=''
    [ "$net" = "ws" ] && trans="      \"transport\": { \"type\": \"ws\", \"path\": \"$path\", \"headers\": { \"Host\": \"${host:-$srv}\" } },"
    [ "$tls" = "tls" ] && tlsc="      \"tls\": { \"enabled\": true, \"server_name\": \"${sni:-${host:-$srv}}\", \"insecure\": false },"
    cat > /tmp/sb.json <<JSON
{
  "log": { "level": "error" },
  "inbounds": [{ "type": "socks", "listen": "127.0.0.1", "listen_port": 1080 }],
  "outbounds": [{ "type": "vmess", "server": "$srv", "server_port": $port, "uuid": "$uuid", "alter_id": ${aid:-0}, "security": "auto",$trans$tlsc "tag": "proxy" }]
}
JSON
}

test_proxy() {
    sing-box run -c /tmp/sb.json >/dev/null 2>&1 & local pid=$!; sleep 3
    local code; code=$(curl -s --socks5-hostname 127.0.0.1:1080 --max-time 10 -o /dev/null -w "%{http_code}" "https://betadash.lunes.host/login" || true)
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    echo "$code" | grep -qE "200|301|302|403"
}

main() {
    local NODE_LINK="${NODE_LINK:-}"
    if [ -z "$NODE_LINK" ]; then echo "PROXY_SERVER=" >> "$GITHUB_ENV"; return 0; fi
    get_singbox || { warn "sing-box 安装失败，使用直连"; echo "PROXY_SERVER=" >> "$GITHUB_ENV"; return 0; }
    local lines=() line
    while IFS= read -r line || [ -n "$line" ]; do [ -z "$line" ] || lines+=("$line"); done <<< "$NODE_LINK"
    info "共检测到 ${#lines[@]} 个代理节点配置行，准备轮询测试..."
    local ok=0
    for i in "${!lines[@]}"; do
        line="${lines[$i]}"
        echo "----------------------------------------"
        info "正在尝试节点 [$((i+1)) / ${#lines[@]}] ..."
        [[ "$line" == vmess://* ]] || { warn "不支持的协议"; continue; }
        local srv port uuid aid net path host tls sni
        IFS=$'\t' read -r srv port uuid aid net path host tls sni <<< "$(parse_vmess "$line")" || continue
        [ -n "$srv" ] && [ -n "$port" ] && [ -n "$uuid" ] || { warn "字段解析不完整"; continue; }
        gen_config "$srv" "$port" "$uuid" "$aid" "$net" "$path" "$host" "$tls" "$sni"
        if test_proxy; then
            info "✅ 节点 [$((i+1))] 测试通过"
            echo "PROXY_SERVER=socks5://127.0.0.1:1080" >> "$GITHUB_ENV"
            ok=1; break
        else
            warn "❌ 节点 [$((i+1))] 连接失败"
        fi
    done
    [ $ok -eq 0 ] && { warn "❌ 所有节点测试失败，切换为直连模式！"; echo "PROXY_SERVER=" >> "$GITHUB_ENV"; }
}
main "$@"
EOF
