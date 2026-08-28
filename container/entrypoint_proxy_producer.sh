#!/bin/bash
# Entrypoint for the producer container in the transparent proxy setup.
# Sends plain TCP or UDP traffic to the gateway, which transparently encrypts it.
set -e

TARGET_HOST="${TARGET_HOST:-172.30.0.20}"
TARGET_PORT="${TARGET_PORT:-9000}"
PROTO="${PROTO:-tcp}"
MSG_SIZE="${MSG_SIZE:-1024}"
MSG_COUNT="${MSG_COUNT:-100000}"
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
MEASURE_LATENCY="${MEASURE_LATENCY:-0}"

echo "=== Proxy Producer ==="
echo "  Target:   $TARGET_HOST:$TARGET_PORT"
echo "  Protocol: $PROTO"
echo "  Msg size: $MSG_SIZE"
echo "  Msg count: $MSG_COUNT"
echo "  Log dir:  $LOG_DIR"
echo "  Run ID:   $RUN_ID"
echo "======================"

# Wait for gateway to be ready
echo "Waiting for gateway at ${TARGET_HOST}:${TARGET_PORT}..."
sleep 5  # Give gateway time to start

for i in $(seq 1 30); do
    if timeout 1 bash -c "echo > /dev/tcp/${TARGET_HOST}/${TARGET_PORT}" 2>/dev/null; then
        echo "Gateway is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARNING: Gateway not ready after 30s, proceeding anyway"
    fi
    sleep 1
done

# Use bench_tcp or bench_udp as the traffic generator
mkdir -p "$LOG_DIR"

LATENCY_FLAG=""
if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    LATENCY_FLAG="--latency"
fi

if [ "$PROTO" = "tcp" ]; then
    echo "Starting TCP traffic generator..."
    exec bench_tcp sender \
        --host "$TARGET_HOST" \
        --port "$TARGET_PORT" \
        --size "$MSG_SIZE" \
        --count "$MSG_COUNT" \
        --log-dir "$LOG_DIR" \
        --run-id "$RUN_ID" \
        $LATENCY_FLAG
elif [ "$PROTO" = "udp" ]; then
    echo "Starting UDP traffic generator..."
    exec bench_udp sender \
        --host "$TARGET_HOST" \
        --port "$TARGET_PORT" \
        --size "$MSG_SIZE" \
        --count "$MSG_COUNT" \
        --log-dir "$LOG_DIR" \
        --run-id "$RUN_ID" \
        $LATENCY_FLAG
else
    echo "ERROR: Unknown protocol: $PROTO"
    exit 1
fi
