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

> **Nested podman (`INSTALL_PODMAN=true`)?** Dan is `docker compose up` hierboven niet genoeg: nested/detached containers (Testcontainers, Quarkus Dev Services) vereisen óók de runtime-override die `/dev/net/tun` + security-opts meegeeft. Het exacte startcommando verschilt per OS en staat in [podman/README.md](podman/README.md). Zonder de override start de container prima, maar waarschuwt de entrypoint dat nested containers zullen falen. Gebruik je óók `INSTALL_SSHD=true`, geef dan beide overrides mee — zie [Kepler (SSH-remote)](#kepler-ssh-remote).

Verder lezen:
- [Opstarten, configureren en afsluiten](docs/opstarten-en-afsluiten.md) — build-toggles (`INSTALL_*`), runtime-vars, devcontainer volume-gedrag, post-install setup (GitHub CLI, Git, SDKman, Node.js, Python) en afsluiten.
- [Maven en Testcontainers via podman](podman/README.md) — Testcontainers draait ín de sandbox, via rootless podman. Er is geen host-side agent meer. Niet elk platform is ondersteund; zie de platformtabel daar.
- [Firewall](#firewall) — netwerk-beperkingen van de container.

> **LET OP**: Bij wijziging in environment variabelen moet ook het volume verwijderd en opnieuw aangemaakt worden. Dit
> reset alle configuratie en data.


## Image beschrijving 
Er is een native versie van Claude geinstalleerd.

Er wordt een directory `projects` aangemaakt (als die er nog niet is), daarin kun je je projecten uitchecken en
bewerken. Dit is een volume mount van een lokale directory, zodat je ook buiten docker bij deze bestanden kunt.

> **Let op:** Claude schrijft in deze map, inclusief `pom.xml`, `mvnw`, `Makefile`, `package.json`-scripts en
> git-hooks. Draai host-side build-tooling (`mvn`, `npm`, `make`) niet blind op deze map na een Claude-sessie — dat
> voert die bestanden uit met jouw host-rechten (issue #44). Draai builds en tests ín de sandbox; voor Testcontainers
> zie [podman/README.md](podman/README.md).

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

> **Isolatie:** draai de sandbox bij voorkeur in een VM (eigen kernel-grens). De VM omhult de container; Kepler bereikt de sandbox-sshd via de VM. Zo voegt SSH inbound-oppervlak toe binnen een grens, niet direct op je host-kernel.

> **Combineer je dit met `INSTALL_PODMAN=true`? Dan is de VM geen voorkeur maar een vereiste.** De podman-override peelt outer-sandbox-hardening af (`systempaths=unconfined` heft de masked/RO `/proc`-paden op, seccomp gaat naar `defaultAction=ALLOW` met een blocklist). Die verzwakte containergrens combineren met een inbound SSH-poort betekent dat één gecompromitteerde SSH-sessie merkbaar dichter bij de kernel staat. In een VM raakt dat de VM-kernel, niet die van je host.

### Beveiliging (niet omzeild)
- **sshd gehard**: pubkey-only (`AuthenticationMethods publickey`), geen root-login, alleen user `claude`, geen agent- of X11-forwarding, `AllowTcpForwarding local` (Kepler heeft alleen `-L` nodig), `LoginGraceTime 30`, `MaxAuthTries 3`, `LogLevel VERBOSE`, `RequiredRSASize 3072` (genereer bij voorkeur een ed25519-sleutel). De volledige stand staat in `/etc/ssh/sshd_config.d/kepler.conf`; de build weigert als die drop-in niet toegepast blijkt (`sshd -t`/`sshd -T`).
- **SSH staat alleen aan als je erom vraagt**: de entrypoint start sshd op `ENABLE_SSHD=true`, wat `compose.override.kepler.yml` zet — niet op de aanwezigheid van de binary. Een image die één keer met `INSTALL_SSHD=true` gebouwd is, zet dus niet bij elke `up` een poort open.
- **Geen sleutels in de image**: host-keys worden bij eerste start op het `claude-home` volume aangemaakt, niet tijdens de build — een privésleutel in een image-layer zou iedereen met die image de identiteit van je sandbox geven. Je Kepler-pubkey komt runtime via `KEPLER_SSH_PUBKEY` en wordt gevalideerd voor hij weggeschreven wordt.
- **Auth-logging**: sshd logt naar `/var/log/sshd/sshd.log` op een eigen volume (er draait geen syslog-daemon; zonder dit verdwijnt elke login spoorloos). Het bestand is `640 root:claude` en `/var/log` is van root: root schrijft, `claude` leest mee maar kan bestaande regels niet aanpassen, verwijderen of het pad omleggen. `LogLevel VERBOSE` zet de key-fingerprint erbij. OpenSSH schrijft zelf geen datum of tijd achter `-E`; sshd schrijft daarom naar een fifo en een root-leesluis zet er een ISO-8601-tijdstempel voor.
- **`ANTHROPIC_API_KEY` staat buiten sshd zelf**: de daemon wordt gestart met `env -u ANTHROPIC_API_KEY`, zodat een pre-auth-lek in OpenSSH de sleutel niet uit zijn eigen omgeving kan lezen. Dat beschermt de daemon, niet de sessie: de sessie zelf krijgt de variabele niet — sshd bouwt daar een verse omgeving op — maar de entrypoint en alles wat daaruit voortkomt draagt hem wél, en een sessie is dezelfde uid, dus `/proc/<pid>/environ` van zo'n proces levert hem alsnog. Gebruik bij voorkeur `claude login`.
- **Geen sudo- of setuid-route naar root**: sshd start in de root-fase van de entrypoint, vóór de privilege-drop — zelfde patroon als de firewall. Er is geen `sudo` en geen sudoers-regel in de image, en setuid-bits worden gestript.
- **sshd erft de firewall-capabilities niet**: hij start via `setpriv --bounding-set=-net_admin,-net_raw`, zodat een lek in OpenSSH niet meteen `iptables -F` kan doen.
- **`PermitOpen localhost:* 127.0.0.1:* [::1]:*`**: Keplers `-L`-tunnel mag alleen naar de container zelf, niet naar de docker-gateway of buurcontainers. Alle drie de loopback-vormen staan erin omdat sshd de bestemming letterlijk vergelijkt, zonder naamresolutie.
- **`PerSourcePenalties no`**: OpenSSH ≥9.8 straft per bron-IP. Keplers kortlevende tunnel-connecties tellen als afgebroken sessies, en achter een NAT/port-forward (gvproxy op macOS, Docker's portpublish) ziet sshd élke client als dezelfde bron — die straf treft dus alle clients samen. Met pubkey-only valt er niets te raden, dus de maatregel kost meer dan hij oplevert; `LoginGraceTime`/`MaxAuthTries` dekken de resterende DoS-hoek af. De smoke-test heeft er een regressie-guard voor.

### Beveiliging (wat het níet dekt)
- **De loopback-binding geldt alleen vanaf de host.** Binnen de container luistert sshd op `0.0.0.0:22`, en `init-firewall.sh` accepteert inbound vanaf het hele bridge-subnet. Een andere container op datzelfde compose-netwerk bereikt poort 22 dus rechtstreeks, langs de `127.0.0.1`-publish om. Draai geen onvertrouwde containers op dit netwerk.
- **Een geslaagde login is een volledige shell als `claude`** — inclusief schrijfrechten op de host-bindmount `${PROJECTS_DIR}:/home/claude/projects` en leestoegang tot de `claude login`-credentials op het volume. De SSH-hardening beperkt wie binnenkomt, niet wat die daarna mag.
- **Poortforwarding blijft mogelijk.** `AllowTcpForwarding local` is nodig voor Keplers tunnel; een sessie kan daarmee poorten op de container zelf benaderen. `PermitOpen` houdt dat binnen de container — draait je devserver niet op loopback maar op het container-IP, dan werkt de tunnel ernaartoe niet.
- **Geen agent-forwarding.** `AllowAgentForwarding no` houdt je host-sleutels buiten de sandbox, maar betekent ook dat je vanuit een Kepler-worktree niet met de host-sleutel kunt pushen. Regel git-toegang ín de container (`gh auth login`).
- **De auth-log roteert niet en verlaat de container niet.** Het bestand staat op het `sshd-log` volume en overleeft een container-recreate, maar groeit onbegrensd en verdwijnt zodra je dat volume verwijdert. Let op het verschil met `claude-home`: dat volume is `external`, `sshd-log` niet, dus `docker compose down -v` wist juist het spoor en laat de data staan. Wil je het als bewijsmateriaal, stuur het dan naar een bestemming buiten de sandbox — binnen de container blijft het het enige exemplaar, en wie root in de container heeft kan het alsnog herschrijven.
- **Het spoor is stil te leggen door de ingesloten partij.** sshd schrijft naar een fifo waar een root-leesluis de tijdstempel bijzet. Eén mislukte schrijfactie is genoeg om die luis definitief te beëindigen — hij erft `errexit` — en niets brengt hem terug behalve een herstart. Is hij weg, dan verdwijnen regels van de daemon geruisloos, want sshd negeert SIGPIPE en controleert het schrijfresultaat niet. Nieuwe verbindingen blokkeren dan op het openen van de fifo, vóór authenticatie: SSH-toegang valt stil zonder melding, en de container moet herstart worden om de luis terug te krijgen.
- **Een lek in sshd levert container-root op.** De daemon draait als root (nodig voor privilege separation), dus een pre-auth-kwetsbaarheid weegt zwaarder dan een gecompromitteerde sessie als `claude`.
- **`openssh-server` komt ongepind uit apt** en valt buiten Dependabot. CI scant de sshd-variant wel met Trivy, dus een kwetsbare sshd blokkeert de PR; de fix is een rebuild. Met een luisterende dienst erbij is regelmatig herbouwen geen hygiëne meer maar een beveiligingseis.
- **Bij een `docker exec` als root** staat `/home/claude/.local/bin` — door `claude` beschrijfbaar — vooraan in `PATH`. Dat is niet nieuw in deze opzet, maar de kring die als `claude` kan draaien wordt met SSH wel groter. Gebruik `docker exec -u claude`.

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
   Start met de override erbij — die publiceert de poort én zet `ENABLE_SSHD=true`, waarop de entrypoint sshd start (waarom je 'm niet hernoemt: zie de kop van `compose.override.kepler.yml`):
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
   De twee overrides botsen niet: kepler zet alleen `ports` + `environment`, podman alleen `devices`/`security_opt` + `environment`, en `environment` merget per key. Verifieer het resultaat met `docker compose -f ... config` — check dat `ports`, `/dev/net/tun`, alle vier de `security_opt`-entries en beide env-vars erin staan. Op macOS gebruik je `compose.override.podman-macos.yml`; zie de per-OS-matrix in [podman/README.md](podman/README.md).
3. **Claude authenticeren** (eenmalig, persist in het volume):
   ```
   docker exec -it claude-sandbox claude login
   ```
4. **Kepler-remote toevoegen**: in Kepler → Settings → Remote Environments → Add Remote Machine, host `127.0.0.1`, poort `2222`, user `claude`, key-based auth. Draait de sandbox in een VM, wijs dan naar de VM (of een SSH-tunnel daarheen).

> **Gebruik `127.0.0.1`, niet `localhost`.** Op macOS met een Podman-machine bindt gvproxy de doorgezette poort **alleen op IPv4** (`lsof -iTCP:2222 -sTCP:LISTEN -n -P` toont één IPv4-regel). macOS resolvet `localhost` eerst naar `::1`, waar niets luistert → `Connection refused`, terwijl `127.0.0.1` het wél doet. Vul dus overal het IP-adres in: in Kepler, in `~/.ssh/config` en in scripts.

> **Caveat — host-key na volume-recreate:** de host-key staat op het `claude-home` volume en overleeft een image-rebuild. Verwijder je het volume (nodig bij elke wijziging in environment-variabelen), dan komt er een nieuwe en ziet Kepler een known_hosts-mismatch; verwijder dan de oude entry.

> **Het auth-spoor staat op een eigen volume.** `sshd-log` wordt door compose aangemaakt en staat los van `claude-home`: verwijder je dat laatste om een environment-variabele te wijzigen, dan blijven de auth-events staan. Andersom geldt het ook, en dat is de verrassende kant: `claude-home` is `external` en `sshd-log` niet, dus `docker compose down -v` gooit het spoor weg en laat je data ongemoeid.

> **Caveat — `authorized_keys` wordt elke start overschreven:** staat `KEPLER_SSH_PUBKEY` gezet, dan schrijft de entrypoint het bestand bij iedere container-start opnieuw. Een handmatig toegevoegde tweede sleutel overleeft dus geen `restart`. De var houdt één sleutel; een meerregelige of ongeldige waarde wordt geweigerd en laat het bestaande bestand ongemoeid. Meerdere sleutels nodig? Laat `KEPLER_SSH_PUBKEY` leeg en beheer `authorized_keys` zelf op het volume — de entrypoint laat een bestaand, niet-leeg bestand met rust.

> **Kepler-bug — `ssh exited before the tunnel on local port N was ready (code 0)`:** Kepler zet een SSH ControlMaster op en draait de tunnel als `ssh -N -L` mux-slave. Een mux-slave vraagt áltijd een sessie aan (ook met `-N` — bekend OpenSSH-gedrag), draagt de forward over aan de master en exit binnen ~10-30 ms. De poort is dan al klaar, maar Keplers readiness-poll (`waitForTunnelReady`) behandelt het ssh-child-exit als fataal en gooit vóór z'n poort-check. De forward zélf werkt; het is een race die Kepler verliest, en de bug ligt bij Kepler — wij kunnen 'm hier alleen omzeilen. **Workaround in het image:** `/etc/zsh/zprofile` rekt die fantoom-login-shell met een `sleep 0.4`, zodat Keplers eerste poll de al-klare poort pakt vóór het child exit. De guard beperkt dat tot echte SSH-sessies (`$SSH_CONNECTION` gezet, niet-interactief, buitenste shell), zodat een `zsh -lc` van een orchestrator die vertraging niet betaalt. De smoke-test heeft er een regressie-guard voor (sectie 7). Zodra Kepler dit upstream fixt, kan de workaround eruit.

### Testen
`kepler/smoke-test.sh` draait vanaf de **host** (niet in de container) tegen een al draaiende sandbox, en verifieert poortbinding, login, PATH in een non-interactieve sessie, de effectieve sshd-config, de host-key op het volume, de capabilities van het sshd-proces, een echte `-L`-tunnel, de PerSourcePenalties- en tunnel-race-workarounds en de firewall:
```
./kepler/smoke-test.sh -i ~/.ssh/kepler
./kepler/smoke-test.sh -i ~/.ssh/kepler --podman   # gestapelde override
```
`--help` toont de rest (`--host`/`--port` voor een sandbox in een VM, `--cli podman`). Exit-code 0 = alles groen.

Test daarnaast de **regressie** dat SSH uit blijft als je er niet om vraagt — zowel een build met `INSTALL_SSHD=false` als een image mét sshd die je zónder de kepler-override start:

```
./kepler/smoke-test.sh --expect-no-sshd
```

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
