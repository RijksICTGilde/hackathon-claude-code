#!/bin/bash
set -euo pipefail

# Vaste PATH voor de root-fase. De image zet `/home/claude/.local/bin` vooraan,
# en dat pad ligt op het claude-home volume en is van `claude`: zonder deze regel
# bepaalt de ingesloten partij welke `iptables` of `setpriv` root uitvoert, en
# een herstart volstaat om dat te laten gebeuren. De gebruikersfase krijgt zijn
# eigen PATH terug vlak vóór de privilege-drop.
ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER_PATH="$PATH"
PATH="$ROOT_PATH"

# Draait als root, uitsluitend om de firewall op te zetten, en dropt daarna
# onherroepelijk naar `claude`. OPEN_HTTPS en ALLOWED_DOMAINS worden alleen hier
# gelezen — na de drop kan `claude` de egress-allowlist niet meer heropenen.
# Waarom de firewall vóór de drop moet: ADR 0001 §2.3.1 "Firewall vóór de
# privilege-drop".

echo "entrypoint OPEN_HTTPS: ${OPEN_HTTPS:-false}"
echo "entrypoint ALLOWED_DOMAINS: ${ALLOWED_DOMAINS:-}"
if ! /usr/local/bin/init-firewall.sh; then
    {
        echo "FATAL: Firewall-initialisatie mislukt."
        echo "Veelvoorkomende oorzaken:"
        echo "  - OPEN_HTTPS heeft geen waarde 'true' of 'false'"
        echo "  - Container mist NET_ADMIN/NET_RAW (controleer cap_add in compose.yml)"
        echo "  - iptables/ipset modules niet beschikbaar op host-kernel"
        echo "Zie de output hierboven voor het concrete iptables/ipset-commando dat faalde."
    } >&2
    exit 1
fi

# In complain-modus dwingt het profiel de /proc/sys-denies niet af. Faal dan hard
# i.p.v. de sandbox met een gat te laten starten. Alleen ons eigen profiel
# checken: op macOS/Rancher is apparmor=unconfined de legitieme stand.
# Achtergrond: ADR 0001 §2.3.2 "AppArmor-enforce-borging".
#
# ALLOW_APPARMOR_COMPLAIN=true degradeert de fatal tot een waarschuwing, voor het
# diagnoserecept in docs/hardening-verificatie.md sectie 4.
aa_current="$(cat /proc/self/attr/current 2>/dev/null || true)"
case "$aa_current" in
    *"claude-sandbox-podman (complain)"*)
        msg="het AppArmor-profiel claude-sandbox-podman staat in complain-modus. In die modus worden de /proc/sys-denies niet afgedwongen. Zet enforce met 'sudo aa-enforce /etc/apparmor.d/claude-sandbox-podman' en recreate de container."
        if [[ "${ALLOW_APPARMOR_COMPLAIN:-false}" == "true" ]]; then
            echo "WAARSCHUWING: $msg (toegestaan via ALLOW_APPARMOR_COMPLAIN=true — alleen voor debug)" >&2
        else
            echo "FATAL: $msg" >&2
            exit 1
        fi ;;
esac

# HOME expliciet zetten: de container draait nu als root, dus Docker zet HOME op
# /root. setpriv laat de omgeving ongemoeid, en entrypoint.sh schrijft
# podman-config naar $HOME/.config/containers — zonder deze regel belandt die op
# de verkeerde plek en verliest de sandbox zijn storage.conf.
export HOME=/home/claude
export USER=claude
export LOGNAME=claude

# Numerieke id's, niet de naam: niet elke setpriv-versie accepteert een
# gebruikersnaam bij --reuid/--regid.
claude_uid="$(id -u claude)"
claude_gid="$(id -g claude)"

# GEEN --no-new-privs: setuid-root `newuidmap` loopt daarop stuk en podman
# degradeert naar single-uid. De weg naar euid 0 die de vlag zou blokkeren is in
# plaats daarvan gesloten door de setuid-strip in de Dockerfile. Verwijder deze
# regel dus niet "voor de veiligheid" — zie ADR 0001 §2.3.3 "Privilege-drop
# zonder --no-new-privs".
#
# --inh-caps=-all leegt de inheritable set. De bounding set blijft staan, want
# setuid-root newuidmap moet daar in multi-uid CAP_SYS_ADMIN uit kunnen trekken.
# PATH terug naar die van de image: de gebruikersfase draait als `claude` en
# heeft `/home/claude/.local/bin` nodig voor de claude-CLI.
PATH="$USER_PATH"
exec setpriv --reuid="$claude_uid" --regid="$claude_gid" --init-groups \
    --inh-caps=-all /opt/entrypoint.sh "$@"
