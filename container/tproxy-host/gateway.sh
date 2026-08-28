#!/usr/bin/env bash
# gateway.sh — Toggle the host-network Docker demo between HTTP and HTTPS modes
#
# Usage:
#   ./gateway.sh up       # start nginx + gateway
#   ./gateway.sh start    # start/restart just the gateway (HTTPS)
#   ./gateway.sh stop     # stop just the gateway (HTTP)
#   ./gateway.sh status   # show current mode
#   ./gateway.sh logs     # follow gateway logs
#   ./gateway.sh down     # remove both demo containers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.nginx-host.yml"
GATEWAY_CONTAINER="scg_tproxy_gateway"
NGINX_CONTAINER="scg_tproxy_nginx_4200"

state() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "not-created"
}

wait_http() {
    for _ in $(seq 1 30); do
        if curl -fsS http://localhost:4200/ >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_https() {
    for _ in $(seq 1 30); do
        if curl -fsk https://localhost:4200/ >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

case "${1:-status}" in
    up)
        docker compose -f "$COMPOSE_FILE" up -d
        wait_https
        echo "HTTPS mode active: https://localhost:4200"
        ;;

    start)
        if [[ "$(state "$NGINX_CONTAINER")" = "not-created" ]]; then
            docker compose -f "$COMPOSE_FILE" up -d nginx
        elif [[ "$(state "$NGINX_CONTAINER")" != "running" ]]; then
            docker start "$NGINX_CONTAINER" >/dev/null
        fi

        docker start "$GATEWAY_CONTAINER" 2>/dev/null || docker compose -f "$COMPOSE_FILE" up -d scg-gateway
        wait_https
        echo "HTTPS mode active: https://localhost:4200"
        ;;

    stop)
        docker stop "$GATEWAY_CONTAINER"
        wait_http
        echo "HTTP mode active: http://localhost:4200"
        ;;

    status)
        NX="$(state "$NGINX_CONTAINER")"
        GW="$(state "$GATEWAY_CONTAINER")"
        echo "NGINX:   ${NX}"
        echo "Gateway: ${GW}"
        if [[ "$GW" = "running" ]]; then
            echo "Mode: HTTPS (https://localhost:4200)"
        elif [[ "$NX" = "running" ]]; then
            echo "Mode: HTTP (http://localhost:4200)"
        else
            echo "Mode: inactive"
        fi
        ;;

    logs)
        docker logs -f "$GATEWAY_CONTAINER"
        ;;

    down)
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        ;;

    *)
        echo "Usage: $0 {up|start|stop|status|logs|down}" >&2
        exit 1
        ;;
esac
