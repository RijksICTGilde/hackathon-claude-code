#!/usr/bin/env bash
# Draai op de HOST (niet in de container), vanuit claude-sandbox/. Verifieert de
# Kepler-remote-opzet: een image gebouwd met INSTALL_SSHD=true, gestart met
# compose.override.kepler.yml. Zie README 'Kepler (SSH-remote)'.
#
#   ./host-agents/kepler/smoke-test.sh -i ~/.ssh/kepler
#   ./host-agents/kepler/smoke-test.sh -i ~/.ssh/kepler --podman   # gestapelde override
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
  -h, --help           Deze hulp
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--identity)  KEY="$2"; shift 2 ;;
        -p|--port)      PORT="$2"; shift 2 ;;
        -H|--host)      HOST="$2"; shift 2 ;;
        -c|--container) CONTAINER="$2"; shift 2 ;;
        --podman)       PODMAN=true; shift ;;
        --cli)          CLI="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "FOUT: onbekende optie '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$KEY" ]] || { echo "FOUT: -i/--identity is verplicht (private key bij KEPLER_SSH_PUBKEY)." >&2; exit 2; }
[[ -r "$KEY" ]] || { echo "FOUT: key '$KEY' niet leesbaar." >&2; exit 2; }

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

# Host-key-churn (elke image-build genereert nieuwe host-keys) zou dit script na
# elke rebuild laten struikelen op een known_hosts-mismatch. Daarom een eigen,
# wegwerpbare known_hosts: we testen de sandbox, niet je known_hosts-hygiëne.
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

# Duur (ms) van een SSH-actie. Gebruikt Python voor een monotone klok met
# ms-resolutie (bash heeft geen sub-seconde timing zonder externe tools).
_ms_since() { python3 -c 'import sys,time; print(round((time.time()-float(sys.argv[1]))*1000))' "$1"; }
# Kale login-shell: GEEN commando (`ssh host < /dev/null`) → sshd draait de
# login-shell die /etc/zsh/zprofile sourcet (waar de Kepler-delay zit).
ssh_timed_login() {
    local t0; t0="$(python3 -c 'import time;print(time.time())')"
    ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=10 \
        "claude@$HOST" </dev/null >/dev/null 2>&1 || true
    _ms_since "$t0"
}
# Probe zoals Kepler: `zsh -c` sourcet GEEN zprofile, dus mag niet vertraagd zijn.
ssh_timed_probe() {
    local t0; t0="$(python3 -c 'import time;print(time.time())')"
    ssh_run "zsh -c true" >/dev/null 2>&1 || true
    _ms_since "$t0"
}

section "0. Container draait"
if "$CLI" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    pass "container '$CONTAINER' draait"
else
    echo "FOUT: container '$CONTAINER' draait niet. Start eerst (zie README 'Kepler (SSH-remote)')." >&2
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
    fail "sshd-proces draait niet (check 'docker compose logs $CONTAINER' op de WAARSCHUWING)"
fi

section "2. Poortbinding — alleen loopback"
# De belangrijkste security-assertie van deze opzet: de SSH-poort mag nooit op
# 0.0.0.0/:: staan. Publiceren op een wildcard-adres zet een agent-shell open
# voor het hele netwerk.
BINDING="$("$CLI" port "$CONTAINER" 22 2>/dev/null || true)"
if [[ -z "$BINDING" ]]; then
    fail "poort 22 niet gepubliceerd — draai je met compose.override.kepler.yml?"
elif grep -qE '^(0\.0\.0\.0|\[?::\]?):' <<<"$BINDING"; then
    fail "poort op wildcard-adres gepubliceerd ($BINDING) — MOET 127.0.0.1 zijn"
else
    pass "poort alleen op loopback ($BINDING)"
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

