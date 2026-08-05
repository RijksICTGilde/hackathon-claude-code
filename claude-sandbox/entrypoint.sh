#!/bin/bash
set -euo pipefail

# Draait als `claude`, gestart door /opt/entrypoint-root.sh nadat die de firewall
# heeft opgezet en naar deze user is gedropt. Hier is geen root meer bereikbaar:
# er is geen sudo en geen sudoers-regel. Zie ADR 0001 §2.4 "Gebruikersfase".
if [[ "$(id -u)" -eq 0 ]]; then
    echo "FATAL: entrypoint.sh draait als root. Dit script hoort als 'claude' te draaien," \
         "gestart via /opt/entrypoint-root.sh. Start de container via de ENTRYPOINT," \
         "niet door dit script rechtstreeks aan te roepen." >&2
    exit 1
fi

# Hint als optionele runtimes ontbreken (bv. INSTALL_JVM=false bij build)
if [[ ! -f /home/claude/.sdkman/bin/sdkman-init.sh ]]; then
    echo "INFO: SDKman/JVM niet aanwezig in deze image — herbouw met INSTALL_JVM=true om 'sdk install java' etc. te kunnen draaien." >&2
fi

# Rootless podman storage-config op het claude-home volume zetten. Baked-in in de
# image werkt niet betrouwbaar: een al bestaand named volume wordt NIET opnieuw
# uit de image gevuld, dus de image-versie wordt geschaduwd. Daarom hier bij
# elke start. Storage is altijd vfs; waarom fuse-overlayfs niet ondersteund
# wordt staat in ADR 0001 §2.4.1 "Storage: alleen vfs". ignore_chown_errors
# alleen in single-uid.
if command -v podman >/dev/null 2>&1; then
    # Guard tegen een silent misconfig: het image is mét podman gebouwd
    # (INSTALL_PODMAN=true), maar de container kan gestart zijn met ALLEEN
    # compose.yml — zonder compose.override.podman-*.yml. Dan ontbreken de
    # runtime-relaxaties (device /dev/net/tun + security_opt) en falen nested/
    # detached containers pas veel later, losgekoppeld van de start (pasta:
    # "Failed to open() /dev/net/tun"; en met --network=none "mount proc:
    # Permission denied"). /dev/net/tun is de betrouwbare tell: beide overrides
    # (linux + macos) geven het door, geen enkele plain-compose-start doet dat.
    if [[ ! -e /dev/net/tun ]]; then
        echo "WAARSCHUWING: podman is geïnstalleerd, maar /dev/net/tun ontbreekt — de sandbox is" \
             "gestart ZONDER compose.override.podman-*.yml. Nested/detached containers (Testcontainers," \
             "Quarkus Dev Services) zullen falen. Recreate mét de override, bv. op macOS:" \
             "podman-compose -f compose.yml -f compose.override.podman-macos.yml up -d --force-recreate" >&2
    fi

    # Single-uid (default) of multi-uid? De subuid-entry komt uit de image
    # (PODMAN_MULTIUID=true bij de build). Multi-uid vereist runtime CAP_SYS_ADMIN:
    # de kernel laat een uid_map-write alleen toe aan wie die capability heeft in
    # de doel-namespace óf er de eigenaar van is, en newuidmap is setuid-root
    # (euid 0 ≠ eigenaar 1000). Docker laat CAP_SYS_ADMIN per default uit de
    # bounding set, dus zonder compose.override.podman-multiuid.yml faalt élke
    # podman-actie met "newuidmap: write to uid_map failed". Hier vangen we dat
    # bij de start af i.p.v. veel later in een build.
    if grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
        multiuid=true
        capbnd=$(awk '/^CapBnd:/ {print $2}' /proc/self/status)
        if (( 0x$capbnd & (1 << 21) )); then
            echo "INFO: rootless podman in multi-uid modus (subuid-range + CAP_SYS_ADMIN)"
        else
            echo "WAARSCHUWING: de image is gebouwd met PODMAN_MULTIUID=true, maar CAP_SYS_ADMIN" \
                 "ontbreekt — de sandbox is gestart ZONDER compose.override.podman-multiuid.yml." \
                 "Podman zal falen met 'newuidmap: write to uid_map failed'. Recreate mét die override" \
                 "(stapel hem op je platform-override), of herbouw met PODMAN_MULTIUID=false." >&2
        fi
    else
        multiuid=false
    fi

    conf_dir="$HOME/.config/containers"
    mkdir -p "$conf_dir"
    storage_conf="$conf_dir/storage.conf"
    # storage.conf is een gegenereerd bestand: elke start herschreven.
    # ignore_chown_errors hoort bij single-uid: images die naar een niet-gemapte
    # uid chownen mogen bij image-extractie niet hard falen. In multi-uid bestaan
    # die uids wél, en dan zou de optie een echte fout maskeren — dus weglaten.
    if [[ "$multiuid" == "true" ]]; then
        chown_opt=""
    else
        chown_opt=$'ignore_chown_errors = "true"\n'
    fi
    printf '[storage]\ndriver = "vfs"\n\n[storage.options.vfs]\n%s' "$chown_opt" > "$storage_conf"
    echo "INFO: rootless podman storage.conf → driver=vfs multiuid=$multiuid ($storage_conf)"
    # default_sysctls=[]: podman zet default net.ipv4.ping_group_range, maar
    # /proc/sys is read-only in de outer container → "Read-only file system".
    # Leegmaken zorgt dat crun niets probeert te zetten.
    # netns="pasta": netwerkmodus voor álle geneste containers, óók die via de
    # podman-Docker-API (Testcontainers). Waarom geen bridge, en wat het kost:
    # ADR 0001 §2.4.2 "Netwerk: pasta".
    # firewall_driver=iptables: netavark roept default `nft` aan, maar die binary
    # zit niet in de image. Alleen nog relevant als iemand expliciet een
    # bridge-netwerk aanmaakt.
    containers_conf="$conf_dir/containers.conf"
    if [[ ! -f "$containers_conf" ]]; then
        printf '[containers]\nnetns = "pasta"\ndefault_sysctls = []\n\n[network]\nfirewall_driver = "iptables"\n' > "$containers_conf"
        echo "INFO: rootless podman containers.conf aangemaakt op $containers_conf"
    elif ! grep -qE '^[[:space:]]*netns[[:space:]]*=' "$containers_conf"; then
        # Migratie voor volumes van vóór de pasta-default: netns-regel bijplaatsen
        # zonder de rest van een handmatig aangepaste config te overschrijven. De
        # grep matcht ook een ingesprongen netns, zodat we geen duplicaat-key maken
        # (podman's TOML-parser breekt daarop).
        if grep -q '^\[containers\]' "$containers_conf"; then
            sed -i '/^\[containers\]/a netns = "pasta"' "$containers_conf"
        else
            # Config zonder [containers]-sectie: append de sectie i.p.v. een sed
            # die niets zou matchen (en stil zou falen).
            printf '\n[containers]\nnetns = "pasta"\n' >> "$containers_conf"
        fi
        if grep -qE '^[[:space:]]*netns[[:space:]]*=' "$containers_conf"; then
            echo "INFO: netns=\"pasta\" toegevoegd aan bestaande containers.conf (nested-bridge-fix)"
        else
            echo "WAARSCHUWING: netns=\"pasta\" niet kunnen toevoegen aan $containers_conf — zet het handmatig onder [containers], anders faalt Testcontainers op de netavark-bridge." >&2
        fi
    fi

    # De podman-socket hier starten i.p.v. per build-sessie, zodat het pause-proces
    # dat de user-namespace vastlegt in een schone omgeving ontstaat. Waarom dat
    # uitmaakt: ADR 0001 §2.4.3 "Podman-socket bij container-start".
    if [[ -e /dev/net/tun ]]; then
        # Komt normaal uit de podman-override (zelfde pad als DOCKER_HOST daar);
        # de fallback houdt dit blok zelfstandig werkend. In /tmp en niet onder
        # $HOME: dat is een persistent volume, en libpod-runtime-state die een
        # herstart overleeft (pause.pid, alive) laat podman naar processen wijzen
        # die niet meer bestaan.
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/podman-run-$(id -u)}"
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 700 "$XDG_RUNTIME_DIR"
        podman_sock="$XDG_RUNTIME_DIR/podman/podman.sock"
        # podman maakt de map van de socket niet zelf aan.
        mkdir -p "$(dirname "$podman_sock")"
        # Ruimt state op die van een vorige container-instantie in het volume
        # kan zijn blijven staan (bv. via een eigen XDG_RUNTIME_DIR).
        podman system migrate >/dev/null 2>&1 || true
        setsid podman system service --time=0 "unix://$podman_sock" \
            </dev/null >/tmp/podman-service.log 2>&1 &
        for _ in $(seq 1 20); do [[ -S "$podman_sock" ]] && break; sleep 0.5; done
        if [[ -S "$podman_sock" ]]; then
            echo "INFO: podman-socket draait op $podman_sock (DOCKER_HOST staat in de podman-override)"
        else
            echo "WAARSCHUWING: de podman-socket kwam niet op — zie /tmp/podman-service.log. Testcontainers/Dev Services zullen falen op DOCKER_HOST." >&2
        fi
        # Vangt de degradatie af die dit blok juist moet voorkomen, zodat je hem
        # bij de start ziet i.p.v. veel later als een chown-fout in een build.
        if [[ "$multiuid" == "true" ]]; then
            uidmap=$(podman info --format '{{.Host.IDMappings.UIDMap}}' 2>/dev/null || true)
            if [[ "$uidmap" != *"} {"* ]]; then
                echo "WAARSCHUWING: podman mapt maar één uid ($uidmap) terwijl multi-uid aan staat. Images die naar een tweede uid chownen (postgres, mysql) zullen falen. Herstel: 'podman system migrate' en herstart de socket." >&2
            fi
        fi
    fi
