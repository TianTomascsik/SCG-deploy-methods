#!/bin/bash
# Entrypoint for the transparent proxy gateway container.
# Sets up iptables TPROXY rules and launches the gateway binary with TOML config.
set -e

PIPE_MODE="${PIPE_MODE:-tls}"
CONFIG_PATH="${GATEWAY_CONFIG:-/etc/gateway/gateway.toml}"
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
MEASURE_LATENCY="${MEASURE_LATENCY:-0}"
CONSUMER_HOST="${CONSUMER_HOST:-172.30.0.10}"
CONSUMER_PORT="${CONSUMER_PORT:-9000}"
LISTEN_PORT="${LISTEN_PORT:-9000}"
PROTO="${PRODUCER_PROTO:-tcp}"

echo "=== Transparent Proxy Gateway ==="
echo "  Mode:          $PIPE_MODE"
echo "  Config:        $CONFIG_PATH"
echo "  Listen port:   $LISTEN_PORT"
echo "  Consumer:      $CONSUMER_HOST:$CONSUMER_PORT"
echo "  Protocol:      $PROTO"
echo "  Log dir:       $LOG_DIR"
echo "  Run ID:        $RUN_ID"
echo "=================================="

# ─── Load kernel modules ───────────────────────────────────────────────────────
modprobe tls 2>/dev/null || true

# ─── Sysctl tuning ─────────────────────────────────────────────────────────────
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem="4096 87380 16777216" >/dev/null 2>&1 || true

# ─── Generate TOML config automatically ────────────────────────────────────────
mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$LOG_DIR"

DIRECTION="encrypt"
LATENCY_CFG="false"
if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    LATENCY_CFG="true"
fi

cat > "$CONFIG_PATH" <<EOF
# Auto-generated gateway configuration
log_dir = "$LOG_DIR"
run_id = "$RUN_ID"
latency = $LATENCY_CFG
sock_buf_size = 16777216

[[rule]]
name = "${DIRECTION}-${PROTO}-${PIPE_MODE}"
direction = "$DIRECTION"
listen_addr = "0.0.0.0:${LISTEN_PORT}"
listen_proto = "$PROTO"
upstream_addr = "${CONSUMER_HOST}:${CONSUMER_PORT}"
tls_mode = "$PIPE_MODE"
priority = 0
transparent = false
EOF

echo "Generated config:"
cat "$CONFIG_PATH"
echo ""

# ─── Setup TPROXY iptables rules (optional, for transparent mode) ──────────────
# Uncomment these for fully transparent TPROXY mode:
#
# ip rule add fwmark 0x1 lookup 100 2>/dev/null || true
# ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
#
# if [ "$PROTO" = "tcp" ]; then
#     iptables -t mangle -A PREROUTING -p tcp --dport "$LISTEN_PORT" \
#         -j TPROXY --tproxy-mark 0x1/0x1 --on-port "$LISTEN_PORT" 2>/dev/null || true
# elif [ "$PROTO" = "udp" ]; then
#     iptables -t mangle -A PREROUTING -p udp --dport "$LISTEN_PORT" \
#         -j TPROXY --tproxy-mark 0x1/0x1 --on-port "$LISTEN_PORT" 2>/dev/null || true
# fi

# ─── Wait for consumer to be reachable ──────────────────────────────────────────
echo "Waiting for consumer at ${CONSUMER_HOST}:${CONSUMER_PORT}..."
for i in $(seq 1 30); do
    if timeout 1 bash -c "echo > /dev/tcp/${CONSUMER_HOST}/${CONSUMER_PORT}" 2>/dev/null; then
        echo "Consumer is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARNING: Consumer not ready after 30s, proceeding anyway"
    fi
    sleep 1
done

# ─── Launch gateway ────────────────────────────────────────────────────────────
ARGS="--config $CONFIG_PATH"
if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    ARGS="$ARGS --latency"
fi

echo "Starting gateway with: gateway $ARGS"
exec gateway $ARGS
