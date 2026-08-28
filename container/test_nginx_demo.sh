#!/bin/bash
# Test script for the SCG NGINX TLS termination demo.
# Builds and starts containers, verifies HTTPS access, then cleans up.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.nginx-demo.yml"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

cleanup() {
    info "Cleaning up containers..."
    docker compose -f "$COMPOSE_FILE" down --volumes --remove-orphans 2>/dev/null || true
}

# Cleanup on exit
trap cleanup EXIT

echo "============================================"
echo "  SCG NGINX Demo — TLS Termination Test"
echo "============================================"
echo ""

# ─── Build and start ───────────────────────────────────────────────────────────
info "Building and starting containers..."
docker compose -f "$COMPOSE_FILE" up --build -d

# ─── Wait for gateway to be ready ──────────────────────────────────────────────
info "Waiting for SCG gateway to start (port 8443)..."
for i in $(seq 1 60); do
    if timeout 1 bash -c "echo > /dev/tcp/localhost/8443" 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        fail "Gateway did not start within 60s"
        docker compose -f "$COMPOSE_FILE" logs scg-gateway
        exit 1
    fi
    sleep 1
done
pass "SCG gateway is listening on port 8443"

# ─── Test 1: HTTPS curl ────────────────────────────────────────────────────────
info "Testing HTTPS access with curl..."
HTTP_CODE=$(curl -sk -o /tmp/nginx_demo_response.html -w "%{http_code}" https://localhost:8443/ 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    pass "HTTPS request returned HTTP 200"
else
    fail "HTTPS request returned HTTP $HTTP_CODE (expected 200)"
    echo "Response body:"
    cat /tmp/nginx_demo_response.html 2>/dev/null
    exit 1
fi

# ─── Test 2: Verify NGINX content ─────────────────────────────────────────────
if grep -q "Welcome to nginx" /tmp/nginx_demo_response.html 2>/dev/null; then
    pass "Response contains NGINX welcome page"
else
    fail "Response does not contain expected NGINX content"
    cat /tmp/nginx_demo_response.html
    exit 1
fi

# ─── Test 3: TLS handshake info ───────────────────────────────────────────────
info "Checking TLS handshake..."
TLS_INFO=$(echo | openssl s_client -connect localhost:8443 2>/dev/null | grep -E "Protocol|Cipher|subject")

if echo "$TLS_INFO" | grep -qi "TLS"; then
    pass "TLS handshake successful"
    echo "$TLS_INFO" | head -5
else
    fail "TLS handshake failed"
    exit 1
fi

# ─── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo -e "  ${GREEN}ALL TESTS PASSED${NC}"
echo "============================================"
echo ""
echo "  You can now access the demo in your browser:"
echo ""
echo "    https://localhost:8443"
echo ""
echo "  (Accept the self-signed certificate warning)"
echo ""
echo "  The SCG gateway terminates TLS and forwards"
echo "  plain HTTP to the NGINX backend."
echo ""
echo "  To stop: docker compose -f $COMPOSE_FILE down"
echo "============================================"

# Remove trap so containers stay running for browser testing
trap - EXIT
echo ""
info "Containers left running for browser testing."
info "Run 'docker compose -f $COMPOSE_FILE down' when done."
