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
