FROM debian:13.7-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# Gebruik bash met -e, -u en pipefail zodat pipelines niet stil falen
# (truncated download, HTTP-fouten na redirect, ongedefinieerde variabelen)
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG INSTALL_JVM=true
ARG INSTALL_RTK=true
ARG INSTALL_OVERHEID_PLUGINS=true
ARG INSTALL_OVERHEID_GEO=false
ARG INSTALL_OVERHEID_ZAD_ACTIONS=false
ARG INSTALL_ANTHROPIC_PLUGINS=true
ARG INSTALL_LOCAL_SKILLS=true
ARG INSTALL_CAVEMAN=true

# Basis development tools en netwerk/security tools (geïnspireerd op de officiële devcontainer)
# Let op: houd de tools-lijst in de README in sync bij wijzigingen
#
# APT_UPGRADE_EPOCH is het cache-busting-mechanisme: een nieuwe waarde
# invalideert deze laag en elke RUN erna, zodat `apt-get upgrade` niet uit de
# layer cache komt terwijl de digest-pin op de base image Debians rebuilds niet
# volgt. De echo zet de epoch in de build-log. De job apt-security-refresh in
# check-upstream.yml bumpt de waarde.
#
# De upgrade zit bewust in deze eerste apt-laag en niet in een eigen laag
# verderop: dat zou elke pull permanent groter maken. De prijs is dat een bump
# alles hierna opnieuw bouwt — ook de plugin-installs, die niet gepind zijn en
# dus opnieuw resolven — en dat elke gebruiker alles boven de base-laag opnieuw
# ophaalt.
ARG APT_UPGRADE_EPOCH=2026-11-09
RUN echo "apt-upgrade epoch: ${APT_UPGRADE_EPOCH}" && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    less \
    git \
    curl \
    ca-certificates \
    procps \
    fzf \
    zsh \
    man-db \
    zip \
    unzip \
    gnupg2 \
    gh \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    jq \
    nano \
    vim \
    ripgrep \
    openssh-client \
    file \
    xz-utils \
    libatomic1 \
    python3 \
    python3-pip \
    python3-venv \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js LTS officiële binary (amd64 + arm64); SHAs uit nodejs.org/dist pinnen voor supply-chain integriteit
# Versie + SHAs worden wekelijks gemonitord door .github/workflows/check-upstream.yml
# (opent automatisch een PR zodra er een nieuwere LTS-release is).
# De binary linkt tegen libatomic.so.1; libatomic1 staat daarom in de apt-laag hierboven.
# Let op: houd versie in de README tools-tabel in sync
RUN NODE_VERSION=v26.13.0 && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) NODE_ARCH=x64;   SHA=d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997 ;; \
      arm64) NODE_ARCH=arm64; SHA=406fe3fbde1c054adff8b297c16fdb5af6659db327c1ac8acd46b56ef1af9a92 ;; \
      *) echo "FOUT: Node.js niet beschikbaar voor architectuur '$ARCH'" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz && \
    echo "$SHA  /tmp/node.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' && \
    rm /tmp/node.tar.xz && \
    actual=$(node --version) && \
    { [[ "$actual" == "${NODE_VERSION}" ]] || { echo "FOUT: node-versie '$actual' != verwacht '${NODE_VERSION}'" >&2; exit 1; }; } && \
    npm --version >/dev/null

# npm apart pinnen: de versie die met de Node-tarball meekomt loopt achter op
# npm's eigen release-lijn, en die achterstand zit in dependencies die npm
# bundelt (tar, undici, brace-expansion). Node bumpen lost dat niet op — alleen
# npm zelf brengt nieuwere versies van die modules mee.
#
# Blijf op dezelfde major als de gebundelde npm: een major-bump hoort een eigen
# afweging te zijn, niet een bijvangst van een security-fix.
# Versie wordt wekelijks gemonitord door .github/workflows/check-upstream.yml.
RUN NPM_VERSION=11.21.2 && \
    npm install -g "npm@${NPM_VERSION}" --no-audit --no-fund && \
    actual=$(npm --version) && \
    { [[ "$actual" == "${NPM_VERSION}" ]] || { echo "FOUT: npm-versie '$actual' != verwacht '${NPM_VERSION}'" >&2; exit 1; }; }

# git-delta installeren (amd64 + arm64); SHAs uit de upstream release pinnen voor supply-chain integriteit
# Versie + SHAs worden wekelijks gemonitord door .github/workflows/check-upstream.yml
# (opent automatisch een PR zodra er een nieuwere release op dandavison/delta is).
# Dit pakket komt met `dpkg -i` binnen, niet uit apt: de wekelijkse verversing
# van de apt-laag kan het dus niet bewegen en laat het buiten de weging.
RUN DELTA_VERSION=0.20.1 && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) SHA=0683067a4cbbcc19b9fd2841253131d1b37ccfa724725098d811d4d0d9fcc25b ;; \
      arm64) SHA=6e08b734d611037eb9eb5db883cab7ac0a089216a9efdc1d2caac44319029c28 ;; \
      *) echo "FOUT: git-delta niet beschikbaar voor architectuur '$ARCH'" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
    echo "$SHA  /tmp/git-delta.deb" | sha256sum -c - && \
    dpkg -i /tmp/git-delta.deb && \
    rm /tmp/git-delta.deb

