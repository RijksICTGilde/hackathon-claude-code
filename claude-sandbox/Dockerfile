FROM debian:13.4-slim@sha256:109e2c65005bf160609e4ba6acf7783752f8502ad218e298253428690b9eaa4b

# Gebruik bash met -e, -u en pipefail zodat pipelines niet stil falen
# (truncated download, HTTP-fouten na redirect, ongedefinieerde variabelen)
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG INSTALL_JVM=true
ARG INSTALL_DOCKER=false
ARG INSTALL_RTK=true
ARG INSTALL_OVERHEID_PLUGINS=true
ARG INSTALL_OVERHEID_GEO=false
ARG INSTALL_OVERHEID_ZAD_ACTIONS=false
ARG INSTALL_ANTHROPIC_PLUGINS=true
ARG INSTALL_LOCAL_SKILLS=true
ARG INSTALL_CAVEMAN=true

# Basis development tools en netwerk/security tools (geïnspireerd op de officiële devcontainer)
# Let op: houd de tools-lijst in de README in sync bij wijzigingen
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    less \
    git \
    curl \
    ca-certificates \
    procps \
    sudo \
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
    python3 \
    python3-pip \
    python3-venv \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js LTS officiële binary (amd64 + arm64); SHAs uit nodejs.org/dist pinnen voor supply-chain integriteit
# Versie + SHAs worden wekelijks gemonitord door .github/workflows/check-upstream.yml
# (opent automatisch een PR zodra er een nieuwere LTS-release is).
# Let op: houd versie in de README tools-tabel in sync
RUN NODE_VERSION=v24.15.0 && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) NODE_ARCH=x64;   SHA=472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6 ;; \
      arm64) NODE_ARCH=arm64; SHA=f3d5a797b5d210ce8e2cb265544c8e482eaedcb8aa409a8b46da7e8595d0dda0 ;; \
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

# git-delta installeren (amd64 + arm64); SHAs uit de upstream release pinnen voor supply-chain integriteit
# Versie + SHAs worden wekelijks gemonitord door .github/workflows/check-upstream.yml
# (opent automatisch een PR zodra er een nieuwere release op dandavison/delta is).
RUN DELTA_VERSION=0.19.2 && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) SHA=ea4f0222950ee750a3d38dd80d03bce4cee07a3f63928fc47548383bcaf23093 ;; \
      arm64) SHA=0edc36cf514f1bd84becac3e94ee8ae9f8818c6a1f99f7b2ee67b362afa253d3 ;; \
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
# afkomstig van https://raw.githubusercontent.com/rtk-ai/rtk/v0.35.0/install.sh).
# Updates komen via .github/workflows/check-upstream.yml (wekelijkse PR bij upstream-diff).
COPY --chown=claude:claude vendor/install-scripts/rtk.sh /tmp/rtk-install.sh
RUN case "$INSTALL_RTK" in \
      true) sh /tmp/rtk-install.sh && \
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
# Install docker (rootless mode). De container draait privileged zodra
# INSTALL_DOCKER=true (compose.yml koppelt die twee); zie compose.yml voor
# de security-trade-off.
COPY install-docker.sh /tmp/install-docker.sh
RUN chmod +x /tmp/install-docker.sh && \
    case "$INSTALL_DOCKER" in \
      true) /tmp/install-docker.sh && rm -f /tmp/install-docker.sh ;; \
      false) rm -f /tmp/install-docker.sh && \
             echo "INFO: INSTALL_DOCKER=false — Docker overgeslagen" ;; \
      *) echo "FOUT: INSTALL_DOCKER='$INSTALL_DOCKER' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "claude ALL=(root) NOPASSWD: SETENV: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/claude-firewall && \
  chmod 0440 /etc/sudoers.d/claude-firewall

USER claude

# Rootless Docker environment
ENV XDG_RUNTIME_DIR=/run/user/1000
ENV DOCKER_HOST=unix:///run/user/1000/docker.sock
# cgroup namespace is vereist voor sysfs mount in geneste user namespaces.
# --net=pasta: pasta (uit passt) i.p.v. default slirp4netns; sneller en zuiniger
# met geheugen. Val terug op slirp4netns door --net=slirp4netns te zetten én
# `slirp4netns` te installeren in install-docker.sh.
ENV DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS="--cgroupns --net=pasta"
# Testcontainers detecteert dat het in een container draait en zou anders
# de default-gateway-IP (172.17.0.1 = Docker Desktop's bridge) gebruiken.
# Rootlesskit publiceert poorten echter op claude-code's localhost, niet
# op die gateway — dus geven we localhost expliciet op.
ENV TESTCONTAINERS_HOST_OVERRIDE=localhost

# Startup script voor firewall
COPY --chown=claude:claude entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR /home/claude/projects

ENTRYPOINT ["/opt/entrypoint.sh"]
