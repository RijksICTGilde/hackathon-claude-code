#!/usr/bin/env bash
# PostgreSQL als proces in de sandbox, zonder container en zonder root.
#
# WAAROM: in single-uid rootless podman bestaat er precies één uid in de
# namespace (0). PostgreSQL weigert als uid 0 te draaien (vaste check in de
# server, geen flag om te overrulen), en elke andere uid is niet gemapt —
# `--user 999`, `--user 1000`, `--userns=keep-id:uid=999` en `--uidmap 999:0:1`
# falen allemaal (op `insufficient UIDs or GIDs available in user namespace`
# resp. `container ID 0 cannot be mapped to a host ID`). Postgres in een
# container en single-uid modus sluiten elkaar dus uit. Zie de
# "Openstaand"-sectie in README.md.
#
# Als proces is er geen probleem: `claude` is uid 1000, een doodgewone non-root
# uid. Geen userns, geen setuid-helper, geen subuid-range — dit verandert niets
# aan de isolatie van de sandbox.
#
# De binaries komen als Maven-artifact (Zonky's embedded-postgres-binaries: een
# tarball in een jar). Dat werkt zonder root, in tegenstelling tot
# `apt install postgresql`. De jar bevat alleen initdb/pg_ctl/postgres — geen
# psql of createdb; voor JDBC is dat genoeg.
#
# GEDRAG: `run` is met opzet gelijk aan Quarkus Dev Services — verse database
# per run, vrije poort, en opruimen na afloop (ook bij een gefaalde of
# afgebroken build). Draai je in plaats daarvan `start`, dan krijg je een
# blijvende server en is die garantie er niet; zie de waarschuwing daar.
#
# Draai dit BINNEN de sandbox.
#
#   ./postgres-lokaal.sh run -- ./mvnw clean test    verse DB, build, opruimen
#   ./postgres-lokaal.sh start [--env-only]          blijvende server
#   ./postgres-lokaal.sh stop | status | reset
set -euo pipefail

# Maven komt via SDKman, dat alleen in interactieve shells op PATH staat. Source
# het hier zodat dit script standalone werkt. Strict-mode tijdelijk uit: de
# vendored init gebruikt unset-vars.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
    set +u; source "$HOME/.sdkman/bin/sdkman-init.sh"; set -u
fi

PG_VERSIE="${PG_VERSIE:-18.0.0}"
PG_WACHTWOORD="${PG_WACHTWOORD:-postgres}"

BASIS="$HOME/.local/share/pg-embedded"
INSTALL_DIR="$BASIS/$PG_VERSIE"
# Blijvende data (`start`) staat apart van de wegwerp-data per `run`.
DATA_DIR="$BASIS/data-$PG_VERSIE"

# De Unix-socket moet in een KORT pad: postgres kapt af op 107 bytes, en een
# socket onder $HOME/.local/share/... haalt dat niet ("Unix-domain socket path
# is too long"). De tests verbinden over TCP; deze dir is voor pg_ctl zelf.
SOCKET_DIR="${PG_SOCKET_DIR:-/tmp/pgsock}"

env_only=false

# Bij --env-only moet stdout uitsluitend export-regels bevatten, zodat
# `eval "$(...)"` werkt. Alle voortgang gaat dan naar stderr.
melden() { if [[ "$env_only" == true ]]; then echo "$@" >&2; else echo "$@"; fi }

pg_bin() {
    local b="$INSTALL_DIR/bin/$1"; shift
    [[ -x "$b" ]] || { echo "FOUT: $b ontbreekt." >&2; exit 1; }
    "$b" "$@"
}

draait() {
    local d="$1"
    [[ -d "$d" ]] && "$INSTALL_DIR/bin/pg_ctl" -D "$d" status >/dev/null 2>&1
}

