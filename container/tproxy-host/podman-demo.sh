#!/usr/bin/env bash
# podman-demo.sh — Host-network demo control for OCI tar / Podman workflow
#
# Usage:
#   sudo ./podman-demo.sh load                # load local tar files into podman
#   sudo ./podman-demo.sh up                  # start nginx + gateway (HTTPS mode)
#   sudo ./podman-demo.sh start               # start/restart just the gateway
#   sudo ./podman-demo.sh stop                # stop just the gateway (HTTP mode)
#   sudo ./podman-demo.sh status              # show current mode
#   sudo ./podman-demo.sh logs                # follow gateway logs
#   sudo ./podman-demo.sh down                # remove both demo containers
#   sudo ./podman-demo.sh test-http           # verify plain HTTP mode
#   sudo ./podman-demo.sh test-https          # verify HTTPS mode
#
# Notes:
# - Run with rootful podman because host networking + NET_ADMIN are required.
# - Expects images/tars produced by ./build.sh --with-demo

set -euo pipefail

cd "$(dirname "$0")"

PODMAN="${PODMAN:-podman}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-scg-gateway:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-scg-demo-nginx:latest}"
GATEWAY_TAR="${GATEWAY_TAR:-./scg-gateway.tar}"
NGINX_TAR="${NGINX_TAR:-./scg-demo-nginx.tar}"
GATEWAY_CONTAINER="scg_tproxy_gateway"
NGINX_CONTAINER="scg_tproxy_nginx_4200"

require_podman() {
    if ! command -v "$PODMAN" >/dev/null 2>&1; then
        echo "ERROR: podman is not installed." >&2
        exit 1
    fi
}

warn_rootful() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "WARNING: rootful podman is typically required for host networking + NET_ADMIN." >&2
        echo "Try: sudo $0 ${1:-status}" >&2
    fi
}

container_state() {
    local name="$1"
    "$PODMAN" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "not-created"
}

wait_nginx_internal() {
    for _ in $(seq 1 30); do
        if "$PODMAN" exec "$NGINX_CONTAINER" wget -qO- http://127.0.0.1:4200/ >/dev/null 2>&1; then
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
        exited|configured|created)
            "$PODMAN" start "$NGINX_CONTAINER" >/dev/null
            ;;
        *)
            "$PODMAN" run -d \
                --name "$NGINX_CONTAINER" \
                --replace \
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
            "$PODMAN" restart "$GATEWAY_CONTAINER" >/dev/null
            ;;
        exited|configured|created)
            "$PODMAN" start "$GATEWAY_CONTAINER" >/dev/null
            ;;
        *)
            "$PODMAN" run -d \
                --name "$GATEWAY_CONTAINER" \
                --replace \
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
        "$PODMAN" stop "$GATEWAY_CONTAINER" >/dev/null
    fi

    if ! wait_http; then
        echo "ERROR: HTTP mode did not become available on http://localhost:4200" >&2
        exit 1
    fi
}

require_podman
warn_rootful "${1:-status}"

case "${1:-status}" in
    load)
        [[ -f "$NGINX_TAR" ]] || { echo "ERROR: missing $NGINX_TAR" >&2; exit 1; }
        [[ -f "$GATEWAY_TAR" ]] || { echo "ERROR: missing $GATEWAY_TAR" >&2; exit 1; }
        "$PODMAN" load -i "$NGINX_TAR"
        "$PODMAN" load -i "$GATEWAY_TAR"
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
        "$PODMAN" logs -f "$GATEWAY_CONTAINER"
        ;;

    down)
        "$PODMAN" rm -f "$GATEWAY_CONTAINER" "$NGINX_CONTAINER" >/dev/null 2>&1 || true
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
