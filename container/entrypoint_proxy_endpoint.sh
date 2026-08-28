#!/bin/bash
# Entrypoint for the consumer/endpoint container in the transparent proxy setup.
# Listens on a port for incoming traffic — either plain TCP/UDP (encrypt test)
# or acts as a simple echo/sink for benchmarking.
set -e

ROLE="${ROLE:-consumer}"
LISTEN_PORT="${LISTEN_PORT:-9000}"
LISTEN_PROTO="${LISTEN_PROTO:-tcp}"
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
MEASURE_LATENCY="${MEASURE_LATENCY:-0}"

echo "=== Proxy Endpoint ($ROLE) ==="
echo "  Listen port: $LISTEN_PORT"
echo "  Protocol:    $LISTEN_PROTO"
echo "  Log dir:     $LOG_DIR"
echo "  Run ID:      $RUN_ID"
echo "==============================="

mkdir -p "$LOG_DIR"

LATENCY_FLAG=""
if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    LATENCY_FLAG="--latency"
fi

# Use bench_receiver as the consumer — it acts as a TLS-capable sink
# For the transparent proxy encrypt test, the consumer receives TLS traffic
# For the transparent proxy decrypt test, the consumer receives plain TCP/UDP
if [ "$LISTEN_PROTO" = "tcp" ]; then
    echo "Starting TCP receiver..."
    exec bench_receiver \
        --port "$LISTEN_PORT" \
        --log-dir "$LOG_DIR" \
        --run-id "$RUN_ID" \
        $LATENCY_FLAG
elif [ "$LISTEN_PROTO" = "udp" ]; then
    echo "Starting UDP receiver (socat sink)..."
    # Simple UDP sink: receive and discard, log byte counts
    exec socat -u UDP-LISTEN:"$LISTEN_PORT",fork,reuseaddr OPEN:/dev/null
else
    echo "ERROR: Unknown protocol: $LISTEN_PROTO"
    exit 1
fi
