# Opstarten, configureren en afsluiten

## Opstarten
Gebruik je `OPEN_HTTPS=false`, kijk dan of je nog extra domeinen wilt openzetten via `ALLOWED_DOMAINS` in `.env`.  
Met docker compose kun je helaas niet een container starten en daarin direct een interactieve sessie hebben, je moet achteraf
verbinding maken met de container.

### Optionele componenten

De image kent build-time toggles waarmee je componenten aan- of uitschakelt. Iedere waarde moet exact `true` of `false` zijn (andere waardes laten de build expliciet falen). De meeste defaults staan op `true`; `INSTALL_OVERHEID_GEO` en `INSTALL_OVERHEID_ZAD_ACTIONS` zijn uitzonderingen en staan op `false` (zie de noten bij de tabel).

<!-- Houd deze tabel in sync met de ARG-regels in de Dockerfile en de build-args in compose.yml -->

| Argument                       | Default | Wat het installeert                                                                          |
|--------------------------------|---------|----------------------------------------------------------------------------------------------|
| `INSTALL_JVM`                  | `true`  | SDKman + LSP-plugins (jdtls, kotlin)                                                         |
| `INSTALL_RTK`                  | `true`  | rtk + auto-patch                                                                             |
| `INSTALL_OVERHEID_PLUGINS`     | `true`  | DON-plugins (standaarden, developer-overheid, nerds, internet)                               |
| `INSTALL_OVERHEID_GEO`         | `false` | Losse `geo`-plugin (Geonovum geo-standaarden); default uit om context-budget te sparen       |
| `INSTALL_OVERHEID_ZAD_ACTIONS` | `false` | Losse `zad-actions`-plugin (ZAD GitHub Actions); default uit om context-budget te sparen     |
| `INSTALL_ANTHROPIC_PLUGINS`    | `true`  | Anthropic-plugins (+ LSP's bij `INSTALL_JVM=true`)                                           |
| `INSTALL_LOCAL_SKILLS`         | `true`  | Lokale skills uit `skills/` (digital-waste-spotter)                                          |
| `INSTALL_CAVEMAN`              | `true`  | caveman plugin (third-party, ~75% token-reductie via communicatie-stijl)                     |
| `INSTALL_PODMAN`               | `false` | Rootless podman voor Testcontainers ín de sandbox; vereist een platform-override — zie [podman/README.md](../podman/README.md) |
| `PODMAN_MULTIUID`              | `false` | subuid/subgid-range voor `claude`, nodig voor DB-images die naar een tweede uid chownen; vereist `compose.override.podman-multiuid.yml` |
| `INSTALL_SSHD`                 | `false` | OpenSSH-server (gehard) voor de Kepler-remote-opzet; default uit — zie README 'Kepler (SSH-remote)' |
| `INSTALL_GO`                   | `false` | Go en `functl` voor plug-ins op het Fundament-platform — zie [Fundament-plug-ins](#fundament-plug-ins-na-install_gotrue) |

Zet de waardes in `.env` of op de commandline:
```
INSTALL_JVM=false docker compose build
```
(`compose.yml` geeft alle waardes via `${INSTALL_X:?}`-interpolatie door als build-args; ontbrekende of lege waardes laten de build vroegtijdig falen.)

> **Let op — volume-recreate vereist:** plugins, skills, rtk en SDKman komen alle terecht onder `/home/claude`, een pad dat onder het `claude-home` volume valt. Het flippen van *elke* toggle vereist daarom **altijd** een image-rebuild **én** volume-recreate, anders blijft de oude inhoud staan (zie [Devcontainer volume-gedrag](#devcontainer-volume-gedrag)). De `cap_add` (NET_ADMIN, NET_RAW) blijven nodig voor de firewall.

#### Runtime-toggles

Naast de build-time toggles kent de container deze runtime-env-vars:

| Variabele                | Default | Wat het doet                                                                                                                                              |
|--------------------------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `MARKETPLACE_AUTOUPDATE` | `true`  | Draait `claude plugin marketplace update` bij entrypoint-start zodat plugin-bundels up-to-date blijven zonder image-rebuild. Niet-fataal bij netwerk-/upstream-failure. |
| `ENABLE_SSHD`            | `false` | Start de sshd in déze run. Wordt gezet door `compose.override.kepler.yml`; zonder deze var luistert er geen SSH, ook niet in een image met `INSTALL_SSHD=true`. |
| `KEPLER_SSH_PUBKEY`      | _(leeg)_ | Publieke SSH-sleutel die de entrypoint naar `~/.ssh/authorized_keys` schrijft zodat Kepler kan inloggen. Wordt gevalideerd; een ongeldige waarde laat het bestaande bestand ongemoeid. Zie README 'Kepler (SSH-remote)'. |

#### Voorbeeld: `sdk install java` na `INSTALL_JVM=true`

Na een build met `INSTALL_JVM=true` is SDKman aanwezig — installeer een JDK met `sdk install java` (zie ook [Na installatie](#na-installatie)).

#### Fundament-plug-ins na `INSTALL_GO=true`

Met `INSTALL_GO=true` bevat de image Go en [`functl`](https://github.com/fundament-oss/fundament/tree/master/functl), het hulpprogramma waarmee je plug-ins voor het [Fundament-platform](https://docs.fundament-poc.nl/docs/developer/plugins) opzet. Beide staan buiten `claude-home`: na het flippen van deze toggle volstaan een rebuild en een nieuwe container, het volume hoeft niet opnieuw.

Een plug-in opzetten, bouwen en testen:

```bash
sdk=$(go list -m -f '{{.Version}}' "github.com/fundament-oss/fundament@$(functl version | cut -d- -f1)")
functl plugin create mijn-plugin --template minimal --console none --sdk-version "$sdk"
cd mijn-plugin
go mod tidy
go build -o mijn-plugin-plugin . && go test ./...
```

De `--sdk-version` is nodig: zonder die vlag pint `functl` de SDK op een revisie die upstream niet meer bestaat, en dan faalt `go mod tidy` met `unknown revision`. De regel hierboven neemt de SDK van dezelfde commit als de geïnstalleerde `functl`.

- **Netwerk.** Bij `OPEN_HTTPS=false` zet de firewall `proxy.golang.org` en `sum.golang.org` er zelf bij. Een module die niet via die proxy te halen is (privé, een eigen mirror), voeg je toe aan `ALLOWED_DOMAINS`. De firewall resolvet domeinen eenmalig bij de start; verandert het adres van een Google-host daarna, dan helpt een herstart van de container.
- **Modulecache.** Go bewaart downloads onder `~/go`, in het `claude-home`-volume; ze overleven een herstart.
- **Versie.** `GOTOOLCHAIN=local` staat vast: vraagt een `go.mod` een nieuwere Go, dan faalt de build in plaats van dat Go stil een andere toolchain ophaalt.
- **Wat niet kan.** De testomgeving van Fundament voor plug-ins (een lokaal Kubernetes-cluster, ruim 16 GiB geheugen) draait niet in de sandbox: kind en k3d hebben rechten nodig die de afscherming van de container ongedaan maken. Draai dat cluster op de host. `just`, `skaffold` en `k3d` uit de `mise.toml` van de scaffold zitten niet in de image; de `go`-commando's hierboven zijn wat `just build` en `just test` uitvoeren.

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

> **Nested podman (`INSTALL_PODMAN=true`)?** Dit commando gebruikt alleen `compose.yml` en laat de runtime-relaxaties weg die nested/detached containers nodig hebben (device `/dev/net/tun` + security-opts). Start dan met de override erbij; het exacte commando verschilt per OS en staat in [`podman/README.md`](../podman/README.md). Vergeet je de override, dan start de container gewoon, maar waarschuwt de entrypoint bij opstart dat nested containers zullen falen — controleer die log dus na een (her)start.

Je kunt nu connecten met de draaiende container, bijvoorbeeld om een shell (bash, zsh) te starten of om Claude te starten:
- `docker compose exec -u claude claude bash`
- `docker compose exec -u claude claude claude --dangerously-skip-permissions`
- `docker exec -tiu claude claude-sandbox bash`

> `-u claude` is nodig: de container start als root om de firewall op te zetten en dropt daarna naar `claude`. Zonder `-u claude` krijg je een root-shell. In `docker compose exec -u claude claude …` is de eerste `claude` de user en de tweede de service-naam.

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
