#!/bin/bash
#
# V2rayU Watchdog - 代理健康监控与自动修复
# 每 5 分钟执行一次，检测代理是否存活，不存活则自动刷新订阅并切换服务器
#

set -e

CONFIG_FILE="$HOME/.V2rayU/config.json"
LOG_FILE="$HOME/.V2rayU/watchdog.log"
SUB_URL="https://jmssub.net/members/getsub.php?service=1310320&id=f5b96e62-8b49-49cd-8922-ac0dc1b96618"
XRAY_BIN="/usr/local/v2rayu/bin/xray-core/xray-arm64"
SOCKS_PORT="1080"
HTTP_PORT="1087"
TEST_URL="https://www.google.com"
TEST_TIMEOUT=5
HEALTHY_FILE="$HOME/.V2rayU/.watchdog_healthy"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === 检测代理是否存活 ===
check_proxy() {
    # 尝试通过 HTTP 代理访问 Google
    if curl -x "http://127.0.0.1:${HTTP_PORT}" \
        -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$TEST_TIMEOUT" \
        --max-time "$TEST_TIMEOUT" \
        "$TEST_URL" 2>/dev/null | grep -q "200\|301\|302"; then
        return 0  # 存活
    fi

    # 再试 SOCKS5
    if curl -x "socks5://127.0.0.1:${SOCKS_PORT}" \
        -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$TEST_TIMEOUT" \
        --max-time "$TEST_TIMEOUT" \
        "$TEST_URL" 2>/dev/null | grep -q "200\|301\|302"; then
        return 0  # 存活
    fi

    return 1  # 死亡
}

# === 直连获取订阅（bypass proxy） ===
fetch_subscription() {
    log "fetching subscription via direct connection..."

    local raw
    raw=$(curl --noproxy "*" -s --connect-timeout 10 --max-time 15 "$SUB_URL" 2>/dev/null)

    if [ -z "$raw" ]; then
        log "ERROR: subscription fetch returned empty"
        return 1
    fi

    # base64 解码
    local decoded
    decoded=$(echo "$raw" | base64 -d 2>/dev/null)

    if [ -z "$decoded" ]; then
        log "ERROR: base64 decode failed, raw=${raw:0:50}..."
        return 1
    fi

    echo "$decoded"
    return 0
}

