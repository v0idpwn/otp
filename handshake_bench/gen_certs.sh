#!/usr/bin/env bash
# Generate self-signed certs/keys for the handshake benchmark.
# Produces:
#   certs/rsa4096.key + certs/rsa4096.crt
#   certs/ecdsa.key   + certs/ecdsa.crt   (P-256)
#
# Idempotent: skips generation if files already exist. Pass --force to regenerate.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$DIR/certs"
mkdir -p "$CERT_DIR"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

gen_rsa4096() {
    local key="$CERT_DIR/rsa4096.key" crt="$CERT_DIR/rsa4096.crt"
    if [[ $FORCE -eq 0 && -f "$key" && -f "$crt" ]]; then
        echo "rsa4096: already present, skipping"
        return
    fi
    echo "rsa4096: generating..."
    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$key" -out "$crt" \
        -days 365 -subj "/CN=hs-bench-rsa4096" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
}

gen_ecdsa() {
    local key="$CERT_DIR/ecdsa.key" crt="$CERT_DIR/ecdsa.crt"
    if [[ $FORCE -eq 0 && -f "$key" && -f "$crt" ]]; then
        echo "ecdsa: already present, skipping"
        return
    fi
    echo "ecdsa: generating P-256..."
    openssl req -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$key" -out "$crt" \
        -days 365 -subj "/CN=hs-bench-ecdsa" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
}

gen_rsa4096
gen_ecdsa
echo "certs written to $CERT_DIR"
