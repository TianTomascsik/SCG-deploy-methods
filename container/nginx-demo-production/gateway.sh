#!/usr/bin/env bash
# gateway.sh — Toggle between HTTPS (gateway) and HTTP (direct nginx) modes
#
# Usage:
#   ./gateway.sh up       → Start the stack (nginx + gateway in HTTPS mode)
#   ./gateway.sh start    → Start/restart just the gateway (switch to HTTPS)
#   ./gateway.sh stop     → Stop just the gateway (switch to HTTP)
#   ./gateway.sh status   → Show current mode
#   ./gateway.sh build    → Build the gateway image
#   ./gateway.sh logs     → Show gateway logs
#   ./gateway.sh down     → Tear down everything

set -euo pipefail
cd "$(dirname "$0")"

case "${1:-status}" in
  up)
    echo "→ Starting stack (nginx + gateway)..."
    docker compose up -d
    echo ""
    echo "✓ HTTPS mode active: https://localhost:8080"
    ;;

  start)
    echo "→ Starting gateway container..."
    docker start scg_nginx_gateway 2>/dev/null || docker compose up -d
    echo ""
    echo "✓ HTTPS mode active: https://localhost:8080"
    ;;

  stop)
    echo "→ Stopping gateway container..."
    docker stop scg_nginx_gateway
    echo ""
    echo "✓ HTTP mode active: http://localhost:8080"
    ;;

  status)
    GW=$(docker inspect --format='{{.State.Status}}' scg_nginx_gateway 2>/dev/null || echo "not running")
    NX=$(docker inspect --format='{{.State.Status}}' nginx_backend 2>/dev/null || echo "not running")
    echo "NGINX:   ${NX}"
    echo "Gateway: ${GW}"
    if [ "$GW" = "running" ]; then
      echo "→ Mode: HTTPS (https://localhost:8080)"
    elif [ "$NX" = "running" ]; then
      echo "→ Mode: HTTP (http://localhost:8080)"
    else
      echo "→ Mode: INACTIVE (nothing on port 8080)"
    fi
    ;;

  build)
    docker compose build scg-gateway
    ;;

  logs)
    docker logs -f scg_nginx_gateway
    ;;

  down)
    docker compose down
    echo "✓ All containers stopped and removed."
    ;;

  *)
    echo "Usage: $0 {up|start|stop|status|build|logs|down}"
    exit 1
    ;;
esac
