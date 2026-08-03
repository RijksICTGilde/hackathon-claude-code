#!/usr/bin/env bash
# Draai BINNEN de sandbox-container (met INSTALL_PODMAN=true gebouwd en de
# podman compose-override actief). Verifieert dat rootless Podman nested
# containers en een Testcontainers-build kan draaien.
set -euo pipefail

# Maven komt via SDKman, dat alleen in interactieve shells op PATH staat. Source
# het hier zodat dit script standalone werkt (niet alleen wanneer de caller het
# al deed). Strict-mode tijdelijk uit: de vendored init gebruikt unset-vars.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
    set +u; source "$HOME/.sdkman/bin/sdkman-init.sh"; set -u
fi
command -v mvn >/dev/null 2>&1 || { echo "FOUT: 'mvn' niet op PATH (installeer via 'sdk install maven')." >&2; exit 1; }

# Rootless podman heeft een schrijfbare XDG_RUNTIME_DIR nodig; in een container
# zonder systemd bestaat /run/user/<uid> vaak niet. Maak er zelf een.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/podman-run-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Single-uid of multi-uid? Bepaalt of PostgresSmokeTest meedraait: die vereist
# een tweede uid in de namespace (zie de noot in dat bestand).
if grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
    MULTIUID=true
else
    MULTIUID=false
fi

echo "== 1. podman info (rootless, multiuid=$MULTIUID) =="
podman info --format 'rootless={{.Host.Security.Rootless}} driver={{.Store.GraphDriverName}} uidmap={{.Host.IDMappings.UIDMap}}'

if [[ "$MULTIUID" == "true" ]]; then
    # Een gedegradeerd pause-proces laat podman single-uid draaien terwijl de
    # subuid-range er gewoon is. Dat faalt pas veel later, als een onbegrijpelijke
    # `chown: Invalid argument` in een DB-image — dus hier hard afvangen.
    podman info --format '{{.Host.IDMappings.UIDMap}}' | grep -q '} {' || {
        echo "FOUT: multi-uid staat aan, maar podman mapt maar één uid. Stale pause-proces:" \
             "draai 'podman system migrate' en herstart de podman-socket." >&2
        exit 1
    }
fi

echo "== 2. nested container =="
podman run --rm alpine:3.20 echo "nested-ok"

echo "== 3. podman socket =="
SOCK="${TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE:-$XDG_RUNTIME_DIR/podman/podman.sock}"
# De entrypoint start de socket al bij container-start (en legt daarmee de
# user-namespace vast). Draait hij, dan die gebruiken: een tweede service op
# hetzelfde pad kan niet binden én verwijdert bij het afsluiten de socket van de
# eerste, waarna Testcontainers terugvalt op /var/run/docker.sock en faalt.
if [ -S "$SOCK" ]; then
    echo "bestaande socket: $SOCK"
else
    echo "geen socket gevonden, zelf starten: $SOCK"
    mkdir -p "$(dirname "$SOCK")"
    podman system service --time=0 "unix://$SOCK" &
    SVC=$!
    trap 'kill "$SVC" 2>/dev/null || true' EXIT
    # Wachten tot de socket er is (max ~10s)
    for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
    [ -S "$SOCK" ] || { echo "FOUT: podman-socket kwam niet op" >&2; exit 1; }
fi

echo "== 4. Maven + Testcontainers =="
export DOCKER_HOST="unix://$SOCK"
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="$SOCK"
# Ryuk (resource-reaper) is in nested rootless setups vaak instabiel; daarom uit.
export TESTCONTAINERS_RYUK_DISABLED=true
# Rootless podman publisht gepublishte poorten op localhost, maar Testcontainers
# resolvet de container-host default als de netavark bridge-gateway (bv.
# 10.88.0.1) → port-wait timeouts op containers die op een poort wachten
# (Postgres, Redis, Quarkus Dev-Services). Deze smoke gebruikt een alpine zonder
# port-wait en zou het missen; echte builds hebben dit nodig. Bevestigd op een
# echt project (289+46 tests groen pas mét deze override).
export TESTCONTAINERS_HOST_OVERRIDE=localhost
cd "$(dirname "$0")/sample"
mvn -B --no-transfer-progress test "-Dpodman.multiuid=$MULTIUID"

if [[ "$MULTIUID" == "true" ]]; then
    echo "== OK — Testcontainers werkt (incl. Postgres) =="
else
    echo "== OK — Testcontainers werkt (single-uid; PostgresSmokeTest overgeslagen) =="
fi
