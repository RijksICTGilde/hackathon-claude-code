#!/usr/bin/env bash
# Draai op de HOST (niet in de container). Verifieert de
# Kepler-remote-opzet: een image gebouwd met INSTALL_SSHD=true, gestart met
# compose.override.kepler.yml. Zie README 'Kepler (SSH-remote)'.
#
#   ./kepler/smoke-test.sh -i ~/.ssh/kepler
#   ./kepler/smoke-test.sh -i ~/.ssh/kepler --podman   # gestapelde override
#
# Het script start niets op en bouwt niets: het test de container die al draait.
# Zo blijft het herhaalbaar tegen precies de opzet die je Kepler ook geeft.
set -euo pipefail

KEY=""
PORT=2222
HOST=127.0.0.1
CONTAINER=claude-sandbox
PODMAN=false
CLI=docker
EXPECT_NO_SSHD=false

usage() {
    cat <<'EOF'
Gebruik: smoke-test.sh -i <private-key> [opties]

  -i, --identity PAD   Private key die bij KEPLER_SSH_PUBKEY hoort (verplicht)
  -p, --port POORT     Host-poort van de sandbox-sshd (default 2222)
  -H, --host HOST      Host waar de poort op gepubliceerd is (default 127.0.0.1;
                       draait de sandbox in een VM: het VM-adres of tunnel-endpoint)
  -c, --container NAAM Container-naam (default claude-sandbox)
      --podman         Verwacht óók de podman-override (checkt /dev/net/tun en
                       de security-opts in de draaiende container)
      --cli CMD        Container-CLI voor ps/exec/port (default docker; bv. podman)
      --expect-no-sshd Keer de verwachting om: verifieert dat een container
                       ZONDER de Kepler-opzet geen sshd draait en geen poort
                       publiceert. Vereist geen key.
  -h, --help           Deze hulp
EOF
}

# Zonder deze check geeft een optie zonder waarde onder `set -u` een kale
# "$2: unbound variable" in plaats van de usage.
need_value() { [[ $# -ge 2 ]] || { echo "FOUT: $1 vereist een waarde." >&2; usage >&2; exit 2; }; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--identity)  need_value "$@"; KEY="$2"; shift 2 ;;
        -p|--port)      need_value "$@"; PORT="$2"; shift 2 ;;
        -H|--host)      need_value "$@"; HOST="$2"; shift 2 ;;
        -c|--container) need_value "$@"; CONTAINER="$2"; shift 2 ;;
        --podman)       PODMAN=true; shift ;;
        --expect-no-sshd) EXPECT_NO_SSHD=true; shift ;;
        --cli)          need_value "$@"; CLI="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "FOUT: onbekende optie '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

command -v "$CLI" >/dev/null || { echo "FOUT: container-CLI '$CLI' niet gevonden (zie --cli)." >&2; exit 2; }

if [[ "$EXPECT_NO_SSHD" != true ]]; then
    [[ -n "$KEY" ]] || { echo "FOUT: -i/--identity is verplicht (private key bij KEPLER_SSH_PUBKEY)." >&2; exit 2; }
    [[ -r "$KEY" ]] || { echo "FOUT: key '$KEY' niet leesbaar." >&2; exit 2; }
fi

# Op macOS met een Podman-machine bindt gvproxy de doorgezette poort alleen op
# IPv4, terwijl 'localhost' daar eerst naar ::1 resolvet → Connection refused op
# een opzet die verder helemaal goed staat. Waarschuw i.p.v. stil te falen.
if [[ "$HOST" == "localhost" ]]; then
    printf '  \033[33mLET OP\033[0m --host localhost: gebruik 127.0.0.1. Een doorgezette poort luistert vaak alleen op IPv4, en localhost resolvet eerst naar ::1.\n' >&2
fi