# Non-root user aanmaken
RUN useradd -m -s /bin/zsh claude

# Bash-history na elk commando wegschrijven (i.p.v. alleen bij exit)
ENV PROMPT_COMMAND="history -a"

RUN mkdir -p /home/claude/.m2 /home/claude/projects && chown claude:claude /home/claude/.m2 /home/claude/projects

# Force git to use HTTPS instead of SSH for GitHub
RUN git config --system url."https://github.com/".insteadOf "git@github.com:"

# Wissel naar non-root user
USER claude
WORKDIR /home/claude

# Native Claude Code installeren via gevendord install-script (vendor/install-scripts/claude.sh).
# Het script staat in de repo zodat builds reproduceerbaar zijn ongeacht of upstream
# https://claude.ai/install.sh op dat moment is gewijzigd of (tijdelijk) onbereikbaar.
# Updates komen via .github/workflows/check-upstream.yml (wekelijkse PR bij upstream-diff).
# Script zelf doet SHA-verificatie van de claude-binary die het ophaalt.
COPY --chown=claude:claude vendor/install-scripts/claude.sh /tmp/claude-install.sh
RUN bash /tmp/claude-install.sh && \
    rm /tmp/claude-install.sh && \
    command -v /home/claude/.local/bin/claude >/dev/null

ENV PATH="/home/claude/.local/bin:${PATH}"

# Claude config directory voorbereiden
RUN mkdir -p /home/claude/.claude

# Plugins installeren per groep (ARGs sturen welke groepen meedoen).
# Let op: houd de plugin-lijst in de README in sync bij wijzigingen.
# Faalt dit op een verse build, dan is de oorzaak meestal: marketplace onbereikbaar
# (Docker build-network), plugin upstream hernoemd/verwijderd, of claude-CLI mismatch.
#
# Overheid-blok: marketplace wordt één keer toegevoegd zodra minstens één
# INSTALL_OVERHEID_*-flag true is. Nieuwe split toevoegen = 1 entry in
# OVERHEID_FLAGS + 1 if-blok per plugin; marketplace-guard schaalt mee.
RUN case "$INSTALL_ANTHROPIC_PLUGINS" in \
      true) claude plugin marketplace add anthropics/claude-plugins-official || { echo "FOUT: marketplace 'anthropics/claude-plugins-official' toevoegen is mislukt (netwerk of marketplace verwijderd/hernoemd?)" >&2; exit 1; } && \
            for p in github pr-review-toolkit commit-commands superpowers feature-dev \
                     claude-md-management code-review code-simplifier security-guidance \
                     claude-code-setup ralph-loop; do \
              claude plugin install "$p" || { echo "FOUT: plugin '$p' installeren is mislukt (netwerk of plugin verwijderd/hernoemd?)" >&2; exit 1; }; \
            done ;; \
      false) echo "INFO: INSTALL_ANTHROPIC_PLUGINS=false — Anthropic-plugins overgeslagen" ;; \
      *) echo "FOUT: INSTALL_ANTHROPIC_PLUGINS='$INSTALL_ANTHROPIC_PLUGINS' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac && \
    OVERHEID_FLAGS=(INSTALL_OVERHEID_PLUGINS INSTALL_OVERHEID_GEO INSTALL_OVERHEID_ZAD_ACTIONS) && \
    for v in "${OVERHEID_FLAGS[@]}"; do \
      case "${!v}" in \
        true|false) ;; \
        *) echo "FOUT: $v='${!v}' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
      esac; \
    done && \
    overheid_any=false && \
    for v in "${OVERHEID_FLAGS[@]}"; do \
      if [ "${!v}" = "true" ]; then overheid_any=true; fi; \
    done && \
    if [ "$overheid_any" = "true" ]; then \
      claude plugin marketplace add developer-overheid-nl/skills-marketplace || { echo "FOUT: marketplace 'developer-overheid-nl/skills-marketplace' toevoegen is mislukt (netwerk of marketplace verwijderd/hernoemd?)" >&2; exit 1; }; \
    fi && \
    if [ "$INSTALL_OVERHEID_PLUGINS" = "true" ]; then \
      for p in standaarden developer-overheid nerds internet; do \
        claude plugin install "$p" || { echo "FOUT: plugin '$p' installeren is mislukt (netwerk of plugin verwijderd/hernoemd?)" >&2; exit 1; }; \
      done; \
    else echo "INFO: INSTALL_OVERHEID_PLUGINS=false — Overheid-plugins overgeslagen"; fi && \
    if [ "$INSTALL_OVERHEID_GEO" = "true" ]; then \
      claude plugin install geo || { echo "FOUT: plugin 'geo' installeren is mislukt (netwerk of plugin verwijderd/hernoemd?)" >&2; exit 1; }; \
    else echo "INFO: INSTALL_OVERHEID_GEO=false — geo-plugin overgeslagen"; fi && \
    if [ "$INSTALL_OVERHEID_ZAD_ACTIONS" = "true" ]; then \
      claude plugin install zad-actions || { echo "FOUT: plugin 'zad-actions' installeren is mislukt (netwerk of plugin verwijderd/hernoemd?)" >&2; exit 1; }; \
    else echo "INFO: INSTALL_OVERHEID_ZAD_ACTIONS=false — zad-actions-plugin overgeslagen"; fi && \
    if [ "$INSTALL_JVM" = "true" ] && [ "$INSTALL_ANTHROPIC_PLUGINS" = "true" ]; then \
      for p in jdtls-lsp kotlin-lsp; do \
        claude plugin install "$p" || { echo "FOUT: plugin '$p' installeren is mislukt (netwerk of plugin verwijderd/hernoemd?)" >&2; exit 1; }; \
      done; \
    else \
      echo "INFO: LSP-plugins overgeslagen (INSTALL_JVM='$INSTALL_JVM', INSTALL_ANTHROPIC_PLUGINS='$INSTALL_ANTHROPIC_PLUGINS' — beide moeten 'true' zijn)"; \
    fi

