#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.nginx-host.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

cleanup() {
    info "Stopping demo containers..."
    docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup EXIT

info "Starting host-network nginx + SCG gateway demo..."
docker compose -f "$COMPOSE_FILE" up --build -d

info "Waiting for nginx to answer on plain HTTP 127.0.0.1:4200 from inside the backend container..."
for i in $(seq 1 60); do
    if docker exec scg_tproxy_nginx_4200 wget -qO- http://127.0.0.1:4200/ 2>/dev/null | grep -q "SCG TProxy Host Demo"; then
        pass "Backend nginx is serving on 127.0.0.1:4200"
        break
    fi
    if [ "$i" -eq 60 ]; then
        fail "Backend nginx did not become ready"
        docker compose -f "$COMPOSE_FILE" logs nginx
        exit 1
    fi
    sleep 1
done

info "Waiting for the gateway to install redirect rules and accept TLS on localhost:4200..."
for i in $(seq 1 60); do
    if curl -sk https://localhost:4200/ 2>/dev/null | grep -q "SCG TProxy Host Demo"; then
        pass "HTTPS interception works on https://localhost:4200"
        break
    fi
    if [ "$i" -eq 60 ]; then
        fail "Did not get the demo page through TLS interception"
        docker compose -f "$COMPOSE_FILE" logs scg-gateway
        exit 1
    fi
    sleep 1
done

info "Checking that plain HTTP from a non-root host process is no longer usable..."
set +e
HTTP_OUTPUT="$(curl -sS --max-time 5 http://localhost:4200/ 2>&1)"
HTTP_STATUS=$?
set -e
if [ "$HTTP_STATUS" -ne 0 ]; then
    pass "Plain HTTP is intercepted instead of being served directly"
else
    fail "Plain HTTP unexpectedly succeeded"
    printf '%s\n' "$HTTP_OUTPUT"
    exit 1
fi

info "Inspecting the presented certificate..."
TLS_INFO="$(echo | openssl s_client -connect localhost:4200 -servername localhost 2>/dev/null | grep -E 'subject=|Protocol|Cipher' || true)"
printf '%s\n' "$TLS_INFO"

info "Active redirect rules inside the host-network gateway container:"
docker exec scg_tproxy_gateway iptables -t nat -S SCG_ENCRYPT

echo
pass "Host TProxy nginx demo is ready."
echo "Browser check: https://localhost:4200"
echo "Accept the certificate warning once and you should see the demo page."
echo
info "Containers are still running for browser verification."
info "Stop them with: docker compose -f $COMPOSE_FILE down"

trap - EXIT
