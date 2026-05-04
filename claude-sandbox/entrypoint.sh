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

# Rootless Docker starten (geconditioneerd op aanwezigheid in image)
if command -v dockerd-rootless.sh >/dev/null 2>&1; then
    # Rootless Docker data directory voorbereiden
    mkdir -p /home/claude/.local/share/docker

    echo "Rootless Docker starten..."
    dockerd-rootless.sh > /tmp/dockerd.log 2>&1 &
    dockerd_pid=$!

    # Wacht tot Docker socket beschikbaar is. Breek binnen ~1s af als dockerd
    # crasht (anders 30s stilte voor de FATAL — slecht te debuggen).
    docker_started=false
    dockerd_crash=false
    for i in $(seq 1 30); do
        if ! kill -0 "$dockerd_pid" 2>/dev/null; then
            dockerd_crash=true
            break
        fi
        if docker info >/dev/null 2>&1; then
            echo "Rootless Docker is gestart"
            docker_started=true
            break
        fi
        sleep 1
    done

    if [[ "$docker_started" != true ]]; then
        {
            if [[ "$dockerd_crash" == true ]]; then
                echo "FATAL: Rootless Docker-proces is gecrasht."
            else
                echo "FATAL: Rootless Docker niet gestart binnen 30s."
            fi
            echo "--- /tmp/dockerd.log ---"
            cat /tmp/dockerd.log 2>/dev/null || echo "(logbestand niet aanwezig)"
        } >&2
        exit 1
    fi
else
    echo "INFO: Docker niet aanwezig in deze image — herbouw met INSTALL_DOCKER=true om nested containers te draaien." >&2
fi

exec sleep infinity
