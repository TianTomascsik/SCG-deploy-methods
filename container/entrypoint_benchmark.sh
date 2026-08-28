#!/bin/bash
# Entrypoint for the benchmark producer/consumer container (2-container variant).
# Runs benchmarks with pipe output directed to the remote receiver.
set -e

RECEIVER_HOST="${RECEIVER_HOST:-receiver}"
RECEIVER_PORT="${RECEIVER_PORT:-9443}"
PIPE_TARGET="${RECEIVER_HOST}:${RECEIVER_PORT}"
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
BENCHMARKS="${BENCHMARKS:-tcp_raw udp_raw}"
PIPE_MODE="${PIPE_MODE:-tls}"  # tls, ktls, or none
KTLS_THREADS="${KTLS_THREADS:-}"
TLS_THREADS="${TLS_THREADS:-}"
INSTANCE="${INSTANCE:-0}"

if [ "$PIPE_MODE" != "none" ]; then
    # Wait for receiver to be ready
    echo "Waiting for receiver at ${PIPE_TARGET}..."
    for i in $(seq 1 30); do
        if timeout 1 bash -c "echo > /dev/tcp/${RECEIVER_HOST}/${RECEIVER_PORT}" 2>/dev/null; then
            echo "Receiver is ready."
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "ERROR: Receiver not ready after 30s"
            exit 1
        fi
        sleep 1
    done

    # Slight delay for receiver to fully initialize after TCP check
    sleep 1
else
    echo "Pipe mode: none — data will be received and dropped (no pipe)"
fi

echo "=== Benchmark Runner (2-container) ==="
echo "  Pipe mode:    $PIPE_MODE"
if [ "$PIPE_MODE" != "none" ]; then
    echo "  Pipe target:  $PIPE_TARGET"
fi
echo "  Benchmarks:   $BENCHMARKS"
echo "  Log dir:      $LOG_DIR"
echo "  Run ID:       $RUN_ID"
echo "========================================"

COMMON_ARGS="--log-dir $LOG_DIR --run-id $RUN_ID --instance $INSTANCE"

if [ "$PIPE_MODE" != "none" ]; then
    COMMON_ARGS="--pipe-target $PIPE_TARGET $COMMON_ARGS"
fi

if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
    COMMON_ARGS="$COMMON_ARGS --latency"
fi

PIPE_ARGS=""
if [ "$PIPE_MODE" = "ktls" ]; then
    PIPE_ARGS="--ktls"
    PIPE_ARGS="$PIPE_ARGS --ktls-threads ${KTLS_THREADS:-1}"
elif [ "$PIPE_MODE" = "tls" ]; then
    PIPE_ARGS="--tls"
    PIPE_ARGS="$PIPE_ARGS --tls-threads ${TLS_THREADS:-1}"
fi

if [ "$TCP_CORK" = "1" ] || [ "$TCP_CORK" = "true" ]; then
    PIPE_ARGS="$PIPE_ARGS --tcp-cork"
fi

run_bench() {
    local bench_name="$1"
    local binary="$2"
    local server_args="$3"
    local client_args="$4"

    echo ""
    echo "--- Running: $bench_name ---"

    # Build client-specific args (latency flag must match server)
    local client_extra=""
    if [ "$MEASURE_LATENCY" = "1" ] || [ "$MEASURE_LATENCY" = "true" ]; then
        client_extra="--latency"
    fi

    # Start server in background
    $binary server $server_args $COMMON_ARGS $PIPE_ARGS &
    local server_pid=$!
    sleep 0.5

    # Start client
    $binary client $client_args $client_extra
    local client_exit=$?

    # Wait for server to finish
    wait $server_pid 2>/dev/null || true

    if [ $client_exit -ne 0 ]; then
        echo "WARNING: $bench_name client exited with code $client_exit"
    fi

    echo "--- Finished: $bench_name ---"
    sleep 1
}

for bench in $BENCHMARKS; do
    case "$bench" in
        tcp_raw)
            run_bench "TCP Raw" bench_tcp "raw --server-addr 0.0.0.0" "raw --server-addr 127.0.0.1"
            ;;
        tcp_structured)
            run_bench "TCP Structured" bench_tcp "structured --server-addr 0.0.0.0" "structured --server-addr 127.0.0.1"
            ;;
        udp_raw)
            run_bench "UDP Raw" bench_udp "raw --server-addr 0.0.0.0" "raw --server-addr 127.0.0.1"
            ;;
        udp_structured)
            run_bench "UDP Structured" bench_udp "structured --server-addr 0.0.0.0" "structured --server-addr 127.0.0.1"
            ;;
        uds_raw)
            run_bench "UDS Raw" bench_uds "raw" "raw"
            ;;
        uds_structured)
            run_bench "UDS Structured" bench_uds "structured" "structured"
            ;;
        shm_ring)
            run_bench "SHM Ring" bench_shm "ring" "ring"
            ;;
        shm_seg)
            run_bench "SHM Seg" bench_shm "seg" "seg"
            ;;
        shm_seg_optimized)
            run_bench "SHM Seg Optimized" bench_shm "seg_optimized" "seg_optimized"
            ;;
        shm_seg_ktls)
            run_bench "SHM Seg kTLS" bench_shm "seg_ktls" "seg_ktls"
            ;;
        *)
            echo "Unknown benchmark: $bench"
            ;;
    esac
done

echo ""
echo "=== All benchmarks complete ==="
