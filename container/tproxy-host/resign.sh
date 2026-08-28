#!/usr/bin/env bash
# resign.sh — Re-sign the SCG config files after editing them.
#
# Self-contained: uses only openssl (Ed25519 detached signatures, exactly the
# format the gateway's signed-config loader verifies: base64 of the raw
# signature over the exact file bytes, stored next to the file as <file>.sig).
#
# Usage:
#   ./resign.sh --key /path/to/key.pem       # Sign ./configs/ with that key
#   ./resign.sh --key K --config-dir DIR     # Sign a mounted host config dir
#   ./resign.sh --key K --validate           # Sign, then verify the result
#   ./resign.sh --validate-only              # Only verify (no key needed)
#
# The script:
#   1. Checks the schema SHA-256 pinned in scg.defaults.json matches the
#      on-disk schema
#   2. Signs scg.defaults.json and scg.user.json (Ed25519 detached .sig)
#   3. Optionally verifies both signatures against the trust anchor
#
# Generate a fresh keypair (keep the private key OUTSIDE the repository):
#   openssl genpkey -algorithm ed25519 -out /path/OUTSIDE/repo/signing.key.pem
#   openssl pkey -in /path/OUTSIDE/repo/signing.key.pem -pubout \
#     -out configs/trust/config-signing.pub.pem
#
# Full semantic validation (schema + signatures + rule semantics) is done by
# the gateway itself:  gateway --config-dir <DIR> --validate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- defaults ----------------------------------------------------------------
CONFIG_DIR="$SCRIPT_DIR/configs"
KEY_FILE=""
DO_VALIDATE=false
VALIDATE_ONLY=false

# --- parse args ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        --key)
            KEY_FILE="$2"
            shift 2
            ;;
        --validate)
            DO_VALIDATE=true
            shift
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- resolve paths ------------------------------------------------------------
CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"
DEFAULTS="$CONFIG_DIR/scg.defaults.json"
USER_CFG="$CONFIG_DIR/scg.user.json"
SCHEMA="$CONFIG_DIR/scg.lite.schema.json"
PUBKEY="$CONFIG_DIR/trust/config-signing.pub.pem"

# --- preflight checks --------------------------------------------------------
fail=false
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found" >&2; fail=true; }
for f in "$DEFAULTS" "$USER_CFG" "$SCHEMA"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: not found: $f" >&2
        fail=true
    fi
done
if [[ "$VALIDATE_ONLY" = false ]]; then
    if [[ -z "$KEY_FILE" ]]; then
        echo "ERROR: --key /path/to/signing.key.pem is required for signing." >&2
        echo "       The private key must live OUTSIDE the repository (see --help)." >&2
        fail=true
    elif [[ ! -f "$KEY_FILE" ]]; then
        echo "ERROR: private key not found: $KEY_FILE" >&2
        fail=true
    fi
fi
if [[ "$fail" = true ]]; then
    exit 2
fi

# --- schema hash check --------------------------------------------------------
schema_hash="$(openssl dgst -sha256 -r "$SCHEMA" | cut -d' ' -f1)"
if ! grep -q "\"schema_sha256\": \"$schema_hash\"" "$DEFAULTS"; then
    echo "ERROR: schema_sha256 pinned in $DEFAULTS does not match $SCHEMA" >&2
    echo "       on-disk schema hash: $schema_hash" >&2
    echo "       Update runtime.config_signing.schema_sha256, then re-run." >&2
    exit 3
fi
echo "Schema hash OK ($schema_hash)"

verify_one() {
    local f="$1" tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    if [[ ! -f "$f.sig" ]]; then
        echo "ERROR: signature file missing: $f.sig" >&2
        return 1
    fi
    openssl base64 -d -A -in "$f.sig" -out "$tmp"
    if openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$f" \
        -sigfile "$tmp" >/dev/null 2>&1; then
        echo "Signature OK: $f"
    else
        echo "ERROR: signature check FAILED for $f" >&2
        return 1
    fi
}

# --- validate only ------------------------------------------------------------
if [[ "$VALIDATE_ONLY" = true ]]; then
    echo "=== Verifying signed config ==="
    echo "  Config dir: $CONFIG_DIR"
    verify_one "$DEFAULTS"
    verify_one "$USER_CFG"
    echo "Verification passed. (Run 'gateway --config-dir $CONFIG_DIR --validate'"
    echo "for full schema + semantic validation.)"
    exit 0
fi

# --- sign ---------------------------------------------------------------------
echo "=== Signing SCG config files ==="
echo "  Config dir: $CONFIG_DIR"
echo "  Key:        $KEY_FILE"
for f in "$DEFAULTS" "$USER_CFG"; do
    openssl pkeyutl -sign -inkey "$KEY_FILE" -rawin -in "$f" \
        | openssl base64 -A > "$f.sig"
    echo "Signed: $f -> $f.sig"
done
echo "Config files signed successfully."

# --- optional validation after signing ----------------------------------------
if [[ "$DO_VALIDATE" = true ]]; then
    echo ""
    echo "=== Verifying signed config ==="
    verify_one "$DEFAULTS"
    verify_one "$USER_CFG"
    echo "Verification passed."
fi