# Vrije poort zoeken, net als Dev Services doet. Vaste poort zou twee gelijktijdige
# builds (of een blijvende `start`-server) op elkaar laten botsen.
vrije_poort() {
    local p
    for _ in $(seq 1 50); do
        p=$(( 49152 + RANDOM % 16000 ))
        (echo >"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1 || { echo "$p"; return 0; }
    done
    echo "FOUT: geen vrije poort gevonden." >&2
    return 1
}

binaries_ophalen() {
    [[ -x "$INSTALL_DIR/bin/postgres" ]] && return 0

    local arch artifact
    arch="$(uname -m)"
    case "$arch" in
        x86_64)        artifact="embedded-postgres-binaries-linux-amd64" ;;
        aarch64|arm64) artifact="embedded-postgres-binaries-linux-arm64v8" ;;
        *) echo "FOUT: geen embedded-postgres-binaries bekend voor architectuur '$arch'." >&2; exit 1 ;;
    esac

    command -v mvn >/dev/null 2>&1 || { echo "FOUT: 'mvn' niet op PATH (sdk install maven)." >&2; exit 1; }

    melden "== binaries ophalen: $artifact:$PG_VERSIE =="
    mvn -B -q dependency:get -Dartifact="io.zonky.test.postgres:$artifact:$PG_VERSIE" 1>&2

    local jar="$HOME/.m2/repository/io/zonky/test/postgres/$artifact/$PG_VERSIE/$artifact-$PG_VERSIE.jar"
    [[ -f "$jar" ]] || { echo "FOUT: jar niet gevonden na download: $jar" >&2; exit 1; }

    local tmp; tmp="$(mktemp -d)"
    unzip -o -q "$jar" -d "$tmp"
    local txz
    txz="$(find "$tmp" -maxdepth 1 -name 'postgres-linux-*.txz' -print -quit)"
    [[ -n "$txz" ]] || { rm -rf "$tmp"; echo "FOUT: geen postgres-tarball in $jar" >&2; exit 1; }

    mkdir -p "$INSTALL_DIR"
    tar xf "$txz" -C "$INSTALL_DIR"
    rm -rf "$tmp"
    melden "   uitgepakt in $INSTALL_DIR"
}

cluster_aanmaken() {
    local data="$1"
    mkdir -p "$data"
    local pwfile; pwfile="$(mktemp)"
    printf '%s' "$PG_WACHTWOORD" > "$pwfile"
    # scram-sha-256 i.p.v. trust: de server luistert op localhost, maar in de
    # sandbox draaien ook agent-processen. Een wachtwoord kost hier niets.
    #
    # Uitvoer gaat naar een log en niet naar /dev/null: initdb is de stap die
    # stukloopt op een volle disk of een half-gevulde data-dir, en dan wil je de
    # reden zien in plaats van alleen een exit-code.
    local initlog; initlog="$(mktemp)"
    if ! pg_bin initdb -D "$data" -U postgres --auth=scram-sha-256 \
              --pwfile="$pwfile" -E UTF8 >"$initlog" 2>&1; then
        echo "FOUT: initdb faalde in $data:" >&2
        cat "$initlog" >&2
        rm -f "$pwfile" "$initlog"
        exit 1
    fi
    rm -f "$pwfile" "$initlog"
}

server_starten() {
    local data="$1" poort="$2" log="$3"
    mkdir -p "$SOCKET_DIR"
    # listen_addresses op 127.0.0.1: een testdatabase hoort niet buiten de
    # container bereikbaar te zijn, ook niet als de firewall al dichtstaat.
    if ! pg_bin pg_ctl -D "$data" \
              -o "-p $poort -k $SOCKET_DIR -c listen_addresses=127.0.0.1" \
              -l "$log" start >/dev/null; then
        echo "FOUT: postgres startte niet. Log:" >&2
        tail -20 "$log" >&2 || true
        exit 1
    fi
}

env_regels() {
    local poort="$1"
    # Dev Services schakelen zichzelf uit zodra er een jdbc.url staat; de vlag
    # staat er expliciet bij zodat uit de env leesbaar is wat er gebeurt.
    cat <<EOF
export QUARKUS_DATASOURCE_JDBC_URL="jdbc:postgresql://localhost:$poort/postgres"
export QUARKUS_DATASOURCE_USERNAME="postgres"
export QUARKUS_DATASOURCE_PASSWORD="$PG_WACHTWOORD"
export QUARKUS_DATASOURCE_DEVSERVICES_ENABLED="false"
EOF
}

