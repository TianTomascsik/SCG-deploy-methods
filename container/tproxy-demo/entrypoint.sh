#!/bin/bash
# Entrypoint for the TPROXY demo gateway container.
# The gateway binary handles all iptables setup/teardown via its config.
# This script enables IP forwarding and adds any extra routes needed.

set -e

# Enable IP forwarding so traffic transits through this container.
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Load kTLS module if available (optional, for kTLS provider).
modprobe tls 2>/dev/null || true

# Add extra static routes if defined (space-separated "SUBNET via NEXTHOP" pairs).
# Example: EXTRA_ROUTES="172.30.2.0/24 via 172.30.0.2"
if [ -n "${EXTRA_ROUTES:-}" ]; then
    for route_spec in $EXTRA_ROUTES; do
        # Accumulate words until we see "via", then apply.
        :
    done
    # Simpler: treat it as a raw "ip route add" argument string.
    ip route replace $EXTRA_ROUTES 2>/dev/null || true
    echo "[entrypoint] Added route: $EXTRA_ROUTES"
fi

CONFIG="${GATEWAY_CONFIG:-/etc/scg/gateway.json}"

echo "=== SCG TPROXY Gateway ==="
echo "  Config: $CONFIG"
echo "=========================="

exec gateway --config "$CONFIG" --log-stdout
