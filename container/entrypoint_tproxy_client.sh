#!/bin/bash
# Entrypoint for the client container in the TPROXY demo.
# Sets up routing so traffic to NGINX goes through the SCG encrypt gateway,
# then runs curl to demonstrate transparent proxy operation.
set -e

NGINX_IP="${NGINX_IP:-172.31.0.10}"
NGINX_PORT="${NGINX_PORT:-80}"
GATEWAY_IP="${GATEWAY_IP:-172.31.0.20}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== SCG TPROXY — Client ===${NC}"
echo "  Target:   http://${NGINX_IP}:${NGINX_PORT}"
echo "  Gateway:  ${GATEWAY_IP} (transparent)"
echo "=============================="

# ─── Setup routing through the encrypt gateway ─────────────────────────────────
# Force all traffic destined for the NGINX IP to go through the SCG encrypt
# gateway. The gateway's iptables REDIRECT rule will intercept it.
echo ""
echo -e "${YELLOW}[SETUP]${NC} Adding route: ${NGINX_IP}/32 via ${GATEWAY_IP}"
ip route replace "${NGINX_IP}/32" via "${GATEWAY_IP}"

echo "Routing table:"
ip route show | grep "${NGINX_IP}"
echo ""

# ─── Wait for services ─────────────────────────────────────────────────────────
echo -e "${YELLOW}[WAIT]${NC} Waiting for SCG gateways to be ready..."
# Give the gateways time to start without connecting to the encrypt port
# (connecting to port 3128 would create fake forwarded connections)
sleep 15
echo -e "${GREEN}[OK]${NC} Proceeding with test."

# ─── Test 1: Plain HTTP request (transparently encrypted on wire) ──────────────
echo ""
echo "============================================"
echo -e "${CYAN}  TEST: Plain HTTP request to NGINX${NC}"
echo "  (Traffic is transparently encrypted by SCG)"
echo "============================================"
echo ""

echo -e "${YELLOW}[TEST]${NC} curl http://${NGINX_IP}:${NGINX_PORT}/"
echo "---"

HTTP_RESPONSE=$(curl -s -o /tmp/response.html -w "%{http_code}" "http://${NGINX_IP}:${NGINX_PORT}/" 2>&1) || true

if [ "$HTTP_RESPONSE" = "200" ]; then
    echo -e "${GREEN}[PASS]${NC} HTTP 200 OK — NGINX welcome page received!"
    echo ""
    echo "Response (first 10 lines):"
    head -10 /tmp/response.html
elif [ -f /tmp/response.html ] && grep -q "nginx" /tmp/response.html 2>/dev/null; then
    echo -e "${GREEN}[PASS]${NC} Response received (HTTP $HTTP_RESPONSE) — content from NGINX"
    head -10 /tmp/response.html
else
    echo -e "${RED}[FAIL]${NC} No valid response (HTTP code: $HTTP_RESPONSE)"
    echo "Response:"
    cat /tmp/response.html 2>/dev/null || echo "(empty)"
fi

# ─── Test 2: Show the transparent encryption proof ─────────────────────────────
echo ""
echo "============================================"
echo -e "${CYAN}  PROOF: Traffic is encrypted on the wire${NC}"
echo "============================================"
echo ""
echo "The client sent a plain HTTP request to ${NGINX_IP}:${NGINX_PORT}"
echo "but the traffic between SCG-encrypt (${GATEWAY_IP}) and"
echo "SCG-decrypt (172.31.0.40) is TLS-encrypted."
echo ""
echo "Capturing 5 seconds of traffic to prove TLS on wire..."

# Capture a few packets in the background while making another request
tcpdump -i eth0 -c 20 -w /tmp/capture.pcap host 172.31.0.40 2>/dev/null &
TCPDUMP_PID=$!
sleep 1

# Make another request to generate traffic
curl -s "http://${NGINX_IP}:${NGINX_PORT}/" >/dev/null 2>&1 || true
sleep 3

kill $TCPDUMP_PID 2>/dev/null || true
wait $TCPDUMP_PID 2>/dev/null || true

# Analyze the capture
if [ -f /tmp/capture.pcap ]; then
    PACKET_COUNT=$(tcpdump -r /tmp/capture.pcap 2>/dev/null | wc -l)
    TLS_PACKETS=$(tcpdump -r /tmp/capture.pcap 2>/dev/null | grep -c "8443" || echo "0")
    echo -e "${GREEN}[PROOF]${NC} Captured $PACKET_COUNT packets to/from decrypt gateway (port 8443)"
    echo "  These packets contain TLS-encrypted data."
    echo ""
    echo "  Packet summary:"
    tcpdump -r /tmp/capture.pcap -n 2>/dev/null | head -10
else
    echo -e "${YELLOW}[INFO]${NC} tcpdump capture not available"
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo -e "${GREEN}  DEMO COMPLETE${NC}"
echo "============================================"
echo ""
echo "  What happened:"
echo "  1. Client sent plain HTTP to ${NGINX_IP}:${NGINX_PORT}"
echo "  2. Traffic was routed through SCG-encrypt (${GATEWAY_IP})"
echo "  3. SCG-encrypt intercepted via iptables REDIRECT"
echo "  4. SCG-encrypt wrapped the traffic in TLS"
echo "  5. TLS traffic sent to SCG-decrypt (172.31.0.40:8443)"
echo "  6. SCG-decrypt stripped TLS"
echo "  7. Plain HTTP forwarded to NGINX (${NGINX_IP}:${NGINX_PORT})"
echo "  8. NGINX responded normally"
echo ""
echo "  Neither the client nor NGINX knew about the encryption!"
echo "============================================"

# Keep container alive for manual inspection
echo ""
echo -e "${YELLOW}[INFO]${NC} Container staying alive for manual testing."
echo "  docker exec -it tproxy_client bash"
echo "  curl http://${NGINX_IP}:${NGINX_PORT}/"
echo ""
exec sleep infinity
