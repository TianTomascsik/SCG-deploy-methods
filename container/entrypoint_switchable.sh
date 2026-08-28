#!/bin/bash
# Entrypoint for the SCG switchable gateway container.
# Launches the Python control server which manages HTTP/HTTPS toggling.
set -e

NGINX_HOST="${NGINX_HOST:-172.29.0.10}"
NGINX_PORT="${NGINX_PORT:-80}"
LISTEN_PORT="${LISTEN_PORT:-8080}"
CONTROL_PORT="${CONTROL_PORT:-9090}"

echo "=== SCG Switchable Gateway Demo ==="
echo "  NGINX:       ${NGINX_HOST}:${NGINX_PORT}"
echo "  Traffic:     port ${LISTEN_PORT}"
echo "  Control UI:  port ${CONTROL_PORT}"
echo "===================================="
echo ""

# Wait for NGINX to be reachable
echo "Waiting for NGINX at ${NGINX_HOST}:${NGINX_PORT}..."
for i in $(seq 1 30); do
    if timeout 1 bash -c "echo > /dev/tcp/${NGINX_HOST}/${NGINX_PORT}" 2>/dev/null; then
        echo "NGINX is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARNING: NGINX not ready after 30s, proceeding anyway"
    fi
    sleep 1
done

echo ""
echo "Starting control server..."
echo "  Control panel: http://localhost:${CONTROL_PORT}"
echo "  NGINX access:  http://localhost:${LISTEN_PORT}"
echo ""

exec python3 /app/control_server.py
