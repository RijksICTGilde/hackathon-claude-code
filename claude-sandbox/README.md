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

Verdere optionele stappen staan in [Na installatie](#na-installatie). Vervolgens kan je claude starten met
`claude-danger`.

Voor toggles zie [Optionele componenten](#optionele-componenten), voor firewall-opties [Firewall](#firewall).

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
| SDK-manager         | SDKman (standaard aan, optioneel — zie [Optionele componenten](#optionele-componenten))                 |
| Token-optimalisatie | rtk (reduce token use) (standaard aan, optioneel — zie [Optionele componenten](#optionele-componenten)) |
| Firewall            | iptables, ipset, iproute2, dnsutils, aggregate                                                          |

## Plugins en skills
<!-- Houd deze lijsten in sync met de plugin installs in de Dockerfile -->
De volgende plugins zijn voorgeinstalleerd in de image:

### Anthropic plugins

> Deze plugins worden geïnstalleerd als `INSTALL_ANTHROPIC_PLUGINS=true`; bij `false` wordt geen enkele uit deze lijst geïnstalleerd. De LSP-plugins (`jdtls-lsp`, `kotlin-lsp`) vereisen daarnaast `INSTALL_JVM=true`. Zie [Optionele componenten](#optionele-componenten).

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

> Deze plugins worden geïnstalleerd op basis van de toggle in de laatste kolom. De plugins onder `INSTALL_OVERHEID_PLUGINS` zijn standaard aan; `geo` en `zad-actions` staan los achter eigen toggles (default `false`) omdat hun skill-bundels relatief veel context-budget kosten. Zie [Optionele componenten](#optionele-componenten).

| Plugin              | Functie                                          | Toggle                          |
|---------------------|--------------------------------------------------|---------------------------------|
| standaarden         | Nederlandse overheidsstandaarden                 | `INSTALL_OVERHEID_PLUGINS`      |
| developer-overheid  | Developer resources voor Nederlandse overheid    | `INSTALL_OVERHEID_PLUGINS`      |
| nerds               | Nederlandse Richtlijn Digitale Systemen (NeRDS)  | `INSTALL_OVERHEID_PLUGINS`      |
| internet            | Internet.nl standaarden                          | `INSTALL_OVERHEID_PLUGINS`      |
| geo                 | Geospatiale standaarden                          | `INSTALL_OVERHEID_GEO`          |
| zad-actions         | GitHub Actions voor Nederlandse overheid         | `INSTALL_OVERHEID_ZAD_ACTIONS`  |

### Caveman (third-party)

> Wordt geïnstalleerd als `INSTALL_CAVEMAN=true`; bij `false` niet. Zie [Optionele componenten](#optionele-componenten).

| Plugin  | Functie                                                                |
|---------|------------------------------------------------------------------------|
| caveman | Ultra-compressed communicatie-modus (~75% token-reductie via stijl)    |

<!-- Houd deze lijst in sync met de skills/ directory -->
### Lokale skills

> Deze skills worden geïnstalleerd als `INSTALL_LOCAL_SKILLS=true`; bij `false` wordt geen enkele uit deze lijst geïnstalleerd. Zie [Optionele componenten](#optionele-componenten).

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

## Opstarten
Gebruik je `OPEN_HTTPS=false`, kijk dan of je nog extra domeinen wilt openzetten via `ALLOWED_DOMAINS` in `.env`.  
Met docker compose kun je helaas niet een container starten en daarin direct een interactieve sessie hebben, je moet achteraf
verbinding maken met de container.

### Optionele componenten

De image kent build-time toggles waarmee je componenten aan- of uitschakelt. Iedere waarde moet exact `true` of `false` zijn (andere waardes laten de build expliciet falen). De meeste defaults staan op `true`; `INSTALL_DOCKER`, `INSTALL_OVERHEID_GEO` en `INSTALL_OVERHEID_ZAD_ACTIONS` zijn uitzonderingen en staan op `false` (zie de noten bij de tabel).

| Argument                       | Default | Wat het installeert                                                                          |
|--------------------------------|---------|----------------------------------------------------------------------------------------------|
| `INSTALL_JVM`                  | `true`  | SDKman + LSP-plugins (jdtls, kotlin)                                                         |
| `INSTALL_DOCKER`               | `false` | Docker daemon in de container (builds + nested containers); zet de container ook privileged |
| `INSTALL_RTK`                  | `true`  | rtk + auto-patch                                                                             |
| `INSTALL_OVERHEID_PLUGINS`     | `true`  | DON-plugins (standaarden, developer-overheid, nerds, internet)                               |
| `INSTALL_OVERHEID_GEO`         | `false` | Losse `geo`-plugin (Geonovum geo-standaarden); default uit om context-budget te sparen       |
| `INSTALL_OVERHEID_ZAD_ACTIONS` | `false` | Losse `zad-actions`-plugin (ZAD GitHub Actions); default uit om context-budget te sparen     |
| `INSTALL_ANTHROPIC_PLUGINS`    | `true`  | Anthropic-plugins (+ LSP's bij `INSTALL_JVM=true`)                                           |
| `INSTALL_LOCAL_SKILLS`         | `true`  | Lokale skills uit `skills/` (digital-waste-spotter)                                          |
| `INSTALL_CAVEMAN`              | `true`  | caveman plugin (third-party, ~75% token-reductie via communicatie-stijl)                     |

Zet de waardes in `.env` of op de commandline:
```
INSTALL_DOCKER=false docker compose build
```
(`compose.yml` geeft alle waardes via `${INSTALL_X:?}`-interpolatie door als build-args; ontbrekende of lege waardes laten de build vroegtijdig falen.)

> **Let op — `INSTALL_DOCKER=true` impliceert `privileged: true`:** op recente kernels (Ubuntu 24.04+, TUXEDO) kan rootlesskit zonder privileged geen user namespace meer aanmaken, dus crasht de daemon bij start. `compose.yml` koppelt daarom de privileged-flag direct aan `INSTALL_DOCKER`. Een gecompromitteerd proces in een privileged container heeft effectief root op de host — zet de toggle alleen aan als je de Docker daemon (voor builds of nested containers) écht nodig hebt.

> **Let op — volume-recreate vereist:** plugins, skills, rtk en SDKman komen alle terecht onder `/home/claude`, een pad dat onder het `claude-home` volume valt. Het flippen van *elke* toggle vereist daarom **altijd** een image-rebuild **én** volume-recreate, anders blijft de oude inhoud staan (zie [Devcontainer volume-gedrag](#devcontainer-volume-gedrag)). De `cap_add` (NET_ADMIN, NET_RAW) blijven onvoorwaardelijk nodig voor de firewall, ook als `INSTALL_DOCKER=false`.

#### Runtime-toggles

Naast de build-time toggles kent de container één runtime-env-var:

| Variabele                | Default | Wat het doet                                                                                                                                              |
|--------------------------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `MARKETPLACE_AUTOUPDATE` | `true`  | Draait `claude plugin marketplace update` bij entrypoint-start zodat plugin-bundels up-to-date blijven zonder image-rebuild. Niet-fataal bij netwerk-/upstream-failure. |

#### Voorbeeld: `sdk install java` na `INSTALL_JVM=true`

Na een build met `INSTALL_JVM=true` is SDKman aanwezig — installeer een JDK met `sdk install java` (zie ook [Na installatie](#na-installatie)).

Kopieer het `.env.sample` bestand naar `.env` en pas eventueel de projects directory aan:
```
cp .env.sample .env
```
Standaard wordt `./projects` gebruikt. Pas `PROJECTS_DIR` in `.env` aan om een andere directory te mounten.

Er is gekozen voor een externe volume, deze dien je eerst aan te maken:
```
docker volume create claude-home
```

### Devcontainer volume-gedrag
> Het `claude-home` volume mount de volledige home directory (`/home/claude`). Bij de allereerste start (met een leeg volume) wordt de inhoud vanuit de image gekopieerd. Bij volgende starts heeft de inhoud van het volume voorrang op de image — dit is standaard devcontainer-gedrag en zorgt ervoor dat je instellingen, auth tokens, shell history en geinstalleerde tools behouden blijven tussen herstarts en rebuilds. Keerzijde: nieuwe plugins, skills, rtk-patches of SDKman-installs die je via toggles toevoegt, verschijnen pas na het verwijderen en opnieuw aanmaken van het volume:
> ```
> docker compose down
> docker volume rm claude-home && docker volume create claude-home
> docker compose up --build --detach
> ```
> Het is aan de gebruiker om te bepalen wanneer je dit wil doen. Sommige upgrades kunnen ook met de hand toegevoegd worden.

Start daarna de container met docker compose
```
docker compose up --build --detach
```
Je kunt nu connecten met de draaiende container, bijvoorbeeld om een shell (bash, zsh) te starten of om Claude te starten:
- `docker compose exec claude bash`
- `docker compose exec claude claude --dangerously-skip-permissions`
- `docker exec -tiu claude claude-sandbox bash`

Je landt automatisch in de 'projects' directory.

Als je voor de variant met de shell kiest kun je zelf eerst naar je project-directory navigeren en dan Claude starten, dan heb
je meer controle over de historie van Claude (die wordt onthouden voor de directory waarin Claude gestart is).

Voor beide shells wordt er een alias `claude-danger` aangemaakt, daarmee wordt claude gestart met de vlag `--dangerously-skip-permissions`.

## Na installatie
Eenmaal in de container kun je de volgende tools configureren:

### GitHub CLI
Authenticeer met GitHub zodat je repositories kunt clonen en pull requests kunt maken:
```
gh auth login
```
Kies voor HTTPS en volg de browser-flow. Het token wordt opgeslagen in het `claude-home` volume en blijft behouden bij herstarts.

Daarna kun je je git-naam en -e-mail rechtstreeks uit je GitHub-account overnemen:
```
git config --global user.name "$(gh api user --jq '.name // .login')"
git config --global user.email "$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
```
De `noreply`-alias is GitHub's privacy-vriendelijke variant en wordt door commit-attribution gewoon herkend (je echte adres blijft privé).

### Git
Stel je naam en e-mail in (als je geen `gh` gebruikt):
```
git config --global user.name "Je Naam"
git config --global user.email "je@email.nl"
```

### SDKman (Java, Kotlin, Maven, Gradle)
Standaard geïnstalleerd (tenzij `INSTALL_JVM=false`). Installeer een JDK of andere tools met:
```
sdk install java
sdk install maven
```

### Node.js
`node` en `npm` zijn direct beschikbaar:
```
node --version
npm install
```

### Python
`python3` en `pip3` zijn direct beschikbaar:
```
python3 --version
pip3 --version
python3 -m venv .venv && source .venv/bin/activate
```

## Afsluiten
```
docker compose down
```

## Dependency-onderhoud
De build is robuust tegen onverwachte upstream-wijzigingen via twee mechanismen:

1. **Vendoring** voor install-scripts zonder versie-URL. De scripts van `claude.ai/install.sh`, `get.sdkman.io` en de gepinde `rtk` v0.35.0 staan onder `vendor/install-scripts/` en worden via `COPY` in de image gezet. Een upstream-wijziging breekt de build dus nooit; de wijziging komt pas binnen via een gereviewde PR.
2. **Versie- en SHA-pinning** voor binaries en apt-pakketten. Node.js, git-delta en de Docker apt-pakketten staan met exacte versies (en voor de tarballs/.deb's met SHA-256) in `Dockerfile` en `install-docker.sh`. Upstream-releases zijn permanent, dus de pin blijft geldig totdat een nieuwere versie wordt gemerged.

De workflow `.github/workflows/check-upstream.yml` draait elke maandagochtend en opent automatisch een PR zodra:
- een vendored install-script upstream is gewijzigd (PR vervangt het bestand in `vendor/install-scripts/`)
- een nieuwere Node.js LTS-release beschikbaar is (PR werkt versie + amd64/arm64-SHAs bij)
- een nieuwere `git-delta`-release beschikbaar is (idem)
- een nieuwere Docker apt-pakketversie beschikbaar is in de Debian 13 trixie-suite

Review de PR (kijk naar release notes, draai eventueel `docker compose build --no-cache` lokaal) en merge. Dependabot houdt daarnaast de Debian base-image en GitHub Actions zelf bijgewerkt.

> **Eenmalige repo-setting:** Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests" aanvinken, anders kan de workflow geen PR openen.
