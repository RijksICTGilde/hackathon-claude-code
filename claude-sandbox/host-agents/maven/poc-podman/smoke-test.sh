#!/usr/bin/env bash
# Draai BINNEN de sandbox-container (met INSTALL_PODMAN=true gebouwd en de
# podman compose-override actief). Bewijst dat rootless Podman nested containers
# en een Testcontainers-build kan draaien.
set -euo pipefail

# Rootless podman heeft een schrijfbare XDG_RUNTIME_DIR nodig; in een container
# zonder systemd bestaat /run/user/<uid> vaak niet. Maak er zelf een.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/podman-run-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "== 1. podman info (rootless) =="
podman info --format 'rootless={{.Host.Security.Rootless}} driver={{.Store.GraphDriverName}}'

echo "== 2. nested container =="
podman run --rm alpine:3.20 echo "nested-ok"

echo "== 3. podman socket service =="
SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"
mkdir -p "$(dirname "$SOCK")"
podman system service --time=0 "unix://$SOCK" &
SVC=$!
trap 'kill "$SVC" 2>/dev/null || true' EXIT
# Wachten tot de socket er is (max ~10s)
for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "FOUT: podman-socket kwam niet op" >&2; exit 1; }

echo "== 4. Maven + Testcontainers =="
export DOCKER_HOST="unix://$SOCK"
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="$SOCK"
# Ryuk (resource-reaper) is in nested rootless setups vaak instabiel; uit voor de PoC.
export TESTCONTAINERS_RYUK_DISABLED=true
cd "$(dirname "$0")/sample"
mvn -B --no-transfer-progress test

echo "== PoC GESLAAGD =="
