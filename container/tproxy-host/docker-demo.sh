#!/usr/bin/env bash
# docker-demo.sh — Host-network demo control for Docker image tar workflow
#
# Usage:
#   ./docker-demo.sh load                # load local tar files into docker
#   ./docker-demo.sh up                  # start nginx + gateway (HTTPS mode)
#   ./docker-demo.sh start               # start/restart just the gateway
#   ./docker-demo.sh stop                # stop just the gateway (HTTP mode)
#   ./docker-demo.sh status              # show current mode
#   ./docker-demo.sh logs                # follow gateway logs
#   ./docker-demo.sh down                # remove both demo containers
#   ./docker-demo.sh test-http           # verify plain HTTP mode
#   ./docker-demo.sh test-https          # verify HTTPS mode
#
# Notes:
# - Expects images/tars produced by: ./build.sh --runtime docker --with-demo

set -euo pipefail

cd "$(dirname "$0")"

DOCKER="${DOCKER:-docker}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-scg-gateway:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-scg-demo-nginx:latest}"
GATEWAY_TAR="${GATEWAY_TAR:-./scg-gateway.tar}"
NGINX_TAR="${NGINX_TAR:-./scg-demo-nginx.tar}"
GATEWAY_CONTAINER="scg_tproxy_gateway"
NGINX_CONTAINER="scg_tproxy_nginx_4200"

require_docker() {
    if ! command -v "$DOCKER" >/dev/null 2>&1; then
        echo "ERROR: docker is not installed." >&2
        exit 1
    fi
}

container_state() {
    local name="$1"
    "$DOCKER" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "not-created"
}

wait_nginx_internal() {
    for _ in $(seq 1 30); do
        if "$DOCKER" exec "$NGINX_CONTAINER" wget -qO- http://127.0.0.1:4200/ >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_http() {
    for _ in $(seq 1 30); do
        if curl -fsS http://127.0.0.1:4200/ >/dev/null 2>&1; then
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

start_nginx_if_needed() {
    local state
    state="$(container_state "$NGINX_CONTAINER")"
    case "$state" in
        running)
            ;;
        exited|created)
            "$DOCKER" start "$NGINX_CONTAINER" >/dev/null
            ;;
        *)
            "$DOCKER" run -d \
                --name "$NGINX_CONTAINER" \
                --network host \
                "$NGINX_IMAGE" >/dev/null
            ;;
    esac

    if ! wait_nginx_internal; then
        echo "ERROR: nginx demo did not become ready on 127.0.0.1:4200 inside the host-network container" >&2
        exit 1
    fi
}

start_gateway() {
    local state
    state="$(container_state "$GATEWAY_CONTAINER")"
    case "$state" in
        running)
            "$DOCKER" restart "$GATEWAY_CONTAINER" >/dev/null
            ;;
        exited|created)
            "$DOCKER" start "$GATEWAY_CONTAINER" >/dev/null
            ;;
        *)
            "$DOCKER" run -d \
                --name "$GATEWAY_CONTAINER" \
                --network host \
                --privileged \
                --cap-add NET_ADMIN \
                --cap-add NET_RAW \
                "$GATEWAY_IMAGE" >/dev/null
            ;;
    esac

    if ! wait_https; then
        echo "ERROR: gateway did not expose https://localhost:4200" >&2
        exit 1
    fi
}

stop_gateway() {
    if [[ "$(container_state "$GATEWAY_CONTAINER")" = "running" ]]; then
        "$DOCKER" stop "$GATEWAY_CONTAINER" >/dev/null
    fi

    if ! wait_http; then
        echo "ERROR: HTTP mode did not become available on http://localhost:4200" >&2
        exit 1
    fi
}

require_docker

case "${1:-status}" in
    load)
        [[ -f "$NGINX_TAR" ]] || { echo "ERROR: missing $NGINX_TAR" >&2; exit 1; }
        [[ -f "$GATEWAY_TAR" ]] || { echo "ERROR: missing $GATEWAY_TAR" >&2; exit 1; }
        "$DOCKER" load -i "$NGINX_TAR"
        "$DOCKER" load -i "$GATEWAY_TAR"
        ;;

    up)
        start_nginx_if_needed
        start_gateway
        echo "HTTPS mode active: https://localhost:4200"
        ;;

    start)
        start_nginx_if_needed
        start_gateway
        echo "HTTPS mode active: https://localhost:4200"
        ;;

    stop)
        start_nginx_if_needed
        stop_gateway
        echo "HTTP mode active: http://localhost:4200"
        ;;

    status)
        NX="$(container_state "$NGINX_CONTAINER")"
        GW="$(container_state "$GATEWAY_CONTAINER")"
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
        "$DOCKER" logs -f "$GATEWAY_CONTAINER"
        ;;

    down)
        "$DOCKER" rm -f "$GATEWAY_CONTAINER" "$NGINX_CONTAINER" >/dev/null 2>&1 || true
        echo "Removed demo containers."
        ;;

    test-http)
        curl -fsS http://localhost:4200/ | grep -q "SCG TProxy Host Demo"
        echo "HTTP mode check passed."
        ;;

    test-https)
        curl -fsk https://localhost:4200/ | grep -q "SCG TProxy Host Demo"
        echo "HTTPS mode check passed."
        ;;

    *)
        echo "Usage: $0 {load|up|start|stop|status|logs|down|test-http|test-https}" >&2
        exit 1
        ;;
esac
