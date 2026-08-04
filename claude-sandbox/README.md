# Claude Sandbox
Deze image is voorbereid voor `claude --dangerously-skip-permissions`. gebaseerd op de [devcontainer-opzet van Anthropic](https://code.claude.com/docs/en/devcontainer) voor het draaien van Claude Code in een Docker-container met netwerkbeperkingen. De originele broncode is te vinden in de [anthropics/claude-code Git-repository](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

## Quick start

Voor de volledig uitgeruste image met standaardinstellingen:

```
cp .env.sample .env
docker volume create claude-home
docker compose up --build --detach
docker exec -tiu claude claude-sandbox bash   # werkt ook vanuit andere directories dan deze repo
```

Daarna kun je claude starten met `claude-danger`.

> **Nested podman (`INSTALL_PODMAN=true`)?** Dan is `docker compose up` hierboven niet genoeg: nested/detached containers (Testcontainers, Quarkus Dev Services) vereisen óók de runtime-override die `/dev/net/tun` + security-opts meegeeft. Start met beide files, bv. op macOS:
> ```
> podman-compose -f compose.yml -f compose.override.podman-macos.yml up -d --force-recreate
> ```
> Zie [host-agents/maven/podman/README.md](host-agents/maven/podman/README.md) voor de per-OS-matrix (Linux/Tuxedo/macOS). Zonder de override start de container prima, maar waarschuwt de entrypoint dat nested containers zullen falen. Gebruik je óók `INSTALL_SSHD=true`, geef dan beide overrides mee — zie [Kepler (SSH-remote)](#kepler-ssh-remote).

Verder lezen:
- [Opstarten, configureren en afsluiten](docs/opstarten-en-afsluiten.md) — build-toggles (`INSTALL_*`), runtime-vars, devcontainer volume-gedrag, post-install setup (GitHub CLI, Git, SDKman, Node.js, Python) en afsluiten.
- [Maven MCP-agent (host-side)](docs/maven-mcp-agent.md) — voor Maven-builds die de host-Docker nodig hebben (Testcontainers e.d.).
- [Firewall](#firewall) — netwerk-beperkingen van de container.

> **LET OP**: Bij wijziging in environment variabelen moet ook het volume verwijderd en opnieuw aangemaakt worden. Dit
> reset alle configuratie en data.


## Image beschrijving 
Er is een native versie van Claude geinstalleerd.

Er wordt een directory `projects` aangemaakt (als die er nog niet is), daarin kun je je projecten uitchecken en
bewerken, dit is een volume mount van een lokale directory, op deze manier kun je ook buiten docker naar deze directory
navigeren en de applicatie bouwen, testen of opstarten bijvoorbeeld.

De image bevat een firewall die uitgaand verkeer beperkt. Zie [Firewall](#firewall) voor details.

<!-- Houd deze lijst in sync met de apt-get install in de Dockerfile (sudo is weggelaten: alleen intern gebruikt door firewall) -->
De image bevat de volgende tools:

| Categorie           | Tools                                                                                                   |
|---------------------|---------------------------------------------------------------------------------------------------------|
| Shell & editors     | zsh, nano, vim, less, fzf, man-db                                                                       |
| Versiebeheer        | git, git-delta, gh (GitHub CLI)                                                                         |
| Netwerk             | curl, openssh-client, ca-certificates (+ openssh-server bij `INSTALL_SSHD=true`, zie [Kepler (SSH-remote)](#kepler-ssh-remote)) |
| Zoeken              | ripgrep, file                                                                                           |
| Data & scripting    | jq                                                                                                      |
| Archivering         | zip, unzip, gnupg2, xz-utils                                                                            |
| Systeem             | procps                                                                                                  |
| Runtimes            | Node.js 22 LTS (nodejs.org officiële binary, SHA-pinned), Python 3 (pip3 + venv)                        |
| SDK-manager         | SDKman (standaard aan, optioneel — zie [Optionele componenten](docs/opstarten-en-afsluiten.md#optionele-componenten))                 |
| Token-optimalisatie | rtk (reduce token use) (standaard aan, optioneel — zie [Optionele componenten](docs/opstarten-en-afsluiten.md#optionele-componenten)) |
| Firewall            | iptables, ipset, iproute2, dnsutils, aggregate                                                          |

## Plugins en skills
<!-- Houd deze lijsten in sync met de plugin installs in de Dockerfile -->
De volgende plugins zijn voorgeinstalleerd in de image:

### Anthropic plugins

> Deze plugins worden geïnstalleerd als `INSTALL_ANTHROPIC_PLUGINS=true`; bij `false` wordt geen enkele uit deze lijst geïnstalleerd. De LSP-plugins (`jdtls-lsp`, `kotlin-lsp`) vereisen daarnaast `INSTALL_JVM=true`. Zie [Optionele componenten](docs/opstarten-en-afsluiten.md#optionele-componenten).

| Plugin               | Functie                                         |
|----------------------|-------------------------------------------------|
| github               | GitHub integratie (issues, PRs)                 |
| pr-review-toolkit    | Gespecialiseerde code review agents             |
| commit-commands      | Git workflow automatisering                     |
| superpowers          | Planning, debugging en review workflows         |
| feature-dev          | Begeleide feature-ontwikkeling                  |
| claude-md-management | CLAUDE.md onderhoud                             |
| code-review          | Algemene code review                            |
| code-simplifier      | Code vereenvoudiging en opschoning              |
| security-guidance    | Beveiligingsadvies                              |
| claude-code-setup    | Automatiseringsaanbevelingen voor Claude Code   |
| ralph-loop           | Herhaalt prompt in loop tot taak klaar is       |
| jdtls-lsp            | Java Language Server                            |
| kotlin-lsp           | Kotlin Language Server                          |

### Developer Overheid NL plugins

> Deze plugins worden geïnstalleerd op basis van de toggle in de laatste kolom. De plugins onder `INSTALL_OVERHEID_PLUGINS` zijn standaard aan; `geo` en `zad-actions` staan los achter eigen toggles (default `false`) omdat hun skill-bundels relatief veel context-budget kosten. Zie [Optionele componenten](docs/opstarten-en-afsluiten.md#optionele-componenten).

| Plugin              | Functie                                          | Toggle                          |
|---------------------|--------------------------------------------------|---------------------------------|
| standaarden         | Nederlandse overheidsstandaarden                 | `INSTALL_OVERHEID_PLUGINS`      |
| developer-overheid  | Developer resources voor Nederlandse overheid    | `INSTALL_OVERHEID_PLUGINS`      |
| nerds               | Nederlandse Richtlijn Digitale Systemen (NeRDS)  | `INSTALL_OVERHEID_PLUGINS`      |
| internet            | Internet.nl standaarden                          | `INSTALL_OVERHEID_PLUGINS`      |
| geo                 | Geospatiale standaarden                          | `INSTALL_OVERHEID_GEO`          |
| zad-actions         | GitHub Actions voor Nederlandse overheid         | `INSTALL_OVERHEID_ZAD_ACTIONS`  |

### Caveman (third-party)

> Wordt geïnstalleerd als `INSTALL_CAVEMAN=true`; bij `false` niet. Zie [Optionele componenten](docs/opstarten-en-afsluiten.md#optionele-componenten).

| Plugin  | Functie                                                                |
|---------|------------------------------------------------------------------------|
| caveman | Ultra-compressed communicatie-modus (~75% token-reductie via stijl)    |

<!-- Houd deze lijst in sync met de skills/ directory -->
### Lokale skills

> Deze skills worden geïnstalleerd als `INSTALL_LOCAL_SKILLS=true`; bij `false` wordt geen enkele uit deze lijst geïnstalleerd. Zie [Optionele componenten](docs/opstarten-en-afsluiten.md#optionele-componenten).

| Skill                  | Functie                                                       |
|------------------------|---------------------------------------------------------------|
| digital-waste-spotter  | Analyse van digitale verspilling in code (compute, I/O, etc.) |

Lokale skills staan in de `skills/` directory en worden bij het bouwen van de image meegenomen.

## Firewall
De container draait met een iptables-firewall die uitgaand verkeer beperkt. Bij het opstarten wordt `init-firewall.sh` uitgevoerd.

### Standaard gedrag (OPEN_HTTPS=true)
Met de standaard configuratie (`OPEN_HTTPS=true` in `.env.sample`) wordt al het uitgaand HTTPS-verkeer op poort 443 toegestaan, ongeacht de bestemming. Al het overige verkeer wordt geblokkeerd:

| Verkeer                          | Beleid                                                                   |
|----------------------------------|--------------------------------------------------------------------------|
| Uitgaand HTTPS (poort 443)       | Toegestaan (alle bestemmingen)                                           |
| Uitgaand DNS (poort 53)          | Toegestaan (alleen Docker DNS en host network)                           |
| Host network                     | Toegestaan                                                               |
| Uitgaand overig (incl. SSH)      | Geblokkeerd (REJECT)                                                     |
| Inkomend                         | Geblokkeerd, behalve antwoorden op eigen verzoeken (ESTABLISHED/RELATED) |
| Localhost                        | Toegestaan                                                               |

Git-verkeer naar GitHub wordt automatisch via HTTPS afgehandeld doordat `git config --system` alle `git@github.com:` URL's herschrijft naar `https://github.com/`. SSH-clone URL's werken daardoor gewoon, ook al is poort 22 geblokkeerd.

### Strikte whitelist (OPEN_HTTPS=false)
Zet `OPEN_HTTPS=false` in `.env` om alleen verkeer naar gewhiteliste hosts toe te staan. De whitelist wordt opgebouwd uit GitHub IP-ranges (dynamisch opgehaald) en DNS-resolutie van domeinen uit het script plus de `ALLOWED_DOMAINS` variabele in `.env`. Alleen HTTPS-verkeer (poort 443) is toegestaan naar gewhiteliste IP's.

De Anthropic devcontainer-opzet werkt standaard met een strikte domein-whitelist. Dit project staat standaard al het HTTPS-verkeer toe, om de volgende redenen:

- **Dit project is bedoeld voor open source proof of concepts** waarin geen echte of gevoelige data wordt verwerkt. De voornaamste risico's van een open poort 443 (data-exfiltratie, supply chain aanvallen) zijn daarmee beperkt.
- **Een domein-whitelist is fragiel**: DNS-resolutie kan falen, IP-adressen veranderen, en CDN's roteren regelmatig. Dit leidt tot onvoorspelbare blokkades.
- **Developer experience**: nieuwe tools, package registries en documentatiesites werken direct zonder de whitelist aan te passen.

> **Let op:** voor omgevingen waar wel gevoelige data wordt verwerkt, is de strikte whitelist (`OPEN_HTTPS=false`) aan te raden.

## Kepler (SSH-remote)

[GitKraken Kepler](https://www.gitkraken.com/kepler) is een agentic development environment die coding-agents (o.a. Claude Code) orkestreert. Kepler kan agents op een **remote machine via SSH** draaien: worktrees én agent-sessies draaien remote, de Kepler-UI blijft lokaal. Kepler kent géén "custom agent-command"-optie, dus de agent draait op wát je in-SSH't — daarom draaien we een gehard `sshd` **ín** deze sandbox, zodat Claude in de gecureerde, gefirewallde image blijft draaien i.p.v. op de kale host/VM.

> **Isolatie:** draai de sandbox bij voorkeur in een VM (eigen kernel-grens, zie [docs/maximale-isolatie-linux.md](docs/maximale-isolatie-linux.md)). De VM omhult de container; Kepler bereikt de sandbox-sshd via de VM. Zo voegt SSH inbound-oppervlak toe binnen een grens, niet direct op je host-kernel.

> **Combineer je dit met `INSTALL_PODMAN=true`? Dan is de VM geen voorkeur maar een vereiste.** De podman-override peelt outer-sandbox-hardening af (`systempaths=unconfined` heft de masked/RO `/proc`-paden op, seccomp gaat naar `defaultAction=ALLOW` met een blocklist). Die verzwakte containergrens combineren met een inbound SSH-poort betekent dat één gecompromitteerde SSH-sessie merkbaar dichter bij de kernel staat. In een VM raakt dat de VM-kernel, niet die van je host.

### Beveiliging (niet omzeild)
- **sshd gehard**: alleen pubkey-auth, geen wachtwoord, geen root-login, alleen user `claude` (`/etc/ssh/sshd_config.d/kepler.conf`).
- **Poort alleen op `127.0.0.1`** (nooit `0.0.0.0`) — zie `compose.override.kepler.yml`. In een VM = VM-loopback; Kepler tunnelt naar de VM.
- **Firewall blijft aan**: `init-firewall.sh` laat inbound vanaf het host-netwerk al toe (geen versoepeling nodig); egress-allowlist bevat `api.anthropic.com` + GitHub, dus Claude en git werken.
- **Geen baked keys**: host-keys worden per build gegenereerd (`ssh-keygen -A`); je Kepler-pubkey komt runtime via `KEPLER_SSH_PUBKEY`.
- **Auth zonder secret in env**: `ANTHROPIC_API_KEY` via de container-env bereikt een sshd-sessie níet (sshd reset de env). Gebruik `claude login` — de credentials persisten in het `claude-home` volume.
- **sudoers minimaal**: `claude` mag via NOPASSWD uitsluitend `/usr/sbin/sshd` starten (zelfde patroon als de firewall-drop-in).
- **`PerSourcePenalties no`**: OpenSSH ≥9.8 straft standaard per bron-IP (mislukte/afgebroken connecties → tijdelijke weigering). Achter een NAT/port-forward ziet sshd élke client als dezelfde bron (gvproxy op macOS, of Docker's portpublish), dus die throttling straft legitieme clients voor elkaars gedrag — Kepler opent meerdere sessies, dus dit tikt aan en blokkeert. Op een loopback-only, pubkey-only poort levert het nauwelijks beveiliging op, dus uit (zie de Dockerfile-comment; de smoke-test heeft er een regressie-guard voor). `MaxStartups` blijft op de default.

### Opzet
1. **Build met sshd** (opt-in; vereist image-rebuild + volume-recreate zoals elke toggle):
   ```
   INSTALL_SSHD=true docker compose build
   ```
   > **Bouw je met `podman-compose` (bv. macOS Podman-machine)?** Zet dan `BUILDAH_FORMAT=docker`, anders honoreert buildah de Dockerfile-`SHELL ["/bin/bash", …]` niet en breken de `bash`-constructies (`[[ … ]]`) met `sh: [[: not found`:
   > ```
   > BUILDAH_FORMAT=docker INSTALL_SSHD=true podman-compose -f compose.yml -f compose.override.kepler.yml up --build -d --force-recreate
   > ```
2. **Pubkey + poort** via de override. Zet je Kepler-pubkey in `.env`:
   ```
   KEPLER_SSH_PUBKEY="ssh-ed25519 AAAA... kepler"
   ```
   Start met de override erbij (NIET hernoemen naar `compose.override.yml` — dat auto-load de poort op elke `up`):
   ```
   INSTALL_SSHD=true docker compose -f compose.yml -f compose.override.kepler.yml up --build -d
   ```
   **Draai je ook met `INSTALL_PODMAN=true`, geef dan béide overrides mee.** Overrides stapelen — ze vervangen elkaar niet, maar een `-f` die je weglaat is simpelweg weg. Alleen de kepler-override betekent dus geen `/dev/net/tun` en geen security-opts, waarna de entrypoint waarschuwt en nested containers (Testcontainers, Quarkus Dev Services) falen:
   ```
   INSTALL_SSHD=true docker compose \
     -f compose.yml \
     -f compose.override.podman-linux.yml \
     -f compose.override.kepler.yml \
     up --build -d
   ```
   De twee overrides botsen niet: kepler zet alleen `ports` + `environment`, podman alleen `devices`/`security_opt` + `environment`, en `environment` merget per key. Verifieer het resultaat met `docker compose -f ... config` — check dat `ports`, `/dev/net/tun`, alle vier de `security_opt`-entries en beide env-vars erin staan. Op macOS gebruik je `compose.override.podman-macos.yml`; zie de per-OS-matrix in [host-agents/maven/podman/README.md](host-agents/maven/podman/README.md).
3. **Claude authenticeren** (eenmalig, persist in het volume):
   ```
   docker exec -it claude-sandbox claude login
   ```
4. **Kepler-remote toevoegen**: in Kepler → Settings → Remote Environments → Add Remote Machine, host `127.0.0.1`, poort `2222`, user `claude`, key-based auth. Draait de sandbox in een VM, wijs dan naar de VM (of een SSH-tunnel daarheen).

> **Gebruik `127.0.0.1`, niet `localhost`.** Op macOS met een Podman-machine bindt gvproxy de doorgezette poort **alleen op IPv4** (`lsof -iTCP:2222 -sTCP:LISTEN -n -P` toont één IPv4-regel). macOS resolvet `localhost` eerst naar `::1`, waar niets luistert → `Connection refused`, terwijl `127.0.0.1` het wél doet. Vul dus overal het IP-adres in: in Kepler, in `~/.ssh/config` en in scripts.

> **Caveat — host-key churn:** host-keys worden bij elke image-build opnieuw gegenereerd. Na een rebuild ziet Kepler een gewijzigde host-key (known_hosts-mismatch); verwijder de oude entry of persist de host-keys op het volume als je vaak herbouwt.

> **Caveat — `authorized_keys` wordt elke start overschreven:** staat `KEPLER_SSH_PUBKEY` gezet, dan schrijft de entrypoint het bestand bij iedere container-start opnieuw. Een handmatig toegevoegde tweede sleutel overleeft dus geen `restart`. De var houdt één sleutel: een `\n` in `.env` komt als letterlijke backslash-n in het bestand terecht (de entrypoint gebruikt `printf '%s'`), niet als regeleinde. Meerdere sleutels nodig? Laat `KEPLER_SSH_PUBKEY` leeg en beheer `authorized_keys` zelf op het volume — de entrypoint laat een bestaand, niet-leeg bestand met rust.

> **Kepler-bug — `ssh exited before the tunnel on local port N was ready (code 0)`:** Kepler zet een SSH ControlMaster op en draait de tunnel als `ssh -N -L` mux-slave. Een mux-slave vraagt áltijd een sessie aan (ook met `-N` — bekend OpenSSH-gedrag), draagt de forward over aan de master en exit binnen ~10-30 ms. De poort is dan al klaar, maar Keplers readiness-poll (`waitForTunnelReady`) behandelt het ssh-child-exit als fataal en gooit vóór z'n poort-check. De forward zélf werkt (curl door de tunnel geeft HTTP 200); het is een race die Kepler verliest. Server-onafhankelijk (reproduceert ook tegen een kale sshd), dus een Kepler-bug, geen sandbox-fout. **Workaround in het image:** `/etc/zsh/zprofile` rekt de fantoom-login-shell die de mux-slave opent met een korte `sleep` (alleen non-interactieve login-shells; de `zsh -c` probe en interactieve shells blijven ongemoeid), zodat Keplers eerste poll de al-klare poort pakt vóór het child exit. Zie de Dockerfile-comment bij `INSTALL_SSHD`; de smoke-test heeft er een regressie-guard voor (sectie 7). Los dit bij voorkeur upstream op — dan kan de workaround eruit.

### Testen
`host-agents/kepler/smoke-test.sh` draait vanaf de **host** (niet in de container) tegen een al draaiende sandbox, en verifieert poortbinding, login, PATH in een non-interactieve sessie, de hardening-weigeringen, de PerSourcePenalties- en tunnel-race-workarounds en de firewall:
```
./host-agents/kepler/smoke-test.sh -i ~/.ssh/kepler
./host-agents/kepler/smoke-test.sh -i ~/.ssh/kepler --podman   # gestapelde override
```
`--help` toont de rest (`--host`/`--port` voor een sandbox in een VM, `--cli podman`). Exit-code 0 = alles groen.

Test daarnaast één keer de **regressie**: een build met `INSTALL_SSHD=false` hoort géén `sshd` in de image te hebben, geen poort te publiceren en niets over SSH te loggen. De toggle moet uit-blijven als je hem niet aanzet.

## Dependency-onderhoud
De build is robuust tegen onverwachte upstream-wijzigingen via twee mechanismen:

1. **Vendoring** voor install-scripts zonder versie-URL. De scripts van `claude.ai/install.sh`, `get.sdkman.io` en de gepinde `rtk` v0.35.0 staan onder `vendor/install-scripts/` en worden via `COPY` in de image gezet. Een upstream-wijziging breekt de build dus nooit; de wijziging komt pas binnen via een gereviewde PR.
2. **Versie- en SHA-pinning** voor binaries. Node.js en git-delta staan met exacte versies en SHA-256 in `Dockerfile`. Upstream-releases zijn permanent, dus de pin blijft geldig totdat een nieuwere versie wordt gemerged.

De workflow `.github/workflows/check-upstream.yml` draait elke maandagochtend en opent automatisch een PR zodra:
- een vendored install-script upstream is gewijzigd (PR vervangt het bestand in `vendor/install-scripts/`)
- een nieuwere Node.js LTS-release beschikbaar is (PR werkt versie + amd64/arm64-SHAs bij)
- een nieuwere `git-delta`-release beschikbaar is (idem)

Review de PR (kijk naar release notes, draai eventueel `docker compose build --no-cache` lokaal) en merge. Dependabot houdt daarnaast de Debian base-image en GitHub Actions zelf bijgewerkt.

> **Eenmalige repo-setting:** Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests" aanvinken, anders kan de workflow geen PR openen.
