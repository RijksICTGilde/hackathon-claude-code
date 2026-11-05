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
| `INSTALL_K8S`                  | `false` | `kubectl` en `helm` voor Helm-charts en een cluster buiten de container — zie [Kubernetes (kubectl en helm)](#kubernetes-kubectl-en-helm) |

Zet de waardes in `.env` of op de commandline:
```
INSTALL_JVM=false docker compose build
```
(`compose.yml` geeft de verplichte waardes via `${INSTALL_X:?}`-interpolatie door als build-args; ontbrekende of lege waardes laten de build vroegtijdig falen. `INSTALL_PODMAN`, `PODMAN_MULTIUID`, `INSTALL_SSHD` en `INSTALL_K8S` gaan via `${INSTALL_X:-false}`, zodat een bestaande `.env` zonder die regel blijft werken.)

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

### Devcontainer volume-gedrag
> Het `claude-home` volume mount de volledige home directory (`/home/claude`). Bij de allereerste start (met een leeg volume) wordt de inhoud vanuit de image gekopieerd. Bij volgende starts heeft de inhoud van het volume voorrang op de image — dit is standaard devcontainer-gedrag en zorgt ervoor dat je instellingen, auth tokens, shell history en geinstalleerde tools behouden blijven tussen herstarts en rebuilds. Keerzijde: nieuwe plugins, skills, rtk-patches of SDKman-installs die je via toggles toevoegt, verschijnen pas na het verwijderen en opnieuw aanmaken van het volume:
> ```
> docker compose down
> docker volume rm claude-home && docker volume create claude-home
> docker compose up --build --detach
> ```
> Het is aan de gebruiker om te bepalen wanneer je dit wil doen. Sommige upgrades kunnen ook met de hand toegevoegd worden.

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

### Kubernetes (kubectl en helm)

Met `INSTALL_K8S=true` bevat de image `kubectl` (1.35) en `helm` (4.3). Daarmee schrijf en controleer je [Helm-charts](https://helm.sh/docs/topics/charts/), en rol je ze uit naar een cluster buiten de container. Beide tools staan buiten `claude-home`: na het flippen van deze toggle volstaan een rebuild en een nieuwe container, het volume hoeft niet opnieuw. Wat `helm` zelf bewaart (chart-repositories, cache), komt onder `~/.config/helm` en `~/.cache/helm` in het volume.

Charts controleren kan zonder cluster en zonder netwerk:

```bash
helm create demo     # maakt een voorbeeldchart
helm lint demo       # controleert de chart op fouten
helm template demo   # toont de Kubernetes-bestanden die de chart oplevert
```

Gebruikt een chart andere charts (`dependencies` in `Chart.yaml`), dan haalt `helm dependency build` die op; zie [Netwerk](#netwerk-welke-domeinen).

Een cluster ín de sandbox kan niet: daarvoor heeft de sandbox rechten nodig die de afscherming van de container ongedaan maken. Het cluster draait op je eigen machine of op afstand. Dat geldt ook voor de ontwikkelomgeving van Fundament: die vraagt Docker met minstens 16 GiB geheugen, en 24 GiB met de plug-in-sandbox erbij.

Koppelen aan een cluster gaat in drie stappen: op de host beperkte toegang maken, daarvan een kubeconfig voor de sandbox schrijven, en die in de container zetten. Na de sessie ruim je de toegang weer op. Voor een cluster in Fundament gaat de eerste stap anders; zie [Fundament](#fundament).

#### Rechten: wat Claude met het cluster kan

Claude kan alles wat de toegangsgegevens in de kubeconfig toestaan. De sandbox en de firewall beperken dat niet, en Claude kan het token ook kopiëren en buiten de sandbox gebruiken. Geef de sandbox daarom een eigen ServiceAccount in één namespace, met een eigen rol. De ingebouwde rol `edit` is te ruim: daarmee kan Claude Secrets lezen en zelf tokens uitgeven die langer gelden.

Maak de toegang op de host, met de kubeconfig van de clusterbeheerder (die van k3d of van je cloudprovider), hier voor namespace `team-a`:

```bash
NS=team-a
kubectl create namespace "$NS"
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted
kubectl -n "$NS" create serviceaccount sandbox
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: sandbox
rules:
- apiGroups: [""]
  resources: [pods, services, configmaps, persistentvolumeclaims, serviceaccounts]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [""]
  resources: [pods/log, events, endpoints]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [pods/portforward]
  verbs: [create]
- apiGroups: [apps]
  resources: [deployments, statefulsets, daemonsets, replicasets]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [batch]
  resources: [jobs, cronjobs]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [networking.k8s.io]
  resources: [ingresses]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [autoscaling]
  resources: [horizontalpodautoscalers]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [policy]
  resources: [poddisruptionbudgets]
  verbs: [get, list, watch, create, update, patch, delete]
EOF
kubectl -n "$NS" create rolebinding sandbox --role=sandbox --serviceaccount="$NS:sandbox"
```

Wat de rol `sandbox` wel en niet mag:

- **Wel**, in deze namespace: workloads, services, ConfigMaps, volumes, ServiceAccounts en ingresses beheren, logs en events lezen, en port-forwarden. Dat is genoeg voor de meeste charts.
- **Niet**: Secrets lezen of aanmaken, tokens uitgeven (`serviceaccounts/token`), zich voordoen als een ander (`impersonate`), rechten, quota of de namespace zelf wijzigen (dus ook de Pod Security-labels niet), en commando's in pods uitvoeren (`exec`). Met een Secret kan Claude een token zonder einddatum laten aanmaken.
- **Helm zonder Secrets.** `helm` bewaart releases standaard in Secrets. De override zet daarom `HELM_DRIVER=configmap`: `helm` bewaart ze dan in ConfigMaps. Maakt een chart zelf Secrets aan, maak die dan op de host aan als beheerder en verwijs er in de chart naar; veel charts hebben daarvoor een optie `existingSecret`.

**Pod Security.** `enforce=restricted` weigert pods die als root draaien, extra rechten vragen of bij de node kunnen. `helm install` slaagt dan wel, maar de pods van zo'n chart komen er niet; `helm` toont alleen een waarschuwing, en `kubectl get events` de weigering. Ook de voorbeeldchart van `helm create` haalt `restricted` niet. Valt een chart daarop om, gebruik dan `enforce=baseline` met `warn=restricted`. `baseline` weigert nog steeds pods met directe toegang tot de node, en je krijgt een waarschuwing bij wat `restricted` zou weigeren:

```bash
kubectl label --overwrite namespace team-a pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
```

Pod Security verkleint de kans dat een pod uit het cluster breekt, maar sluit het niet uit. Bij k3d is dat de stap naar je eigen machine: de nodes zijn containers met volledige rechten op je host.

**Na de sessie: altijd opruimen.** Een token van `kubectl create token` verloopt, maar dat begrenst de toegang niet: Claude kan een pod starten die onder de ServiceAccount `sandbox` draait en daarmee een nieuw token krijgen. Pas het verwijderen van de ServiceAccount maakt al zijn tokens ongeldig. Ruim daarom na elke sessie op de host op:

```bash
kubectl delete namespace team-a                       # alles weg
kubectl -n team-a delete serviceaccount sandbox       # of minimaal de ServiceAccount
```

#### Een kubeconfig voor de sandbox

`kubectl` en `helm` vinden een cluster via een *kubeconfig*: een bestand met het adres van het cluster en je toegangsgegevens. Schrijf er op de host een voor de sandbox, met alleen het token van de ServiceAccount. Zet het buiten je projectmap: die is in de container schrijfbaar. Gebruik hetzelfde pad voor `F` als straks voor `SANDBOX_KUBECONFIG` in `.env`.

```bash
NS=team-a
F=/home/jij/.kube/sandbox/config
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
(
  umask 077
  if [ -z "$F" ] || [ -z "$NS" ] || [ -z "$SERVER" ] || [ -z "$CA" ]; then
    echo "FOUT: F, NS, server of CA is leeg" >&2
  elif [ -s "$F" ] && [ "$(kubectl --kubeconfig "$F" config view -o jsonpath='{.users[*].name}')" != sandbox ]; then
    echo "FOUT: $F bevat andere toegangsgegevens dan 'sandbox'; kies een ander pad" >&2
  elif mkdir -p -m 700 "$(dirname "$F")" &&
       TOKEN=$(kubectl -n "$NS" create token sandbox --duration=8h); then
    cat > "$F" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: sandbox
  cluster:
    server: $SERVER
    certificate-authority-data: $CA
users:
- name: sandbox
  user:
    token: $TOKEN
contexts:
- name: sandbox
  context:
    cluster: sandbox
    user: sandbox
    namespace: $NS
current-context: sandbox
EOF
    chmod 644 "$F"
  fi
)
kubectl --kubeconfig "${F:?zet F}" config view -o jsonpath='{.users[*].name}{"\n"}'   # moet precies 'sandbox' tonen
```

- Het blok vervangt de hele inhoud van `F`. Staat daar al een kubeconfig met andere toegangsgegevens, dan stopt het, zodat er nooit een beheertoegang in de sandbox belandt.
- Mislukt het aanmaken van het token, dan blijft het bestand zoals het was. Het token komt niet op de commandline van een ander programma terecht.
- `--flatten` neemt de CA ook over als de beheer-kubeconfig naar een CA-bestand verwijst.
- **Token vernieuwen**: draai hetzelfde blok opnieuw. Het overschrijft het bestand op zijn plek, dus een draaiende container ziet het nieuwe token meteen.
- De map kan alleen jij openen; het bestand zelf moet leesbaar zijn voor iedereen. Rootless podman maakt van jouw bestand in de container een bestand van root, en een bestand met `600` kan de gebruiker `claude` dan niet lezen.

#### De kubeconfig in de container

1. Zet in `.env` het pad uit `F`: `SANDBOX_KUBECONFIG=/home/jij/.kube/sandbox/config`.
2. Start de container met `compose.override.kubeconfig.yml`. Gebruik je een podman-override, zet die er met nog een `-f` bij.
   ```bash
   docker compose -f compose.yml -f compose.override.kubeconfig.yml up -d
   ```
3. Controleer in de container met `kubectl version`. Dat toont de versie van `kubectl` (1.35) en die van het cluster. Scheelt dat meer dan één minor-versie, dan waarschuwt `kubectl`; kies dan een cluster op 1.34, 1.35 of 1.36.

Het bestand staat in de container alleen-lezen op `/run/kubeconfig/config`, buiten de projectmap en buiten `claude-home`; start je zonder de override, dan is het weg. Een andere namespace kies je per commando (`-n <naam>`). `KUBECONFIG` en `HELM_DRIVER` staan in de omgeving van de container, maar niet in een SSH-sessie (Kepler); zet ze daar zelf met `export`.

#### Een testcluster op je eigen machine (k3d)

Reken er niet op dat de firewall je eigen machine afschermt: hoe verkeer van de sandbox naar je machine loopt, verschilt per container-runtime. Hieronder staan twee routes. Kies de eerste waar het kan: die werkt met `OPEN_HTTPS=false`.

**Docker (Desktop of Engine): het cluster op het netwerk van de sandbox.** Start eerst de sandbox, nog zonder de kubeconfig-override; compose maakt daarbij het netwerk aan. De naam van dat netwerk toont `docker inspect claude-sandbox -f '{{range $n, $_ := .NetworkSettings.Networks}}{{println $n}}{{end}}'`, meestal `claude-sandbox_default`. Maak dan het cluster:

```bash
k3d cluster create fieldlab \
  --image rancher/k3s:v1.35.10-k3s1 \
  --network claude-sandbox_default \
  --k3s-arg "--tls-san=k3d-fieldlab-server-0@server:0" \
  --k3s-arg "--kubelet-arg=seccomp-default=true@server:0"
```

- `--image` kiest Kubernetes 1.35, gelijk aan `kubectl` in de sandbox.
- `--network` zet het cluster op het netwerk van de sandbox. De sandbox bereikt de API-server dan zonder `OPEN_HTTPS=true` en zonder `ALLOWED_DOMAINS`. Sandbox en cluster bereiken elkaar daarmee op alle poorten, niet alleen de API-server.
- `--tls-san` neemt de naam van de server in het certificaat op; anders weigert `kubectl` de verbinding.
- `seccomp-default=true` geeft pods standaard het seccomp-profiel van de container-runtime. Dat beperkt welke systeemaanroepen een pod mag doen.

Maak daarna de kubeconfig zoals hierboven, met `SERVER=https://k3d-fieldlab-server-0:6443` in plaats van de regel die het adres opzoekt: de kubeconfig van k3d wijst naar een poort op je machine, niet naar het netwerk van de sandbox. Start de sandbox dan opnieuw, met de override. Verwijder het cluster (`k3d cluster delete fieldlab`) vóór `docker compose down`; anders kan compose het netwerk niet opruimen.

Deze route is niet getest.

**Rootless podman: het cluster op je machine, API-server op poort 443.** Deze route vraagt `OPEN_HTTPS=true`. Dat staat al het uitgaande verkeer over poort 443 toe, naar elke bestemming, en `ALLOWED_DOMAINS` doet dan niets. Gebruik hem alleen als de eerste route niet kan, en zet `OPEN_HTTPS` daarna terug.

```bash
k3d cluster create fieldlab \
  --image rancher/k3s:v1.35.10-k3s1 \
  --api-port 443 \
  --k3s-arg "--tls-san=host.containers.internal@server:0" \
  --k3s-arg "--kubelet-arg=seccomp-default=true@server:0"
```

- `--api-port 443` zet de API-server op poort 443 van je machine. Die poort is ook bereikbaar vanaf je netwerk; zonder toegangsgegevens kom je er niet in, maar zet het cluster uit als je het niet gebruikt (`k3d cluster stop fieldlab`).
- Rootless podman mag standaard geen poort onder 1024 openen. Dan lukt `--api-port 443` alleen als je die grens op de host verlaagt (`net.ipv4.ip_unprivileged_port_start`).
- Gebruik in de kubeconfig `SERVER=https://host.containers.internal:443`.

Getest met rootless podman op Linux: een poort op de host is met deze instellingen vanuit de sandbox bereikbaar. Een k3d-cluster op deze route is niet getest.

De plug-in-sandbox van Fundament kiest zelf een willekeurige poort voor de API-server. Bedien die vanaf de host.

#### Een cluster op afstand

Het adres van het cluster staat in de kubeconfig, op de regel `server:`. Zet die host bij `OPEN_HTTPS=false` in `ALLOWED_DOMAINS`. Naar buiten laat de firewall alleen poort 443 door, ook met `OPEN_HTTPS=true`. Draait de API-server op een andere poort (bij k3s is dat 6443), dan bereikt de sandbox hem niet.

#### Fundament

De kubeconfig uit de console van Fundament of van `functl cluster kubeconfig` bevat geen token. `kubectl` vraagt bij elk gebruik een kortlevend token aan via `functl`, met je API-sleutel. Draai `functl` daarom op de host, en zet alleen zo'n kortlevend token in de kubeconfig van de sandbox. De API-sleutel komt dan niet in de sandbox.

Op de host, met `functl` ingelogd (`functl auth login`) en de kubeconfig van Fundament in `~/.kube/fundament.yaml`:

```bash
CLUSTER=<cluster-id>       # zie functl cluster list
NS=<namespace van je project>
F=/home/jij/.kube/sandbox/config
SERVER=$(kubectl --kubeconfig ~/.kube/fundament.yaml config view --minify -o jsonpath='{.clusters[0].cluster.server}')
(
  umask 077
  if [ -z "$F" ] || [ -z "$NS" ] || [ -z "$SERVER" ]; then
    echo "FOUT: F, NS of server is leeg" >&2
  elif [ -s "$F" ] && [ "$(kubectl --kubeconfig "$F" config view -o jsonpath='{.users[*].name}')" != sandbox ]; then
    echo "FOUT: $F bevat andere toegangsgegevens dan 'sandbox'; kies een ander pad" >&2
  elif mkdir -p -m 700 "$(dirname "$F")" &&
       TOKEN=$(functl cluster token "$CLUSTER" | jq -er .status.token); then
    cat > "$F" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: sandbox
  cluster:
    server: $SERVER
users:
- name: sandbox
  user:
    token: $TOKEN
contexts:
- name: sandbox
  context:
    cluster: sandbox
    user: sandbox
    namespace: $NS
current-context: sandbox
EOF
    chmod 644 "$F"
  fi
)
kubectl --kubeconfig "${F:?zet F}" config view -o jsonpath='{.users[*].name}{"\n"}'   # moet precies 'sandbox' tonen
```

Het blok werkt zoals dat bij [Een kubeconfig voor de sandbox](#een-kubeconfig-voor-de-sandbox), zonder CA: de kubeconfig van Fundament noemt er geen, en `kubectl` gebruikt dan de CA's van het systeem. Het token is kort geldig (een kwartier); draai het blok daarna opnieuw. Het hoort niet bij één cluster: `functl` gebruikt hetzelfde soort token voor de API van Fundament zelf. Wie het token heeft, kan dus zolang het geldt met jouw rechten bij Fundament.

`functl` zit niet in de image. Met Go in de container (`INSTALL_GO`, zie [#210](https://github.com/RijksICTGilde/hackathon-claude-code/pull/210)) kun je het daar zelf installeren en de kubeconfig van Fundament ongewijzigd gebruiken. Dat kost meer: de API-sleutel komt dan in `~/.config/fundament/credentials`, in `claude-home`. Hij blijft daar staan, en Claude kan ermee nieuwe tokens halen tot je de sleutel intrekt.

Wat het token mag, hangt af van je rol in Fundament:

- **Organisatiebeheerder** (`Organization admin`): `cluster-admin`, volledige toegang tot het hele cluster. Gebruik zo'n account niet voor de sandbox.
- **Projectbeheerder** (`Project admin`): de rol `admin` in elke namespace van het project. Daarmee kan Claude ook zelf ServiceAccounts, rechten en tokens aanmaken die langer gelden dan het token van `functl`.
- **Projectviewer** (`viewer`): de rol `view` in de namespaces van het project: alleen lezen, zonder Secrets. Dit is de veiligste keuze, maar uitrollen kan er niet mee.

Gebruik voor de sandbox dus een account dat geen organisatiebeheerder is en alleen bij het project hoort waar je aan werkt. Maak er een aparte API-sleutel voor, en trek die na afloop in. Ruim als projectbeheerder na de sessie ook op wat Claude in de namespaces aan ServiceAccounts en RoleBindings heeft aangemaakt.

#### Netwerk: welke domeinen

Met `OPEN_HTTPS=false` komt de sandbox alleen bij de domeinen in `ALLOWED_DOMAINS`. De firewall zet er voor Kubernetes niets zelf bij. Zet erin wat je gebruikt:

- **De API-server**: de host uit de regel `server:` van de kubeconfig (niet nodig bij een k3d-cluster op het netwerk van de sandbox).
- **Fundament met `functl` in de container**: daarnaast de hosts van `api_endpoint` en `authn_url` uit de configuratie van `functl` (`functl config path` laat zien waar die staat).
- **Chart-repositories en OCI-registries**, alleen als je chart ze gebruikt: de host uit `helm repo add <naam> <url>`, of uit `oci://ghcr.io/...`. Een registry stuurt de bestanden vaak door naar een tweede host, bij `ghcr.io` bijvoorbeeld `pkg-containers.githubusercontent.com`. Mislukt een download, dan noemt de foutmelding van `helm` de host die hij niet bereikt.

De container-images van je chart haalt het cluster op, niet de sandbox. Daarvoor hoeft niets in `ALLOWED_DOMAINS`.

Elk domein dat je toevoegt, opent meer dan alleen dat domein. De firewall laat IP-adressen door, geen namen. Veel registries en chart-repositories staan achter een CDN, waar duizenden andere sites hetzelfde adres delen; die zijn dan ook bereikbaar. De firewall zoekt de adressen alleen bij de start op. Weigert een verbinding die eerst werkte later direct (`no route to host`), dan is het adres van dat domein waarschijnlijk veranderd; herstart dan de container.

## Afsluiten
```
docker compose down
```