# Lokale skills installeren (geconditioneerd op INSTALL_LOCAL_SKILLS).
# Let op: houd de skills-lijst in de README in sync bij wijzigingen.
COPY --chown=claude:claude skills/ /tmp/local-skills/
RUN case "$INSTALL_LOCAL_SKILLS" in \
      true) mkdir -p /home/claude/.claude/skills && \
            cp -a /tmp/local-skills/. /home/claude/.claude/skills/ && \
            rm -rf /tmp/local-skills ;; \
      false) rm -rf /tmp/local-skills && \
             echo "INFO: INSTALL_LOCAL_SKILLS=false — lokale skills overgeslagen" ;; \
      *) echo "FOUT: INSTALL_LOCAL_SKILLS='$INSTALL_LOCAL_SKILLS' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# caveman plugin (third-party, https://github.com/JuliusBrussee/caveman) —
# ultra-compressed communicatie-modus, snijdt ~75% tokens.
RUN case "$INSTALL_CAVEMAN" in \
      true) claude plugin marketplace add JuliusBrussee/caveman || { echo "FOUT: marketplace 'JuliusBrussee/caveman' toevoegen is mislukt (netwerk of marketplace verwijderd/hernoemd?)" >&2; exit 1; } && \
            claude plugin install caveman@caveman || { echo "FOUT: plugin 'caveman@caveman' installeren is mislukt (netwerk of plugin verwijderd/hernoemd?)" >&2; exit 1; } ;; \
      false) echo "INFO: INSTALL_CAVEMAN=false — caveman overgeslagen" ;; \
      *) echo "FOUT: INSTALL_CAVEMAN='$INSTALL_CAVEMAN' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# rtk (reduce token use) via gevendord install-script (vendor/install-scripts/rtk.sh,
# afkomstig van https://raw.githubusercontent.com/rtk-ai/rtk/v1.2.0/install.sh).
# Updates komen via .github/workflows/check-upstream.yml (wekelijkse PR bij upstream-diff).
# RTK_VERSION pint de binary; zonder pin volgt de installer 'latest' en is de
# image niet reproduceerbaar. Geen losse SHA-pin zoals bij Node.js en git-delta:
# het script verifieert de binary tegen de checksums.txt van dezelfde release.
COPY --chown=claude:claude vendor/install-scripts/rtk.sh /tmp/rtk-install.sh
RUN case "$INSTALL_RTK" in \
      true) RTK_VERSION=v1.2.0 sh /tmp/rtk-install.sh && \
            rm /tmp/rtk-install.sh && \
            command -v rtk >/dev/null && \
            rtk init -g --auto-patch ;; \
      false) rm -f /tmp/rtk-install.sh && \
             echo "INFO: INSTALL_RTK=false — rtk overgeslagen" ;; \
      *) echo "FOUT: INSTALL_RTK='$INSTALL_RTK' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# Aliases
RUN echo 'alias claude-danger="claude --dangerously-skip-permissions"' >> /home/claude/.bashrc && \
    echo 'alias claude-danger="claude --dangerously-skip-permissions"' >> /home/claude/.zshrc

# Optionele SDKman-installatie (voor JVM-talen — geen JDK standaard, draai `sdk install java` zelf)
# Via gevendord install-script (vendor/install-scripts/sdkman.sh, afkomstig van https://get.sdkman.io).
# Updates komen via .github/workflows/check-upstream.yml (wekelijkse PR bij upstream-diff).
# Let op: houd documentatie in de README sectie 'Optionele componenten' in sync
COPY --chown=claude:claude vendor/install-scripts/sdkman.sh /tmp/sdkman-install.sh
RUN case "$INSTALL_JVM" in \
      true) bash /tmp/sdkman-install.sh && \
            rm /tmp/sdkman-install.sh && \
            bash -c 'set -eo pipefail; source /home/claude/.sdkman/bin/sdkman-init.sh && sdk version >/dev/null' ;; \
      false) rm -f /tmp/sdkman-install.sh && \
             echo "INFO: INSTALL_JVM=false — SDKman overgeslagen" ;; \
      *) echo "FOUT: INSTALL_JVM='$INSTALL_JVM' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

USER root
# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
# Geen sudoers-regel: de firewall draait in de root-fase van de entrypoint, vóór
# de drop naar `claude`. Zie ADR 0001 §2.3.1 "Firewall vóór de privilege-drop".
RUN chmod +x /usr/local/bin/init-firewall.sh

