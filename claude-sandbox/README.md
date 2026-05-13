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
| Netwerk             | curl, openssh-client, ca-certificates                                                                   |
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