FAILCOUNT=0
FAILLIST=""
pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFOUT\033[0m %s\n' "$1"; FAILCOUNT=$((FAILCOUNT + 1)); FAILLIST="${FAILLIST}  - ${1}"$'\n'; }
section() { printf '\n== %s ==\n' "$1"; }

# Eigen, wegwerpbare known_hosts: we testen de sandbox, niet je
# known_hosts-hygiëne. De host-key staat op het volume en overleeft een rebuild,
# maar niet een volume-recreate.
KNOWN_HOSTS="$(mktemp)"
trap 'rm -f "$KNOWN_HOSTS"' EXIT

# BatchMode: nooit om een wachtwoord of passphrase vragen — een test die blijft
# hangen op een prompt is erger dan een test die faalt.
ssh_run() {
    ssh -i "$KEY" -p "$PORT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "claude@$HOST" "$@"
}

# Duur (ms) + exit-status van een commando, via de `time`-builtin. Geen externe
# tool nodig; `date +%s%N` en $EPOCHREALTIME ontbreken op de bash 3.2 van macOS.
# Echoot "<ms> <rc>", zodat de aanroeper een mislukte verbinding kan
# onderscheiden van een trage — een mislukte login is snel, en zou anders als
# "delay ontbreekt" gerapporteerd worden.
_timed() {
    # LC_NUMERIC=C: de `time`-builtin volgt de locale, en op een Nederlandse
    # host geeft %3R "0,412" — het decimaalteken weghalen levert dan geen getal
    # op en de rekenkundige expansie hieronder breekt het script af.
    local TIMEFORMAT=%3R LC_NUMERIC=C dur rc rcfile
    # De exit-status via een bestand: de `time`-meting draait in een command
    # substitution, dus een variabele die daarbinnen gezet wordt is buiten weg.
    rcfile="$(mktemp)" || { echo "FOUT: mktemp mislukt — geen schrijfbare tempdir." >&2; exit 2; }
    dur="$( { time { "$@" >/dev/null 2>&1; echo $? >"$rcfile"; } ; } 2>&1 )"
    rc="$(cat "$rcfile")"
    rm -f "$rcfile"
    # 10#: "0412" is anders octaal en telt fout.
    printf '%s %s\n' "$(( 10#${dur//[.,]/} ))" "$rc"
}
# Kale login-shell: GEEN commando (`ssh host < /dev/null`) → sshd draait de
# login-shell die /etc/zsh/zprofile sourcet (waar de Kepler-delay zit).
ssh_timed_login() {
    _timed ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=10 \
        "claude@$HOST" </dev/null
}
# Probe zoals Kepler: `zsh -c` sourcet GEEN zprofile, dus mag niet vertraagd zijn.
ssh_timed_probe() { _timed ssh_run "zsh -c true"; }

section "0. Container draait"
if "$CLI" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    pass "container '$CONTAINER' draait"
else
    echo "FOUT: container '$CONTAINER' draait niet. Start eerst (zie README 'Kepler (SSH-remote)')." >&2
    exit 1
fi

# De default-opzet — iedereen die Kepler niet gebruikt — hoort geen SSH te
# hebben. Zonder deze modus is dat pad alleen handmatig te controleren, en de
# fail-open-variant (image met INSTALL_SSHD=true, gestart zonder de override)
# ziet er van buiten uit als een gewone sandbox.
if [[ "$EXPECT_NO_SSHD" == true ]]; then
    section "SSH hoort uit te staan"
    if "$CLI" exec "$CONTAINER" sh -c 'command -v pgrep >/dev/null && ! pgrep -x sshd >/dev/null'; then
        pass "geen sshd-proces"
    else
        fail "sshd draait terwijl SSH uit hoort te staan — de start hoort achter ENABLE_SSHD te zitten, niet achter de aanwezigheid van de binary"
    fi
    if [[ -z "$("$CLI" port "$CONTAINER" 22 2>/dev/null || true)" ]]; then
        pass "poort 22 niet gepubliceerd"
    else
        fail "poort 22 is gepubliceerd terwijl SSH uit hoort te staan"
    fi
    # Een afwezigheid in de logs bewijst niets als er geen logs zijn: een
    # logdriver die lezen niet ondersteunt (journald, none) of een geroteerde
    # log geeft anders een PASS. Daarom eerst een canary die er altijd hoort te
    # staan.
    LOGS="$("$CLI" logs "$CONTAINER" 2>&1 || true)"
    if ! grep -q 'entrypoint OPEN_HTTPS:' <<<"$LOGS"; then
        fail "containerlogs bevatten de entrypoint-start niet (logdriver leest niet, of logs zijn geroteerd) — een sshd-start is hiermee NIET uit te sluiten"
    elif grep -qi 'sshd gestart' <<<"$LOGS"; then
        fail "containerlog meldt een sshd-start terwijl SSH uit hoort te staan"
    else
        pass "geen sshd-start in de containerlogs"
    fi
    section "Resultaat"
    if [[ "$FAILCOUNT" -eq 0 ]]; then
        echo "Alles groen — deze container draait geen SSH."
        exit 0
    fi
    echo "$FAILCOUNT check(s) gefaald:"
    printf '%s' "$FAILLIST"
    exit 1
fi

section "1. sshd aanwezig en gestart"
if "$CLI" exec "$CONTAINER" sh -c 'command -v sshd >/dev/null'; then
    pass "sshd in de image (INSTALL_SSHD=true)"
else
    echo "FOUT: geen sshd in de container — image is zonder INSTALL_SSHD=true gebouwd." >&2
    exit 1
fi
if "$CLI" exec "$CONTAINER" sh -c 'pgrep -x sshd >/dev/null'; then
    pass "sshd-proces draait"
else
    fail "sshd-proces draait niet — check de containerlogs op de WAARSCHUWING uit entrypoint-root.sh"
fi
# sshd hoort als root te draaien: hij start in de root-fase, vóór de
# privilege-drop. Een sshd als `claude` kan zijn privilege separation niet doen.
if "$CLI" exec "$CONTAINER" sh -c 'ps -o user= -p "$(pgrep -x sshd | head -1)" 2>/dev/null | grep -qw root'; then
    pass "sshd draait als root (gestart in de root-fase)"
else
    fail "sshd draait niet als root — hij hoort in entrypoint-root.sh te starten, vóór de privilege-drop"
fi

section '1b. Geen route naar root voor claude'
# Er hoort geen sudo en geen sudoers-drop-in in de image te zitten: sshd start
# in de root-fase, vóór de privilege-drop. Een sudoers-regel of een setuid-
# binary maakt die drop betekenisloos.
if "$CLI" exec "$CONTAINER" sh -c '! command -v sudo >/dev/null'; then
    pass "geen sudo-binary in de image"
else
    fail "sudo is terug in de image — claude heeft daarmee mogelijk weer een pad naar root"
fi
if "$CLI" exec "$CONTAINER" sh -c '! ls -A /etc/sudoers.d 2>/dev/null | grep -q .'; then
    pass "geen sudoers-drop-ins"
else
    fail "/etc/sudoers.d is niet leeg — sshd hoort in de root-fase te starten, niet via sudo"
fi
if "$CLI" exec "$CONTAINER" sh -c \
    'test -z "$(find / -xdev -type f -perm -4000 ! -name newuidmap ! -name newgidmap 2>/dev/null)"'; then
    pass "geen setuid-binaries buiten newuidmap/newgidmap"
else
    fail "setuid-root-binary aangetroffen — de setuid-strip in de Dockerfile draait niet ná alle apt-installs"
fi

section "2. Poortbinding — alleen loopback"
# De belangrijkste security-assertie van deze opzet: de SSH-poort mag nooit op
# 0.0.0.0/:: staan. Publiceren op een wildcard-adres zet een agent-shell open
# voor het hele netwerk. Positief asserten, niet de wildcards uitsluiten: een
# LAN-adres als 192.168.64.2 is geen wildcard en zou anders slagen.
BINDING="$("$CLI" port "$CONTAINER" 22 || true)"
if [[ -z "$BINDING" ]]; then
    fail "poort 22 niet gepubliceerd — draai je met compose.override.kepler.yml?"
elif grep -qE '^(127\.[0-9.]+|\[::1\]):' <<<"$BINDING"; then
    pass "poort alleen op loopback ($BINDING)"
else
    fail "poort niet op loopback gepubliceerd ($BINDING) — MOET 127.0.0.1 zijn"
fi

section "3. SSH-login met key"
if ssh_run 'echo ok' >/dev/null 2>&1; then
    pass "login als 'claude' met pubkey"
else
    echo "FOUT: SSH-login mislukt op $HOST:$PORT. Draai 'ssh -v -i $KEY -p $PORT claude@$HOST' voor de reden." >&2
    echo "  - 'Permission denied (publickey)' → key hoort niet bij KEPLER_SSH_PUBKEY; check .env en de entrypoint-logs." >&2
    echo "  - 'Connection refused' terwijl de poort gepubliceerd is → probeer 127.0.0.1 i.p.v. een hostnaam (IPv4-only forward)." >&2
    exit 1
fi
# StrictModes weigert een authorized_keys die de inlogger niet bezit. Los
# asserten, want anders komt die regressie binnen als een generieke
# "login mislukt" en zoekt iedereen aan de verkeerde kant.
if "$CLI" exec -u claude "$CONTAINER" sh -c \
    'test -O ~/.ssh/authorized_keys && [ "$(stat -c %a ~/.ssh/authorized_keys)" = 600 ] && [ "$(stat -c %a ~/.ssh)" = 700 ]'; then
    pass "authorized_keys van claude, 600 in een 700-directory"
else
    fail "authorized_keys heeft verkeerde eigenaar of rechten — StrictModes weigert 'm; het bestand hoort in de gebruikersfase geschreven te worden (entrypoint.sh), niet in de root-fase"
fi

section "4. PATH in een non-interactieve sessie"
# Het scenario dat in de praktijk breekt: een SSH-sessie erft de Docker `ENV PATH`
# niet, dus `claude` (in ~/.local/bin) is "command not found" tenzij de PATH-fix
# in /etc/zsh/zshenv pakt. Alle drie de vormen lopen via de login-shell zsh en
# dekken dus diezelfde fix; ze tonen dat Keplers shellkeuze niet uitmaakt.
for shell_desc in \
    "default-shell:command -v claude" \
    "zsh -c:zsh -c 'command -v claude'" \
    "sh -c:sh -c 'command -v claude'"
do
    desc="${shell_desc%%:*}"; cmd="${shell_desc#*:}"
    if ssh_run "$cmd" >/dev/null 2>&1; then
        pass "claude op PATH via $desc"
    else
        fail "claude NIET op PATH via $desc — Kepler faalt als het deze shell-vorm gebruikt"
    fi
done
if VERSION="$(ssh_run 'claude --version' 2>/dev/null)"; then
    pass "claude uitvoerbaar over SSH ($VERSION)"
else
    fail "'claude --version' mislukt over SSH"
fi

section "5. Hardening — de effectieve serverconfig"
# Via `sshd -T` (de config zoals sshd hem toepast), niet via een ssh-poging: een
# client met BatchMode=yes biedt wachtwoord-auth sowieso niet aan, en root wordt
# al door AllowUsers geweigerd. Zulke pogingen falen dus ook op een server
# zonder hardening — ze bewijzen niets.
EFFECTIVE="$("$CLI" exec "$CONTAINER" sshd -T 2>/dev/null || true)"
if [[ -z "$EFFECTIVE" ]]; then
    fail "'sshd -T' gaf geen output — config onleesbaar of sshd niet in de image"
else
    for directive in \
        'passwordauthentication no' \
        'kbdinteractiveauthentication no' \
        'permitrootlogin no' \
        'pubkeyauthentication yes' \
        'allowusers claude' \
        'allowagentforwarding no' \
        'x11forwarding no' \
        'permituserrc no' \
        'permittunnel no' \
        'gatewayports no'
    do
        if grep -qix "$directive" <<<"$EFFECTIVE"; then
            pass "$directive"
        else
            fail "$directive staat niet zo in de effectieve config — check /etc/ssh/sshd_config.d/kepler.conf"
        fi
    done
fi
# Gedragscheck bovenop de config: een login als root moet echt stuklopen.
if ! ssh -i "$KEY" -p "$PORT" -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 "root@$HOST" 'echo nope' >/dev/null 2>&1; then
    pass "root-login geweigerd"
else
    fail "root-login ACCEPTEERT — PermitRootLogin/AllowUsers staan niet goed in sshd_config.d/kepler.conf"
fi

section "6. Burst — geen per-bron-straf na mislukte auth"
# Regressie-guard voor PerSourcePenalties (afweging: README 'Kepler
# (SSH-remote)'). Een burst en niet één login, want gespreide calls maken het gat
# onzichtbaar: sectie 5 deed net een authfail vanaf deze bron, en staat de straf
# nog aan, dan sneuvelt juist een reeks snelle legitieme logins.
# Parallel, want dat is ook wat Kepler doet (meerdere kanalen tegelijk) — en het
# maakt de burst een burst in plaats van een reeks gespreide logins.
BURST=5
bfail=0
burst_pids=()
for _ in $(seq 1 "$BURST"); do
    ssh_run true >/dev/null 2>&1 &
    burst_pids+=($!)
done
for pid in "${burst_pids[@]}"; do
    wait "$pid" || bfail=$((bfail + 1))
done
if [[ "$bfail" -eq 0 ]]; then
    pass "$BURST/$BURST snelle logins na authfails geslaagd (geen per-bron-straf)"
else
    fail "$bfail/$BURST snelle logins geweigerd — PerSourcePenalties straft legitieme clients achter de NAT (zet 'PerSourcePenalties no' in sshd_config.d/kepler.conf)"
fi

section "7. Kepler tunnel-race workaround actief"
# Kepler zet een SSH ControlMaster op en draait de tunnel als `ssh -N -L`
# mux-slave; die exit binnen ~10-30 ms nadat de forward aan de master is
# overgedragen. Keplers readiness-poll ziet dat child-exit als fataal en gooit
# vóór z'n poort-check → "ssh exited before the tunnel ... was ready (code 0)",
# terwijl de forward werkt. Een Kepler-bug (server-onafhankelijk). De sandbox
# rekt daarom de fantoom-login-shell die de mux-slave opent (/etc/zsh/zprofile:
# `sleep` voor non-interactieve login-shells), zodat Keplers eerste poll de
# al-klare poort pakt vóór het child exit. We meten dat: een kale login-shell
# (geen commando → sourcet zprofile) moet merkbaar vertraagd zijn; de `zsh -c`
# probe (sectie 4) mag dat NIET zijn.
read -r LOGIN_MS LOGIN_RC <<<"$(ssh_timed_login)"
read -r PROBE_MS PROBE_RC <<<"$(ssh_timed_probe)"
if [[ ! "$LOGIN_MS$LOGIN_RC$PROBE_MS$PROBE_RC" =~ ^[0-9]+$ ]]; then
    # _timed draait in een command substitution en erft `set -e` niet, dus een
    # mislukte mktemp levert lege waarden i.p.v. een afbreking. Zonder deze
    # guard leest de vergelijking hieronder die als 0 en meldt stellig dat de
    # workaround ontbreekt.
    fail "timing-meting leverde geen bruikbare waarden (schrijfbare tempdir?) — sectie 7 zegt niets over de workaround"
elif [[ "$LOGIN_RC" -ne 0 || "$PROBE_RC" -ne 0 ]]; then
    # Zonder deze tak wordt een kapotte verbinding als "delay ontbreekt"
    # gerapporteerd: een mislukte login is snel, en een hangende raakt de
    # ConnectTimeout. Beide zouden hieronder een zeer stellige, onjuiste
    # diagnose over /etc/zsh/zprofile opleveren.
    fail "SSH-verbinding mislukte tijdens de timing-meting (login rc=$LOGIN_RC, probe rc=$PROBE_RC) — de meting zegt niets over de workaround; zie sectie 3 en 6"
else
    # Het verschil tussen beide metingen, niet de absolute duur: de handshake
    # zelf haalt op een sandbox in een VM of op een trage host de 250 ms al, en
    # een absolute drempel zou daar een vals-rood over de zprofile-workaround
    # geven.
    DELTA=$(( LOGIN_MS - PROBE_MS ))
    if [[ "$DELTA" -ge 250 && "$DELTA" -lt 1500 ]]; then
        pass "kale login-shell ${DELTA}ms trager dan de probe (${LOGIN_MS}ms vs ${PROBE_MS}ms) — workaround actief"
    elif [[ "$DELTA" -lt 250 ]]; then
        fail "kale login-shell niet vertraagd t.o.v. de probe (${LOGIN_MS}ms vs ${PROBE_MS}ms) — /etc/zsh/zprofile-workaround ontbreekt; Kepler faalt met 'ssh exited before the tunnel ... (code 0)'"
    else
        fail "kale login-shell ${DELTA}ms trager dan de probe — de sleep in /etc/zsh/zprofile staat te hoog; elke Kepler-login betaalt dat"
    fi
fi

section "8. Firewall nog intact vanuit een SSH-sessie"
# Een SSH-sessie moet onder dezelfde egress-allowlist vallen als de rest van de
# container: de netwerkregels zitten op de container, niet op de shell.
if ssh_run 'curl -sS --max-time 15 -o /dev/null https://api.anthropic.com' >/dev/null 2>&1; then
    pass "api.anthropic.com bereikbaar (Claude kan werken)"
else
    fail "api.anthropic.com onbereikbaar — Claude zal over SSH niet werken"
fi
# OPEN_HTTPS uit de container lezen i.p.v. het verschil open te laten: met
# OPEN_HTTPS=true is bereikbaar verwacht gedrag, met false is het een lek — en
# dat laatste mag geen groene run opleveren.
OPEN_HTTPS_VAL="$("$CLI" exec "$CONTAINER" printenv OPEN_HTTPS 2>/dev/null || echo false)"
if ssh_run 'curl -sS --max-time 5 -o /dev/null https://example.com' >/dev/null 2>&1; then
    if [[ "$OPEN_HTTPS_VAL" == true ]]; then
        printf '  \033[33mINFO\033[0m example.com bereikbaar — verwacht bij OPEN_HTTPS=true\n'
    else
        fail "example.com bereikbaar terwijl OPEN_HTTPS=$OPEN_HTTPS_VAL — de egress-allowlist lekt"
    fi
else
    pass "example.com geblokkeerd (strikte allowlist actief)"
fi

if [[ "$PODMAN" == true ]]; then
    section "9. Gestapelde podman-override"
    # Aparte -f die je vergeet is stil: de container start prima, maar zonder
    # /dev/net/tun en security-opts falen nested containers pas tijdens een build.
    if "$CLI" exec "$CONTAINER" sh -c 'test -c /dev/net/tun'; then
        pass "/dev/net/tun aanwezig (podman-override meegegeven)"
    else
        fail "/dev/net/tun ontbreekt — compose.override.podman-*.yml niet meegegeven naast de kepler-override"
    fi
    if "$CLI" exec "$CONTAINER" sh -c 'command -v podman >/dev/null'; then
        pass "podman in de image (INSTALL_PODMAN=true)"
    else
        fail "geen podman in de image — image is zonder INSTALL_PODMAN=true gebouwd"
    fi
    # systempaths=unconfined laat /proc/sysrq-trigger ongemaskeerd achter; dat is
    # precies de relaxatie die de override aanzet, dus een bruikbare tell.
    if "$CLI" exec "$CONTAINER" sh -c 'test -w /proc/sysrq-trigger' 2>/dev/null; then
        pass "security-opts actief (systempaths=unconfined zichtbaar)"
    else
        fail "security-opts lijken niet actief — check 'docker compose ... config' op security_opt"
    fi
fi

section "Resultaat"
if [[ "$FAILCOUNT" -eq 0 ]]; then
    echo "Alles groen — Kepler kan deze sandbox als remote gebruiken."
    echo "Volgende stap: Kepler → Settings → Remote Environments → Add Remote Machine"
    echo "  host $HOST, poort $PORT, user claude, key $KEY"
    exit 0
fi
echo "$FAILCOUNT check(s) gefaald:"
printf '%s' "$FAILLIST"
# De entrypoint-waarschuwingen en de sshd-auth-log zijn bij vrijwel elke gefaalde
# run de volgende stap; scheelt een handmatige ronde.
echo
echo "Containerlog (laatste relevante regels):"
"$CLI" logs --tail 100 "$CONTAINER" 2>&1 | grep -iE 'sshd|kepler|WAARSCHUWING|FATAL' || echo "  (niets gevonden)"
echo "sshd-auth-log:"
"$CLI" exec "$CONTAINER" tail -n 20 /var/log/sshd.log 2>/dev/null || echo "  (niet leesbaar)"
exit 1
