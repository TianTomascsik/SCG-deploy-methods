#!/bin/bash
# Entrypoint for the SCG decrypt gateway in the TPROXY demo.
# Accepts incoming TLS connections from the encrypt gateway, strips TLS,
# and forwards plain HTTP to the NGINX backend.
set -e

LISTEN_PORT="${LISTEN_PORT:-8443}"
UPSTREAM_HOST="${UPSTREAM_HOST:-172.31.0.10}"
UPSTREAM_PORT="${UPSTREAM_PORT:-80}"
LOG_LEVEL="${LOG_LEVEL:-info}"
CONFIG_PATH="/etc/gateway/config.json"

echo "=== SCG TPROXY — Decrypt Gateway ==="
echo "  Listen:    0.0.0.0:${LISTEN_PORT} (TLS)"
echo "  Upstream:  ${UPSTREAM_HOST}:${UPSTREAM_PORT} (plain HTTP)"
echo "  Log level: ${LOG_LEVEL}"
echo "======================================"

# ─── Generate gateway config ───────────────────────────────────────────────────
mkdir -p "$(dirname "$CONFIG_PATH")"

cat > "$CONFIG_PATH" <<EOF
{
  "log_level": "${LOG_LEVEL}",
  "sock_buf_size": 16777216,
  "allow_unverified_transport": true,
  "policy": {
    "default_action": "allow",
    "whitelist": []
  },
  "rules": [
    {
      "name": "tproxy-decrypt",
      "direction": "decrypt",
      "listen_addr": "0.0.0.0:${LISTEN_PORT}",
      "listen_proto": "tcp",
      "upstream_addr": "${UPSTREAM_HOST}:${UPSTREAM_PORT}",
      "security_provider": "tls",
      "verify": "none",
      "transparent": false,
      "protocol_version": "tls1.3",
      "priority": 0
    }
  ]
}
EOF

echo "Generated config:"
cat "$CONFIG_PATH"
echo ""

# ─── Wait for upstream NGINX ───────────────────────────────────────────────────
echo "Waiting for NGINX at ${UPSTREAM_HOST}:${UPSTREAM_PORT}..."
for i in $(seq 1 30); do
    if timeout 1 bash -c "echo > /dev/tcp/${UPSTREAM_HOST}/${UPSTREAM_PORT}" 2>/dev/null; then
        echo "NGINX is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARNING: NGINX not ready after 30s, proceeding anyway"
    fi
    sleep 1
done

# ─── Launch gateway ────────────────────────────────────────────────────────────
echo "Starting SCG decrypt gateway..."
exec gateway --config "$CONFIG_PATH"
