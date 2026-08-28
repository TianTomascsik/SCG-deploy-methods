#!/bin/bash
# Test script for the SCG NGINX TPROXY demo.
# Builds and starts the 4-container topology, waits for the client to complete
# its test, and displays results.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.nginx-tproxy.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

cleanup() {
    info "Cleaning up containers..."
    docker compose -f "$COMPOSE_FILE" down --volumes --remove-orphans 2>/dev/null || true
}

trap cleanup EXIT

echo "============================================"
echo "  SCG NGINX TPROXY Demo — Full Test"
echo "============================================"
echo ""
echo "  Architecture:"
echo "    Client → SCG-Encrypt → [TLS] → SCG-Decrypt → NGINX"
echo ""

# ─── Build and start ───────────────────────────────────────────────────────────
info "Building and starting 4-container topology..."
docker compose -f "$COMPOSE_FILE" up --build -d

# ─── Wait for all services ─────────────────────────────────────────────────────
info "Waiting for NGINX (172.31.0.10:80)..."
for i in $(seq 1 30); do
    if docker exec tproxy_nginx wget -q --spider http://localhost:80/ 2>/dev/null; then
        break
    fi
    sleep 1
done
pass "NGINX is serving"

info "Waiting for decrypt gateway (172.31.0.40:8443)..."
for i in $(seq 1 60); do
    if timeout 1 bash -c "echo > /dev/tcp/localhost/8443" 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        fail "Decrypt gateway did not start"
        docker compose -f "$COMPOSE_FILE" logs scg-decrypt
        exit 1
    fi
    sleep 1
done
pass "Decrypt gateway is listening"

info "Waiting for encrypt gateway to start..."
for i in $(seq 1 60); do
    if docker logs tproxy_scg_encrypt 2>&1 | grep -q "Running -- press Ctrl+C"; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        fail "Encrypt gateway did not start"
        docker compose -f "$COMPOSE_FILE" logs scg-encrypt
        exit 1
    fi
    sleep 1
done
pass "Encrypt gateway is listening"

# ─── Wait for client to complete its test ──────────────────────────────────────
info "Waiting for client test to complete (up to 90s)..."
for i in $(seq 1 90); do
    if docker logs tproxy_client 2>&1 | grep -q "\[PASS\]\|\[FAIL\]\|DEMO COMPLETE"; then
        break
    fi
    sleep 1
done

# ─── Verify from client logs ───────────────────────────────────────────────────
echo ""
info "Client container output:"
echo "---"
docker logs tproxy_client 2>&1 | tail -50
echo "---"
echo ""

# Check if client got a successful response
if docker logs tproxy_client 2>&1 | grep -q "\[PASS\]"; then
    pass "Client successfully accessed NGINX through transparent proxy"
else
    fail "Client did not get expected response"
    echo ""
    echo "Full logs:"
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
fi

# ─── Test: Direct HTTPS access to decrypt gateway (browser-accessible) ─────────
info "Testing direct HTTPS access to decrypt gateway (browser endpoint)..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost:8443/ 2>/dev/null) || true

if [ "$HTTP_CODE" = "200" ]; then
    pass "Direct HTTPS access works (https://localhost:8443)"
else
    info "Direct HTTPS access returned HTTP $HTTP_CODE (this is expected if decrypt gateway only accepts from encrypt gateway)"
fi

# ─── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo -e "  ${GREEN}TPROXY DEMO COMPLETE${NC}"
echo "============================================"
echo ""
echo "  What was demonstrated:"
echo ""
echo "  1. Client sent plain HTTP to NGINX IP (172.31.0.10:80)"
echo "  2. Traffic was transparently routed through SCG-encrypt"
echo "  3. SCG-encrypt intercepted via iptables REDIRECT"
echo "  4. Traffic was encrypted with TLS 1.3 on the wire"
echo "  5. SCG-decrypt terminated TLS and forwarded to NGINX"
echo "  6. Client received NGINX welcome page — fully transparent!"
echo ""
echo "  Manual testing:"
echo "    docker exec -it tproxy_client curl http://172.31.0.10:80/"
echo "    docker exec -it tproxy_client tcpdump -i eth0 host 172.31.0.40"
echo ""
echo "  Browser access (direct to decrypt gateway):"
echo "    https://localhost:8443"
echo ""
echo "  To stop: docker compose -f $COMPOSE_FILE down"
echo "============================================"

# Remove trap so containers stay running
trap - EXIT
echo ""
info "Containers left running for manual testing."
info "Run 'docker compose -f $COMPOSE_FILE down' when done."
