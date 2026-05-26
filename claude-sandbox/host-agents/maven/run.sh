#!/usr/bin/env bash
#
# Launcher voor de Maven MCP-agent op de host. Voert alle stappen in één keer
# uit: venv klaarzetten, deps installeren, JAVA_HOME regelen en de agent starten
# voor een opgegeven Maven-project.
#
# Gebruik:
#   ./run.sh /pad/naar/jouw/maven-project
#
# Overige instellingen blijven via env vars werken, bv:
#   MAVEN_AGENT_PORT=8888 MVN_TIMEOUT=900 ./run.sh /pad/...
set -euo pipefail

# Caller-directory vastleggen vóór we naar de scriptdir springen, zodat een
# relatief project-pad klopt vanuit waar de gebruiker staat.
CALLER_PWD="$PWD"
cd "$(dirname "$0")"

# --- Project-directory bepalen en valideren -------------------------------
# Eerste argument is verplicht: het pad naar het Maven-project. Een impliciete
# default op $PWD verbergt teveel (verkeerde directory → onbegrijpelijke
# pom.xml-fout verderop), dus we eisen een expliciete keuze van de gebruiker.
if [[ $# -lt 1 ]]; then
    echo "ERROR: project-directory ontbreekt." >&2
    echo "Gebruik: $(basename "$0") /pad/naar/jouw/maven-project" >&2
    exit 2
fi
# Relatief pad oplossen vanuit de caller-directory, niet de scriptdir.
RAW_PROJECT_DIR="$1"
case "$RAW_PROJECT_DIR" in
    /*) ;;                                          # absoluut: laten staan
    *)  RAW_PROJECT_DIR="$CALLER_PWD/$RAW_PROJECT_DIR" ;;
esac
if [[ ! -e "$RAW_PROJECT_DIR" ]]; then
    echo "ERROR: project-directory '$RAW_PROJECT_DIR' bestaat niet." >&2
    exit 1
fi
if [[ ! -d "$RAW_PROJECT_DIR" ]]; then
    echo "ERROR: '$RAW_PROJECT_DIR' is geen directory." >&2
    exit 1
fi
PROJECT_DIR="$(cd "$RAW_PROJECT_DIR" && pwd)" || {
    echo "ERROR: kan '$RAW_PROJECT_DIR' niet betreden (permissies?)." >&2
    exit 1
}
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
# Quiet op de happy path; bij een fout opnieuw mét volledige output zodat de
# echte pip-diagnostiek zichtbaar is (de tweede run breekt af via set -e).
.venv/bin/pip install --quiet --require-hashes -r requirements.txt || {
    echo "→ deps faalden, opnieuw met volledige output:" >&2
    .venv/bin/pip install --require-hashes -r requirements.txt
}

# --- JAVA_HOME ------------------------------------------------------------
# SDKman wordt normaal via je shell-rc (.bashrc/.zshrc) geladen, en die draait
# alleen in interactieve shells. Een script ziet die rc niet, dus sourcen we de
# init hier expliciet zodat Maven (of ./mvnw) een JVM vindt zonder dat je vanuit
# een SDKman-shell hoeft te starten. Bestaande JAVA_HOME respecteren we.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
    # SDKman-init draait in déze shell; strict-mode tijdelijk uit omdat de
    # vendored init unset-vars en non-zero returns gebruikt voor normaal
    # gedrag. Exit-status capturen we vóór we strict-mode terugzetten, zodat
    # een echte fout (kapotte install, ontbrekend candidate-symlink) alsnog
    # zichtbaar wordt in plaats van te verdwijnen achter de tijdelijke
    # `set +euo pipefail`.
    set +euo pipefail
    # shellcheck disable=SC1091
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    SDKMAN_RC=$?
    set -euo pipefail
    if (( SDKMAN_RC != 0 )); then
        echo "⚠️  SDKman-init exit $SDKMAN_RC — JAVA_HOME wordt niet via SDKman" \
             "gezet; controleer ~/.sdkman of zet JAVA_HOME handmatig." >&2
    fi
fi
# Zonder JVM faalt Maven straks alsnog, met een onbegrijpelijke foutmelding
# diep in de agent. Veel distro's en Homebrew leveren echter een werkende
# `mvn` zonder geëxporteerde JAVA_HOME (de Apache-wrapper resolved `java` via
# PATH en `readlink`), dus we accepteren ook een `java` op PATH; pas als
# beide ontbreken stoppen we hard.
if [[ -z "${JAVA_HOME:-}" ]] && ! command -v java >/dev/null 2>&1; then
    echo "ERROR: geen JAVA_HOME gezet en geen 'java' op PATH gevonden." >&2
    echo "  Zet JAVA_HOME naar een JDK, of installeer er één via SDKman" \
         "('sdk install java')." >&2
    exit 1
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
         "interfaces en de agent heeft géén authenticatie — draai dit niet op een" \
         "onvertrouwd netwerk. Op Docker/Rancher Desktop is dit onnodig: zet" \
         "MAVEN_AGENT_HOST=127.0.0.1." >&2
fi

# --- Starten --------------------------------------------------------------
echo "→ agent starten voor PROJECT_DIR=$PROJECT_DIR"
exec env PROJECT_DIR="$PROJECT_DIR" .venv/bin/python maven_agent.py
