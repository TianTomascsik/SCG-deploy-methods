#!/bin/bash
# Entrypoint for the gateway container (receiver-decrypt mode).
# Accepts incoming TLS/kTLS connections, decrypts data, measures throughput/latency,
# and optionally forwards decrypted data to a downstream container.
set -e

PORT="${GATEWAY_PORT:-9443}"
DECRYPT_MODE="${DECRYPT_MODE:-tls}"  # tls or ktls
FORWARD_TARGET="${FORWARD_TARGET:-}" # empty = no forwarding, or "host:port"
FORWARD_PROTO="${FORWARD_PROTO:-tcp}" # tcp or udp
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
EXPECTED_TESTS="${EXPECTED_TESTS:-0}"

ARGS="gateway --port $PORT --log-dir $LOG_DIR --run-id $RUN_ID"

if [ "$DECRYPT_MODE" = "ktls" ]; then
    ARGS="$ARGS --ktls-decrypt"
fi

if [ -n "$FORWARD_TARGET" ]; then
    # Wait for downstream to be ready
    FWD_HOST=$(echo "$FORWARD_TARGET" | cut -d: -f1)
    FWD_PORT=$(echo "$FORWARD_TARGET" | cut -d: -f2)
    echo "Waiting for downstream at ${FORWARD_TARGET}..."
    for i in $(seq 1 30); do
        if timeout 1 bash -c "echo > /dev/tcp/${FWD_HOST}/${FWD_PORT}" 2>/dev/null; then
            echo "Downstream is ready."
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "WARNING: Downstream not ready after 30s, proceeding anyway"
        fi
        sleep 1
    done
    ARGS="$ARGS --forward-target $FORWARD_TARGET"
    if [ "$FORWARD_PROTO" = "udp" ]; then
        ARGS="$ARGS --forward-udp"
    fi
fi

if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    ARGS="$ARGS --latency"
fi

if [ "$EXPECTED_TESTS" -gt 0 ] 2>/dev/null; then
    ARGS="$ARGS --expected-tests $EXPECTED_TESTS"
fi

echo "=== Gateway (Receiver-Decrypt) ==="
echo "  Port:           $PORT"
echo "  Decrypt mode:   $DECRYPT_MODE"
echo "  Forward target: ${FORWARD_TARGET:-none}"
echo "  Forward proto:  $FORWARD_PROTO"
echo "  Log dir:        $LOG_DIR"
echo "  Run ID:         $RUN_ID"
echo "  Expected tests: $EXPECTED_TESTS"
echo "==================================="

exec bench_gateway $ARGS
