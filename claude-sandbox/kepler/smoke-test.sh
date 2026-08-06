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
TUNNEL_PORT=22322

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
      --tunnel-port N  Lokale poort voor de -L tunneltest (default 22322)
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
        --tunnel-port)  need_value "$@"; TUNNEL_PORT="$2"; shift 2 ;;
        --cli)          need_value "$@"; CLI="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "FOUT: onbekende optie '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

command -v "$CLI" >/dev/null || { echo "FOUT: container-CLI '$CLI' niet gevonden (zie --cli)." >&2; exit 2; }

# Poorten vroeg afvangen: een niet-numerieke waarde komt anders pas veel later
# naar boven als een ssh-fout over een 'bad forwarding specification'.
for _p in "PORT:$PORT" "TUNNEL_PORT:$TUNNEL_PORT"; do
    [[ "${_p#*:}" =~ ^[1-9][0-9]{0,4}$ ]] && [[ "${_p#*:}" -le 65535 ]] ||
        { echo "FOUT: ${_p%%:*}='${_p#*:}' is geen geldig poortnummer." >&2; exit 2; }
done

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
# De containerlog draagt bij vrijwel elke storing de reden.
# Als functie, want de hardste exits zitten midden in het script en zouden die
# bron anders juist overslaan.
dump_logs() {
    local raw
    echo
    echo "Containerlog (relevante regels):"
    # Geen enkele fout wegfilteren: dit draait als het al mis is, en de reden
    # ("No such container", daemon onbereikbaar) zou anders door de grep of door
    # een vervangende tekst verdwijnen — inclusief een eigen diagnose die dan
    # onwaar kan zijn.
    if ! raw="$("$CLI" logs --tail 100 "$CONTAINER" 2>&1)"; then
        echo "  ('$CLI logs' faalde: $(tr '\n' ' ' <<<"$raw"))"
    else
        grep -iE 'sshd|kepler|WAARSCHUWING|FATAL' <<<"$raw" || echo "  (geen sshd/kepler-regels in de laatste 100)"
    fi
}