# Optioneel: rootless Podman voor Maven+Testcontainers ín de container. Default
# uit. Bediening: claude-sandbox/podman/README.md. Afwegingen: ADR 0001 §2.2
# "Bouwfase (image)".
#
# De `sed` verwijdert de subuid/subgid-range voor `claude` (single-uid, default);
# bij PODMAN_MULTIUID=true wordt hij er juist weer in gezet. Wat dat verschil
# betekent staat in ADR 0001 §2.2.2 "Single-uid default, multi-uid opt-in".
# (Geen inline `#`-comments in de RUN: in een `\`-gecontinueerde RUN is dat
# fragiel over Docker-builders heen.)
#
# podman-docker geeft een `docker`-commando, voor scripts en Justfiles die
# `docker build` aanroepen. /etc/containers/nodocker zet de melding uit die het
# anders bij elke aanroep geeft.
#
# De ARG's staan direct boven deze laag: een build-arg invalideert elke RUN na
# zijn declaratie, dus zo bouwt een flip alleen deze laag en wat erna komt opnieuw.
ARG INSTALL_PODMAN=false
ARG PODMAN_MULTIUID=false
RUN case "$INSTALL_PODMAN" in \
      true) apt-get update && \
            apt-get install -y --no-install-recommends \
              podman podman-docker uidmap passt slirp4netns && \
            apt-get clean && rm -rf /var/lib/apt/lists/* && \
            touch /etc/containers/nodocker && \
            { sed -i '/^claude:/d' /etc/subuid /etc/subgid 2>/dev/null || true ; } && \
            case "$PODMAN_MULTIUID" in \
              true) echo "claude:100000:65536" >> /etc/subuid && \
                    echo "claude:100000:65536" >> /etc/subgid ;; \
              false) echo "INFO: PODMAN_MULTIUID=false — single-uid modus" ;; \
              *) echo "FOUT: PODMAN_MULTIUID='$PODMAN_MULTIUID' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
            esac ;; \
      false) echo "INFO: INSTALL_PODMAN=false — rootless Podman overgeslagen" ;; \
      *) echo "FOUT: INSTALL_PODMAN='$INSTALL_PODMAN' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# Optioneel: OpenSSH-server zodat GitKraken Kepler via SSH een agent-sessie ín
# deze sandbox kan draaien. Default uit. Bediening, beperkingen en de Kepler-bug
# waarvoor hieronder een workaround staat: README-sectie "Kepler (SSH-remote)".
# Let op: houd de README-tools-tabel + Kepler-sectie in sync.
#
# Na de podman-laag, met de ARG direct erboven (zie daar), zodat een flip van
# INSTALL_SSHD de podman-laag in de cache laat. Vóór de setuid-strip, zodat die
# ook over de openssh-bestanden gaat.
#
# Geen host-keys in de image (ADR 0001 §2.3.4); entrypoint-root.sh maakt ze bij
# eerste start op het volume. De `rm` is nodig omdat Debians
# openssh-server-postinst er zelf drie aanmaakt tijdens de apt-install.
#
# PATH-fix in zshenv: een non-interactieve SSH-sessie erft de Docker `ENV PATH`
# niet, dus `claude` in ~/.local/bin zou "command not found" geven. zsh is de
# login-shell van `claude` en sourcet zshenv altijd, ook bij `zsh -c`.
#
# Ciphers wel gepind, KexAlgorithms bewust niet: de default-kexlijst begint met
# de post-quantum hybride uit OpenSSH 10, en vastpinnen op curve25519 zou een
# downgrade zijn. De MACs-regel is een vangnet: bij deze AEAD-only cipherlijst
# onderhandelt OpenSSH sowieso geen aparte MAC, maar hij vangt een latere
# cipher-wijziging af.
#
# PermitOpen houdt `-L` binnen de container; zonder die regel reikt een forward
# tot alles wat de firewall doorlaat, inclusief de docker-gateway. Alle drie de
# loopback-vormen, want sshd vergelijkt de bestemming letterlijk: een client die
# `127.0.0.1` stuurt matcht niet op `localhost`.
#
# PerSourcePenalties uit: achter een NAT/port-forward deelt elke client één
# bron-IP, en Keplers kortlevende tunnel-connecties tellen als afgebroken
# sessies — die straf zou dus alle clients treffen. LoginGraceTime/MaxAuthTries
# dekken de DoS-hoek af. Volledige afweging: README 'Kepler (SSH-remote)'.
#
# `sshd -t`/`sshd -T` in dezelfde laag: zonder die controle levert een niet-
# toegepaste drop-in (Include weg, optie onbekend in deze OpenSSH) een groene
# build met stil uitgevallen hardening. De lus noemt de ontbrekende directive bij
# naam; een kale exit-code laat de bouwer raden welke het was. De controle draait tegen het echte
# HostKey-pad — met `sshd -h` erlangs zou sshd de config-HostKey er alleen bij
# nemen en per aanroep een ERROR-regel over de ontbrekende sleutel printen. De
# wegwerpsleutel verdwijnt weer in dezelfde laag.
ARG INSTALL_SSHD=false
RUN case "$INSTALL_SSHD" in \
      true) apt-get update && \
            apt-get install -y --no-install-recommends openssh-server && \
            apt-get clean && rm -rf /var/lib/apt/lists/* && \
            rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub && \
            mkdir -p /run/sshd && \
            printf '%s\n' \
              'PasswordAuthentication no' \
              'KbdInteractiveAuthentication no' \
              'PermitEmptyPasswords no' \
              'HostbasedAuthentication no' \
              'IgnoreRhosts yes' \
              'PubkeyAuthentication yes' \
              'AuthenticationMethods publickey' \
              'PermitRootLogin no' \
              'AllowUsers claude' \
              'PermitUserEnvironment no' \
              'PermitUserRC no' \
              'AuthorizedKeysFile .ssh/authorized_keys' \
              'X11Forwarding no' \
              'AllowAgentForwarding no' \
              'AllowStreamLocalForwarding no' \
              'AllowTcpForwarding local' \
              'PermitOpen localhost:* 127.0.0.1:* [::1]:*' \
              'GatewayPorts no' \
              'PermitTunnel no' \
              'LogLevel VERBOSE' \
              'LoginGraceTime 30' \
              'MaxAuthTries 3' \
              'ClientAliveInterval 300' \
              'ClientAliveCountMax 2' \
              'Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com' \
              'MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com' \
              'RequiredRSASize 3072' \
              'PidFile /run/sshd.pid' \
              'PerSourcePenalties no' \
              'HostKey /home/claude/.ssh-host/ssh_host_ed25519_key' \
              > /etc/ssh/sshd_config.d/kepler.conf && \
            printf '\ncase ":$PATH:" in *:/home/claude/.local/bin:*) ;; *) export PATH="/home/claude/.local/bin:$PATH" ;; esac\n' \
              >> /etc/zsh/zshenv && \
            printf '\n# Kepler tunnel-race workaround — zie README "Kepler (SSH-remote)".\nif [[ ! -o interactive && -n "$SSH_CONNECTION" && $SHLVL -eq 1 ]]; then sleep 0.4; fi\n' \
              >> /etc/zsh/zprofile && \
            mkdir -p /home/claude/.ssh-host && \
            ssh-keygen -q -t ed25519 -N '' -f /home/claude/.ssh-host/ssh_host_ed25519_key && \
            sshd -t && \
            effective="$(sshd -T)" && \
            # `-i` op de grep hieronder: `sshd -T` dumpt de sleutelnamen vandaag in
            # lowercase, maar dat is geen toegezegd formaat. Zou een latere versie
            # er mixed case van maken, dan faalt de build met de melding dat de
            # drop-in niet toegepast is, wat de verkeerde kant op wijst. De -i
            # kost hier niets: geen van deze waarden onderscheidt zich op casing.
            for d in 'passwordauthentication no' 'permitrootlogin no' \
                     'allowagentforwarding no' 'allowtcpforwarding local' \
                     'permitopen localhost:* 127.0.0.1:* [::1]:*' \
                     'allowusers claude' 'pidfile /run/sshd.pid' \
                     'authorizedkeysfile .ssh/authorized_keys' \
                     'requiredrsasize 3072' 'loglevel VERBOSE'; do \
              grep -qixF "$d" <<<"$effective" || \
                { echo "FOUT: '$d' staat niet in de effectieve sshd-config — de drop-in is niet toegepast" >&2; exit 1; }; \
            done && \
            rm -rf /home/claude/.ssh-host ;; \
      false) echo "INFO: INSTALL_SSHD=false — OpenSSH-server overgeslagen" ;; \
      *) echo "FOUT: INSTALL_SSHD='$INSTALL_SSHD' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# Vangnet op de invariant hierboven: de wegwerpsleutel van de configcontrole
# hoort in dezelfde laag opgeruimd te zijn. Herordent iemand die keten, dan komt
# er stil weer privésleutelmateriaal in de image te staan.
RUN test ! -e /home/claude/.ssh-host

# Optioneel: alles voor het werken met Fundament, in drie lagen: Go en functl,
# kubectl en helm, en just. Default uit. Houd in sync: de build-arg in
# compose.yml, de tools-tabel in README.md, de toelichting bij INSTALL_FUNDAMENT
# in .env.sample, de tabel 'Optionele componenten' in
# docs/opstarten-en-afsluiten.md, en docs/fundament.md.
#
# De ARG staat boven de eerste van de drie lagen en niet bovenaan: elke RUN na een
# ARG krijgt hem mee, dus een flip zou anders alle lagen hierboven opnieuw laten
# bouwen. Drie lagen in plaats van één, zodat een bump van één pin de lagen
# ervóór in de cache laat.
ARG INSTALL_FUNDAMENT=false

# Go en functl, voor het ontwikkelen van Fundament-plug-ins.
#
# Go en functl worden wekelijks gemonitord door .github/workflows/check-upstream.yml
# (jobs go-version en functl-version). De functl-pins staan na de
# architectuurkeuze en niet naast GO_VERSION: aangrenzende regels laten de twee
# auto-PR's met elkaar conflicteren.
#
# Go komt als officiële tarball op versie plus SHA-256 per architectuur. De
# versie is minstens de `go`-regel in de go.mod van Fundament. GOTOOLCHAIN=local staat
# in $GOROOT/go.env en niet als ENV, zodat hij ook geldt in SSH-sessies; anders
# haalt Go bij een hogere `go`-regel zelf een andere toolchain op, buiten deze
# pin om. sed slaagt ook als het patroon ontbreekt, vandaar de controle erna.
# Telemetry gaat uit vóór de eerste go-aanroep: elke aanroep start anders een
# los proces dat na de opruiming nog in /root/.config kan schrijven.
#
# functl wordt vanaf de bron gebouwd. Upstream publiceert alleen een rolling
# release waarvan de assets bij elke push vervangen worden; een SHA-pin daarop
# breekt de build bij de eerstvolgende upstream-push. De pseudo-versie legt de
# commit vast, de h1-hash de inhoud van de module. functl wordt gebouwd als
# hoofdmodule met -mod=readonly: dan toetst Go elke dependency aan de go.sum
# van Fundament, die onder die h1-hash valt. `go install pkg@versie` leest die
# go.sum niet. De versie-stempel is de pseudo-versie, zodat `functl version`
# direct als `--sdk-version` bruikbaar is.
#
# `functl version` draait als nobody, zonder capabilities en met no_new_privs:
# het is upstream-code, en de setuid-strip komt pas na deze laag. Wat nobody in
# /tmp of /var/tmp achterlaat, zou in de image belanden.
#
# Symlinks in /usr/local/bin in plaats van een ENV PATH: een non-interactieve
# SSH-sessie erft de Docker-ENV niet.
RUN case "$INSTALL_FUNDAMENT" in \
      true) GO_VERSION=1.27.3 && \
            ARCH=$(dpkg --print-architecture) && \
            case "$ARCH" in \
              amd64) GO_SHA=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ;; \
              arm64) GO_SHA=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49 ;; \
              *) echo "FOUT: Go niet beschikbaar voor architectuur '$ARCH'" >&2; exit 1 ;; \
            esac && \
            FUNCTL_VERSION=v0.0.0-20261105173205-d80f3ad60d43 && \
            FUNCTL_H1=h1:BDvOO5d4gY15XMsmVALmrHC1agAl+VnFHKxht/IWvn4= && \
            curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz && \
            echo "$GO_SHA  /tmp/go.tar.gz" | sha256sum -c - && \
            tar -xzf /tmp/go.tar.gz -C /usr/local && \
            rm /tmp/go.tar.gz && \
            sed -i -e 's/^GOTOOLCHAIN=auto$/GOTOOLCHAIN=local/' \
                   -e 's/^# Automatically download newer toolchains as directed by go.mod files.$/# De sandbox pint Go; een andere toolchain ophalen staat uit./' \
                   /usr/local/go/go.env && \
            ln -s /usr/local/go/bin/go /usr/local/bin/go && \
            ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt && \
            go telemetry off && \
            actual=$(go env GOVERSION) && \
            { [[ "$actual" == "go${GO_VERSION}" ]] || { echo "FOUT: go-versie '$actual' != verwacht 'go${GO_VERSION}'" >&2; exit 1; }; } && \
            actual=$(env -u GOTOOLCHAIN go env GOTOOLCHAIN) && \
            { [[ "$actual" == "local" ]] || { echo "FOUT: GOTOOLCHAIN in go.env is '$actual', verwacht 'local'" >&2; exit 1; }; } && \
            export GOPATH=/tmp/gobuild GOCACHE=/tmp/gocache GOFLAGS=-modcacherw && \
            info=$(cd /tmp && go mod download -json "github.com/fundament-oss/fundament@${FUNCTL_VERSION}") && \
            actual=$(jq -r .Sum <<<"$info") && \
            { [[ "$actual" == "${FUNCTL_H1}" ]] || { echo "FOUT: fundament ${FUNCTL_VERSION} heeft hash '$actual', verwacht '${FUNCTL_H1}'" >&2; exit 1; }; } && \
            (cd "$(jq -r .Dir <<<"$info")" && \
              go build -mod=readonly -trimpath \
                -ldflags "-s -w -X github.com/fundament-oss/fundament/functl/pkg/cli.version=${FUNCTL_VERSION}" \
                -o /usr/local/bin/functl ./functl/cmd/functl) && \
            mkdir /tmp/functl-home && chown 65534:65534 /tmp/functl-home && \
            actual=$(HOME=/tmp/functl-home setpriv --reuid=65534 --regid=65534 --clear-groups \
                       --no-new-privs --inh-caps=-all --bounding-set=-all functl version) && \
            { [[ "$actual" == "${FUNCTL_VERSION}" ]] || { echo "FOUT: functl-versie '$actual' != verwacht '${FUNCTL_VERSION}'" >&2; exit 1; }; } && \
            rm -rf /tmp/gobuild /tmp/gocache /tmp/functl-home /root/.config/go && \
            { [ ! -d /root/.config ] || rmdir --ignore-fail-on-non-empty /root/.config; } && \
            { [ ! -e /root/.config/go ] || { echo "FOUT: Go-config blijft achter in /root/.config/go" >&2; exit 1; }; } && \
            left=$(find /tmp /var/tmp -mindepth 1 -user 65534 -print -quit) && \
            { [ -z "$left" ] || { echo "FOUT: functl liet bestanden achter, onder meer $left" >&2; exit 1; }; } ;; \
      false) echo "INFO: INSTALL_FUNDAMENT=false — Go en functl overgeslagen" ;; \
      *) echo "FOUT: INSTALL_FUNDAMENT='$INSTALL_FUNDAMENT' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# kubectl en helm, voor Helm-charts en een cluster buiten de container
# (docs/kubernetes.md).
#
# kubectl werkt met een API-server van één minor-versie lager of hoger. De minor
# volgt dus de clusterversie van Fundament, niet de nieuwste kubectl: de
# clusters van het fieldlab draaien 1.36, en 1.36 dekt 1.35 tot en met 1.37.
#
# De versiecontrole draait als nobody, zonder capabilities en met no_new_privs:
# het is upstream-code, en de setuid-strip komt pas na deze laag. De tijdelijke
# HOME vangt config en cache die de tools eventueel schrijven; wat nobody elders
# achterlaat, zou in de image belanden.
#
# check-upstream.yml volgt de pins wekelijks (jobs kubectl-version en
# helm-version). Elke tool heeft een eigen blok, met regels ertussen die geen
# van beide jobs wijzigt: bij aangrenzende regels conflicteren hun auto-PR's.
RUN case "$INSTALL_FUNDAMENT" in \
      true) ARCH=$(dpkg --print-architecture) && \
            KUBECTL_VERSION=v1.36.6 && \
            case "$ARCH" in \
              amd64) KUBECTL_SHA=29818b6729dc9262b692307470d0558d027725e738be5dd47c760261868a2634 ;; \
              arm64) KUBECTL_SHA=35507ef408c3d38849e5d3203e18f8e861db822aa664101a9ced0869edd06046 ;; \
              *) echo "FOUT: kubectl niet beschikbaar voor architectuur '$ARCH'" >&2; exit 1 ;; \
            esac && \
            curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /tmp/kubectl && \
            echo "$KUBECTL_SHA  /tmp/kubectl" | sha256sum -c - && \
            install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && \
            HELM_VERSION=v4.3.1 && \
            case "$ARCH" in \
              amd64) HELM_SHA=0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b ;; \
              arm64) HELM_SHA=8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88 ;; \
              *) echo "FOUT: helm niet beschikbaar voor architectuur '$ARCH'" >&2; exit 1 ;; \
            esac && \
            curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz && \
            echo "$HELM_SHA  /tmp/helm.tar.gz" | sha256sum -c - && \
            mkdir /tmp/helm && \
            tar -xzf /tmp/helm.tar.gz -C /tmp/helm "linux-${ARCH}/helm" && \
            install -m 0755 "/tmp/helm/linux-${ARCH}/helm" /usr/local/bin/helm && \
            rm -rf /tmp/kubectl /tmp/helm.tar.gz /tmp/helm && \
            mkdir /tmp/k8s-home && chown 65534:65534 /tmp/k8s-home && \
            als_nobody() { HOME=/tmp/k8s-home setpriv --reuid=65534 --regid=65534 --clear-groups \
                             --no-new-privs --inh-caps=-all --bounding-set=-all "$@"; } && \
            actual=$(als_nobody kubectl version --client -o json | jq -r .clientVersion.gitVersion) && \
            { [[ "$actual" == "${KUBECTL_VERSION}" ]] || { echo "FOUT: kubectl-versie '$actual' != verwacht '${KUBECTL_VERSION}'" >&2; exit 1; }; } && \
            actual=$(als_nobody helm version --template '{{.Version}}') && \
            { [[ "$actual" == "${HELM_VERSION}" ]] || { echo "FOUT: helm-versie '$actual' != verwacht '${HELM_VERSION}'" >&2; exit 1; }; } && \
            rm -rf /tmp/k8s-home && \
            left=$(find / /tmp /var/tmp /run/lock -xdev \( -path /proc -o -path /sys \) -prune -o -user 65534 -print -quit) && \
            { [ -z "$left" ] || { echo "FOUT: kubectl of helm liet bestanden achter, onder meer $left" >&2; exit 1; }; } ;; \
      false) echo "INFO: INSTALL_FUNDAMENT=false — kubectl en helm overgeslagen" ;; \
      *) echo "FOUT: INSTALL_FUNDAMENT='$INSTALL_FUNDAMENT' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# just: een plug-in uit `functl plugin create` bouwt en test met just. De versie
# is gelijk aan die in de mise.toml van die scaffold. Officiële release-asset op
# versie plus SHA-256 per architectuur; de versiecontrole draait als nobody,
# zoals in de laag hierboven.
#
# skaffold uit diezelfde mise.toml zit er niet in: de scaffold gebruikt hem
# alleen voor `functl plugin dev`, tegen een lokaal k3d-cluster dat niet in de
# sandbox draait.
#
# TODO(#205): wekelijkse tracking van deze pins.
RUN case "$INSTALL_FUNDAMENT" in \
      true) JUST_VERSION=1.42.4 && \
            ARCH=$(dpkg --print-architecture) && \
            case "$ARCH" in \
              amd64) JUST_TRIPLE=x86_64-unknown-linux-musl; \
                     JUST_SHA=678efc1cfbd5fa5a88375daa7e2f3864a049d6d63a0296df925a2ae5f516cb56 ;; \
              arm64) JUST_TRIPLE=aarch64-unknown-linux-musl; \
                     JUST_SHA=beb35a4ed1208ffbb0fef26042c65875759a5358b9ee1a7856dec8490dfd4aca ;; \
              *) echo "FOUT: just niet beschikbaar voor architectuur '$ARCH'" >&2; exit 1 ;; \
            esac && \
            curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${JUST_TRIPLE}.tar.gz" -o /tmp/just.tar.gz && \
            echo "$JUST_SHA  /tmp/just.tar.gz" | sha256sum -c - && \
            mkdir /tmp/just && \
            tar -xzf /tmp/just.tar.gz -C /tmp/just just && \
            install -m 0755 /tmp/just/just /usr/local/bin/just && \
            rm -rf /tmp/just.tar.gz /tmp/just && \
            mkdir /tmp/just-home && chown 65534:65534 /tmp/just-home && \
            actual=$(HOME=/tmp/just-home setpriv --reuid=65534 --regid=65534 --clear-groups \
                       --no-new-privs --inh-caps=-all --bounding-set=-all just --version) && \
            { [[ "$actual" == "just ${JUST_VERSION}" ]] || { echo "FOUT: just-versie '$actual' != verwacht 'just ${JUST_VERSION}'" >&2; exit 1; }; } && \
            rm -rf /tmp/just-home && \
            left=$(find / /tmp /var/tmp /run/lock -xdev \( -path /proc -o -path /sys \) -prune -o -user 65534 -print -quit) && \
            { [ -z "$left" ] || { echo "FOUT: just liet bestanden achter, onder meer $left" >&2; exit 1; }; } ;; \
      false) echo "INFO: INSTALL_FUNDAMENT=false — just overgeslagen" ;; \
      *) echo "FOUT: INSTALL_FUNDAMENT='$INSTALL_FUNDAMENT' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# Strip setuid/setgid-bits, behalve newuidmap/newgidmap die rootless podman nodig
# heeft. Dit is de dragende hardening-laag, geen opruimactie: zonder deze strip
# kan `claude` na de privilege-drop euid 0 winnen via elke setuid-root-binary.
# Verwijder de regel dus niet als een build erop stukloopt — ADR 0001 §2.2.3
# "Setuid-strip" beschrijft wat er dan open komt te staan.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) \
      ! -name newuidmap ! -name newgidmap \
      -exec chmod -s {} + 2>/dev/null || true

USER claude

# Rootless storage-config (vfs + single-uid). Komt mee via de claude-home volume
# (gepopulate bij eerste run, zoals sdkman/.claude); de entrypoint schrijft 'm
# ook op een bestaand volume. ignore_chown_errors is nodig in single-uid modus:
# images die naar uids buiten de enige gemapte uid chownen mogen niet hard falen.
RUN if [ "$INSTALL_PODMAN" = "true" ]; then \
      mkdir -p /home/claude/.config/containers && \
      printf '[storage]\ndriver = "vfs"\n\n[storage.options.vfs]\nignore_chown_errors = "true"\n' \
        > /home/claude/.config/containers/storage.conf ; \
    fi

# De container start als root zodat de firewall kan worden opgezet;
# entrypoint-root.sh dropt daarna naar `claude`. Gevolg voor bediening: `docker
# exec` zonder -u geeft een root-shell. Gebruik `docker exec -u claude` — de
# root-shell waarschuwt daar zelf ook voor.
USER root

# Beide entrypoints zijn root-eigendom en niet schrijfbaar voor `claude`. Dat is
# geen detail: entrypoint-root.sh draait als root bij elke container-start, dus
# een door `claude` schrijfbaar bestand zou een privilege-escalatie zijn die bij
# de volgende herstart afgaat.
#
# Geen COPY --chown/--chmod: die vlaggen vergen een recente BuildKit- of
# buildah-frontend, en op macOS bouwen gebruikers met podman-compose. Een kale
# COPY landt sowieso als root:root; de chmod doen we expliciet.
COPY entrypoint-root.sh /opt/entrypoint-root.sh
COPY entrypoint.sh /opt/entrypoint.sh
COPY controleer-kubeconfig.sh /opt/controleer-kubeconfig.sh
RUN chmod 0755 /opt/entrypoint-root.sh /opt/entrypoint.sh /opt/controleer-kubeconfig.sh

# Vangnet tegen de footgun hierboven: wie per ongeluk als root de container in
# exec't, krijgt het te zien in plaats van ongemerkt als root te werken en
# root-eigendom achter te laten in het claude-home volume. Systeembreed
# (/etc/{bash.bashrc,zsh/zshrc}) en niet per-user, want de aangeraden shell is
# zsh (root leest dan /root/.zshrc, niet .bashrc) en een systeembreed rc-bestand
# dekt bash én zsh, login én non-login.
RUN mkdir -p /etc/zsh && { \
      echo 'if [ -t 1 ] && [ "$(id -u)" -eq 0 ]; then'; \
      echo '  echo "LET OP: je bent root in de sandbox. Claude en projectcode horen als claude te draaien."'; \
      echo '  echo "Gebruik: docker exec -tiu claude claude-sandbox zsh"'; \
      echo 'fi'; \
    } | tee -a /etc/bash.bashrc >> /etc/zsh/zshrc

WORKDIR /home/claude/projects

ENTRYPOINT ["/opt/entrypoint-root.sh"]
