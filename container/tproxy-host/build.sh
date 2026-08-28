#!/usr/bin/env bash
# Build the SCG host-network gateway OCI image and optionally a packaged demo
# nginx image, then export them as tar archives.
#
# Usage:
#   ./build.sh                        # Build + export scg-gateway.tar
#   ./build.sh --runtime docker       # Force Docker even if Podman is installed
#   ./build.sh --with-demo            # Also build/export scg-demo-nginx.tar
#   ./build.sh --no-export            # Build image(s) only (no tar)
#
# When podman is available, exports use OCI archive format.
# When only docker is available, exports use docker-archive format.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
IMAGE_NAME="scg-gateway"
IMAGE_TAG="latest"
TAR_NAME="scg-gateway.tar"
DEMO_IMAGE_NAME="scg-demo-nginx"
DEMO_TAR_NAME="scg-demo-nginx.tar"

NO_EXPORT=false
WITH_DEMO=false
RUNTIME_OVERRIDE="${CONTAINER_RUNTIME:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-export)
            NO_EXPORT=true
            shift
            ;;
        --with-demo)
            WITH_DEMO=true
            shift
            ;;
        --runtime)
            RUNTIME_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

echo "=== Building SCG Gateway OCI image ==="
echo "  Context:  $WORKSPACE_ROOT"
echo "  Image:    $IMAGE_NAME:$IMAGE_TAG"
if [ "$WITH_DEMO" = true ]; then
    echo "  Demo:     $DEMO_IMAGE_NAME:$IMAGE_TAG"
fi
echo ""

# Detect container runtime
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
echo "  Runtime:  $RUNTIME"

$RUNTIME build \
    -t "$IMAGE_NAME:$IMAGE_TAG" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$WORKSPACE_ROOT"

echo ""
echo "✓ Image built: $IMAGE_NAME:$IMAGE_TAG"

if [ "$WITH_DEMO" = true ]; then
    echo ""
    echo "=== Building packaged demo nginx image ==="
    $RUNTIME build \
        -t "$DEMO_IMAGE_NAME:$IMAGE_TAG" \
        -f "$SCRIPT_DIR/demo/Dockerfile" \
        "$SCRIPT_DIR/demo"
    echo "✓ Image built: $DEMO_IMAGE_NAME:$IMAGE_TAG"
fi

if [ "$NO_EXPORT" = false ]; then
    save_image() {
        local image_ref="$1"
        local tar_path="$2"
        if [ "$RUNTIME" = "podman" ]; then
            $RUNTIME save --format oci-archive -o "$tar_path" "$image_ref"
        else
            $RUNTIME save -o "$tar_path" "$image_ref"
        fi
    }

    echo ""
    echo "Exporting OCI image to $SCRIPT_DIR/$TAR_NAME ..."
    save_image "$IMAGE_NAME:$IMAGE_TAG" "$SCRIPT_DIR/$TAR_NAME"
    echo "✓ Exported: $SCRIPT_DIR/$TAR_NAME ($(du -h "$SCRIPT_DIR/$TAR_NAME" | cut -f1))"

    if [ "$WITH_DEMO" = true ]; then
        echo ""
        echo "Exporting packaged demo image to $SCRIPT_DIR/$DEMO_TAR_NAME ..."
        save_image "$DEMO_IMAGE_NAME:$IMAGE_TAG" "$SCRIPT_DIR/$DEMO_TAR_NAME"
        echo "✓ Exported: $SCRIPT_DIR/$DEMO_TAR_NAME ($(du -h "$SCRIPT_DIR/$DEMO_TAR_NAME" | cut -f1))"
    fi

    echo ""
    echo "Load on target machine with:"
    echo "  $RUNTIME load -i $TAR_NAME"
    if [ "$WITH_DEMO" = true ]; then
        echo "  $RUNTIME load -i $DEMO_TAR_NAME"
        echo ""
        echo "Then run the host demo with:"
        if [ "$RUNTIME" = "podman" ]; then
            echo "  sudo ./demo.sh load"
            echo "  sudo ./demo.sh up"
        else
            echo "  ./demo.sh load"
            echo "  ./demo.sh up"
        fi
    fi
fi