# Opruimen bij élke uitgang, ook Ctrl-C of een gefaalde build: anders blijft er
# een postgres-proces en een data-dir achter, en dat is precies het verschil met
# Dev Services dat we hier niet willen hebben.
RUN_DATA=""
opruimen() {
    [[ -n "$RUN_DATA" ]] || return 0
    "$INSTALL_DIR/bin/pg_ctl" -D "$RUN_DATA" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$RUN_DATA"
    RUN_DATA=""
}

# `run` — het equivalent van Dev Services: verse database, vrije poort,
# opruimen na afloop, exit-code van het commando doorgeven.
draai_commando() {
    [[ $# -gt 0 ]] || { echo "FOUT: geen commando opgegeven. Gebruik: $0 run -- ./mvnw clean test" >&2; exit 1; }

    binaries_ophalen

    local poort log
    poort="$(vrije_poort)"
    mkdir -p "$BASIS"
    # RUN_DATA is bewust script-scope en geen `local`: de EXIT-trap draait nadat
    # deze functie is afgelopen, en zou een local dan niet meer kunnen lezen.
    RUN_DATA="$(mktemp -d "$BASIS/run-XXXXXX")"
    log="$RUN_DATA/postgres.log"
    trap opruimen EXIT INT TERM

    echo "== verse PostgreSQL $PG_VERSIE op poort $poort =="
    cluster_aanmaken "$RUN_DATA"
    server_starten "$RUN_DATA" "$poort" "$log"

    set +e
    ( eval "$(env_regels "$poort")"; "$@" )
    local code=$?
    set -e

    if [[ $code -ne 0 ]]; then
        echo "== commando faalde (exit $code) — postgres-log, laatste regels ==" >&2
        tail -20 "$log" >&2 || true
    fi
    return $code
}

starten() {
    binaries_ophalen
    local poort="${PG_POORT:-55432}"

    [[ -d "$DATA_DIR" ]] || { melden "== initdb (eerste keer) =="; cluster_aanmaken "$DATA_DIR"; }

    local log="$BASIS/postgres-$poort.log"
    if draait "$DATA_DIR"; then
        melden "== draait al =="
    else
        melden "== starten op poort $poort =="
        server_starten "$DATA_DIR" "$poort" "$log"
    fi

    if [[ "$env_only" == true ]]; then
        env_regels "$poort"
    else
        cat <<EOF

LET OP: deze server houdt zijn data vast over builds heen. Dev Services geeft
per run een verse database; dat doet '$0 run -- <commando>' ook. Gebruik 'start'
alleen bewust (bv. quarkus:dev), en 'reset' om schoon te beginnen.

Zet deze env-vars vóór je build:
$(env_regels "$poort" | sed 's/^/  /')

Log: $log
EOF
    fi
}

# Subcommando + vlaggen uitlezen. 'run' slikt alles na '--' als het commando.
cmd="${1:-run}"; shift || true
for arg in "$@"; do [[ "$arg" == "--env-only" ]] && env_only=true; done

case "$cmd" in
    run)
        [[ "${1:-}" == "--" ]] && shift
        draai_commando "$@" ;;
    start|--env-only)
        [[ "$cmd" == "--env-only" ]] && env_only=true
        starten ;;
    stop)
        if draait "$DATA_DIR"; then pg_bin pg_ctl -D "$DATA_DIR" -m fast stop; else echo "Draait niet."; fi ;;
    status)
        if draait "$DATA_DIR"; then echo "Draait (data: $DATA_DIR)"; else echo "Draait niet."; exit 1; fi ;;
    reset)
        read -r -p "Data in $DATA_DIR wissen? [j/N] " a
        case "$a" in
            j|J|ja|Ja) draait "$DATA_DIR" && pg_bin pg_ctl -D "$DATA_DIR" -m fast stop >/dev/null
                       rm -rf "$DATA_DIR"; echo "Gewist." ;;
            *) echo "Afgebroken."; exit 1 ;;
        esac ;;
    *)
        echo "Gebruik: $0 {run -- <commando>|start [--env-only]|stop|status|reset}" >&2; exit 1 ;;
esac
