#!/bin/bash
# Entrypoint for the SCG encrypt gateway in the TPROXY demo.
# Sets up iptables REDIRECT to intercept traffic destined for NGINX,
# then launches the gateway in encrypt mode (transparent proxy).
set -e

LISTEN_PORT="${LISTEN_PORT:-3128}"
DECRYPT_HOST="${DECRYPT_HOST:-172.31.0.40}"
DECRYPT_PORT="${DECRYPT_PORT:-8443}"
NGINX_IP="${NGINX_IP:-172.31.0.10}"
NGINX_PORT="${NGINX_PORT:-80}"
LOG_LEVEL="${LOG_LEVEL:-info}"
CONFIG_PATH="/etc/gateway/config.json"

echo "=== SCG TPROXY — Encrypt Gateway ==="
echo "  Listen:      0.0.0.0:${LISTEN_PORT} (TPROXY intercept)"
echo "  Upstream:    ${DECRYPT_HOST}:${DECRYPT_PORT} (TLS)"
echo "  Intercept:   traffic to ${NGINX_IP}:${NGINX_PORT}"
echo "  Log level:   ${LOG_LEVEL}"
echo "======================================"

# ─── Enable IP forwarding ──────────────────────────────────────────────────────
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true

# ─── Setup iptables REDIRECT ──────────────────────────────────────────────────
# Intercept forwarded TCP traffic destined for NGINX and redirect it to the
# local gateway listen port: the client's connection to nginx:80 is redirected
# to the gateway's listen port.
echo "Setting up iptables rules..."

# Flush the entire built-in nat PREROUTING chain — this wipes any pre-existing
# rules there, which is acceptable only because this throwaway demo container
# owns its network namespace.
iptables -t nat -F PREROUTING 2>/dev/null || true

# Redirect forwarded traffic destined for nginx:80 to our local listen port
iptables -t nat -A PREROUTING -p tcp -d "${NGINX_IP}" --dport "${NGINX_PORT}" \
    -j REDIRECT --to-port "${LISTEN_PORT}"

echo "iptables rules:"
iptables -t nat -L PREROUTING -n -v

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
      "name": "tproxy-encrypt",
      "direction": "encrypt",
      "listen_addr": "0.0.0.0:${LISTEN_PORT}",
      "listen_proto": "tcp",
      "upstream_addr": "${DECRYPT_HOST}:${DECRYPT_PORT}",
      "security_provider": "tls",
      "verify": "none",
      "transparent": false,
      "protocol_version": "tls1.3",
      "priority": 0
    }
  ]
}
EOF

echo ""
echo "Generated config:"
cat "$CONFIG_PATH"
echo ""

# ─── Wait for decrypt gateway ──────────────────────────────────────────────────
echo "Waiting for decrypt gateway at ${DECRYPT_HOST}:${DECRYPT_PORT}..."
for i in $(seq 1 30); do
    if timeout 1 bash -c "echo > /dev/tcp/${DECRYPT_HOST}/${DECRYPT_PORT}" 2>/dev/null; then
        echo "Decrypt gateway is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARNING: Decrypt gateway not ready after 30s, proceeding anyway"
    fi
    sleep 1
done

# ─── Launch gateway ────────────────────────────────────────────────────────────
echo "Starting SCG encrypt gateway..."
exec gateway --config "$CONFIG_PATH"
