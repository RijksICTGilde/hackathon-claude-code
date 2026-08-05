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
# Hier en niet na de drop: sshd bindt poort 22 en heeft root nodig voor zijn
# privilege separation. Zelfde reden als bij de firewall — wat root vereist,
# gebeurt vóór de drop, zodat `claude` daarna geen weg terug heeft. Ná
# init-firewall.sh, zodat de poort niet openstaat vóór de INPUT-regels er zijn.
#
# Host-keys op het volume in plaats van in de image: een privésleutel in een
# image-layer geeft iedereen met die image de identiteit van elke container die
# eruit draait. Op het volume overleeft de sleutel een image-rebuild, dus Kepler
# houdt dezelfde known_hosts-entry.
#
# Eigendom wordt elke start getoetst. `/home/claude` is van `claude`, dus die kan
# `.ssh-host` hernoemen en er een eigen sleutel neerzetten; sshd accepteert een
# host-key van een ándere user zonder morren. Daarmee zou de ingesloten partij
# kiezen welke identiteit Kepler in known_hosts pint.
#
# -E, niet syslog: er draait geen syslog-daemon in deze image, dus zonder deze
# vlag verdwijnt élke geslaagde en mislukte login spoorloos. sshd opent het
# bestand vóór het daemoniseren, dus het overleeft de fd-reset. `claude` mag
# meelezen via de groep, niet schrijven. Het bestand wordt alleen aangemaakt als
# het nog niet bestaat: opnieuw aanmaken zou bij elke restart het auth-spoor
# wissen.
#
# De hele voorbereiding is niet-fataal. `/home/claude` is van `claude` en
# persistent, dus de inhoud van `.ssh-host` ligt buiten onze controle; een
# gesloopt of vervangen pad mag de sandbox niet onstartbaar maken. Daarom eerst
# controleren dat het een echte directory is en geen symlink — root die blind in
# een door de sandbox-gebruiker beheerd pad schrijft, is precies de route die de
# privilege-drop moet afsluiten.
prepare_host_key() {
    local key=/home/claude/.ssh-host/ssh_host_ed25519_key
    if [[ -f "$key" && "$(stat -c %u "$key" 2>/dev/null)" != 0 ]]; then
        echo "WAARSCHUWING: host-key op het volume is niet van root — vervangen door een verse." \
             "Kepler ziet daardoor een gewijzigde host-key (known_hosts-mismatch)." >&2
        rm -f "$key" "$key.pub"
    fi
    [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"
}

sshd_ready=false
case "${ENABLE_SSHD:-false}" in
    true)
        if [[ ! -x /usr/sbin/sshd ]]; then
            echo "WAARSCHUWING: ENABLE_SSHD=true maar deze image is zonder INSTALL_SSHD=true gebouwd —" \
                 "er luistert geen sshd. Herbouw met 'INSTALL_SSHD=true docker compose build'." >&2
        elif [[ -e /home/claude/.ssh-host && ( -L /home/claude/.ssh-host || ! -d /home/claude/.ssh-host ) ]]; then
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
        echo "WAARSCHUWING: ENABLE_SSHD='${ENABLE_SSHD}' is ongeldig (verwacht 'true' of 'false') — sshd blijft uit." >&2 ;;
esac

if [[ "$sshd_ready" == true ]]; then
    if /usr/sbin/sshd -E /var/log/sshd.log; then
        echo "INFO: sshd gestart (luistert op 22; host-side bind 127.0.0.1:2222 via compose.override.kepler.yml; auth-log in /var/log/sshd.log)"
    else
        {
            echo "WAARSCHUWING: sshd starten mislukt — Kepler-remote werkt niet. Container draait door."
            echo "Veelvoorkomende oorzaken:"
            echo "  - poort 22 al bezet in deze netwerk-namespace"
            echo "  - onbekende optie in /etc/ssh/sshd_config.d/kepler.conf (controleer met 'sshd -t')"
            echo "  - /run/sshd niet aanwezig"
        } >&2
    fi
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