section "4. PATH in een non-interactieve sessie"
# Het scenario dat in de praktijk breekt: een SSH-sessie erft de Docker `ENV PATH`
# niet, dus `claude` (in ~/.local/bin) is "command not found" tenzij de PATH-fix
# in /etc/zsh/zshenv + /etc/profile.d pakt. Kepler kiest zelf welke shell-vorm het
# gebruikt, dus we testen alle drie i.p.v. te gokken.
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

section "5. Hardening — wat moet weigeren, weigert"
# Verwacht falen. `! cmd` i.p.v. een if-then-else zodat set -e niet meekijkt.
if ! ssh -p "$PORT" -o BatchMode=yes -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 "claude@$HOST" 'echo nope' >/dev/null 2>&1; then
    pass "wachtwoord-auth geweigerd"
else
    fail "wachtwoord-auth ACCEPTEERT — PasswordAuthentication staat niet uit"
fi
if ! ssh -i "$KEY" -p "$PORT" -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 "root@$HOST" 'echo nope' >/dev/null 2>&1; then
    pass "root-login geweigerd"
else
    fail "root-login ACCEPTEERT — PermitRootLogin staat niet uit"
fi

section "6. Burst — geen per-bron-straf na mislukte auth"
# Regressie-guard voor PerSourcePenalties (OpenSSH ≥9.8, default aan). Achter de
# NAT/port-forward (gvproxy op macOS, of Docker's portpublish) ziet sshd élke
# host-connectie als dezelfde bron; één mislukte auth straft dan alle volgende.
# Dit test precies dat gat: de hardening-sectie hierboven deed net twee authfails
# vanaf deze bron. Staat PerSourcePenalties nog aan, dan wordt deze burst van
# legitieme logins geweigerd — terwijl één losse login (sectie 3) nog slaagt.
# Daarom een burst i.p.v. een enkele: de bug is onzichtbaar bij gespreide calls.
BURST=10
bfail=0
for _ in $(seq 1 "$BURST"); do
    ssh_run true >/dev/null 2>&1 || bfail=$((bfail + 1))
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
LOGIN_MS="$(ssh_timed_login)"
PROBE_MS="$(ssh_timed_probe)"
if [[ -n "$LOGIN_MS" && "$LOGIN_MS" -ge 250 ]]; then
    pass "kale login-shell vertraagd (${LOGIN_MS}ms ≥ 250ms) — workaround actief"
elif [[ -n "$LOGIN_MS" ]]; then
    fail "kale login-shell niet vertraagd (${LOGIN_MS}ms) — /etc/zsh/zprofile-workaround ontbreekt; Kepler faalt met 'ssh exited before the tunnel ... (code 0)'"
else
    fail "kon login-shell-duur niet meten"
fi
if [[ -n "$PROBE_MS" && "$PROBE_MS" -lt 250 ]]; then
    pass "zsh -c probe blijft snel (${PROBE_MS}ms) — delay raakt alleen login-shells"
else
    fail "zsh -c probe óók vertraagd (${PROBE_MS}ms) — delay staat te breed (hoort in zprofile, niet zshenv); vertraagt Keplers probe onnodig"
fi

section "8. Firewall nog intact vanuit een SSH-sessie"
# Een SSH-sessie moet onder dezelfde egress-allowlist vallen als de rest van de
# container: de netwerkregels zitten op de container, niet op de shell.
if ssh_run 'curl -sS --max-time 15 -o /dev/null https://api.anthropic.com' >/dev/null 2>&1; then
    pass "api.anthropic.com bereikbaar (Claude kan werken)"
else
    fail "api.anthropic.com onbereikbaar — Claude zal over SSH niet werken"
fi
if ssh_run 'curl -sS --max-time 5 -o /dev/null https://example.com' >/dev/null 2>&1; then
    # Met OPEN_HTTPS=true is dit verwacht gedrag, geen fout — daarom een melding.
    printf '  \033[33mINFO\033[0m example.com bereikbaar — verwacht bij OPEN_HTTPS=true; bij een strikte allowlist is dit een lek\n'
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
exit 1
