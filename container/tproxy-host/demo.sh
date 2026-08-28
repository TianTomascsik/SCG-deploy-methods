#!/usr/bin/env bash
# demo.sh — Host-network demo control for the image-tar workflow
#
# Usage:
#   ./demo.sh [--runtime docker|podman] <command>
#
# Commands:
#   load        load local tar files into the container runtime
#   up          start nginx + gateway (HTTPS mode)
#   start       start/restart just the gateway
#   stop        stop just the gateway (HTTP mode)
#   status      show current mode
#   logs        follow gateway logs
#   down        remove both demo containers
#   test-http   verify plain HTTP mode
#   test-https  verify HTTPS mode
#
# Notes:
# - Runtime auto-detect prefers podman, then docker (same as build.sh);
#   override with --runtime or the CONTAINER_RUNTIME env var.
# - With podman, run rootful (sudo) because host networking + NET_ADMIN are
#   required.
# - Expects images/tars produced by: ./build.sh --with-demo
#   (add --runtime docker to build.sh for the Docker variant)

set -euo pipefail

cd "$(dirname "$0")"

GATEWAY_IMAGE="${GATEWAY_IMAGE:-scg-gateway:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-scg-demo-nginx:latest}"
GATEWAY_TAR="${GATEWAY_TAR:-./scg-gateway.tar}"
NGINX_TAR="${NGINX_TAR:-./scg-demo-nginx.tar}"
GATEWAY_CONTAINER="scg_tproxy_gateway"
NGINX_CONTAINER="scg_tproxy_nginx_4200"

RUNTIME_OVERRIDE="${CONTAINER_RUNTIME:-}"
if [[ "${1:-}" = "--runtime" ]]; then
    RUNTIME_OVERRIDE="${2:-}"
    shift 2 || { echo "ERROR: --runtime needs an argument (docker|podman)." >&2; exit 1; }
fi

case "$RUNTIME_OVERRIDE" in
    "")
        if command -v podman &>/dev/null; then
            RUNTIME=podman
        elif command -v docker &>/dev/null; then
            RUNTIME=docker
        else
            echo "ERROR: Neither podman nor docker found." >&2
            exit 1
        fi
        ;;
    docker|podman)
        RUNTIME="$RUNTIME_OVERRIDE"
        if ! command -v "$RUNTIME" &>/dev/null; then
            echo "ERROR: Requested runtime '$RUNTIME' is not installed." >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: --runtime must be 'docker' or 'podman'." >&2
        exit 1
        ;;
esac

# Podman needs --replace to reuse a leftover container name; rootful is
# expected for host networking + NET_ADMIN.
RUN_FLAGS=()
if [[ "$RUNTIME" = "podman" ]]; then
    RUN_FLAGS=(--replace)
    if [[ "${EUID}" -ne 0 ]]; then
        echo "WARNING: rootful podman is typically required for host networking + NET_ADMIN." >&2
        echo "Try: sudo $0 ${1:-status}" >&2
    fi
fi

container_state() {
    local name="$1"
    "$RUNTIME" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "not-created"
}

wait_nginx_internal() {
    for _ in $(seq 1 30); do
        if "$RUNTIME" exec "$NGINX_CONTAINER" wget -qO- http://127.0.0.1:4200/ >/dev/null 2>&1; then
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
            "$RUNTIME" start "$NGINX_CONTAINER" >/dev/null
            ;;
        *)
            "$RUNTIME" run -d \
                --name "$NGINX_CONTAINER" \
                ${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"} \
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
            "$RUNTIME" restart "$GATEWAY_CONTAINER" >/dev/null
            ;;
        exited|configured|created)
            "$RUNTIME" start "$GATEWAY_CONTAINER" >/dev/null
            ;;
        *)
            "$RUNTIME" run -d \
                --name "$GATEWAY_CONTAINER" \
                ${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"} \
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
        "$RUNTIME" stop "$GATEWAY_CONTAINER" >/dev/null
    fi

    if ! wait_http; then
        echo "ERROR: HTTP mode did not become available on http://localhost:4200" >&2
        exit 1
    fi
}

case "${1:-status}" in
    load)
        [[ -f "$NGINX_TAR" ]] || { echo "ERROR: missing $NGINX_TAR" >&2; exit 1; }
        [[ -f "$GATEWAY_TAR" ]] || { echo "ERROR: missing $GATEWAY_TAR" >&2; exit 1; }
        "$RUNTIME" load -i "$NGINX_TAR"
        "$RUNTIME" load -i "$GATEWAY_TAR"
        ;;

    up|start)
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
        echo "Runtime: ${RUNTIME}"
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
        "$RUNTIME" logs -f "$GATEWAY_CONTAINER"
        ;;

    down)
        "$RUNTIME" rm -f "$GATEWAY_CONTAINER" "$NGINX_CONTAINER" >/dev/null 2>&1 || true
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
        echo "Usage: $0 [--runtime docker|podman] {load|up|start|stop|status|logs|down|test-http|test-https}" >&2
        exit 1
        ;;
esac
