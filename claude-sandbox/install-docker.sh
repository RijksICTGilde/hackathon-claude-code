#!/bin/bash
# Installeer Docker met rootless-ondersteuning: de daemon draait als claude
# (niet als root) binnen de container. Voor de privileged-koppeling: zie
# compose.yml.
set -euo pipefail

# Rootless-vereisten installeren.
# fuse-overlayfs is NIET nodig op Debian 13 (kernel 6.x): dockerd-rootless kiest
# dan de native kernel-overlayfs driver. Verifieer met `docker info | grep -i storage`
# — 'overlayfs' = native (ok), 'fuse-overlayfs' = userspace fallback (voeg dan
# het pakket weer toe).
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    uidmap \
    passt

# Conflicterende pakketten verwijderen (negeer fout als ze niet bestaan)
for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
done

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Docker repo toevoegen
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
# Docker-pakketten gepind voor reproduceerbare builds en supply-chain integriteit.
# Versies worden wekelijks gemonitord door .github/workflows/check-upstream.yml
# (opent automatisch een PR zodra een nieuwere versie beschikbaar is in de
# Debian 13 trixie-suite van download.docker.com).
apt-get install -y --no-install-recommends \
    docker-ce=5:29.4.0-1~debian.13~trixie \
    docker-ce-cli=5:29.4.0-1~debian.13~trixie \
    containerd.io=2.2.3-1~debian.13~trixie \
    docker-buildx-plugin=0.33.0-1~debian.13~trixie \
    docker-compose-plugin=5.1.3-1~debian.13~trixie \
    docker-ce-rootless-extras=5:29.4.0-1~debian.13~trixie

# Apt-cache opruimen (image-grootte)
apt-get clean
rm -rf /var/lib/apt/lists/*

# subuid/subgid ranges toewijzen aan claude user (vereist voor user namespaces)
echo "claude:100000:65536" >> /etc/subuid
echo "claude:100000:65536" >> /etc/subgid

# Runtime directory voor rootless Docker (claude = UID 1000)
mkdir -p /run/user/1000
chown claude:claude /run/user/1000
chmod 700 /run/user/1000
