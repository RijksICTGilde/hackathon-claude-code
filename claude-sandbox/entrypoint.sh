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

# authorized_keys voor de Kepler-remote. De sleutel komt runtime uit
# KEPLER_SSH_PUBKEY, zodat er geen sleutel in de image gebakken zit.
#
# Direct na de sshd-start hierboven: die luistert al voordat deze sleutel er
# staat, dus alles wat hier tussen zou komen (podman-wachtlus, marketplace-update
# over het netwerk) is tijd waarin een client verbindt en `Permission denied`
# krijgt terwijl het log even later meldt dat de sleutel geschreven is.
#
# Hier en niet in de root-fase, zodat `~/.ssh` van `claude` blijft: laat je
# KEPLER_SSH_PUBKEY leeg, dan moet je het bestand zelf kunnen beheren op het
# volume, en dat kan niet in een directory die root heeft aangemaakt.
# SSHD_STATUS komt uit de root-fase. ENABLE_SSHD hier opnieuw interpreteren zou
# betekenen dat deze fase niet weet of sshd daadwerkelijk luistert.
#
# `failed` telt mee als actief: de gebruiker wilde SSH, dus de sleutel hoort
# klaar te staan voor een volgende start. De melding erbij zegt wel dat er nu
# niets luistert.
SSHD_STATUS="${SSHD_STATUS:-disabled}"
case "$SSHD_STATUS" in ready|running|failed) sshd_active=true ;; *) sshd_active=false ;; esac

# sshd start hier, als `claude`: poort 2222 vereist geen root, dus er draait geen
# root-daemon in de container. `-e` stuurt de auth-events naar de containerlog;
# er is geen syslog-daemon, en zonder dit verdwijnt elke login spoorloos.
if [[ "$SSHD_STATUS" == ready ]]; then
    rm -f /run/sshd-claude/sshd.pid
    /usr/sbin/sshd -D -e &
    sshd_pid=$!
    for _ in $(seq 1 15); do [[ -s /run/sshd-claude/sshd.pid ]] && break; sleep 0.2; done
    if [[ -s /run/sshd-claude/sshd.pid ]] && kill -0 "$sshd_pid" 2>/dev/null; then
        SSHD_STATUS=running
        echo "INFO: sshd gestart als $(id -un) (luistert op 2222; host-side bind 127.0.0.1:2222 via compose.override.kepler.yml)"
    else
        SSHD_STATUS=failed
        # Opruimen vóór we "mislukt" melden: bindt sshd wél maar bleef het pidfile
        # uit, dan luistert er iets terwijl het log zegt van niet.
        kill "$sshd_pid" 2>/dev/null || true
        {
            echo "WAARSCHUWING: sshd starten mislukt — Kepler-remote werkt niet. Container draait door."
            echo "Veelvoorkomende oorzaken:"
            echo "  - poort 2222 al bezet in deze netwerk-namespace"
            echo "  - host-key niet leesbaar voor $(id -un) (verwacht 640 root:claude in /home/claude/.ssh-host)"
            echo "  - onbekende optie in /etc/ssh/sshd_config.d/kepler.conf (controleer met 'sshd -t')"
        } >&2
    fi
