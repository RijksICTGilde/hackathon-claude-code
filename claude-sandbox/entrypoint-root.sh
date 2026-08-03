#!/bin/bash
set -euo pipefail

# Draait als root, uitsluitend om de firewall op te zetten, en dropt daarna
# onherroepelijk naar `claude`.
#
# WAAROM DEZE SPLITSING
# De firewall liep eerder via `sudo -E`, met een sudoers-regel die de SETENV-tag
# droeg. Die tag laat BASH_ENV de env_reset van sudo overleven, waarmee
# `sudo BASH_ENV=/tmp/p.sh /usr/local/bin/init-firewall.sh` willekeurige code als
# root draaide — een directe route van uid 1000 naar container-root. Omdat er
# geen userns-remap is, is container-root gelijk aan host-root-uid.
# Daarnaast kon `claude` datzelfde commando zelf opnieuw draaien met
# OPEN_HTTPS=true in zijn eigen omgeving, waarmee de egress-allowlist
# self-service was voor precies de agent die hij moet beperken.
# Beide zijn dicht doordat OPEN_HTTPS en ALLOWED_DOMAINS alleen hier worden
# gelezen, vóór de drop, en er daarna geen weg terug naar root is.

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

# Borg dat de AppArmor-laag die de /proc/sys-escape sluit ook echt afdwingt.
# In de multi-uid opt-in (CAP_SYS_ADMIN in de bounding set) is dat profiel een
# defense-in-depth-laag voor het directe core_pattern-pad; blijft het profiel in
# complain-modus staan (bv. na een aa-complain-debugsessie), dan worden de denies
# niet afgedwongen. Faal dan hard i.p.v. de sandbox met een gat te laten starten.
# Alleen ons profiel checken: op macOS/Rancher is apparmor=unconfined (geen
# match) en zit er een VM-kernelgrens onder, dus daar niet falen.
#
# ALLOW_APPARMOR_COMPLAIN=true degradeert de fatal tot een waarschuwing, zodat je
# het profiel bewust in complain kunt draaien om een AppArmor-denial te
# reproduceren (zie hardening-verificatie.md sectie 4). Alleen de operator kan
# die env zetten bij container-start, vóór de drop naar claude — `claude` bereikt
# deze fase niet.
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

# GEEN --no-new-privs. Dat lijkt gratis hardening, maar setuid-root `newuidmap`
# loopt er precies op stuk ("newuidmap: write to uid_map failed"), waarna podman
# naar single-uid degradeert en DB-images falen met "chown: Invalid argument".
# Gemeten; zie de meettabel in
# docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md.
# De weg naar euid 0 die --no-new-privs zou blokkeren is in plaats daarvan
# gesloten door het strippen van de setuid-bits in de Dockerfile.
#
# --inh-caps=-all leegt de inheritable set. De bounding set blijft staan, want
# setuid-root newuidmap moet daar in multi-uid CAP_SYS_ADMIN uit kunnen trekken.
exec setpriv --reuid="$claude_uid" --regid="$claude_gid" --init-groups \
    --inh-caps=-all /opt/entrypoint.sh "$@"
