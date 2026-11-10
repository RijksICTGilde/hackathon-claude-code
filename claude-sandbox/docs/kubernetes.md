# Kubernetes (kubectl en helm)

## Wat je krijgt en wat niet

**Geef je de sandbox toegang tot een cluster, dan kan Claude alles wat die toegangsgegevens toestaan**, ook buiten de sandbox: het token in de kubeconfig is te kopiëren. Met clustertoegang beperkt `OPEN_HTTPS=false` ook niet meer wat Claude bereikt. Pods draaien op het netwerk van het cluster, en via port-forward, een Ingress of de naam van een container-image loopt verkeer buiten de firewall van de sandbox om. De rechten hieronder verkleinen dat; ze sluiten het niet uit. Bij Fundament geldt het token voor je hele Fundament-account, en kan Claude er een blijvende API-sleutel mee maken: gebruik daar altijd een [apart account](#fundament).

Met `INSTALL_K8S=true` bevat de image `kubectl` (1.35) en `helm` (4.3). Daarmee schrijf en controleer je [Helm-charts](https://helm.sh/docs/topics/charts/), en rol je ze uit naar een cluster buiten de container. Een cluster ín de sandbox kan niet: daarvoor heeft de sandbox rechten nodig die de afscherming van de container ongedaan maken.

Voor `helm` staat een kwetsbaarheid in de certificaatcontrole van Go open (CVE-2026-111943), tot er een helm-release met de fix is. Ze raakt verkeer naar chart-repositories en OCI-registries; verkeer naar de API-server van een cluster nauwelijks, omdat dat met een eigen CA werkt. <!-- trivyignore: CVE-2026-111943 usr/local/bin/helm -->

## Hoofdpad

Wat op de host gebeurt, staat erbij. De rest draai je in de sandbox.

### De image bouwen (op de host)

Nog niet opgezet? Volg dan eerst [Opstarten, configureren en afsluiten](opstarten-en-afsluiten.md). Op de host heb je nodig: [`kubectl`](https://kubernetes.io/docs/tasks/tools/), voor een lokaal cluster [`k3d`](https://k3d.io/stable/#installation), en voor Fundament [`functl`](https://github.com/fundament-oss/fundament/blob/master/docs/user/functl.md#install) en [`jq`](https://jqlang.org/download/).

Zet in `.env` de regel `INSTALL_K8S=true`, en bouw en start de sandbox vanuit `claude-sandbox/`. Gebruik je een podman-override, zet die er met een extra `-f` bij:

```bash
docker compose up --build -d
```

`kubectl` en `helm` staan buiten `claude-home`: het volume hoeft niet opnieuw.

### Charts controleren zonder cluster

Dit kan in de sandbox, zonder cluster en zonder netwerk. `helm create` maakt een voorbeeldchart, `helm lint` controleert hem en `helm template` toont de Kubernetes-bestanden die hij oplevert:

```bash
helm create demo
helm lint demo
helm template demo
```

Gebruikt een chart andere charts (`dependencies` in `Chart.yaml`), dan haalt `helm dependency build` die op; zie [Netwerk en ALLOWED_DOMAINS](#netwerk-en-allowed_domains).

### Een cluster kiezen

**k3d op Docker (voorkeur).** Een testcluster op je eigen machine, op het netwerk van de sandbox. Dit werkt met `OPEN_HTTPS=false`. Start eerst de sandbox ([De image bouwen](#de-image-bouwen-op-de-host)), nog zonder de kubeconfig-override; compose maakt daarbij het netwerk aan. De naam van dat netwerk toont `docker inspect claude-sandbox -f '{{range $n, $_ := .NetworkSettings.Networks}}{{println $n}}{{end}}'`, meestal `claude-sandbox_default`. Wijkt de naam af, vervang dan `claude-sandbox_default` in `--network`. Maak dan op de host het cluster:

```bash
k3d cluster create fieldlab \
  --image rancher/k3s:v1.35.10-k3s1 \
  --network claude-sandbox_default \
  --api-port 127.0.0.1:6550 \
  --k3s-arg "--tls-san=k3d-fieldlab-server-0@server:0" \
  --k3s-arg "--kubelet-arg=seccomp-default=true@server:0" \
  --k3s-arg "--kube-apiserver-arg=enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs@server:0"
```

- `--image` kiest Kubernetes 1.35, gelijk aan `kubectl` in de sandbox.
- `--network` zet het cluster op het netwerk van de sandbox. De sandbox bereikt de API-server dan op `https://k3d-fieldlab-server-0:6443`, zonder `OPEN_HTTPS=true` en zonder `ALLOWED_DOMAINS`. Zet geen andere containers op dit netwerk; behandel alles erop als bereikbaar voor Claude.
- `--api-port 127.0.0.1:6550` zet de API-server voor jou op de host alleen op `127.0.0.1`, niet op je netwerk. Dat adres schrijft k3d in je eigen kubeconfig.
- `--tls-san` neemt de naam van de server in het certificaat op; anders weigert `kubectl` in de sandbox de verbinding.
- `seccomp-default=true` geeft pods standaard het seccomp-profiel van de container-runtime. Dat beperkt welke systeemaanroepen een pod mag doen.
- `DenyServiceExternalIPs` weigert Services met `externalIPs`; zie [wat het rechtenblok doet](#wat-het-rechtenblok-doet). De optie vervangt de standaardlijst van k3s, daarom staat `NodeRestriction` er ook in.

De nodes van k3d zijn containers met de rechten van je container-runtime: bij Docker is dat root op je machine. Zonder Docker, met rootless podman, zie [k3d op rootless podman](#k3d-op-rootless-podman).

**Een cluster op afstand.** Het adres staat in de kubeconfig van de beheerder, op de regel `server:`. Wat er bij `OPEN_HTTPS=false` in `ALLOWED_DOMAINS` moet, staat in [Netwerk en ALLOWED_DOMAINS](#netwerk-en-allowed_domains).

**Fundament.** De rechten komen daar uit je rol in Fundament, niet uit een eigen ServiceAccount: sla de volgende stap over. Lees eerst [Fundament](#fundament): gebruik voor de sandbox een apart account, nooit je eigen.

### Rechten zetten (op de host, als beheerder)

Geef de sandbox een eigen ServiceAccount in één namespace, met een eigen rol. De ingebouwde rol `edit` is te ruim: daarmee kan Claude zelf tokens uitgeven die langer gelden. Draai dit op de host, met de kubeconfig van de clusterbeheerder (die van k3d of van je cloudprovider). Kies in de eerste regel de naam van een nieuwe namespace.

```bash
NS=team-a
{ [ "$(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.claude-sandbox}' 2>/dev/null)" = true ] ||
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl label --local -f - claude-sandbox=true -o yaml | kubectl create -f -; } &&
kubectl label --overwrite namespace "$NS" pod-security.kubernetes.io/enforce=restricted &&
kubectl -n "$NS" create serviceaccount sandbox --dry-run=client -o yaml | kubectl apply -f - &&
kubectl -n "$NS" apply -f - <<'EOF' &&
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
- apiGroups: [autoscaling]
  resources: [horizontalpodautoscalers]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [policy]
  resources: [poddisruptionbudgets]
  verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sandbox
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: sandbox
spec:
  hard:
    pods: "20"
    requests.cpu: "4"
    requests.memory: 8Gi
    requests.ephemeral-storage: 10Gi
    limits.cpu: "20"
    limits.memory: 20Gi
    limits.ephemeral-storage: 20Gi
    persistentvolumeclaims: "5"
    requests.storage: 20Gi
    services: "10"
    services.loadbalancers: "0"
    services.nodeports: "0"
    count/configmaps: "50"
    count/serviceaccounts: "10"
    count/deployments.apps: "20"
    count/statefulsets.apps: "10"
    count/daemonsets.apps: "5"
    count/replicasets.apps: "100"
    count/jobs.batch: "20"
    count/cronjobs.batch: "5"
    count/horizontalpodautoscalers.autoscaling: "10"
    count/poddisruptionbudgets.policy: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: sandbox
spec:
  limits:
  - type: Container
    default: {cpu: "1", memory: 1Gi, ephemeral-storage: 1Gi}
    defaultRequest: {cpu: 100m, memory: 128Mi, ephemeral-storage: 256Mi}
EOF
kubectl -n "$NS" create rolebinding sandbox --role=sandbox --serviceaccount="${NS}:sandbox" --dry-run=client -o yaml | kubectl apply -f -
```

Het blok stopt bij de eerste fout, en geeft de ServiceAccount pas rechten als al het andere staat. Het maakt de namespace aan met het label `claude-sandbox=true`, en stopt bij een bestaande namespace zonder dat label (ook `default`): zo neem je nooit een bestaande namespace van een ander over, en verwijdert het opruimblok er ook geen. Claude kan dat label niet zetten. Opnieuw draaien kan altijd: het zet de objecten uit dit blok terug; wat Claude aanmaakte blijft staan, zie [Opruimen](#opruimen-op-de-host).

#### Wat het rechtenblok doet

- **De NetworkPolicy** laat pods in de namespace alleen elkaar bereiken, plus de DNS van het cluster. Naar buiten en naar andere namespaces kan een pod dan niet. Verkeer tussen een pod en de node waarop hij draait, houdt een NetworkPolicy niet tegen; draait de API-server op die node, zoals bij k3d, dan kan een pod hem daarlangs mogelijk toch bereiken. Van buiten de namespace komt er niets binnen, behalve via `kubectl port-forward` vanuit de sandbox. Zonder DNS vinden pods elkaar niet op naam; heeft je chart dat niet nodig, laat het tweede `to`-blok dan weg. Via DNS kan een pod nog wel namen buiten het cluster opvragen: een smal kanaal naar buiten dat deze policy niet sluit. Een NetworkPolicy werkt alleen als de netwerk-plug-in van het cluster hem afdwingt. k3s, en dus k3d, doet dat standaard; vraag het bij een ander cluster na bij de beheerder. Draait DNS daar niet als `k8s-app: kube-dns` in `kube-system` op poort 53, pas die regel dan aan.
- **De ResourceQuota** begrenst hoeveel pods en andere objecten Claude aanmaakt, en hoeveel rekenkracht en opslag die gebruiken. Bij k3d (opslag via `local-path`) begrenst ze bij blijvende opslag wel het aantal PVC's, maar niet de schijfruimte: `local-path` houdt de gevraagde grootte niet aan. Ze verbiedt Services van het type `LoadBalancer` en `NodePort`: die maken een pod bereikbaar van buiten het cluster.
- **Services met `externalIPs` houdt de quota niet tegen.** Met zo'n Service kan Claude verkeer binnen het cluster naar een willekeurig adres omleiden naar een eigen pod ([CVE-2020-8554](https://github.com/kubernetes/kubernetes/issues/97076)). De k3d-commando's op deze pagina zetten daarom `DenyServiceExternalIPs` aan. Vraag bij een ander cluster de beheerder of die admission-plugin aanstaat, of een ValidatingAdmissionPolicy die `externalIPs` weigert.
- **De LimitRange** vult per container de `resources` aan die hij zelf niet noemt: een limiet van 1 CPU, 1Gi geheugen en 1Gi tijdelijke opslag, en een request van 100m CPU, 128Mi geheugen en 256Mi opslag. Zonder die waarden weigert de quota de pod. Noemt een container alleen een request, dan krijgt hij de standaardlimiet erbij; vraagt hij meer dan die limiet, dan weigert het cluster de pod. `helm install` slaagt dan wel, maar er komen geen pods; de reden staat alleen in `kubectl get events`. Zet in de chart dan ook `limits`.
- **De rol `sandbox`** mag in deze namespace workloads, Services, ConfigMaps, volumes en ServiceAccounts beheren, logs en events lezen, en port-forwarden. Dat is genoeg voor de meeste charts.
- **Niet**: Secrets aanmaken (daarmee kan Claude een token zonder einddatum laten aanmaken), tokens uitgeven via de API (`serviceaccounts/token`), zich voordoen als een ander (`impersonate`), en rechten, NetworkPolicies, quota, LimitRanges of de namespace zelf wijzigen, dus ook de Pod Security-labels niet. Ingresses staan er ook niet in: een Ingress maakt een dienst bereikbaar van buiten het cluster. Heb je dat nodig, voeg `ingresses` (API-groep `networking.k8s.io`) dan zelf toe en pas de NetworkPolicy aan.
- **Via een pod kan Claude meer dan de rol laat zien.** `kubectl exec` mag niet, maar Claude kan een pod starten met elk commando en de uitvoer in de logs lezen. Zo is ook elke Secret in de namespace leesbaar (als volume of omgevingsvariabele), en elk ServiceAccount-token (een pod onder die ServiceAccount). Zet in deze namespace dus geen Secrets die Claude niet mag kennen, en geef geen andere ServiceAccount hier meer rechten dan `sandbox`.
- **Container-images blijven een kanaal.** Het cluster haalt elk image op dat Claude in een pod noemt, van elke registry. De naam van het image gaat zo naar buiten, en het image brengt code binnen. Dat sluit alleen de clusterbeheerder af, bijvoorbeeld met een allowlist van registries.
- **Helm zonder Secrets.** `helm` bewaart releases standaard in Secrets. De override zet daarom `HELM_DRIVER=configmap`: `helm` bewaart ze dan in ConfigMaps, en de values van een release zijn leesbaar voor iedereen die ConfigMaps in de namespace mag lezen. Maakt een chart zelf Secrets aan, maak die dan hier als beheerder aan en verwijs er in de chart naar; veel charts hebben daarvoor een optie `existingSecret`. Gebruik daarin alleen testwaarden die Claude mag kennen.
- **Pod Security `restricted`** weigert pods die als root draaien of bij de node kunnen; zie [Pod Security](#pod-security).

### Een kubeconfig maken (op de host)

`kubectl` en `helm` vinden een cluster via een *kubeconfig*: een bestand met het adres van het cluster en je toegangsgegevens. Schrijf er op de host een voor de sandbox, met alleen een token. Zet het buiten je projectmap: die is in de container schrijfbaar.

Zet eerst de variabelen voor je cluster, in dezelfde shell als het blok daarna. Bij k3d of een cluster op afstand doe je dat met de kubeconfig van de beheerder als actieve context. `HOST_SERVER` is het adres waarop jij het cluster bereikt, `SERVER` dat waarop de sandbox het bereikt:

```bash
NS=team-a
F=$HOME/.kube/sandbox/config
HOST_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$HOST_SERVER
token_ophalen() { kubectl -n "$NS" create token sandbox --duration=8h; }
```

Bij k3d op Docker bereikt de sandbox het cluster op een ander adres dan jij. Zet daarna dus nog, ook bij elk vernieuwen:

```bash
SERVER=https://k3d-fieldlab-server-0:6443
```

Bij [k3d op rootless podman](#k3d-op-rootless-podman) zet je daarna `SERVER=https://host.containers.internal:443`.

Bij Fundament haal je eerst, met `functl` ingelogd op het [aparte account](#fundament), het cluster-id en de kubeconfig van Fundament op. Vul in de tweede regel het cluster-id uit de eerste in:

```bash
functl cluster list
mkdir -p ~/.kube && functl cluster kubeconfig <cluster-id> > ~/.kube/fundament.yaml
```

Werk je met `OPEN_HTTPS=false`, zet dan de host uit de regel `server:` van dat bestand in `ALLOWED_DOMAINS`. Zet daarna, in plaats van de variabelen hierboven:

```bash
unset CLUSTER NS
CLUSTER='<cluster-id>'
NS='<namespace van je project>'
F=$HOME/.kube/sandbox/config
HOST_SERVER=$(kubectl --kubeconfig ~/.kube/fundament.yaml config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=
SERVER=$HOST_SERVER
token_ophalen() {
  case "$CLUSTER" in
    ''|*[^0-9a-fA-F-]*) echo "FOUT: CLUSTER ($CLUSTER) is geen cluster-id; vul hem in" >&2; return 1 ;;
  esac
  functl cluster token "$CLUSTER" | jq -er '.status.token | select(type == "string" and length > 0)'
}
```

`CA=` blijft leeg: de kubeconfig van Fundament noemt geen CA, en `kubectl` gebruikt dan de CA's van het systeem. Vul je een placeholder niet in, dan stopt het schrijfblok hieronder met `FOUT`.

Schrijf dan de kubeconfig. Dit blok is voor elke route hetzelfde:

```bash
(
  umask 077
  if [ -z "$F" ] || [ -z "$NS" ] || [ -z "$SERVER" ] || [ -z "$HOST_SERVER" ]; then
    echo "FOUT: F, NS, SERVER of HOST_SERVER is leeg" >&2
    exit 1
  fi
  case "$NS" in
    *[^a-z0-9-]*) echo "FOUT: NS ($NS) is geen namespace-naam; vul hem in" >&2; exit 1 ;;
  esac
  adres=$(printf '%s' "$SERVER" | tr '[:upper:]' '[:lower:]')
  case "$adres" in
    *://127.*|*://localhost|*://localhost[:/.]*|*://0|*://0[:/]*|*://0.0.0.0*|*://\[::1\]*|*://\[::\]*|*://\[::ffff:127.*|*://\[0:0:0:0:0:0:0:1\]*)
      echo "FOUT: SERVER ($SERVER) wijst in de sandbox naar de container zelf; zet het adres waarop de sandbox het cluster bereikt" >&2
      exit 1 ;;
    *://*) ;;
    *) echo "FOUT: SERVER ($SERVER) is geen URL; begin met https://" >&2; exit 1 ;;
  esac
  if [ -s "$F" ] && [ "$(kubectl --kubeconfig "$F" config view -o jsonpath='{.users[*].name}')" != sandbox ]; then
    echo "FOUT: $F bevat andere toegangsgegevens dan 'sandbox'; kies een ander pad" >&2
    exit 1
  fi
  dir=$(dirname "$F")
  [ -d "$dir" ] || mkdir -m 700 -p "$dir" || exit 1
  case "$(ls -ld "$dir")" in
    d???------*) ;;
    *) echo "FOUT: $dir is ook voor anderen te openen; kies een map die alleen jij kunt openen" >&2; exit 1 ;;
  esac
  TOKEN=$(token_ophalen) && [ -n "$TOKEN" ] || { echo "FOUT: geen token gekregen" >&2; exit 1; }
  tmp=$(mktemp "$dir/.config.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  cat >| "$tmp" <<EOF || exit 1
apiVersion: v1
kind: Config
clusters:
- name: sandbox
  cluster:
    server: $SERVER
${CA:+    certificate-authority-data: $CA}
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
  naam=${SERVER#*://}; naam=${naam%%/*}; naam=${naam%:*}
  kubectl --kubeconfig "$tmp" --server "$HOST_SERVER" --tls-server-name "$naam" auth whoami || exit 1
  cat "$tmp" >| "$F" && chmod 644 "$F"
)
```

- Het blok toont met welk account het cluster het nieuwe token ziet, bij k3d en een cluster op afstand `system:serviceaccount:<namespace>:sandbox`. Die controle loopt via `HOST_SERVER`, met de naam uit `SERVER` voor het certificaat: staat die naam er niet in, dan faalt hij. Of de sandbox `SERVER` ook bereikt, zie je pas in de sandbox.
- Gaat er iets mis, dan eindigt het blok met `FOUT` of een foutmelding van `kubectl`, met een exitcode die niet 0 is, en blijft `F` zoals het was. Staat in `F` al een kubeconfig met andere toegangsgegevens, dan stopt het, zodat er nooit een beheertoegang in de sandbox belandt.
- **Token vernieuwen**: zet dezelfde variabelen en draai het blok opnieuw. Het overschrijft het bestand op zijn plek, dus een draaiende container ziet het nieuwe token meteen. Het token van `kubectl create token` geldt hier 8 uur, dat van Fundament een kwartier.
- De map van `F` moet alleen voor jou te openen zijn; bestaat hij nog niet, dan maakt het blok hem zo aan. Het bestand zelf is leesbaar voor iedereen: onder rootless podman is het in de container van root, en de gebruiker `claude` moet het kunnen lezen.

### Gebruiken in de sandbox

1. Zet in `.env` het pad uit `F`, als absoluut pad (`echo $HOME` toont het begin): `SANDBOX_KUBECONFIG=/home/jij/.kube/sandbox/config`. Nooit je eigen `~/.kube/config`: bevat het bestand meer dan één token, zoals een clientcertificaat, een exec-plugin of een tweede gebruiker, dan start de sandbox niet. `docker compose logs` toont waarom.
2. Start de container met `compose.override.kubeconfig.yml`. Gebruik je een podman-override, zet die er met nog een `-f` bij.
   ```bash
   docker compose -f compose.yml -f compose.override.kubeconfig.yml up -d
   ```
3. Controleer in de container met `kubectl auth whoami` en `kubectl version`. Het tweede toont de versie van `kubectl` (1.35) en die van het cluster. Scheelt dat meer dan één minor-versie, dan waarschuwt `kubectl`; kies dan een cluster op 1.34, 1.35 of 1.36.
4. Rol de voorbeeldchart uit en kijk of de pods er komen:
   ```bash
   helm upgrade --install demo ./demo
   kubectl get pods
   kubectl get events
   ```
   Bij de voorbeeldchart is "geen pods" hier het verwachte resultaat: hij haalt `restricted` niet, en de events tonen de weigering. Zet dan op de host de namespace op `baseline` (zie [Pod Security](#pod-security)), en start in de sandbox de pods opnieuw:
   ```bash
   kubectl rollout restart deployment/demo
   kubectl get pods
   ```
   Komen er bij een eigen chart geen pods, dan staat de reden ook in de events. Ook een request boven de limiet van de [LimitRange](#wat-het-rechtenblok-doet) houdt pods tegen.

Het bestand staat in de container alleen-lezen op `/run/kubeconfig/config`, buiten de projectmap en buiten `claude-home`; start je zonder de override, dan is het weg. `KUBECONFIG` en `HELM_DRIVER` staan in de omgeving van de container, maar niet in een SSH-sessie (Kepler); zet ze daar zelf met `export`. Bij Fundament kies je met `-n <naam>` een andere namespace van je project; de ServiceAccount van de andere routes heeft alleen rechten in zijn eigen namespace.

### Opruimen (op de host)

Niet bij Fundament: `$NS` is daar de namespace van je project. Zie daarvoor [na de sessie](#na-de-sessie-bij-fundament).

Bij k3d of een cluster op afstand: ruim na elke sessie op, met de kubeconfig van de beheerder en dezelfde `NS` als in het rechtenblok:

```bash
if [ "$(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.claude-sandbox}')" = true ]; then
  kubectl delete namespace "$NS"
else
  echo "FOUT: namespace $NS bestaat niet of heeft geen label claude-sandbox=true; niet verwijderd" >&2
  false
fi
```

Dat is de enige betrouwbare manier. Een token van `kubectl create token` verloopt, maar dat begrenst de toegang niet: Claude kan zelf ServiceAccounts aanmaken, en pods starten die een token krijgen dat lang geldig blijft. Pas met de namespace verdwijnen al die ServiceAccounts, pods en tokens.

Verwijder een k3d-cluster dat je niet meer gebruikt (`k3d cluster delete fieldlab`) vóór `docker compose down`; anders kan compose het netwerk niet opruimen.

## Naslag

### k3d op rootless podman

Zonder Docker zet je het cluster op je machine met de API-server op poort 443. Deze route vraagt `OPEN_HTTPS=true`. Dat staat al het uitgaande verkeer over poort 443 toe, naar elke bestemming, en `ALLOWED_DOMAINS` doet dan niets. Gebruik hem alleen als k3d op Docker niet kan, en zet `OPEN_HTTPS` daarna terug.

```bash
k3d cluster create fieldlab \
  --image rancher/k3s:v1.35.10-k3s1 \
  --api-port 443 \
  --k3s-arg "--tls-san=host.containers.internal@server:0" \
  --k3s-arg "--kubelet-arg=seccomp-default=true@server:0" \
  --k3s-arg "--kube-apiserver-arg=enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs@server:0"
```

- `--api-port 443` zet de API-server op poort 443 van je machine, ook bereikbaar vanaf je netwerk. Zonder toegangsgegevens kom je er niet in, maar zet het cluster stop als je het niet gebruikt (`k3d cluster stop fieldlab`).
- Rootless podman mag standaard geen poort onder 1024 openen. Verlaag die grens op de host vóór `k3d cluster create` en vóór elke `k3d cluster start` met `sudo sysctl net.ipv4.ip_unprivileged_port_start=443`, en zet hem na afloop terug op de standaardwaarde: `sudo sysctl net.ipv4.ip_unprivileged_port_start=1024`.
- De nodes zijn hier containers met de rechten van jouw gebruiker.

### Netwerk en ALLOWED_DOMAINS

Met `OPEN_HTTPS=false` komt de sandbox alleen bij de domeinen in `ALLOWED_DOMAINS`. De firewall zet er voor Kubernetes niets zelf bij. Zet erin wat je gebruikt, en niet meer:

- **De API-server**: de host uit de regel `server:` van de kubeconfig (niet nodig bij k3d op Docker). Naar buiten laat de firewall alleen poort 443 door, ook met `OPEN_HTTPS=true`. Draait de API-server op een andere poort (bij k3s is dat 6443), dan bereikt de sandbox hem niet.
- **Een IP-adres in `server:`** kan niet in `ALLOWED_DOMAINS`: de firewall zoekt elk domein op als DNS-naam, en met een IP-adres erin start de container niet. Vraag de beheerder dan om een hostnaam voor de API-server die in het certificaat staat, of gebruik `OPEN_HTTPS=true`, met wat dat opent.
- **Chart-repositories en OCI-registries**, alleen als je chart ze gebruikt: de host uit `helm repo add <naam> <url>`, of uit `oci://ghcr.io/...`. Een registry stuurt de bestanden vaak door naar een tweede host, bij `ghcr.io` bijvoorbeeld `pkg-containers.githubusercontent.com`. Mislukt een download, dan noemt de foutmelding van `helm` de host die hij niet bereikt.

De container-images van je chart haalt het cluster op, niet de sandbox. Daarvoor hoeft niets in `ALLOWED_DOMAINS`. De firewall zoekt de adressen van de domeinen alleen bij de start van de container op: weigert een verbinding die eerst werkte, herstart dan de container.

### Fundament

De kubeconfig uit de console van Fundament of van `functl cluster kubeconfig` bevat geen token. `kubectl` vraagt bij elk gebruik een token aan via `functl cluster token`, met je API-sleutel. `functl` zit niet in de image: draai het op de host, en zet alleen zo'n token in de kubeconfig van de sandbox. De API-sleutel komt dan niet in de sandbox.

**Het korte token begrenst de toegang niet.** Het token geldt een kwartier, maar het is een gewoon gebruikerstoken van Fundament, niet gebonden aan één cluster. De API van Fundament accepteert het ook. Elk lid van een organisatie mag een API-sleutel aanmaken, dus binnen dat kwartier kan Claude een nieuwe sleutel op het account aanmaken. Die blijft geldig tot je hem intrekt, of tot de maximale termijn als de beheerder van Fundament die heeft ingesteld. Als projectbeheerder kan Claude daarnaast leden aan het project toevoegen.

Geef de sandbox daarom nooit een token van je eigen account. Gebruik een apart Fundament-account dat in de organisatie geen beheerder is en alleen de projectrol heeft die je nodig hebt. Wat het token mag, hangt af van die rol:

- **Organisatiebeheerder** (`Organization admin`): `cluster-admin`, volledige toegang tot het hele cluster. Nooit voor de sandbox.
- **Projectbeheerder** (`Project admin`): de rol `admin` in elke namespace van het project. Claude kan daarmee zelf ServiceAccounts, rechten en tokens aanmaken, Secrets lezen en NetworkPolicies wijzigen. De afscherming uit [Rechten zetten](#rechten-zetten-op-de-host-als-beheerder) houdt Claude dan niet tegen. Met deze rol werkt ook de standaard van `helm`: zet in de sandbox `export HELM_DRIVER=secret`, dan staan de values van een release niet in ConfigMaps, die ook projectviewers kunnen lezen.
- **Projectviewer** (`viewer`): de rol `view` in de namespaces van het project: alleen lezen, zonder Secrets. Claude kan dan geen pods starten en dus ook niet via het cluster naar buiten. Dit is de veiligste keuze, maar uitrollen kan er niet mee.

#### Na de sessie bij Fundament

Controleer op de host, ingelogd op het aparte account, welke API-sleutels het account heeft en wie lid is van het project:

```bash
functl apikey list
functl project member list <project-id>
```

Trek een sleutel die je niet kent in met `functl apikey revoke <id>`, en verwijder een onbekend lid met `functl project member remove <project-id> --user-id=<user-id>`. Was het account projectbeheerder, ruim dan ook op wat Claude in de namespaces van het project heeft aangemaakt, zoals ServiceAccounts, RoleBindings en pods.

### Pod Security

`enforce=restricted` weigert pods die als root draaien, extra rechten vragen of bij de node kunnen. `helm install` slaagt dan wel, maar de pods van zo'n chart komen er niet; `helm` toont alleen een waarschuwing, en `kubectl get events` de weigering. Ook de voorbeeldchart van `helm create` haalt `restricted` niet. Valt een chart daarop om, gebruik dan `enforce=baseline` met `warn=restricted`. `baseline` weigert nog steeds pods met directe toegang tot de node, en je krijgt een waarschuwing bij wat `restricted` zou weigeren. Op de host, als beheerder:

```bash
kubectl label --overwrite namespace "$NS" pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
```

Draai je het rechtenblok daarna opnieuw, dan staat de namespace weer op `restricted`; zet dit label dan opnieuw.

Pod Security verkleint de kans dat een pod uit het cluster breekt, maar sluit het niet uit. Bij k3d is dat de stap naar je eigen machine.
