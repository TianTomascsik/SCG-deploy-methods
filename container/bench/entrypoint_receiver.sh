#!/bin/bash
# Entrypoint for the TLS receiver container.
# Listens for TLS connections and measures end-to-end latency.
set -e

PORT="${RECEIVER_PORT:-9443}"
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
EXPECTED_TESTS="${EXPECTED_TESTS:-0}"

ARGS="--port $PORT --log-dir $LOG_DIR --run-id $RUN_ID"

if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    ARGS="$ARGS --latency"
fi

if [ "$EXPECTED_TESTS" -gt 0 ] 2>/dev/null; then
    ARGS="$ARGS --expected-tests $EXPECTED_TESTS"
fi

echo "=== Benchmark Receiver ==="
echo "  Port:           $PORT"
echo "  Log dir:        $LOG_DIR"
echo "  Run ID:         $RUN_ID"
echo "  Expected tests: $EXPECTED_TESTS"
echo "=========================="

exec bench_receiver $ARGS