# === 从订阅中提取 VMess 服务器 ===
parse_vmess_servers() {
    local data="$1"
    local servers=""

    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        [ -z "$line" ] && continue

        # 只处理 vmess:// 链接
        if [[ "$line" != vmess://* ]]; then
            continue
        fi

        # 提取 base64 编码的 JSON
        local b64="${line#vmess://}"
        # 修复 base64 padding
        local pad=$(( (4 - ${#b64} % 4) % 4 ))
        b64="${b64}$(printf '%*s' $pad | tr ' ' '=')"

        local json
        json=$(echo "$b64" | base64 -d 2>/dev/null)
        if [ -z "$json" ]; then
            continue
        fi

        # 提取 address 和 port
        local addr
        addr=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('add',''))" 2>/dev/null)
        local port
        port=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('port',''))" 2>/dev/null)
        local ps
        ps=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ps',''))" 2>/dev/null)

        if [ -n "$addr" ] && [ -n "$port" ]; then
            servers="${servers}${addr}:${port}|${ps}\n"
        fi
    done <<< "$data"

    echo -e "$servers"
}

# === 测试服务器连通性 ===
test_servers() {
    local servers="$1"
    local working=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local addr="${line%%|*}"
        local remark="${line#*|}"
        local ip="${addr%:*}"
        local port="${addr#*:}"

        if nc -zv -w 3 "$ip" "$port" 2>/dev/null; then
            local latency
            latency=$(ping -c 1 -t 2 "$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/' | head -1)
            working="${working}${addr}|${latency:-999}\n"
        fi
    done <<< "$servers"

    echo -e "$working" | sort -t'|' -k2 -n
}

# === 生成新的 config.json ===
generate_config() {
    local working_servers="$1"
    local vnext=""
    local tags=""
    local count=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local addr="${line%%|*}"
        local ip="${addr%:*}"
        local port="${addr#*:}"

        count=$((count + 1))
        [ $count -gt 4 ] && break

        local idx=$count
        if [ $count -gt 1 ]; then
            vnext="${vnext},"
        fi

        vnext="${vnext}
            {
              \"address\": \"${ip}\",
              \"port\": ${port},
              \"users\": [
                {
                  \"alterId\": 0,
                  \"id\": \"f5b96e62-8b49-49cd-8922-ac0dc1b96618\",
                  \"security\": \"auto\"
                }
              ]
            }"

        if [ $count -gt 1 ]; then
            tags="${tags},"
        fi
        tags="${tags}\"proxy-${idx}\""
    done <<< "$working_servers"

    if [ $count -lt 1 ]; then
        log "ERROR: no working servers found"
        return 1
    fi

    log "found $count working servers, generating config..."

    cat > "$CONFIG_FILE" << JSONEOF
{
  "dns": {
    "queryStrategy": "UseIPv4",
    "servers": ["8.8.8.8", "1.1.1.1", {"address": "119.29.29.29", "domains": ["geosite:cn"]}]
  },
  "inbounds": [
    {"listen": "127.0.0.1", "port": "1087", "protocol": "http", "settings": {"timeout": 360}},
    {"listen": "127.0.0.1", "port": "1080", "protocol": "socks", "settings": {"auth": "noauth", "udp": true}},
    {"listen": "127.0.0.1", "port": "11111", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}, "tag": "metrics_in"}
  ],
  "log": {"access": "$HOME/.V2rayU/core.log", "error": "$HOME/.V2rayU/core.log", "loglevel": "info"},
  "metrics": {"tag": "metrics_out"},
  "observatory": {
    "probeInterval": "10s",
    "probeUrl": "http://www.gstatic.com/generate_204",
    "subjectSelector": [${tags}]
  },
  "outbounds": [
JSONEOF

    # Generate each outbound
    count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local addr="${line%%|*}"
        local ip="${addr%:*}"
        local port="${addr#*:}"

        count=$((count + 1))
        [ $count -gt 4 ] && break

        if [ $count -gt 1 ]; then
            echo "," >> "$CONFIG_FILE"
        fi

        cat >> "$CONFIG_FILE" << OUTEOF
    {
      "protocol": "vmess",
      "settings": {"vnext": [{"address": "${ip}", "port": ${port}, "users": [{"alterId": 0, "id": "f5b96e62-8b49-49cd-8922-ac0dc1b96618", "security": "auto"}]}]},
      "streamSettings": {"network": "tcp", "security": "none", "tcpSettings": {}},
      "tag": "proxy-${count}"
    }
OUTEOF
    done <<< "$working_servers"

    cat >> "$CONFIG_FILE" << JSONTAIL
    ,
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIP"}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {"response": {"type": "http"}}, "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "balancers": [{"tag": "balancer", "selector": [${tags}], "strategy": {"type": "random"}}],
    "rules": [
      {"inboundTag": ["metrics_in"], "outboundTag": "metrics_out", "type": "field"},
      {"domain": ["geosite:category-ads-all"], "outboundTag": "block", "type": "field"},
      {"domain": ["geosite:cn", "localhost", "*.itrus.com.cn", "192.168.*.*"], "outboundTag": "direct", "type": "field"},
      {"ip": ["geoip:private", "geoip:cn", "127.0.0.1"], "outboundTag": "direct", "type": "field"},
      {"network": "tcp,udp", "balancerTag": "balancer", "type": "field"}
    ]
  },
  "stats": {}
}
JSONTAIL

    return 0
}

# === 重启 xray-core ===
restart_xray() {
    log "restarting xray-core..."
    pkill -f "xray-arm64 run" 2>/dev/null || true
    sleep 1
    if pgrep -f "xray-arm64 run" > /dev/null; then
        log "WARNING: old xray still running, force killing..."
        pkill -9 -f "xray-arm64 run" 2>/dev/null || true
        sleep 1
    fi
    cd "$HOME/.V2rayU"
    nohup "$XRAY_BIN" run -c config.json > /dev/null 2>&1 &
    sleep 3

    if pgrep -f "xray-arm64 run" > /dev/null; then
        log "xray-core restarted successfully"
        return 0
    else
        log "ERROR: xray-core failed to start"
        return 1
    fi
}

# ======== MAIN ========

# 检查 xray 是否在运行
if ! pgrep -f "xray-arm64 run" > /dev/null; then
    log "xray-core not running, skip health check"
    exit 0
fi

# 检测代理健康
if check_proxy; then
    # 代理健康，记录心跳
    date +%s > "$HEALTHY_FILE" 2>/dev/null || true
    log "proxy healthy ✓"
    exit 0
fi

log "proxy DEAD - starting auto-recovery..."

# 获取最新订阅
SUB_DATA=$(fetch_subscription)
if [ $? -ne 0 ] || [ -z "$SUB_DATA" ]; then
    log "FATAL: cannot fetch subscription"
    exit 1
fi

log "subscription fetched, parsing servers..."

# 解析 VMess 服务器
SERVERS=$(parse_vmess_servers "$SUB_DATA")
if [ -z "$(echo "$SERVERS" | tr -d '[:space:]')" ]; then
    log "FATAL: no vmess servers found in subscription"
    exit 1
fi

# 测试连通性
log "testing server connectivity..."
WORKING=$(test_servers "$SERVERS")
if [ -z "$(echo "$WORKING" | tr -d '[:space:]')" ]; then
    log "FATAL: no working servers found"
    exit 1
fi

# 生成配置
if ! generate_config "$WORKING"; then
    log "FATAL: config generation failed"
    exit 1
fi

# 重启 xray
if restart_xray; then
    # 验证恢复
    sleep 2
    if check_proxy; then
        date +%s > "$HEALTHY_FILE" 2>/dev/null || true
        log "SUCCESS: proxy recovered!"
        # 通知 V2rayU 重新 ping
        exit 0
    else
        log "WARNING: xray restarted but proxy still not responding"
        exit 1
    fi
else
    log "FATAL: xray restart failed"
    exit 1
fi