fi

# Geïnstalleerde marketplaces verversen zodat plugin-bundels up-to-date blijven
# zonder image-rebuild. Niet-fataal: bij netwerk-failure of upstream-issue
# waarschuwen we en draaien we door met de bestaande marketplace-snapshot.
case "${MARKETPLACE_AUTOUPDATE:-true}" in
    true)
        echo "Marketplaces updaten..."
        if ! claude plugin marketplace update; then
            echo "WAARSCHUWING: 'claude plugin marketplace update' mislukte (netwerk of upstream). Container draait door met de huidige marketplace-snapshot." >&2
        fi
        ;;
    false)
        echo "INFO: MARKETPLACE_AUTOUPDATE=false — marketplaces niet ververst"
        ;;
    *)
        echo "FOUT: MARKETPLACE_AUTOUPDATE='${MARKETPLACE_AUTOUPDATE}' is ongeldig (verwacht: 'true' of 'false')" >&2
        exit 1
        ;;
esac

# Optioneel: authorized_keys voor de Kepler-remote schrijven (image gebouwd met
# INSTALL_SSHD=true). De sleutel komt runtime uit KEPLER_SSH_PUBKEY, zodat er
# geen sleutel in de image gebakken zit. sshd zelf is al gestart in de root-fase.
#
# Dat sshd eerder draait dan dit bestand bestaat is geen probleem: sshd leest
# authorized_keys per connectie, niet bij het starten. Schrijven hoort hier en
# niet in de root-fase, zodat het bestand van `claude` is — sshd weigert met
# StrictModes een authorized_keys die de inlogger niet zelf bezit.
if [[ -x /usr/sbin/sshd ]]; then
    if [[ -n "${KEPLER_SSH_PUBKEY:-}" ]]; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        printf '%s\n' "$KEPLER_SSH_PUBKEY" > "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        echo "INFO: Kepler-pubkey naar $HOME/.ssh/authorized_keys geschreven"
    elif [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
        echo "WAARSCHUWING: sshd draait maar er is geen KEPLER_SSH_PUBKEY en geen bestaande authorized_keys — Kepler kan niet inloggen. Zet KEPLER_SSH_PUBKEY in .env (zie compose.override.kepler.yml)." >&2
    fi
fi

exec sleep infinity
