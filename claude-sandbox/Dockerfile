FROM debian:13.6-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

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
ARG INSTALL_PODMAN=false
ARG PODMAN_MULTIUID=false

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
RUN NODE_VERSION=v24.19.0 && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) NODE_ARCH=x64;   SHA=14b342e71204f811bde6153be8e04b62aef63c236fef92b55f9c83154b409647 ;; \
      arm64) NODE_ARCH=arm64; SHA=01443c1e1a29e531ccad5a46fefa6df490d2189c49f7955904aecdbb0fe86fdc ;; \
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
RUN NPM_VERSION=11.19.0 && \
    npm install -g "npm@${NPM_VERSION}" --no-audit --no-fund && \
    actual=$(npm --version) && \
    { [[ "$actual" == "${NPM_VERSION}" ]] || { echo "FOUT: npm-versie '$actual' != verwacht '${NPM_VERSION}'" >&2; exit 1; }; }

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
# afkomstig van https://raw.githubusercontent.com/rtk-ai/rtk/v0.45.0/install.sh).
# Updates komen via .github/workflows/check-upstream.yml (wekelijkse PR bij upstream-diff).
# RTK_VERSION pint de binary; zonder pin volgt de installer 'latest' en is de
# image niet reproduceerbaar. Geen losse SHA-pin zoals bij Node.js en git-delta:
# het script verifieert de binary tegen de checksums.txt van dezelfde release.
COPY --chown=claude:claude vendor/install-scripts/rtk.sh /tmp/rtk-install.sh
RUN case "$INSTALL_RTK" in \
      true) RTK_VERSION=v0.45.0 sh /tmp/rtk-install.sh && \
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
RUN case "$INSTALL_PODMAN" in \
      true) apt-get update && \
            apt-get install -y --no-install-recommends \
              podman uidmap passt slirp4netns && \
            apt-get clean && rm -rf /var/lib/apt/lists/* && \
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
RUN chmod 0755 /opt/entrypoint-root.sh /opt/entrypoint.sh

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
