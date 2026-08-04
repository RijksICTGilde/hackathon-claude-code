#!/bin/bash
set -euo pipefail

# Draait als `claude`, gestart door /opt/entrypoint-root.sh nadat die de firewall
# heeft opgezet en naar deze user is gedropt. Hier is geen root meer bereikbaar:
# er is geen sudo en geen sudoers-regel. Zie entrypoint-root.sh voor het waarom.
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
# elke start, idempotent (alleen schrijven als hij ontbreekt). Default = vfs:
# veilig, geen /dev/fuse / geen kernel-FUSE-oppervlak (zie spec). Voor meer
# snelheid kun je naar fuse-overlayfs (vereist /dev/fuse) — zie de noot in
# compose.override.podman-linux.yml. ignore_chown_errors alleen in single-uid.
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
    # Storage-driver via .env (PODMAN_STORAGE_DRIVER, default vfs). vfs = veilig,
    # geen /dev/fuse. overlay = fuse-overlayfs (sneller) en vereist /dev/fuse;
    # ontbreekt dat device, dan vallen we terug op vfs i.p.v. te breken.
    # storage.conf is een gegenereerd bestand: elke start herschreven uit de env.
    driver="${PODMAN_STORAGE_DRIVER:-vfs}"
    if [[ "$driver" == "overlay" && ! -e /dev/fuse ]]; then
        echo "WAARSCHUWING: PODMAN_STORAGE_DRIVER=overlay maar /dev/fuse ontbreekt — terug naar vfs. Uncomment de '/dev/fuse'-device in je podman-override (compose.override.podman-*.yml) en recreate." >&2
        driver="vfs"
    fi
    # ignore_chown_errors hoort bij single-uid: images die naar een niet-gemapte
    # uid chownen mogen bij image-extractie niet hard falen. In multi-uid bestaan
    # die uids wél, en dan zou de optie een echte fout maskeren — dus weglaten.
    if [[ "$multiuid" == "true" ]]; then
        chown_opt=""
    else
        chown_opt=$'ignore_chown_errors = "true"\n'
    fi
    case "$driver" in
        overlay)
            printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n%s' "$chown_opt" > "$storage_conf" ;;
        vfs)
            printf '[storage]\ndriver = "vfs"\n\n[storage.options.vfs]\n%s' "$chown_opt" > "$storage_conf" ;;
        *)
            echo "WAARSCHUWING: PODMAN_STORAGE_DRIVER='$driver' onbekend (verwacht vfs of overlay) — gebruik vfs." >&2
            printf '[storage]\ndriver = "vfs"\n\n[storage.options.vfs]\n%s' "$chown_opt" > "$storage_conf"
            driver="vfs" ;;
    esac
    echo "INFO: rootless podman storage.conf → driver=$driver multiuid=$multiuid ($storage_conf)"
    # Podman zet default de sysctl net.ipv4.ping_group_range; crun probeert die te
    # schrijven, maar /proc/sys is read-only in de outer container → "Read-only
    # file system". Leeg de default-sysctls zodat crun niets probeert te zetten.
    # default_sysctls=[]: zie ping_group_range hierboven.
    # netns="pasta": default-netwerkmodus voor álle containers, óók die via de
    # podman-Docker-API (Testcontainers). Zonder dit zet netavark voor een
    # bridge-netwerk een IPv6-sysctl op het interface in de outer container-netns,
    # wat faalt met "netavark: failed to set autoconf sysctl: Permission denied":
    # die netns wordt door init_user_ns geowned (geen userns-remap), dus rootless
    # podman mag er /proc/sys/net niet schrijven. pasta geeft elke container een
    # eigen netwerk met port-forwarding naar localhost en vermijdt de bridge —
    # precies genoeg voor Testcontainers met published ports. Bonus: nested egress
    # loopt met pasta als lokaal verkeer via de OUTPUT-chain en valt dus onder de
    # egress-allowlist van init-firewall.sh — anders dan bij de bridge, die via
    # FORWARD routeerde en de allowlist kon omzeilen. Beperking: container-naar-
    # container over netwerknamen (Testcontainers `Network`) werkt niet; dat
    # vereist userns-remap op de outer container (spike, issue #82).
    # firewall_driver=iptables: netavark roept default `nft` aan voor bridge-
    # netwerken, maar die binary zit niet in de image. De iptables-driver gebruikt
    # iptables-nft (al aanwezig) en heeft de nft-binary niet nodig. Met de
    # pasta-default is dit alleen nog relevant als iemand expliciet een
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

    # De podman-socket hier starten i.p.v. per build-sessie. Het eerste
    # podman-commando maakt het pause-proces aan dat de user-namespace vastlegt,
    # en álles daarna joint dat proces. Lukt die eerste aanmaak níet met de
    # volledige subuid-range, dan blijft de hele container in single-uid hangen —
    # ook nadat de oorzaak weg is — en falen DB-images op "chown: Invalid
    # argument". Dat gebeurt bijvoorbeeld als het eerste commando onder
    # no_new_privs draait: newuidmap is setuid-root en wint onder die vlag geen
    # privileges meer ("write to uid_map failed"). Door de socket hier op te
    # zetten, in een schone omgeving vóór er iets anders draait, joinen latere
    # aanroepen een gezonde namespace — ook die onder no_new_privs.
    # De socket geeft geen nieuwe rechten: alles wat als `claude` draait kon al
    # podman aanroepen.
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

exec sleep infinity
