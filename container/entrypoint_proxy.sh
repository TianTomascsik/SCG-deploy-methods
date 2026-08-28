#!/bin/bash
# Entrypoint for the proxy gateway container.
# Generates a TOML config and launches the gateway binary as an explicit proxy
# hop (transparent = false; no iptables rules are installed — see
# docker-compose.nginx-tproxy.yml for real transparent interception).
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

# Transparent TPROXY interception is not implemented in this topology; the
# producer addresses the gateway directly.

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
