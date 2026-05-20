#!/usr/bin/env bash
#
# Launcher voor de Maven MCP-agent op de host. Voert alle stappen in één keer
# uit: venv klaarzetten, deps installeren, JAVA_HOME regelen en de agent starten
# voor een opgegeven Maven-project.
#
# Gebruik:
#   ./run.sh /pad/naar/jouw/maven-project
#   ./run.sh                 # zonder argument: huidige directory
#
# Overige instellingen blijven via env vars werken, bv:
#   MAVEN_AGENT_PORT=8888 MVN_TIMEOUT=900 ./run.sh /pad/...
set -euo pipefail

# Vanuit elke working directory werken: alles is relatief aan de scriptdir.
cd "$(dirname "$0")"

# --- Project-directory bepalen en valideren -------------------------------
PROJECT_DIR="${1:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd || true)"
if [[ -z "$PROJECT_DIR" ]]; then
    echo "ERROR: project-directory '${1:-$PWD}' bestaat niet." >&2
    exit 1
fi
if [[ ! -f "$PROJECT_DIR/pom.xml" ]]; then
    echo "ERROR: geen pom.xml in '$PROJECT_DIR' — is dit wel een Maven-project?" >&2
    exit 1
fi

# --- venv + deps ----------------------------------------------------------
# venv alleen aanmaken als hij ontbreekt; pip install draaien we altijd (snel
# als alles er al staat, en zo pikken we gewijzigde requirements vanzelf op).
if [[ ! -d .venv ]]; then
    echo "→ venv aanmaken (.venv)…"
    python3 -m venv .venv
fi
echo "→ deps installeren/controleren…"
.venv/bin/pip install --quiet -r requirements.txt

# --- JAVA_HOME ------------------------------------------------------------
# SDKman zet JAVA_HOME alleen in interactieve shells; source de init hier zodat
# Maven (of ./mvnw) een JVM vindt zonder dat je vanuit een SDKman-shell hoeft te
# starten. Bestaande JAVA_HOME respecteren we.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.sdkman/bin/sdkman-init.sh"
fi
if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "⚠️  JAVA_HOME is niet gezet en geen SDKman gevonden — Maven kan straks" \
         "geen JVM vinden. Zet JAVA_HOME of installeer een JDK via SDKman." >&2
fi

# --- Bind-adres -----------------------------------------------------------
# Op Linux Docker/Podman resolved host.docker.internal naar het bridge-IP, dus
# moet de agent op 0.0.0.0 luisteren om bereikbaar te zijn. Op Docker/Rancher
# Desktop (Mac/Windows) volstaat de default 127.0.0.1. Een al gezette
# MAVEN_AGENT_HOST respecteren we altijd.
if [[ -z "${MAVEN_AGENT_HOST:-}" && "$(uname -s)" == "Linux" ]]; then
    export MAVEN_AGENT_HOST="0.0.0.0"
    echo "⚠️  Linux gedetecteerd → bind op 0.0.0.0 zodat de container de agent via" \
         "het bridge-IP bereikt. Dit opent poort ${MAVEN_AGENT_PORT:-7777} op al je" \
         "interfaces. Op Docker/Rancher Desktop is dit onnodig: zet" \
         "MAVEN_AGENT_HOST=127.0.0.1." >&2
fi

# --- Starten --------------------------------------------------------------
echo "→ agent starten voor PROJECT_DIR=$PROJECT_DIR"
exec env PROJECT_DIR="$PROJECT_DIR" .venv/bin/python maven_agent.py
