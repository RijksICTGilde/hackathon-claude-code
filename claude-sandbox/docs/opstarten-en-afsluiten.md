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
| `INSTALL_K8S`                  | `false` | `kubectl` en `helm` voor Helm-charts en een cluster buiten de container — zie [Kubernetes-clusters](#kubernetes-clusters-na-install_k8strue) |

Zet de waardes in `.env` of op de commandline:
```
INSTALL_JVM=false docker compose build
```
(`compose.yml` geeft de verplichte waardes via `${INSTALL_X:?}`-interpolatie door als build-args; ontbrekende of lege waardes laten de build vroegtijdig falen. De optionele toggles met default `false` gaan via `${INSTALL_X:-false}`, zodat een bestaande `.env` zonder die regel blijft werken.)

> **Let op — volume-recreate vereist:** plugins, skills, rtk en SDKman komen alle terecht onder `/home/claude`, een pad dat onder het `claude-home` volume valt. Het flippen van zo'n toggle vereist daarom een image-rebuild **én** volume-recreate, anders blijft de oude inhoud staan (zie [Devcontainer volume-gedrag](#devcontainer-volume-gedrag)). De `cap_add` (NET_ADMIN, NET_RAW) blijven nodig voor de firewall.

#### Runtime-toggles

Naast de build-time toggles kent de container deze runtime-env-vars:

| Variabele                | Default | Wat het doet                                                                                                                                              |
|--------------------------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `MARKETPLACE_AUTOUPDATE` | `true`  | Draait `claude plugin marketplace update` bij entrypoint-start zodat plugin-bundels up-to-date blijven zonder image-rebuild. Niet-fataal bij netwerk-/upstream-failure. |
| `ENABLE_SSHD`            | `false` | Start de sshd in déze run. Wordt gezet door `compose.override.kepler.yml`; zonder deze var luistert er geen SSH, ook niet in een image met `INSTALL_SSHD=true`. |
| `KEPLER_SSH_PUBKEY`      | _(leeg)_ | Publieke SSH-sleutel die de entrypoint naar `~/.ssh/authorized_keys` schrijft zodat Kepler kan inloggen. Wordt gevalideerd; een ongeldige waarde laat het bestaande bestand ongemoeid. Zie README 'Kepler (SSH-remote)'. |

#### Voorbeeld: `sdk install java` na `INSTALL_JVM=true`

Na een build met `INSTALL_JVM=true` is SDKman aanwezig — installeer een JDK met `sdk install java` (zie ook [Na installatie](#na-installatie)).

#### Kubernetes-clusters na `INSTALL_K8S=true`

Met `INSTALL_K8S=true` bevat de image `kubectl` en `helm`. Daarmee schrijf en controleer je [Helm-charts](https://helm.sh/docs/topics/charts/), en rol je ze uit naar een cluster buiten de container. Beide tools staan buiten `claude-home`: na het flippen van deze toggle volstaan een rebuild en een nieuwe container, het volume hoeft niet opnieuw. Wat `helm` zelf bewaart (chart-repositories, cache), komt onder `~/.config/helm` en `~/.cache/helm` in het volume.

**Charts controleren zonder cluster.** Hiervoor is geen cluster en geen netwerk nodig:

```bash
helm create demo     # maakt een voorbeeldchart
helm lint demo       # controleert de chart op fouten
helm template demo   # toont de Kubernetes-bestanden die de chart oplevert
```

Gebruikt een chart andere charts (`dependencies` in `Chart.yaml`), dan haalt `helm dependency build` die op; zie [Netwerk](#netwerk-welke-domeinen) voor wat de firewall daarvoor vraagt.

**Wat niet kan: een cluster ín de sandbox.** Een Kubernetes-cluster start zelf containers. Daarvoor heeft de sandbox rechten nodig die de afscherming van de container ongedaan maken: er is geen `/dev/fuse`, de sandbox mag geen netwerken voor geneste containers aanmaken, en een geneste privileged container mag `sysfs` niet mounten. Het cluster draait dus altijd buiten de sandbox: op je eigen machine of op afstand. Dat geldt ook voor de testomgeving van Fundament voor plug-ins, een k3d-cluster dat 16 tot 24 GiB geheugen vraagt.

##### Toegang geven: de kubeconfig

`kubectl` en `helm` vinden een cluster via een *kubeconfig*: een bestand met het adres van het cluster en je toegangsgegevens. `compose.override.kubeconfig.yml` zet zo'n bestand van de host alleen-lezen in de container.

1. Maak op de host een eigen map voor de sandbox, buiten je projectmap, en zet de kubeconfig daarin als `config`. Hoe je een kubeconfig met beperkte rechten maakt, staat bij [Rechten](#rechten-wat-claude-met-het-cluster-kan).
   ```bash
   mkdir -p ~/.kube && mkdir -m 700 ~/.kube/sandbox
   # ... kubeconfig in ~/.kube/sandbox/config zetten ...
   chmod 644 ~/.kube/sandbox/config
   ```
   De map kan alleen jij openen; het bestand zelf moet leesbaar zijn voor iedereen. Rootless podman maakt van jouw bestand in de container een bestand van root, en een bestand met `600` kan de gebruiker `claude` dan niet lezen.
2. Zet het absolute pad in `.env`, bijvoorbeeld `SANDBOX_KUBECONFIG=/Users/jij/.kube/sandbox/config`.
3. Start de container met de override erbij. Gebruik je een podman-override, zet die er met nog een `-f` bij.
   ```bash
   docker compose -f compose.yml -f compose.override.kubeconfig.yml up -d
   ```
4. Controleer in de container met `kubectl version`. Dat toont de versie van `kubectl` (1.35) en die van het cluster. Scheelt dat meer dan één minor-versie, dan waarschuwt `kubectl`; kies dan een cluster op 1.34, 1.35 of 1.36.

Wat de override wel en niet doet:

- Het bestand staat in de container op `/run/kubeconfig/config`, buiten de projectmap en buiten `claude-home`. Start je zonder de override, dan is het weg.
- De sandbox kan het bestand niet wijzigen. Een andere namespace kies je per commando (`-n <naam>`), of op de host in het bestand zelf (`kubectl config set-context --current --namespace=<naam> --kubeconfig ~/.kube/sandbox/config`).
- Wat je op de host met `kubectl config` in het bestand wijzigt, ziet de draaiende container meteen. Zet je er een nieuw bestand voor in de plaats (sommige editors doen dat bij opslaan), dan ziet de container dat pas na `up -d --force-recreate`.
- De sandbox kan het bestand wel lezen, en daarmee het token erin. Claude kan het kopiëren, of versturen naar elke bestemming die de firewall doorlaat. Geef de sandbox daarom alleen toegang die weinig mag en snel verloopt.
- `KUBECONFIG` staat in de omgeving van de container, maar niet in een SSH-sessie (Kepler). Typ daar zelf `export KUBECONFIG=/run/kubeconfig/config`.

Een kubeconfig in `claude-home` (`~/.kube/config`) werkt ook. Maar die blijft staan tot je het volume verwijdert, ook na een rebuild, en de sandbox kan hem aanpassen.

##### Rechten: wat Claude met het cluster kan

Claude kan alles wat de toegangsgegevens in de kubeconfig toestaan: pods starten, Secrets lezen, resources verwijderen. De sandbox en de firewall beperken dat niet. Geef de sandbox daarom eigen toegang:

- **Eén namespace, geen clusterbeheer.** De ingebouwde rol `edit` mag workloads in één namespace beheren, maar geen rechten of quota wijzigen. Ook `edit` mag de Secrets in die namespace lezen.
- **Kort geldig.** Een token van enkele uren, niet een certificaat of token zonder einddatum.
- **Geen pods met toegang tot de node.** Zet op de namespace Pod Security `baseline`. Zonder die grens kan wie pods mag starten, uit het cluster breken. Bij k3d is dat de stap naar je eigen machine: de nodes zijn privileged containers op je host.

De kubeconfig die k3d of een cloudprovider je geeft, is meestal die van de clusterbeheerder. Gebruik die op de host om een beperkte toegang voor de sandbox te maken, hier voor namespace `team-a`:

```bash
kubectl create namespace team-a
kubectl label namespace team-a pod-security.kubernetes.io/enforce=baseline
kubectl -n team-a create serviceaccount sandbox
kubectl -n team-a create rolebinding sandbox-edit --clusterrole=edit --serviceaccount=team-a:sandbox

F=~/.kube/sandbox/config
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode > ca.crt
kubectl --kubeconfig "$F" config set-cluster doel --server="$SERVER" --certificate-authority=ca.crt --embed-certs
kubectl --kubeconfig "$F" config set-credentials sandbox --token="$(kubectl -n team-a create token sandbox --duration=8h)"
kubectl --kubeconfig "$F" config set-context sandbox --cluster=doel --user=sandbox --namespace=team-a
kubectl --kubeconfig "$F" config use-context sandbox
rm ca.crt && chmod 644 "$F"
```

Na acht uur verloopt het token; draai dan de regel met `set-credentials` opnieuw, met dezelfde `F`. Eerder intrekken kan met `kubectl -n team-a delete serviceaccount sandbox`.

**Fundament** werkt anders. De kubeconfig uit de console of van `functl cluster kubeconfig` bevat geen token, maar vraagt bij elk gebruik een kortlevend token aan via `functl cluster token`. Daarvoor moet `functl` in de container staan en ingelogd zijn (`functl auth login`). De API-sleutel die je daarbij opgeeft, komt in `~/.config/fundament/credentials`, in `claude-home`, en blijft daar staan. Wat het token mag, hangt af van je rol in Fundament:

- Ben je organisatiebeheerder, dan heeft Claude volledige toegang tot het hele cluster (`cluster-admin`).
- Als projectbeheerder heeft Claude beheerrechten in de namespaces van dat project.

Gebruik voor de sandbox dus een account dat alleen lid of beheerder van één project is. Maak er een aparte API-sleutel voor, en trek die na afloop in.

##### Een testcluster op je eigen machine (k3d)

Vanuit de sandbox heet je eigen machine `host.docker.internal`; de override zet die naam op Docker Desktop, Docker Engine en podman. De firewall laat naar dat adres alleen poort 443 door, en alleen met `OPEN_HTTPS=true`. De firewall geeft op alle poorten alleen het eigen netwerk van de container vrij, en je machine valt daarbuiten. Met `OPEN_HTTPS=false` is een cluster op je eigen machine dus niet bereikbaar. `host.docker.internal` in `ALLOWED_DOMAINS` zetten helpt niet. De firewall zoekt die namen op via DNS, en daar staat deze naam niet in; op podman start de firewall dan niet.

Maak het cluster daarom met de API-server op poort 443:

```bash
k3d cluster create fieldlab \
  --image rancher/k3s:v1.35.10-k3s1 \
  --api-port 443 \
  --k3s-arg "--tls-san=host.docker.internal@server:0"
```

- `--image` kiest Kubernetes 1.35, gelijk aan `kubectl` in de sandbox.
- `--api-port 443` zet de API-server op poort 443 van je machine. Die poort is ook bereikbaar vanaf je netwerk; zonder toegangsgegevens kom je er niet in, maar zet het cluster uit als je het niet gebruikt (`k3d cluster stop fieldlab`).
- `--tls-san` neemt `host.docker.internal` op in het certificaat van de API-server; anders weigert `kubectl` de verbinding.

Maak daarna de kubeconfig voor de sandbox zoals bij [Rechten](#rechten-wat-claude-met-het-cluster-kan), met `SERVER=https://host.docker.internal:443` in plaats van de regel die het adres opzoekt: de kubeconfig van k3d wijst naar `0.0.0.0`, en vanuit de sandbox is dat de container zelf.

Rootless podman op Linux mag standaard geen poort onder 1024 openen. Dan lukt `--api-port 443` niet zonder die grens op de host te verlagen (`net.ipv4.ip_unprivileged_port_start`). De testomgeving van Fundament voor plug-ins kiest zelf een willekeurige poort; die is vanuit de sandbox niet bereikbaar. Bedien die omgeving vanaf de host.

##### Een cluster op afstand

Het adres van het cluster staat in de kubeconfig, op de regel `server:`. Ook hier geldt: alleen poort 443 komt de sandbox uit, ook met `OPEN_HTTPS=true`. Draait de API-server op een andere poort (bij k3s is dat 6443), dan bereikt de sandbox hem niet.

##### Netwerk: welke domeinen

Met `OPEN_HTTPS=false` komt de sandbox alleen bij de domeinen in `ALLOWED_DOMAINS`. De firewall zet er voor Kubernetes niets zelf bij. Zet erin wat je gebruikt:

- **De API-server**: de host uit de regel `server:` van de kubeconfig.
- **Fundament**: daarnaast de hosts van `api_endpoint` en `authn_url` uit de configuratie van `functl` (`functl config path` laat zien waar die staat).
- **Chart-repositories en OCI-registries**, alleen als je chart ze gebruikt: de host uit `helm repo add <naam> <url>`, of uit `oci://ghcr.io/...`. Een registry stuurt de bestanden vaak door naar een tweede host, bij `ghcr.io` bijvoorbeeld `pkg-containers.githubusercontent.com`. Loopt een download vast, dan noemt de foutmelding van `helm` de host die hij niet bereikt.

De container-images van je chart haalt het cluster op, niet de sandbox. Daarvoor hoeft niets in `ALLOWED_DOMAINS`.

Elk domein dat je toevoegt, opent meer dan alleen dat domein. De firewall laat IP-adressen door, geen namen. Veel registries en chart-repositories staan achter een CDN, waar duizenden andere sites hetzelfde adres delen; die zijn dan ook bereikbaar. De firewall zoekt de adressen alleen bij de start op. Loopt een verbinding later vast op een timeout, herstart dan de container.

### Eerste start


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
