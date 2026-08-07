#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

get_singbox() {
    info "获取 sing-box 最新版本..."
    local ver
    ver=$(curl -sL --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -oP '"tag_name": "\K[^"]+' || true)
    ver="${ver:-v1.13.16}"
    info "版本: $ver"
    local v="${ver#v}"
    curl -sL --max-time 60 "https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${v}-linux-amd64.tar.gz" | tar -xz -C /tmp "sing-box-${v}-linux-amd64/sing-box" 2>/dev/null || return 1
    mv "/tmp/sing-box-${v}-linux-amd64/sing-box" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
}

# 测试代理，测试通过后保留 sing-box 后台运行
test_proxy() {
    # 清理可能存在的旧进程
    if [ -f /tmp/sing-box.pid ]; then
        kill $(cat /tmp/sing-box.pid) 2>/dev/null || true
        rm -f /tmp/sing-box.pid
    fi
    
    nohup sing-box run -c /tmp/sb.json > /tmp/sb.log 2>&1 &
    local pid=$!
    echo "$pid" > /tmp/sing-box.pid
    disown $pid 2>/dev/null || true
    
    sleep 4
    
    local code
    code=$(curl -s --proxy socks5h://127.0.0.1:1080 --max-time 15 -o /dev/null -w "%{http_code}" "https://betadash.lunes.host/login" || true)
    
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ] || [ "$code" = "403" ]; then
        info "✅ 代理测试通过，sing-box 保留后台运行 (PID: $pid)"
        return 0
    fi
    
    warn "代理测试失败 (HTTP $code)，sing-box 日志:"
    cat /tmp/sb.log || true
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    rm -f /tmp/sing-box.pid
    return 1
}

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

    local lines=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        lines+=("$line")
    done <<< "$NODE_LINK"

    info "共检测到 ${#lines[@]} 个代理节点配置行，准备轮询测试..."

    local ok=0
    local i
    for i in "${!lines[@]}"; do
        line="${lines[$i]}"
        echo "----------------------------------------"
        info "正在尝试节点 [$((i+1)) / ${#lines[@]}] ..."

        if [[ "$line" != vmess://* ]]; then
            warn "不支持的协议: ${line:0:30}..."
            continue
        fi

        if ! python3 -c "
import sys, json, base64, re

url = sys.argv[1]
b64 = url.replace('vmess://', '')
b64 = b64.replace('-', '+').replace('_', '/')
pad = 4 - len(b64) % 4
if pad != 4:
    b64 += '=' * pad

try:
    data = json.loads(base64.b64decode(b64).decode('utf-8'))
except Exception as e:
    print(f'decode_error: {e}', file=sys.stderr)
    sys.exit(1)

srv = data.get('add', '')
port = int(data.get('port', 0))
uuid = data.get('id', '')
aid = int(data.get('aid', 0))
net = data.get('net', 'tcp')
path = data.get('path', '/')
host = data.get('host', '')
tls = data.get('tls', '')
sni = data.get('sni', '')

if not srv or not port or not uuid:
    print('missing_fields', file=sys.stderr)
    sys.exit(1)

max_early_data = 0
early_data_header_name = ''
m = re.search(r'^(.*?)\?ed=(\d+)$', path)
if m:
    path = m.group(1)
    max_early_data = int(m.group(2))
    early_data_header_name = 'Sec-WebSocket-Protocol'

outbound = {
    'type': 'vmess',
    'server': srv,
    'server_port': port,
    'uuid': uuid,
    'alter_id': aid,
    'security': 'auto',
    'packet_encoding': 'xudp',
    'global_padding': True,
    'tag': 'proxy'
}

if net == 'ws':
    ws_host = host if host else srv
    transport = {
        'type': 'ws',
        'path': path,
        'headers': {'Host': ws_host}
    }
    if max_early_data > 0:
        transport['max_early_data'] = max_early_data
        transport['early_data_header_name'] = early_data_header_name
    outbound['transport'] = transport

if tls == 'tls':
    tls_sni = sni if sni else (host if host else srv)
    outbound['tls'] = {
        'enabled': True,
        'server_name': tls_sni,
        'insecure': False
    }

config = {
    'log': {'level': 'warn'},
    'inbounds': [{'type': 'socks', 'listen': '127.0.0.1', 'listen_port': 1080}],
    'outbounds': [outbound]
}

with open('/tmp/sb.json', 'w') as f:
    json.dump(config, f, indent=2)

print(f'ok {srv}:{port} path={path} ed={max_early_data}')
" "$line"; then
            warn "VMess 解析失败，跳过该节点"
            continue
        fi

        if test_proxy; then
            info "✅ 节点 [$((i+1))] 测试通过"
            echo "PROXY_SERVER=socks5://127.0.0.1:1080" >> "$GITHUB_ENV"
            ok=1
            break
        else
            warn "❌ 节点 [$((i+1))] 连接失败"
        fi
    done

    if [ $ok -eq 0 ]; then
        warn "❌ 所有配置的代理节点均测试失败，自动切换为直连模式！"
        echo "PROXY_SERVER=" >> "$GITHUB_ENV"
        # 清理残留的 sing-box
        if [ -f /tmp/sing-box.pid ]; then
            kill $(cat /tmp/sing-box.pid) 2>/dev/null || true
            rm -f /tmp/sing-box.pid
        fi
    fi
}

main "$@"