fi
if [[ "$sshd_active" == true ]]; then
    # "ONGEWIJZIGD gelaten" leest als "je werkende opzet is beschermd". Op een
    # vers volume is er niets te beschermen, en dan is de juiste boodschap dat
    # er nu geen sleutel staat. Vooraf bepalen, zodat elke tak hem kan gebruiken.
    if [[ -s "$HOME/.ssh/authorized_keys" ]]; then
        keep="authorized_keys is ONGEWIJZIGD gelaten."
    else
        keep="er staat geen authorized_keys — Kepler kan niet inloggen."
    fi
    if [[ -n "${KEPLER_SSH_PUBKEY:-}" ]]; then
        # Valideren vóór schrijven: een pad in plaats van de sleutelinhoud, een
        # geplakte privésleutel of een meerregelige waarde zou anders een
        # werkende authorized_keys overschrijven mét een geslaagd-melding
        # erachteraan. Meerregelig is bovendien een toegangsconfiguratie op zich:
        # authorized_keys accepteert per regel `command=`/`permitopen=`.
        #
        # Eerst afsluitende witruimte eraf — een waarde uit een YAML block scalar
        # eindigt op een newline, en die zou als tweede sleutel gelezen worden.
        pubkey="$KEPLER_SSH_PUBKEY"
        while [[ "$pubkey" == *[[:space:]] ]]; do pubkey="${pubkey%[[:space:]]}"; done
        while [[ "$pubkey" == [[:space:]]* ]]; do pubkey="${pubkey#[[:space:]]}"; done
        if [[ "$(printf '%s' "$pubkey" | wc -l)" -gt 0 ]]; then
            echo "WAARSCHUWING: KEPLER_SSH_PUBKEY bevat een regeleinde. De var houdt één sleutel;" \
                 "meerdere sleutels beheer je zelf in ~/.ssh/authorized_keys op het volume. $keep" >&2
        # Het keytype vooraan asserten, niet alleen `ssh-keygen -l` draaien: die
        # slaat een eerste veld over voor known_hosts-hostnamen en keurt daardoor
        # ook een known_hosts-regel of een authorized_keys-regel mét opties goed.
        # Zo'n regel schrijft prima weg en wordt door sshd alsnog geweigerd.
        elif [[ ! "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
            echo "WAARSCHUWING: KEPLER_SSH_PUBKEY begint niet met een SSH-keytype. $keep" \
                 "Verwacht de kále inhoud van je .pub-bestand" \
                 "('ssh-ed25519 AAAA... kepler'): geen regel uit known_hosts (hostnaam ervoor), geen" \
                 "authorized_keys-regel met command=/permitopen=, geen pad en geen privésleutel." >&2
        elif ! keyinfo="$(printf '%s\n' "$pubkey" | ssh-keygen -l -f - 2>/dev/null)"; then
            echo "WAARSCHUWING: KEPLER_SSH_PUBKEY is geen geldige publieke SSH-sleutel. $keep" >&2
        # sshd weigert RSA onder RequiredRSASize; zonder deze check zou de sleutel
        # met een geslaagd-melding weggeschreven worden en pas bij het inloggen
        # stukgaan, met "Permission denied (publickey)" als enige aanwijzing.
        elif [[ "$pubkey" == ssh-rsa\ * && "${keyinfo%% *}" -lt 3072 ]]; then
            echo "WAARSCHUWING: KEPLER_SSH_PUBKEY is een RSA-sleutel van ${keyinfo%% *} bits; sshd eist er" \
                 "minstens 3072 (RequiredRSASize). $keep" \
                 "Genereer bij voorkeur een ed25519-sleutel: ssh-keygen -t ed25519 -f ~/.ssh/kepler" >&2
        elif ! mkdir -p "$HOME/.ssh" || ! chmod 700 "$HOME/.ssh"; then
            echo "WAARSCHUWING: $HOME/.ssh niet aanmaakbaar — Kepler kan niet inloggen." \
                 "Controleer de rechten op het claude-home volume." >&2
        # Via een tempbestand: `>` trunceert vóór printf draait, dus een vol of
        # read-only volume zou een lege authorized_keys achterlaten — precies wat
        # de validatie hierboven moet voorkomen.
        elif tmp="$HOME/.ssh/.authorized_keys.$$" &&
             printf '%s\n' "$pubkey" > "$tmp" && chmod 600 "$tmp" &&
             mv -f "$tmp" "$HOME/.ssh/authorized_keys"; then
            if [[ "$SSHD_STATUS" == running ]]; then
                echo "INFO: Kepler-pubkey naar $HOME/.ssh/authorized_keys geschreven"
            else
                echo "WAARSCHUWING: Kepler-pubkey weggeschreven, maar sshd luistert niet" \
                     "(SSHD_STATUS=${SSHD_STATUS}) — zie de waarschuwing eerder in dit log." >&2
            fi
        else
            rm -f "${tmp:-}"
            echo "WAARSCHUWING: authorized_keys schrijven mislukt (vol volume of rechten). $keep" >&2
        fi
    elif [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
        {
            echo "WAARSCHUWING: SSH staat aan, maar er is geen KEPLER_SSH_PUBKEY en geen bestaande authorized_keys — Kepler kan niet inloggen."
            echo "  - Zet KEPLER_SSH_PUBKEY=\"ssh-ed25519 AAAA... kepler\" in .env en recreate de container."
            echo "  - Of beheer ~/.ssh/authorized_keys zelf op het claude-home volume; een bestaand, niet-leeg bestand blijft ongemoeid."
        } >&2
    fi
    # Geldt voor beide paden: sshd loopt de keten tot en met de home-dir na en
    # weigert elk niveau dat voor groep of anderen schrijfbaar is. Dat meldt hij
    # alleen in zijn eigen log — een geslaagd-melding hierboven gevolgd door een
    # stille weigering bij het inloggen is precies wat we willen vermijden.
    # `|| true`: find geeft exit 1 zodra één van de paden ontbreekt, ook als het
    # voor de andere wél een treffer print. Zonder dat zou de waarschuwing juist
    # uitblijven op een vers volume, waar authorized_keys nog niet bestaat.
    perm_bad="$(find "$HOME" "$HOME/.ssh" "$HOME/.ssh/authorized_keys" -maxdepth 0 -perm /022 2>/dev/null || true)"
    if [[ -n "$perm_bad" ]]; then
        echo "WAARSCHUWING: schrijfbaar voor groep of anderen: $(tr '\n' ' ' <<<"$perm_bad")—" \
             "sshd weigert de login daarop. Zet 'chmod 755 $HOME; chmod 700 $HOME/.ssh;" \
             "chmod 600 $HOME/.ssh/authorized_keys'." >&2
    fi
elif [[ -n "${KEPLER_SSH_PUBKEY:-}" ]]; then
    case "$SSHD_STATUS" in
        absent)  echo "WAARSCHUWING: KEPLER_SSH_PUBKEY is gezet, maar deze image bevat geen sshd — de sleutel wordt" \
                      "genegeerd. Herbouw met 'INSTALL_SSHD=true docker compose build'." >&2 ;;
        invalid) echo "WAARSCHUWING: KEPLER_SSH_PUBKEY is gezet, maar ENABLE_SSHD heeft een ongeldige waarde —" \
                      "de sleutel wordt genegeerd." >&2 ;;
        *)       echo "WAARSCHUWING: KEPLER_SSH_PUBKEY is gezet maar SSH staat uit — de sleutel wordt genegeerd." \
                      "Start met '-f compose.override.kepler.yml'." >&2 ;;
    esac
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

exec sleep infinity
