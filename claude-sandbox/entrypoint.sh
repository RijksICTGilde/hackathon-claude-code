#!/bin/bash
set -euo pipefail

# Start firewall
echo "entrypoint OPEN_HTTPS: ${OPEN_HTTPS:-false}"
echo "entrypoint ALLOWED_DOMAINS: ${ALLOWED_DOMAINS:-}"
if ! sudo -E /usr/local/bin/init-firewall.sh; then
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
# compose.override.podman.yml. single-uid → ignore_chown_errors.
if command -v podman >/dev/null 2>&1; then
    conf_dir="$HOME/.config/containers"
    mkdir -p "$conf_dir"
    storage_conf="$conf_dir/storage.conf"
    # Storage-driver via .env (PODMAN_STORAGE_DRIVER, default vfs). vfs = veilig,
    # geen /dev/fuse. overlay = fuse-overlayfs (sneller) en vereist /dev/fuse;
    # ontbreekt dat device, dan vallen we terug op vfs i.p.v. te breken.
    # storage.conf is een gegenereerd bestand: elke start herschreven uit de env.
    driver="${PODMAN_STORAGE_DRIVER:-vfs}"
    if [[ "$driver" == "overlay" && ! -e /dev/fuse ]]; then
        echo "WAARSCHUWING: PODMAN_STORAGE_DRIVER=overlay maar /dev/fuse ontbreekt — terug naar vfs. Zet PODMAN_FUSE_DEVICE=/dev/fuse in .env (zie compose.override.podman.yml)." >&2
        driver="vfs"
    fi
    case "$driver" in
        overlay)
            printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\nignore_chown_errors = "true"\n' > "$storage_conf" ;;
        vfs)
            printf '[storage]\ndriver = "vfs"\n\n[storage.options.vfs]\nignore_chown_errors = "true"\n' > "$storage_conf" ;;
        *)
            echo "WAARSCHUWING: PODMAN_STORAGE_DRIVER='$driver' onbekend (verwacht vfs of overlay) — gebruik vfs." >&2
            printf '[storage]\ndriver = "vfs"\n\n[storage.options.vfs]\nignore_chown_errors = "true"\n' > "$storage_conf"
            driver="vfs" ;;
    esac
    echo "INFO: rootless podman storage.conf → driver=$driver ($storage_conf)"
    # Podman zet default de sysctl net.ipv4.ping_group_range; crun probeert die te
    # schrijven, maar /proc/sys is read-only in de outer container → "Read-only
    # file system". Leeg de default-sysctls zodat crun niets probeert te zetten.
    # default_sysctls=[]: zie ping_group_range hierboven.
    # firewall_driver=iptables: netavark roept default `nft` aan voor bridge-
    # netwerken (Testcontainers), maar die binary zit niet in de image. De
    # iptables-driver gebruikt iptables-nft (al aanwezig) en heeft de nft-binary
    # niet nodig.
    containers_conf="$conf_dir/containers.conf"
    if [[ ! -f "$containers_conf" ]]; then
        printf '[containers]\ndefault_sysctls = []\n\n[network]\nfirewall_driver = "iptables"\n' > "$containers_conf"
        echo "INFO: rootless podman containers.conf aangemaakt op $containers_conf"
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