# Eigen, wegwerpbare known_hosts: we testen de sandbox, niet je
# known_hosts-hygiëne. De host-key staat op het volume en overleeft een rebuild,
# maar niet een volume-recreate.
KNOWN_HOSTS="$(mktemp)" || { echo "FOUT: mktemp mislukt — geen schrijfbare tempdir." >&2; exit 2; }
TUNNEL_ERR=""
TUNNEL_PID=""
KEY_ERR=""
OPEN_HTTPS_ERR=""
SSHD_T_ERR=""
# Eén opruimpunt: de tunneltest verderop start een achtergrondproces, en een
# tweede trap-string zou bij uitbreiding stilletjes uit elkaar lopen.
cleanup() {
    rm -f "$KNOWN_HOSTS" ${TUNNEL_ERR:+"$TUNNEL_ERR"} ${KEY_ERR:+"$KEY_ERR"} ${OPEN_HTTPS_ERR:+"$OPEN_HTTPS_ERR"} ${SSHD_T_ERR:+"$SSHD_T_ERR"}
    # `if` en niet `&&`: onder set -e breekt een mislukte kill de functie af
    # vóór de return, en dan erft het script die exit-code — een geslaagde run
    # zou zo alsnog rood aflopen.
    if [[ -n "$TUNNEL_PID" ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    return 0
}
trap cleanup EXIT

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
# De fout van `ps` apart houden: een daemon die niet draait of een gebruiker
# zonder socket-rechten zijn de gangbaarste oorzaken, en "start de container
# eerst" helpt daar niet.
if ! PS_OUT="$("$CLI" ps --format '{{.Names}}' 2>&1)"; then
    echo "FOUT: '$CLI ps' faalde: $(tr '\n' ' ' <<<"$PS_OUT")" >&2
    exit 2
elif grep -qxF "$CONTAINER" <<<"$PS_OUT"; then
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
    if ! "$CLI" exec "$CONTAINER" sh -c 'command -v pgrep >/dev/null'; then
        fail "pgrep ontbreekt in de container — of er een sshd draait is hiermee niet vast te stellen"
    elif "$CLI" exec "$CONTAINER" sh -c '! pgrep -x sshd >/dev/null'; then
        pass "geen sshd-proces"
    else
        fail "sshd draait terwijl SSH uit hoort te staan — de start hoort achter ENABLE_SSHD te zitten, niet achter de aanwezigheid van de binary"
    fi
    # Leegheid is hier het bewijs, dus eerst vaststellen dat het commando
    # überhaupt bindings kán rapporteren — anders telt een gewijzigd
    # outputformaat of een andere CLI als "geen poort".
    if ! "$CLI" port "$CONTAINER" >/dev/null 2>&1; then
        fail "'$CLI port $CONTAINER' faalt — of poort 2222 gepubliceerd is, is hiermee niet vast te stellen"
    elif [[ -z "$("$CLI" port "$CONTAINER" 2222 2>/dev/null || true)" ]]; then
        pass "poort 2222 niet gepubliceerd"
    else
        fail "poort 2222 is gepubliceerd terwijl SSH uit hoort te staan"
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
    dump_logs >&2
    exit 1
fi
if "$CLI" exec "$CONTAINER" sh -c 'pgrep -x sshd >/dev/null'; then
    pass "sshd-proces draait"
else
    fail "sshd-proces draait niet — check de containerlogs op de WAARSCHUWING uit entrypoint.sh"
fi
# sshd hoort juist NIET als root te draaien: hij start ná de privilege-drop op
# poort 2222, zodat een pre-auth-lek in OpenSSH `claude` oplevert en geen root.
if "$CLI" exec "$CONTAINER" sh -c 'ps -o user= -p "$(pgrep -x sshd | head -1)" 2>/dev/null | grep -qw claude'; then
    pass "sshd draait als claude (geen root-daemon in de container)"
else
    fail "sshd draait niet als claude — hij hoort ná de privilege-drop te starten (entrypoint.sh), op poort 2222"
fi

section '1b. Geen route naar root voor claude'
# Er hoort geen sudo en geen sudoers-drop-in in de image te zitten. `claude` mag
# na de drop geen weg terug hebben; een sudoers-regel of een setuid-binary maakt
# die drop betekenisloos.
if "$CLI" exec "$CONTAINER" sh -c '! command -v sudo >/dev/null'; then
    pass "geen sudo-binary in de image"
else
    fail "sudo is terug in de image — claude heeft daarmee mogelijk weer een pad naar root"
fi
if "$CLI" exec "$CONTAINER" sh -c '! ls -A /etc/sudoers.d 2>/dev/null | grep -q .'; then
    pass "geen sudoers-drop-ins"
else
    fail "/etc/sudoers.d is niet leeg — claude hoort geen weg terug naar root te hebben"
fi
if "$CLI" exec "$CONTAINER" sh -c \
    'test -z "$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) ! -name newuidmap ! -name newgidmap 2>/dev/null)"'; then
    pass "geen setuid/setgid-binaries buiten newuidmap/newgidmap"
else
    fail "setuid/setgid-binary aangetroffen — de strip in de Dockerfile draait niet ná alle apt-installs"
fi

# Host-key hoort op het volume te ontstaan, niet in de image (ADR 0001 §2.4.0).
if "$CLI" exec "$CONTAINER" sh -c '! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1'; then
    pass "geen host-keys in /etc/ssh (die horen op het volume te staan)"
else
    fail "host-keys in /etc/ssh — die zijn in de image gebakken; de Dockerfile hoort ze na de apt-install te verwijderen"
fi
# Eigendom en type expliciet toetsen: `claude` bezit /home/claude en kan het pad
# vervangen, en sshd accepteert een host-key van een andere user zonder morren.
if "$CLI" exec "$CONTAINER" sh -c '
    [ "$(stat -c "%U %G %a" /home/claude/.ssh-host)" = "root claude 750" ] &&
    [ "$(stat -c "%U %G %a" /home/claude/.ssh-host/ssh_host_ed25519_key)" = "root claude 640" ] &&
    [ ! -L /home/claude/.ssh-host/ssh_host_ed25519_key ] &&
    [ -f /home/claude/.ssh-host/ssh_host_ed25519_key ] &&
    [ "$(stat -c %u /home/claude/.ssh-host/ssh_host_ed25519_key)" = 0 ]'; then
    pass "host-key 640 root:claude in een 750 root:claude-directory (sshd draait als claude en moet erdoorheen)"
else
    fail "host-key op /home/claude/.ssh-host ontbreekt of is niet van root — prepare_host_key in entrypoint-root.sh hoort dat af te vangen"
fi
# Permitted én effective moeten leeg zijn — dat is de winst van de niet-root-opzet.
# De bounding set blijft bewust staan: die wordt niet verkleind bij de drop, omdat
# rootless podman hem nodig heeft voor setuid-root newuidmap.
if ! "$CLI" exec "$CONTAINER" sh -c 'pgrep -x sshd >/dev/null'; then
    fail "geen sshd-proces — capabilities niet te controleren"
elif "$CLI" exec "$CONTAINER" sh -c '
    pid=$(pgrep -x sshd | head -1); [ -n "$pid" ] || exit 1
    for f in CapPrm CapEff; do
        v=$(awk -v k="^$f:" "\$0 ~ k {print \$2}" /proc/$pid/status)
        [ -n "$v" ] || exit 1
        [ $(( 0x$v )) -eq 0 ] || exit 1
    done'; then
    pass "sshd heeft een lege permitted- en effective-capability-set"
else
    fail "sshd heeft capabilities in permitted of effective — draait hij toch als root? De niet-root-opzet levert dan niets op"
fi

section "2. Poortbinding — alleen loopback"
# De belangrijkste security-assertie van deze opzet: de SSH-poort mag nooit op
# 0.0.0.0/:: staan. Publiceren op een wildcard-adres zet een agent-shell open
# voor het hele netwerk. Positief asserten, niet de wildcards uitsluiten: een
# LAN-adres als 192.168.64.2 is geen wildcard en zou anders slagen.
BINDING="$("$CLI" port "$CONTAINER" 2222 || true)"
if [[ -z "$BINDING" ]]; then
    fail "poort 2222 niet gepubliceerd — draai je met compose.override.kepler.yml?"
elif grep -qE '^(127\.[0-9.]+|\[::1\]):' <<<"$BINDING"; then
    pass "poort alleen op loopback ($BINDING)"
else
    fail "poort niet op loopback gepubliceerd ($BINDING) — MOET 127.0.0.1 zijn"
fi

# Regelnummer van de containerlog vóór de login: sshd logt met `-e` daarheen, en
# een event van een eerdere start mag de assertie verderop niet groen houden.
# De `logs`-aanroep buiten de pipe: de exitcode van een pipeline is die van
# `wc`, en dat is altijd 0 — een guard eromheen zou nooit vuren.
if ! RAW_LOGS="$("$CLI" logs "$CONTAINER" 2>&1)"; then
    fail "containerlog niet te lezen ($(tr '\n' ' ' <<<"$RAW_LOGS")) — de login-assertie verderop zou een event van een vorige run kunnen tellen"
    AUTH_LOG_OFFSET=""
else
    AUTH_LOG_OFFSET=$(wc -l <<<"$RAW_LOGS")
fi

section "3. SSH-login met key"
if ssh_run 'echo ok' >/dev/null 2>&1; then
    pass "login als 'claude' met pubkey"
else
    echo "FOUT: SSH-login mislukt op $HOST:$PORT. Draai 'ssh -v -i $KEY -p $PORT claude@$HOST' voor de reden." >&2
    echo "  - 'Permission denied (publickey)' → key hoort niet bij KEPLER_SSH_PUBKEY; check .env en de entrypoint-logs." >&2
    echo "  - 'Connection refused' terwijl de poort gepubliceerd is → probeer 127.0.0.1 i.p.v. een hostnaam (IPv4-only forward)." >&2
    echo "  - RSA-sleutel kleiner dan 3072 bits → sshd weigert 'm (RequiredRSASize); gebruik ed25519." >&2
    dump_logs >&2
    exit 1
fi
# Twee invarianten tegelijk. Eigendom: het bestand hoort in de gebruikersfase
# geschreven te zijn, anders kan `claude` zijn eigen sleutels niet beheren —
# sshd accepteert een root-eigen bestand namelijk gewoon, dus dat merk je
# nergens anders. Rechten: sshd weigert wat voor groep of anderen schrijfbaar
# is. Exact 600/700 eisen zou het zelfbeheer-pad onterecht rood maken.
if "$CLI" exec -u claude "$CONTAINER" sh -c \
    'test -O /home/claude/.ssh && test -O /home/claude/.ssh/authorized_keys &&
     test -z "$(find /home/claude /home/claude/.ssh /home/claude/.ssh/authorized_keys -maxdepth 0 -perm /022)"'; then
    pass "authorized_keys van claude en niet schrijfbaar voor groep/anderen"
else
    fail "authorized_keys ontbreekt, is niet van claude (dan is hij in de root-fase geschreven), of /home/claude, ~/.ssh of het bestand is schrijfbaar voor groep/anderen (dan weigert sshd de login): chmod 755 /home/claude; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
fi

# `-e` bestaat om te voorkomen dat een login spoorloos verdwijnt, dus toets dat
# ook. Alleen de regels sinds de offset hierboven tellen mee.
if [[ -z "$AUTH_LOG_OFFSET" ]]; then
    : # offset onbekend; hierboven al gemeld
elif ! RAW_LOGS="$("$CLI" logs "$CONTAINER" 2>&1)"; then
    fail "containerlog niet te lezen voor de auth-controle ($(tr '\n' ' ' <<<"$RAW_LOGS"))"
elif grep -q 'Accepted publickey for claude' <<<"$(tail -n +$((AUTH_LOG_OFFSET + 1)) <<<"$RAW_LOGS")"; then
    pass "containerlog bevat het login-event van deze run"
else
    fail "geen 'Accepted publickey' in de containerlog terwijl de login hierboven slaagde — draait sshd met '-e'? Zonder dat verdwijnt elke login spoorloos (er is geen syslog-daemon)"
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
SSHD_T_ERR="$(mktemp)" || { echo "FOUT: mktemp mislukt — geen schrijfbare tempdir." >&2; exit 2; }
EFFECTIVE="$("$CLI" exec "$CONTAINER" sshd -T 2>"$SSHD_T_ERR")" || true
if [[ -z "$EFFECTIVE" ]]; then
    fail "'sshd -T' gaf geen output: $(tr '\n' ' ' <"$SSHD_T_ERR") (een regel als 'Bad configuration option' wijst naar sshd_config.d/kepler.conf)"
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
        'usepam no' \
        'port 2222' \
        'authorizedkeysfile .ssh/authorized_keys' \
        'allowtcpforwarding local' \
        'requiredrsasize 3072' \
        'permitopen localhost:* 127.0.0.1:* [::1]:*' \
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
if [[ ! "$LOGIN_MS" =~ ^[0-9]+$ || ! "$LOGIN_RC" =~ ^[0-9]+$ ||
      ! "$PROBE_MS" =~ ^[0-9]+$ || ! "$PROBE_RC" =~ ^[0-9]+$ ]]; then
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
    if [[ "$PROBE_MS" -ge 1000 ]]; then
        # Zonder deze tak zou een delay die van zprofile naar zshenv verhuisd is
        # als "workaround ontbreekt" binnenkomen: beide metingen worden dan traag
        # en het verschil valt weg.
        fail "de zsh -c probe is zelf al traag (${PROBE_MS}ms) — staat de delay in zshenv i.p.v. zprofile, of is de verbinding traag? Sectie 7 kan de workaround zo niet beoordelen"
    elif [[ "$DELTA" -ge 250 && "$DELTA" -lt 1500 ]]; then
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
# Drie uitkomsten uit elkaar houden: gezet, niet gezet (compose injecteert de
# var dan niet en init-firewall valt terug op false — bereikbaar is dus een
# lek), en een fout van de CLI (dan valt er niets te concluderen).
OPEN_HTTPS_ERR="$(mktemp)" || { echo "FOUT: mktemp mislukt — geen schrijfbare tempdir." >&2; exit 2; }
open_https_rc=0
OPEN_HTTPS_VAL="$("$CLI" exec "$CONTAINER" printenv OPEN_HTTPS 2>"$OPEN_HTTPS_ERR")" || open_https_rc=$?
if [[ "$open_https_rc" -ne 0 && -s "$OPEN_HTTPS_ERR" ]]; then
    OPEN_HTTPS_VAL="<onleesbaar>"
elif [[ "$open_https_rc" -ne 0 ]]; then
    OPEN_HTTPS_VAL=false
fi
if ssh_run 'curl -sS --max-time 5 -o /dev/null https://example.com' >/dev/null 2>&1; then
    if [[ "$OPEN_HTTPS_VAL" == true ]]; then
        printf '  \033[33mINFO\033[0m example.com bereikbaar — verwacht bij OPEN_HTTPS=true\n'
    elif [[ "$OPEN_HTTPS_VAL" == "<onleesbaar>" ]]; then
        fail "example.com bereikbaar en OPEN_HTTPS niet uit de container te lezen ($(tr '\n' ' ' <"$OPEN_HTTPS_ERR")) — of dit een lek is, is niet vast te stellen"
    else
        fail "example.com bereikbaar terwijl OPEN_HTTPS=$OPEN_HTTPS_VAL — de egress-allowlist lekt"
    fi
else
    pass "example.com geblokkeerd (strikte allowlist actief)"
fi

section "8b. Tunnel naar de container (-L)"
# Wat Kepler feitelijk doet. Een configcheck volstaat hier niet: sshd vergelijkt
# de bestemming letterlijk, dus of PermitOpen de juiste vormen dekt blijkt pas
# uit een echte forward.
if { exec 3<>"/dev/tcp/127.0.0.1/$TUNNEL_PORT"; } 2>/dev/null; then
    exec 3<&-
    # Rood i.p.v. gokken: luistert hier al iets, dan meet de banner-check dat
    # andere proces en meldt het script groen zonder ooit een tunnel te hebben
    # opgezet.
    fail "poort $TUNNEL_PORT is al bezet op deze host — de tunnel is niet te testen; ruim een blijven hangen 'ssh -N -L' naar deze poort op (--tunnel-port kiest een andere)"
else
    TUNNEL_ERR="$(mktemp)" || { echo "FOUT: mktemp mislukt — geen schrijfbare tempdir." >&2; exit 2; }
    ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=10 \
        -o ExitOnForwardFailure=yes -N -L "$TUNNEL_PORT:127.0.0.1:2222" "claude@$HOST" \
        >/dev/null 2>"$TUNNEL_ERR" &
    TUNNEL_PID=$!
    # De banner van de sshd aan de andere kant bewijst dat de forward data
    # draagt; een openstaande poort alleen zegt niets. Bash-native lezen, want
    # `timeout` is GNU coreutils en ontbreekt op macOS.
    BANNER=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # Brace-group: bij `exec 3<>... 2>/dev/null` worden de redirects van
        # links naar rechts verwerkt, dus de connect-fout is al geprint voor
        # /dev/null in beeld komt — dat lekt twee regels per poging.
        if { exec 3<>"/dev/tcp/127.0.0.1/$TUNNEL_PORT"; } 2>/dev/null; then
            IFS= read -r -t 5 BANNER <&3 || BANNER=""
            exec 3<&-
            break
        fi
        sleep 0.3
    done
    BANNER="${BANNER%$'\r'}"
    if [[ "$BANNER" == SSH-2.0-* ]]; then
        pass "-L tunnel naar 127.0.0.1 draagt verkeer ($BANNER)"
    elif kill -0 "$TUNNEL_PID" 2>/dev/null; then
        # ExitOnForwardFailure dekt alleen het lokaal binden; een PermitOpen-
        # weigering is een per-kanaal CHANNEL_OPEN_FAILURE en laat ssh leven.
        # Dit is dus de tak waarin die weigering landt, niet de andere.
        fail "-L tunnel opgezet maar het kanaal draagt niets — PermitOpen in sshd_config.d/kepler.conf staat 127.0.0.1 mogelijk niet toe (sshd matcht de bestemming letterlijk, zonder naamresolutie): $(tr '\n' ' ' <"$TUNNEL_ERR")"
    else
        fail "ssh stopte voor de tunnel stond (login mislukt of lokale poort $TUNNEL_PORT geweigerd): $(tr '\n' ' ' <"$TUNNEL_ERR")"
    fi
    kill "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
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

section "Sleutel uit .env geaccepteerd"
# Anders is de run groen terwijl de entrypoint de nieuwe sleutel geweigerd
# heeft en een oude authorized_keys van het volume het werk doet. De
# container-env is de betrouwbare bron: dat is exact de waarde die de entrypoint
# bij de laatste start zag. Vingerafdrukken vergelijken maakt dit ongevoelig
# voor logrotatie, logdriver en een herstart.
# stdout en stderr gescheiden houden: `2>&1` zou een WARN-regel van de CLI
# (podman doet dat routinematig) vóór de vingerafdruk zetten, waarna de
# vergelijking vals-rood geeft met een zeer stellige, onjuiste diagnose.
KEY_ERR="$(mktemp)" || { echo "FOUT: mktemp mislukt — geen schrijfbare tempdir." >&2; exit 2; }
# `|| want_rc=$?` en niet een losse `$?`: onder set -e breekt een toewijzing met
# een falend commando het script af, en rc 1 is hier het normale geval (var niet
# gezet bij een zelfbeheerde opzet).
want_rc=0
WANT="$("$CLI" exec "$CONTAINER" printenv KEPLER_SSH_PUBKEY 2>"$KEY_ERR")" || want_rc=$?
# Niet alleen op de exit-code afgaan: welke code een CLI voor een daemon-fout
# teruggeeft verschilt per implementatie, en 1 betekent bij printenv juist
# "niet gezet". Lege stderr is het betrouwbare onderscheid.
if [[ "$want_rc" -ne 0 && -s "$KEY_ERR" ]]; then
    fail "KEPLER_SSH_PUBKEY niet uit de container-env te lezen: $(tr '\n' ' ' <"$KEY_ERR")"
elif [[ -z "$WANT" ]]; then
    printf '  \033[33mINFO\033[0m geen KEPLER_SSH_PUBKEY in de container-env — zelfbeheerde authorized_keys, herkomst niet te toetsen\n'
elif ! WANT_FP="$(ssh-keygen -lf - <<<"$WANT" 2>/dev/null)"; then
    fail "KEPLER_SSH_PUBKEY in de container-env is geen geldige sleutel — de entrypoint heeft hem geweigerd; zie de containerlog"
elif ! HAVE_FP="$("$CLI" exec -u claude "$CONTAINER" ssh-keygen -lf /home/claude/.ssh/authorized_keys 2>"$KEY_ERR")"; then
    fail "authorized_keys niet te lezen als claude: $(tr '\n' ' ' <"$KEY_ERR")"
# Zoeken of de gewenste vingerafdruk vóórkomt, niet of hij de enige is: staan er
# meerdere sleutels in het bestand, dan geeft ssh-keygen -lf een regel per stuk
# en zou een gelijkheidstest vals-rood geven. Zonder pipe, want `grep -q` sluit
# af zodra hij matcht en de producent krijgt dan SIGPIPE — onder pipefail telt
# dat als mislukt, dus juist een vroege treffer zou vals-rood geven.
elif grep -qF " $(cut -d' ' -f2 <<<"$WANT_FP") " <<<"$HAVE_FP"; then
    pass "authorized_keys bevat de sleutel uit de container-env"
else
    fail "authorized_keys komt niet overeen met KEPLER_SSH_PUBKEY — je logt in met een oudere sleutel van het volume (env: $WANT_FP / bestand: $HAVE_FP)"
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
# De entrypoint-waarschuwingen zijn bij vrijwel elke gefaalde run de volgende
# stap; scheelt een handmatige ronde.
dump_logs
exit 1
