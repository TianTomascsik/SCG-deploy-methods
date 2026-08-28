#!/bin/bash
# Entrypoint for the consumer container (3-container variant).
# Receives IPC traffic from producer and pipes through TLS to receiver.
# In 3-container mode: Producer -> Consumer (this) -> Receiver
set -e

RECEIVER_HOST="${RECEIVER_HOST:-receiver}"
RECEIVER_PORT="${RECEIVER_PORT:-9443}"
PIPE_TARGET="${RECEIVER_HOST}:${RECEIVER_PORT}"
LOG_DIR="${LOG_DIR:-/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
PROTOCOL="${PROTOCOL:-tcp}"   # tcp, udp, uds, or shm
VARIANT="${VARIANT:-raw}"     # raw, structured, ring, seg, seg_optimized
SOCKET_DIR="${SOCKET_DIR:-/tmp/uds_shared}"
PIPE_MODE="${PIPE_MODE:-tls}" # tls, ktls, or none
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

    sleep 1
else
    echo "Pipe mode: none — data will be received and dropped (no pipe)"
fi

echo "=== Consumer Container (3-container) ==="
echo "  Protocol:     $PROTOCOL"
echo "  Variant:      $VARIANT"
echo "  Pipe mode:    $PIPE_MODE"
if [ "$PIPE_MODE" != "none" ]; then
    echo "  Pipe target:  $PIPE_TARGET"
fi
echo "  Socket dir:   $SOCKET_DIR"
echo "  Log dir:      $LOG_DIR"
echo "  Run ID:       $RUN_ID"
echo "=========================================="

# Build COMMON_ARGS based on protocol
COMMON_ARGS="--log-dir $LOG_DIR --run-id $RUN_ID --instance $INSTANCE"

if [ "$PIPE_MODE" != "none" ]; then
    COMMON_ARGS="--pipe-target $PIPE_TARGET $COMMON_ARGS"
fi

case "$PROTOCOL" in
    tcp|udp)
        COMMON_ARGS="$COMMON_ARGS --server-addr 0.0.0.0"
        ;;
    uds)
        COMMON_ARGS="$COMMON_ARGS --socket-dir $SOCKET_DIR"
        ;;
    shm)
        # SHM uses POSIX shared memory (IPC namespace), no network address needed
        ;;
    *)
        echo "ERROR: Unknown protocol '$PROTOCOL'. Use tcp, udp, uds, or shm."
        exit 1
        ;;
esac

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

BINARY="bench_${PROTOCOL}"

echo "Starting consumer server: $BINARY server $VARIANT $COMMON_ARGS $PIPE_ARGS"
exec $BINARY server $VARIANT $COMMON_ARGS $PIPE_ARGS
