#!/bin/bash
set -euo pipefail

# Draait als root voor alles wat root vereist — firewall, AppArmor-borging en de
# optionele sshd — en dropt daarna onherroepelijk naar `claude`. OPEN_HTTPS en
# ALLOWED_DOMAINS worden alleen hier gelezen — na de drop kan `claude` de
# egress-allowlist niet meer heropenen.
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

# Optioneel: OpenSSH-server starten voor de Kepler-remote-opzet. Gehard bij
# build; bediening in README-sectie "Kepler (SSH-remote)".
#
# ENABLE_SSHD is de schakelaar, niet de aanwezigheid van de binary: een image dat
# één keer met INSTALL_SSHD=true gebouwd is, mag niet bij élke `up` een
# luisterende sshd opzetten. compose.override.kepler.yml zet de var, dus SSH
# staat alleen aan in een run die er expliciet om vraagt.
#
# Alleen de host-key wordt hier voorbereid; sshd zelf start ná de drop, als
# `claude`, op poort 2222. Er draait dus geen root-daemon in de container: een
# pre-auth-lek in OpenSSH levert `claude` op, niet root. De host-key blijft wel
# root-eigendom (640 root:claude) zodat de ingesloten partij hem kan lezen maar
# niet vervangen — anders kiest die zelf welke identiteit Kepler pint.
#
# Host-keys op het volume in plaats van in de image (ADR 0001 §2.3.4). Het pad
# wordt elke start gecontroleerd: `/home/claude` is van `claude`, en sshd
# accepteert een host-key van een andere user zonder morren.
#
# De hele voorbereiding is niet-fataal: een gesloopt pad op het volume mag de
# sandbox niet onstartbaar maken.
prepare_host_key() {
    local key=/home/claude/.ssh-host/ssh_host_ed25519_key
    # Symlinks en niet-reguliere bestanden eerst weg. `-f` dereferencet, dus een
    # kapotte symlink zou ssh-keygen als root buiten .ssh-host laten schrijven,
    # en op een directory of fifo blokkeert het op zijn overwrite-prompt — met
    # stdin_open uit compose.yml hangt de container-start dan onbeperkt.
    if [[ -L "$key" || -L "$key.pub" || ( -e "$key" && ! -f "$key" ) ]]; then
        echo "WAARSCHUWING: host-key-pad op het volume is geen gewoon bestand — vervangen." >&2
        rm -rf -- "$key" "$key.pub" || return 1
    elif [[ ( -f "$key" && "$(stat -c %u "$key" 2>/dev/null)" != 0 ) ||
            ( -f "$key.pub" && "$(stat -c %u "$key.pub" 2>/dev/null)" != 0 ) ]]; then
        echo "WAARSCHUWING: host-key op het volume is niet van root — vervangen door een verse." \
             "Kepler ziet daardoor een gewijzigde host-key (known_hosts-mismatch)." >&2
        rm -f "$key" "$key.pub" || return 1
    fi
    # Bruikbaarheid en niet alleen aanwezigheid: een bestand van 0 bytes — restant
    # van een ssh-keygen die op een vol volume afbrak — telt anders als geldige
    # sleutel, waarna sshd niet start en de oorzaak nergens uit de melding blijkt.
    if [[ -f "$key" ]] && ! ssh-keygen -l -f "$key" >/dev/null 2>&1; then
        echo "WAARSCHUWING: host-key op het volume is onbruikbaar — vervangen door een verse." >&2
        rm -f "$key" "$key.pub" || return 1
    fi
    # Niet op `set -e` leunen: in een conditie-context staat errexit uit, dus een
    # mislukte rm hierboven zou anders alsnog als succes doorgaan en sshd met de
    # vreemde sleutel laten starten.
    [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -f "$key" </dev/null || return 1
    # Root-eigendom met groepsleesrecht: sshd draait als `claude` en moet de
    # sleutel kunnen lezen, maar niet kunnen vervangen.
    chgrp claude "$key" && chmod 640 "$key" || return 1
    [[ "$(stat -c %u "$key" 2>/dev/null)" == 0 ]]
}

# De gebruikersfase moet weten hoe het hier afliep: anders schrijft die straks
# een sleutel weg met een INFO-regel terwijl er geen sshd luistert, of geeft hij
# advies over een var die wél gezet is. setpriv laat de omgeving ongemoeid.
export SSHD_STATUS=disabled
sshd_ready=false
case "${ENABLE_SSHD:-false}" in
    true)
        SSHD_STATUS=failed
        if [[ ! -x /usr/sbin/sshd ]]; then
            SSHD_STATUS=absent
            echo "WAARSCHUWING: ENABLE_SSHD=true maar deze image is zonder INSTALL_SSHD=true gebouwd —" \
                 "er luistert geen sshd. Herbouw met 'INSTALL_SSHD=true docker compose build'." >&2
        elif [[ -L /home/claude/.ssh-host || ( -e /home/claude/.ssh-host && ! -d /home/claude/.ssh-host ) ]]; then
            echo "WAARSCHUWING: /home/claude/.ssh-host is geen directory (symlink of bestand) — host-key niet aanmaakbaar," \
                 "sshd blijft uit. Verwijder het pad op het claude-home volume." >&2
        elif ! install -d -m 700 -o root -g root /home/claude/.ssh-host; then
            echo "WAARSCHUWING: /home/claude/.ssh-host niet aanmaakbaar (vol of read-only volume) — sshd blijft uit." >&2
        elif ! prepare_host_key; then
            echo "WAARSCHUWING: SSH-host-key niet aan te maken op het volume — sshd blijft uit." >&2
        elif [[ ! -f /var/log/sshd.log ]] && ! install -m 640 -o root -g claude /dev/null /var/log/sshd.log; then
            echo "WAARSCHUWING: /var/log/sshd.log niet aanmaakbaar — sshd blijft uit (zonder auth-log is een login niet te herleiden)." >&2
        else
            sshd_ready=true
        fi ;;
    false) ;;
    *)
        SSHD_STATUS=invalid
        echo "WAARSCHUWING: ENABLE_SSHD='${ENABLE_SSHD}' is ongeldig (verwacht 'true' of 'false') — sshd blijft uit." >&2 ;;
esac

if [[ "$sshd_ready" == true ]]; then
    # De directory moet voor `claude` schrijfbaar zijn: sshd draait straks als
    # die gebruiker en schrijft er zijn pidfile.
    install -d -m 750 -o root -g claude /home/claude/.ssh-host || sshd_ready=false
    SSHD_STATUS=$([[ "$sshd_ready" == true ]] && echo ready || echo failed)
    [[ "$sshd_ready" == true ]] ||
        echo "WAARSCHUWING: /home/claude/.ssh-host niet op de juiste rechten te zetten — sshd blijft uit." >&2
fi

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
exec setpriv --reuid="$claude_uid" --regid="$claude_gid" --init-groups \
    --inh-caps=-all /opt/entrypoint.sh "$@"
