# Fieldlab: helm en kubectl in de sandbox

**Doel:** teams op het Fieldlab soevereine basis (23-25 november 2026) kunnen in de sandbox
Helm-charts schrijven en controleren, en ze uitrollen naar een Kubernetes-cluster buiten de
container (#205). De documentatie zegt eerlijk wat Claude met die toegang kan.

## Context

- Fundament draait clusters op Gardener. Welke Kubernetes-versies een installatie aanbiedt, is
  door de beheerder ingevoerde data en staat niet in de repo. De lokale fixtures van Fundament
  bieden 1.33 en 1.34; de gepinde Gardener (v1.138) ondersteunt voor clusters tot en met 1.35, en
  1.33 valt vóór het Fieldlab uit de Gardener-ondersteuning. De aan-de-slagpagina van het Fieldlab
  (`fieldlab2026.projects.digilab.network/aan-de-slag`) zegt dat de clusters 1.36 draaien, en
  vraagt deelnemers om kubectl 1.35, 1.36 of 1.37.
- De kubeconfig van Fundament bevat geen token en geen CA: hij wijst naar de kube-api-proxy en
  roept `functl cluster token` aan. Dat geeft een platform-JWT van een kwartier
  (`APITokenExpiry` in `authn-api`), niet gebonden aan één cluster; `functl` gebruikt hetzelfde
  soort token voor de API van Fundament. Rollen: organisatiebeheerder `cluster-admin`,
  projectbeheerder `admin` en projectviewer `view` in de namespaces van het project.
- Met dat token kan Claude een blijvende API-sleutel aanmaken. Nagelezen in
  `fundament-oss/fundament` (commit `d80f3ad`): `common/authz/model.fga` geeft
  `can_create_apikey: viewer` op de organisatie, en elk geaccepteerd organisatielid is minstens
  viewer (`authz-worker/pkg/worker/handler/organization_user.go`). De organization-api accepteert
  elke geldige gebruikers-JWT (`auth_interceptor.go`), dus ook die uit de token-exchange
  (`authn-api/pkg/authn/exchange_token.go`). `CreateAPIKey` geeft een sleutel zonder einddatum,
  tenzij de installatie `APIKeyMaxExpiresIn` zet. `project.can_manage_members` is
  `project_admin`. De commando's in de documentatie komen uit `functl/pkg/cli`:
  `apikey list|revoke`, `project member list|remove --user-id`.
- `functl` staat alleen bij `INSTALL_GO=true` in de image, voor plug-ins. Inloggen bij Fundament
  gebeurt op de host; de sandbox krijgt alleen het token, en weigert een kubeconfig die `functl`
  aanroept.
- De ontwikkelomgeving van Fundament vraagt Docker met minstens 16 GiB geheugen, 24 GiB met de
  plug-in-sandbox (een k3d-cluster met een willekeurige API-poort) erbij.

## Snede

| # | Branch | Inhoud | Issue |
|---|---|---|---|
| 3 | `feat/helm-kubectl` (op #219) | `INSTALL_K8S`: `kubectl` en `helm`, kubeconfig-override, documentatie over koppelen, netwerk en rechten, en de K8S-laag in `build-variants` | Refs #205 |
| 4 | `chore/helm-kubectl-tracking` (op 3) | wekelijkse jobs voor `kubectl` en `helm` plus fixtures | Refs #205 |

PR 3 staat op #219, dat de opt-in-varianten in één job `build-variants` bouwt en scant. Zo
wordt de K8S-laag getest in de PR die hem introduceert: `INSTALL_K8S=true` gaat mee in die build,
met een stap die `kubectl version --client` en `helm version` in de image tegen de pins toetst. De
language-scan van `build-variants` ziet daarna kubectl en helm. De suppressies voor hun
CVE's en de helm-melding in `docs/kubernetes.md` zitten daarom ook in PR 3. Een losse
K8S-job zou een tweede image-build per PR kosten, voor een laag die de andere niet raakt.

#205 blijft open: deployen naar een echt cluster (op de host en op afstand) is hier niet getest.

De documentatie staat in `claude-sandbox/docs/kubernetes.md`: wat je krijgt en wat niet (de
risico's eerst, dan wat er geïnstalleerd is), een hoofdpad voor een deelnemer (image bouwen,
charts controleren, cluster kiezen, rechten, kubeconfig, gebruiken, opruimen) en naslag. `opstarten-en-afsluiten.md` verwijst er onder 'Na installatie' naar, de README onder 'Verder lezen'.

## Ontwerpkeuzes

**kubectl 1.36, niet de nieuwste (1.37).** kubectl ondersteunt één minor-versie verschil met de
API-server. De clusters van het Fieldlab draaien 1.36; kubectl 1.36 dekt 1.35 tot en met 1.37, en
zit daarmee midden in wat de aan-de-slagpagina vraagt. De tracking-job in PR 4 volgt dus
`stable-1.36.txt`, niet `stable.txt`; een minor-bump is een bewuste keuze die de
clusterversies volgt. `kubectl version` toont de skew als een cluster erbuiten valt.

**Officiële binaries op versie plus SHA-256 per architectuur**, op eigen variabelenamen
(`KUBECTL_SHA`, `HELM_SHA`). De delta-job in `check-upstream.yml` telt `amd64\)\s*SHA=` en
verwacht precies één treffer. De SHA's zijn gecontroleerd door te downloaden, te hashen en te
vergelijken met de gepubliceerde `.sha256`/`.sha256sum`.

**Versiecontrole als nobody.** `kubectl version --client` en `helm version` draaien via `setpriv`
zonder capabilities, met `no_new_privs` en een tijdelijke HOME; de build faalt op een afwijkende
versie of op bestanden van uid 65534 ergens op het root-bestandssysteem (plus `/tmp`, `/var/tmp`
en `/run/lock` expliciet, voor het geval een builder die apart mount). De gepubliceerde image
bevat geen bestanden van 65534, en `/tmp`, `/var/tmp` en `/run/lock` zijn de enige mappen die
iedereen mag schrijven (gemeten). De setuid-strip komt pas na deze laag.

**ARG direct boven de laag**, zodat een flip niet de hele image opnieuw bouwt. De laag staat na de
sshd-vangnetregel en vóór de setuid-strip.

**Kubeconfig via een read-only bind-mount buiten `claude-home`.**
`compose.override.kubeconfig.yml` mount `SANDBOX_KUBECONFIG` op `/run/kubeconfig/config` en zet
`KUBECONFIG`. Afgewogen:

- *Doel `/home/claude/.kube/config`:* het mountpunt blijft als leeg root-bestand (mode 700) in het
  volume achter, ook na een start zonder override, en dan weigert `kubectl` die config. Gemeten
  met podman.
- *Kubeconfig in `claude-home`:* overleeft herstarts, maar blijft staan tot het volume weg is, en
  de sandbox kan hem wijzigen.
- *Bind-mount buiten home:* weg zodra je zonder override start; de sandbox kan hem niet wijzigen.
  Lezen, en dus het token kopiëren, kan wel; dat staat in de documentatie.
- *In de projectmap:* die is in de container schrijfbaar.

Het host-bestand moet `644` zijn in een `700`-map: rootless podman maakt van het bestand in de
container een root-bestand, en `claude` kan `600` dan niet lezen (gemeten).

**Geen `extra_hosts` in de override.** De voorkeursroute voor een cluster op de host (Docker)
heeft geen hostnaam nodig, en podman zet `host.containers.internal` zelf. `host-gateway` vraagt
bovendien een recente podman (≥ 5.3), zodat de override op oudere versies zou breken.

**Cluster op de host: twee routes.** De documentatie beschrijft per route wat hij opent, zonder
isolatieclaim en zonder mechanismen van de firewall te beschrijven.

- *Docker (voorkeur):* `k3d cluster create … --network claude-sandbox_default --api-port
  127.0.0.1:6550`, server-URL voor de sandbox `https://k3d-<naam>-server-0:6443`, die naam via
  `--tls-san` in het certificaat. Het cluster staat op het containernetwerk van de sandbox;
  `OPEN_HTTPS=false` kan blijven. Advies erbij: zet geen andere containers op dit netwerk;
  behandel alles erop als bereikbaar voor Claude. `--api-port 127.0.0.1:…` houdt de API voor de
  host op loopback, niet op het LAN. De netwerknaam is bevestigd met `docker compose config`; de
  route zelf is niet getest (geen Docker of k3d beschikbaar).
- *Rootless podman (alternatief, naslag):* API-server op poort 443 van de host,
  `host.containers.internal` in de TLS-SAN, `OPEN_HTTPS=true`. De documentatie zegt wat dat opent
  (al het uitgaande verkeer over 443), dat poort 443 onder rootless podman
  `ip_unprivileged_port_start` vraagt, en dat je die na afloop terugzet op 1024. Gemeten: een
  host-poort is met deze instellingen vanuit de sandbox bereikbaar; een k3d-cluster op deze route
  is niet getest.

De k3d-nodes hebben de rechten van de container-runtime: bij Docker root, bij rootless podman de
gebruiker.

**Firewall: niets automatisch erbij.** De documentatie noemt per situatie welke domeinen in
`ALLOWED_DOMAINS` horen (API-server, chart-repositories en OCI-registries). Een IP-adres in
`server:` kan er niet in: `init-firewall.sh` resolvet elk item met `dig A` en stopt bij een lege
uitkomst, zodat de container niet start. Uitweg: een hostnaam voor de API-server, of
`OPEN_HTTPS=true`. Container-images haalt het cluster op, niet de sandbox.

**Clustertoegang omzeilt de egress-allowlist.** Met `create pods` en `pods/portforward` kan
Claude een pod als proxy gebruiken; pods hebben het netwerk van het cluster, en een Ingress of
een image-referentie zijn ook kanalen. De documentatie zegt dat vooraan: met clustertoegang
beperkt `OPEN_HTTPS=false` niet wat Claude via het cluster bereikt. Mitigatie in het
rechtenblok, als risicoverkleining:

- een NetworkPolicy voor Ingress en Egress: pods bereiken alleen elkaar in de namespace en de DNS
  van het cluster (`k8s-app: kube-dns` in `kube-system`, poort 53). DNS blijft nodig voor
  naamresolutie tussen pods en is een smal restkanaal. Zonder netwerk-plug-in die policies
  afdwingt doet de policy niets; k3s doet dat standaard.
- een ResourceQuota: pods, CPU, geheugen, tijdelijke en blijvende opslag, en aantallen per
  schrijfbaar objecttype (`count/configmaps`, `services`, `count/jobs.batch` enz.), zodat de
  sandbox etcd niet kan volschrijven. `services.loadbalancers` en `services.nodeports` op 0, omdat
  die een pod van buiten het cluster bereikbaar maken.
- een LimitRange die per container de ontbrekende `resources` aanvult (ook bij een container die
  er een deel van noemt); zonder die waarden weigert de quota de pod. Standaardlimiet 1 CPU, 1Gi
  geheugen en 1Gi `ephemeral-storage`: een container die alleen een request noemt, krijgt die
  limiet erbij, en een request erboven laat de pod stil wegvallen (fout alleen in de events). 1
  CPU/1Gi laat de gangbare requests van charts door; de limits-quota is pods × standaardlimiet
  (20 CPU, 20Gi), zodat het aantal pods de grens blijft en de requests-quota (4 CPU, 8Gi) het
  werkelijke gebruik begrenst.
- `externalIPs` (CVE-2020-8554): de Role mag Services, en een ClusterIP-Service met
  `spec.externalIPs` valt buiten de quota en kan clusterverkeer naar een willekeurig adres
  omleiden. De k3d-commando's zetten `DenyServiceExternalIPs` aan, via
  `--kube-apiserver-arg=enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs`. k3s zet
  zelf `enable-admission-plugins=NodeRestriction`, en een extra argument met dezelfde naam
  vervangt dat (`pkg/util/args.go`, `GetArgs`), dus `NodeRestriction` staat er expliciet in. De
  komma blijft heel: k3s zet `DisableSliceFlagSeparator`, k3d leest `--k3s-arg` als
  `StringArray`. Voor een cluster op afstand is het een vraag aan de beheerder (de plugin of een
  ValidatingAdmissionPolicy).
- geen `ingresses` in de Role: een Ingress maakt een dienst van buiten bereikbaar. Wie het nodig
  heeft, voegt het toe en past de policy aan.

Image-pull blijft een restkanaal (de naam gaat naar buiten, code komt binnen); dat sluit alleen de
clusterbeheerder af, met een allowlist van registries.

**Rechten: een eigen Role, geen `edit`.** De ingebouwde `edit` geeft `create` op
`serviceaccounts/token`, schrijven van Secrets en `impersonate`; daarmee maakt Claude zelf een
langer geldend token. De Role `sandbox` geeft CRUD op pods, services, ConfigMaps, PVC's,
ServiceAccounts, workloads (apps, batch), HPA's en PDB's, plus lezen van logs, events en
endpoints, en port-forward. Geen Secrets, geen `serviceaccounts/token`, geen `impersonate`, geen
RBAC, geen NetworkPolicies, quota of LimitRanges, geen ingresses, geen
`exec`/`attach`/ephemeral containers, geen wijziging van de namespace (dus ook niet van de Pod
Security-labels). Een Secret aanmaken zou volstaan voor een token zonder einddatum
(`kubernetes.io/service-account-token`), dus ook schrijven van Secrets valt weg.

Lezen van Secrets valt met RBAC niet af te sluiten: een pod mag elke Secret in de namespace
mounten en onder elke ServiceAccount daar draaien, en via de opdracht van een pod en de logs
draait Claude elk commando. De documentatie zegt dat, adviseert geen geheime Secrets en geen
ruimere ServiceAccounts in de namespace, en `existingSecret` alleen met testwaarden die Claude mag
kennen. Omdat helm releases standaard in Secrets bewaart, zet de override
`HELM_DRIVER=configmap`; de release-values staan dan in ConfigMaps, leesbaar voor wie ConfigMaps
mag lezen.

**Rechtenblok als één `&&`-keten, idempotent.** Elke stap is herhaalbaar
(`create … --dry-run=client -o yaml | kubectl apply -f -`, `label --overwrite`, `apply`), en de
RoleBinding komt als laatste: faalt een stap (bijvoorbeeld als namespace-admin, die quota en
LimitRange niet mag zetten), dan stopt de keten met een exitcode ongelijk aan 0 en krijgt de
ServiceAccount geen rechten in een half afgeschermde namespace. Een heredoc midden in de keten
(`<<'EOF' &&`) werkt geplakt in bash en zsh. Een nieuwe run zet een `baseline`-terugval weer op
`restricted`; de documentatie zegt dat.

De namespace krijgt bij het aanmaken het label `claude-sandbox=true` (`kubectl create`, niet
`apply`), en het blok stopt bij een bestaande namespace zonder dat label, ook `default`. Anders zou
het een namespace van een ander overnemen: de ServiceAccount `sandbox` kan daar een pod starten
onder een bestaande ServiceAccount met meer rechten, en het opruimblok zou de namespace
verwijderen. De Role mag de namespace niet wijzigen, dus Claude kan het label niet zetten.

**Opruimen: de namespace verwijderen.** Het token is geen grens: Claude kan eigen
ServiceAccounts aanmaken en pods met langlevende projected tokens starten. Alleen
`kubectl delete namespace` ruimt dat allemaal op; de documentatie noemt geen andere route. Het
opruimblok verwijdert alleen een namespace met het label `claude-sandbox=true`, en eindigt anders
met `FOUT` en een exitcode ongelijk aan 0 (`false`, geen `exit`: het blok wordt geplakt).

**Pod Security `restricted`**, met `baseline` + `warn=restricted` als terugval, en voor k3d
`seccomp-default=true` op de kubelet. Beschreven als risicoverkleining: bij k3d zijn de nodes
privileged containers op de host. De voorbeeldchart van `helm create` haalt `restricted` niet;
`helm install` slaagt dan, maar de pods komen er niet.

**Kubeconfig-recept: variabelen per route, één schrijfblok.** Per route zet de deelnemer `NS`,
`F` (`$HOME/.kube/sandbox/config`; in `.env` het absolute pad, omdat compose daar niet op elke
versie `$HOME` invult), `HOST_SERVER` (waar de host het cluster bereikt), `SERVER` (waar de
sandbox het bereikt), `CA` en een functie `token_ophalen`. Bij k3d op Docker en op podman
verschilt `SERVER` van `HOST_SERVER`, ook bij vernieuwen. De CA komt uit `--flatten`, zodat een
CA-bestandspad in de beheer-kubeconfig ook werkt. Het schrijfblok is voor alle routes gelijk:

- het controleert `F`, `NS`, `SERVER` en `HOST_SERVER` op leeg, weigert een `NS` met andere tekens
  dan `a-z`, `0-9` en `-` (een niet ingevulde placeholder), weigert een `SERVER` zonder `://` of
  die in de sandbox naar de container zelf wijst (na omzetten naar kleine letters: `127.*`,
  `localhost`, `localhost.`, `0`, `0.0.0.0`, `[::1]`, `[::]`, `[::ffff:127.…]`,
  `[0:0:0:0:0:0:0:1]`: de vergeten k3d-regel), en weigert als `F` al andere users dan `sandbox`
  bevat. De tekenklasse is `[^…]`, niet `[!…]`: geplakt in zsh geeft `!` `event not found`. Elke
  fout eindigt met `exit 1` in de subshell: het blok eindigt met een exitcode ongelijk aan 0, zonder een
  interactieve shell te sluiten.
- de map krijgt alleen een modus als het blok hem zelf maakt (`[ -d ] || mkdir -m 700 -p`); een
  bestaande map die groep of anderen toegang geeft is een fout (`ls -ld` tegen `d???------*`,
  ook op macOS). Een willekeurige bovenliggende map, zoals `$HOME`, wordt nooit aangepast.
- pas dan vraagt het een token aan; een leeg token is een fout. Het schrijft naar een
  `mktemp`-bestand in dezelfde map (600 door `umask 077`, opgeruimd met `trap … EXIT`), met een
  heredoc, zodat het token in geen argv komt. De CA-regel komt er alleen in als `CA` gezet is
  (`${CA:+…}`).
- de controle is `kubectl --kubeconfig "$tmp" --server "$HOST_SERVER" --tls-server-name <host uit
  SERVER> auth whoami`: ze toont het account dat het cluster bij het token ziet, en faalt als de
  naam waarmee de sandbox verbindt niet in het certificaat staat. Pas na een geslaagde controle
  zet `cat "$tmp" >| "$F"` het bestand op zijn plek, daarna `chmod 644`. Bij een mislukte controle
  blijft de oude kubeconfig staan.

Beide schrijfacties gebruiken `>|`, zodat ze ook werken met `noclobber` (het tijdelijke bestand
bestaat al door `mktemp`). `cat >|` op `F` houdt de inode gelijk, zodat een draaiende container
een vernieuwd token meteen ziet; een nieuw bestand (ook `mv` van het tijdelijke) ziet een bind-mount pas na
`--force-recreate` (gemeten). bash en zsh bewaren een heredoc mogelijk kort in een tijdelijk
bestand met mode 600.

Geen `#`-commentaar in shellblokken: zsh zonder `interactivecomments` (de shell van `claude` in
de image, en vaak op de host) voert `#` als argument uit. Ook geen `"$VAR:…"`: zsh leest `:s` als
modifier (`bad substitution`); de rolebinding gebruikt daarom `"${NS}:sandbox"`.

**Fundament: `functl` op de host, apart account.** Een voorblok draait `functl cluster list`
(toont het cluster-id) en `functl cluster kubeconfig <id> > ~/.kube/fundament.yaml`
(`functl/pkg/cli/cluster_kubeconfig.go` print de kubeconfig op stdout). De host uit `server:`
moet bij `OPEN_HTTPS=false` in `ALLOWED_DOMAINS`. Het variabelenblok begint met
`unset CLUSTER NS`, en de placeholders staan tussen enkele aanhalingstekens
(`CLUSTER='<cluster-id>'`): zonder quotes is `<` een redirect en het blok een syntaxfout, en zsh
met bracketed paste verwerpt dan het hele geplakte blok, zodat een waarde uit een eerdere run
blijft staan. Een niet ingevulde placeholder vangt het schrijfblok (`NS`) of `token_ophalen`
(`CLUSTER`). `functl cluster token` gebruikt het cluster-id niet (`cluster_token.go`: "accepted for
compatibility"), dus `token_ophalen` controleert zelf dat `CLUSTER` een id is: alleen hexadecimale
tekens en `-`, want de API valideert cluster-id's als UUID (`buf.validate` `uuid: true` in
`organization-api/pkg/proto/v1/cluster.proto`). Daarna roept het
`functl cluster token "$CLUSTER" | jq -er '.status.token | select(type == "string" and length > 0)'`
aan. `CA` is expliciet leeg, zodat een CA uit een eerdere run in dezelfde shell niet meekomt.
Omdat het token een blijvende API-sleutel kan aanmaken (zie Context), adviseert de documentatie
nooit een token van het eigen account, maar een apart account dat geen organisatiebeheerder is en alleen de nodige projectrol heeft (viewer het veiligst), en na
de sessie `functl apikey list` en `functl project member list`. Als projectbeheerder mag de
Secret-driver van helm; dan kan Claude ook NetworkPolicies wijzigen, en houdt de afscherming uit
het rechtenblok hem niet tegen.

## Verificatie

- Testimage met de K8S-laag letterlijk uit de Dockerfile (Debian-basis, podman, amd64). De
  RUN-instructie in de image (`podman image history`) is gelijk aan die in de huidige Dockerfile;
  de Dockerfile-wijzigingen daarna (sync-comment, `TODO(#205)`) raken alleen comments, en de
  image is daarna niet opnieuw gebouwd:
  - `true`: `kubectl` v1.35.10 en `helm` v4.3.1 in `/usr/local/bin`; `/tmp`, `/var/tmp` schoon.
  - `false`: geen `kubectl` of `helm`.
  - Een ongeldige waarde (`ja`) laat de build falen.
- Mutatiecheck op de build-controles: 7 mutaties, 7 gevangen (beide SHA's, beide
  versiecontroles, de opruiming, een achtergelaten bestand in `/run/lock`, een map in `/var/tmp`).
- `amd64\)\s*SHA=` en `arm64\)\s*SHA=` hebben elk precies één treffer.
- Override: `docker compose config` lost bind-mount, `read_only`, `KUBECONFIG` en `HELM_DRIVER`
  op, zonder `extra_hosts`; het standaardnetwerk heet `claude-sandbox_default`. Zonder
  `SANDBOX_KUBECONFIG` weigert compose met de foutmelding uit de override.
- Read-only bind-mount (podman): vernieuwen met `cat >` op de host is meteen zichtbaar in de
  container; schrijven vanuit de container faalt; `claude` leest het `644`-bestand.
- Alle bash-blokken uit `docs/kubernetes.md` behalve `k3d cluster create` en `docker compose up`
  letterlijk geëxtraheerd en geplakt in `bash -i` en in `zsh -i` (zonder `interactivecomments`,
  gecontroleerd), als niet-root, tegen etcd plus kube-apiserver en kube-controller-manager
  v1.35.10 (RBAC, PodSecurity, ResourceQuota, LimitRanger; geen scheduler of kubelet): 373
  controles groen, per shell een eigen namespace. De extractie faalt op `#` in een shellblok, en
  op een k3d-commando zonder `DenyServiceExternalIPs`. De API-server heet in de proef
  `api.proef.test` (via `/etc/hosts` op 127.0.0.1), met `k3d-fieldlab-server-0` in het
  certificaat.
  - Rechtenblok als cluster-admin: twee runs na elkaar rc 0; namespace met label
    `claude-sandbox=true`; Role, NetworkPolicy (Ingress en Egress, DNS op 53), ResourceQuota (met
    aantallen en `ephemeral-storage`), LimitRange en RoleBinding aanwezig; quota-status door de
    controller-manager gezet. Een bestaande namespace zonder label, met een ServiceAccount die
    `cluster-admin` heeft: rc ongelijk aan 0 (`AlreadyExists`), geen ServiceAccount, RoleBinding
    of NetworkPolicy `sandbox`, labels ongemoeid. `NS=default`: rc ongelijk aan 0, niets gezet.
    Als namespace-admin (ClusterRole `admin` in één namespace): rc ongelijk aan 0 bij de eerste
    stap, geen RoleBinding. Na de Pod Security-terugval zet een nieuwe run `restricted` terug,
    rc 0.
  - `kubectl auth can-i` als de ServiceAccount: wel workloads, pods, services, ConfigMaps,
    ServiceAccounts, logs, events, port-forward, jobs, PDB's; niet Secrets (get/list/create),
    `serviceaccounts/token`, `impersonate` (users en serviceaccounts), `exec`, `attach`,
    ephemeral containers, ingresses, roles/rolebindings, NetworkPolicies, ResourceQuotas en
    LimitRanges (create/update/patch/delete), de namespace (update/patch), andere namespaces,
    nodes. `delete networkpolicy` als sandbox: `forbidden`.
  - Gedrag: pod zonder `resources` krijgt limiet 1 CPU en 1Gi `ephemeral-storage`; een container
    met alleen eigen limits krijgt de ontbrekende waarden aangevuld; een pod met alleen een
    request van 2 CPU wordt geweigerd; een Deployment met alleen een request van 2Gi wordt
    toegelaten, de weigering staat alleen in `kubectl get events` (als sandbox leesbaar).
    `LoadBalancer`- en `NodePort`-Service geweigerd door de quota, `ClusterIP` toegelaten, een
    ClusterIP-Service met `externalIPs` toegelaten (het beschreven risico); de 51e ConfigMap
    geweigerd. Een pod met een Secret-volume en een pod onder ServiceAccount `sandbox`
    toegelaten; sandbox maakt een eigen ServiceAccount.
  - Charts- en gebruiken-blok als sandbox: `helm create/lint/template`; `helm upgrade --install`
    twee keer (revisie 2) met `HELM_DRIVER=configmap`, `kubectl get events` toont de
    Pod Security-weigering van de voorbeeldchart, er komen geen pods; de Secret-driver wordt
    geweigerd. Na `baseline`: `kubectl auth can-i patch deployments.apps` is `yes`, het
    herstart-blok als sandbox geeft rc 0 en zet `restartedAt`, en er komen pods (zonder kubelet
    alleen als object). `helm uninstall` slaagt.
  - Kubeconfig-blok: vers (rc 0, `auth whoami` toont `system:serviceaccount:<ns>:sandbox`, CA
    als bestandspad ingebed, 644 in een nieuwe 700-map, token in geen argv, geen tijdelijk
    bestand achter), vernieuwen (zelfde inode), k3d-variabelen (`server:` het k3d-adres, whoami
    via `HOST_SERVER` met `--tls-server-name`). Rc ongelijk aan 0, oude kubeconfig ongewijzigd
    en geen tijdelijk bestand bij: naam uit `SERVER` niet in het certificaat, `create token`
    faalt of is leeg, ongeldig token, token van een ander cluster. Geweigerd zonder
    token-aanvraag: `SERVER` op `127.0.0.1:6550`, `localhost:6443`, `localhost`, `0.0.0.0:443`,
    `[::1]:6443`, `LOCALHOST:6550`, `HTTPS://127.0.0.1:6550`, `localhost.:6550`, `0:6550`, `0`,
    `[::ffff:127.0.0.1]:6443`, `[0:0:0:0:0:0:0:1]:6443`, `[::]:6443`, en de vergeten k3d-regel
    bij een beheer-kubeconfig op `127.0.0.1`; `SERVER` zonder `://` (`localhost:6550`,
    `k3d-fieldlab-server-0:6443`); `NS` als niet ingevulde placeholder, `Team-A` of `team_a`;
    een bestaande map met 755 (map ongemoeid); `F` direct in `$HOME` (`$HOME` ongemoeid);
    bestaand beheerbestand; lege `F`, `NS` of `SERVER`. Lege beheer-kubeconfig: rc ongelijk aan
    0. Met `noclobber` (bash `set -o`, zsh `setopt`): nieuw en vernieuwen rc 0, zelfde inode.
  - Fundament met een nep-`functl` en de proef-CA als systeem-CA: het voorblok roept
    `cluster list` en `cluster kubeconfig <id>` aan en schrijft `~/.kube/fundament.yaml`; ok
    (rc 0, whoami, geen CA, geen exec, token in geen argv); `fail`, lege string, `null` en een
    getal: rc ongelijk aan 0, bestand ongewijzigd, en `token_ophalen` zelf faalt. Lege
    `CLUSTER`: `token_ophalen` faalt zonder `functl` aan te roepen. Vergeten placeholders met
    oude `NS`/`CLUSTER` in de shell: beide of alleen `NS` geeft `FOUT: NS (<namespace van je
    project>)`, alleen `CLUSTER` geeft `FOUT: CLUSTER (<cluster-id>)`; in alle drie geen
    `functl cluster token` en het bestand ongewijzigd. Het na-de-sessie-blok roept
    `functl apikey list` en `functl project member list <id>` aan.
  - Opruimen: verwijdert de eigen namespace, daarna weigert de apiserver het token van `sandbox`
    en dat van een door de sandbox aangemaakte ServiceAccount. Een namespace zonder label,
    `default` en een niet-bestaande namespace: rc ongelijk aan 0 met `FOUT`, namespace blijft.
  - Plakproef op een pty (`paste.py`), in `bash -i` en `zsh -i`, met bracketed paste en regel
    voor regel: rechtenblok op een nieuwe namespace (rc 0, label, RoleBinding) en een tweede run
    (rc 0); een vreemde namespace met een `cluster-admin`-ServiceAccount en `default`: rc ongelijk
    aan 0, geen ServiceAccount of RoleBinding. Fundament-blok ongevuld na oude waarden in de
    shell: `FOUT`, `NS` en `CLUSTER` daarna de placeholders (het blok liep dus), geen bestand;
    alleen `NS` of alleen `CLUSTER` ingevuld: `FOUT` voor de andere, geen `functl cluster token`;
    beide ingevuld: rc 0 en whoami. `noclobber` met nieuw en vernieuwen: rc 0. `LOCALHOST`
    geweigerd. Opruimen weigert de vreemde namespace en verwijdert de eigen; de shell leeft
    daarna nog.
  - Dezelfde kube-apiserver met `--enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs`
    (de waarde die k3s doorgeeft): een Service met `externalIPs` geweigerd, ook voor de
    beheerder; ClusterIP zonder `externalIPs` toegelaten.
- Mutatiecheck op de recepten, per mutatie de proef (plakproef alleen met bracketed paste); elke
  mutatie hoort minstens één controle rood te maken.
  - Namespace-label en opruimen, NS- en CLUSTER-controle, `>|`, loopback en herstart: 26
    mutaties, 25 gevangen (hoofdproef in bash, plakproef in bash en zsh met bracketed paste).
    Gevangen: labelcontrole weg, `create` wordt `apply`, label niet gezet, namespace niet
    idempotent, opruimbewaking weg, opruimen zonder `false`, NS-controle weg of zonder `exit`,
    `[^…]` wordt `[!…]` (alleen in geplakte zsh), CLUSTER-controle weg, zonder `return` of met
    lege `CLUSTER` toegestaan, placeholders zonder quotes, `>|` terug naar `>` (tijdelijk bestand
    en `F` apart), kleine letters weg, schemacontrole weg, `localhost`, `localhost.`, `0`,
    `[::]`, `[::ffff:127.…]` of `[0:0:0:0:0:0:0:1]` weg, tijdelijk bestand weg, herstartregel
    weg. Niet gevangen: `unset CLUSTER NS` weg; met gequote placeholders lopen beide toewijzingen
    altijd, dus de `unset` verandert niets meer.
  - De overige mutaties (`&&`-keten, RoleBinding, loopback zonder `exit`, `[::1]`, whoami,
    `--tls-server-name`, mapcontrole, `trap`, LimitRange, quota, events,
    `DenyServiceExternalIPs`, lege-waardecontroles, `jq`, `--flatten`, NetworkPolicy, ingresses,
    `$NS:` in zsh), hoofdproef in bash en zsh: 25 mutaties, 24 gevangen. Niet gevangen:
    `mkdir -m 700 -p` naar `mkdir -p`; onder `umask 077` krijgt de map toch 700.
- Eerder gemeten met de vorige versie van de rol, nu niet herhaald: Pod Security weigert onder
  `restricted` een pod zonder securityContext en een hostPath-pod; onder `baseline` met
  `warn=restricted` toegelaten met waarschuwing, hostPath nog steeds geweigerd.
  `system:aggregate-to-edit` bevat `serviceaccounts/token`, Secrets aanmaken en `impersonate`.

Niet geverifieerd: een echt cluster met draaiende pods (k3d op de host via beide routes, met
`--api-port 127.0.0.1:6550` en de `--k3s-arg`-regels; de syntax is alleen tegen de broncode van
k3d en k3s gelezen, Fundament, een cluster op afstand), of de NetworkPolicy wordt
afgedwongen (de testapiserver heeft geen netwerk-plug-in), de DNS-selector op een echt cluster,
`auth whoami` via de kube-api-proxy van Fundament, de Fundament-blokken tegen echte `functl`, de
gedragsclaims over Fundament anders dan door het lezen van de broncode, Docker Desktop en
Docker Engine, arm64, en de volledige image-build.

## PR 4: tracking en CI-build

De job `build-k8s-variant` en de suppressies hieronder zijn naar PR 3 verhuisd, toen die op #219
kwam te staan. De K8S-laag bouwt en scant nu mee in `build-variants`. PR 4 houdt de wekelijkse
jobs, de fixtures en de aparte Dockerfile-blokken. Wat hieronder over `build-k8s-variant` staat,
geldt nu voor de K8S-stap in `build-variants`.

### Stappen

1. Dockerfile: kubectl- en helm-pins in eigen blokken binnen de laag; `TODO(#205)` weg.
2. `check-upstream.yml`: jobs `kubectl-version` en `helm-version`, achteraan in het bestand.
3. Fixtures in `test-check-upstream-jobs.sh`, als eigen sectie aan het eind.
4. `build-image.yml`: de K8S-stap in `build-variants` (nu in PR 3).
5. `.trivyignore.yaml`, README 'Dependency-onderhoud' en CLAUDE.md.

### Ontwerpkeuzes

**kubectl volgt `stable-<minor>.txt`.** De minor komt uit de pin, dus de job bumpt alleen
patches. Noemt dat bestand een andere minor, dan faalt de job. Een nieuwere minor in `stable.txt`
geeft een `::warning::` in de run, ook zonder patch, en een zin in de PR-body als er een PR
komt. Ligt `stable.txt` drie of meer minors voor (of een andere major), dan valt de gepinde
minor buiten de drie die upstream ondersteunt: dan faalt de job. Er komen dan geen patches en
dus geen auto-PR meer; een waarschuwing in een groene geplande run ziet niemand, een rode run
geeft een mail.

**SHA's ook bij gelijke versie tegen upstream.** Zonder nieuwe release haalt de job de
checksums van de gepinde versie op en vergelijkt ze met de pins. Een verkeerd overgenomen of
upstream gewijzigde checksum valt zo binnen een week op; CI bouwt de K8S-laag niet op arm64.
De telling van de pins weigert een hash van meer dan 64 tekens (`(?![a-f0-9])`).

**helm kiest zelf uit de releaselijst.** helm brengt v3 en v4 naast elkaar uit (v4.3.1 en
v3.22.1 staan direct na elkaar in de lijst), dus `releases/latest` kan een v3-patch zijn. De job
haalt alle pagina's (`gh api --paginate`, samengevoegd met `jq -s`) en houdt alleen tags over
die geen concept en geen pre-release zijn en exact `vX.Y.Z` zijn (`\A…\z`: `$` laat in jq een
afsluitende newline door). Daarna sorteert hij numeriek en kiest hij binnen de gepinde major.
Staat de gepinde versie zelf niet in die lijst, dan faalt de job: de lijst is dan onvolledig of
teruggezet. Daarmee is een lagere `latest` dan de pin onmogelijk en vervalt de aparte
downgradecontrole. Een hogere major wordt gemeld, net als bij kubectl, maar laat de job niet
falen: een nieuwe helm-major maakt de vorige niet meteen onveilig, en er is geen
supportbeleid dat een vaste grens geeft.

**Gepubliceerde checksums, niet zelf hashen.** `kubectl.sha256` van `dl.k8s.io` en
`.sha256sum` van `get.helm.sh` komen van dezelfde host als de binary. Zelf downloaden en hashen
zegt dus niets extra's over de herkomst, en kost per run twee downloads van 60 MB. De build
toetst de binary ertegen. Dit volgt `node-version` en `go-version`; `delta-version` hasht zelf
omdat delta geen checksumbestand publiceert. Bij helm moet de bestandsnaam in de `.sha256sum`
kloppen.

**Pins in eigen blokken.** In de Dockerfile van PR 3 stonden `KUBECTL_VERSION` en
`HELM_VERSION` op aangrenzende regels, net als de SHA's per architectuur. Een kubectl- en een
helm-auto-PR conflicteerden daardoor altijd. Nu heeft elke tool een eigen `case`, met regels
ertussen die geen van beide jobs wijzigt. Beide `case`-blokken weigeren een onbekende
architectuur.

**README en `docs/kubernetes.md` verschuiven mee bij een helm-minor.** De job vervangt de
vermelding met de omringende tekst (`helm 4.3 (` en `` `helm` (4.3) ``), met precies één treffer
per bestand, zodat een ander getal met dezelfde cijfers blijft staan. `vervang-pin.sh` weigert
spaties en haakjes, dus dit gaat via `perl` met `\Q…\E`. Bij kubectl verandert de minor nooit
via de job.

**Suppressies opruimen.** De PR-bodies van beide jobs vragen de reviewer de suppressies op die
binary in `.trivyignore.yaml` na te lopen, zoals `npm-version` al doet. Een overbodige
suppressie maakt niets rood en zou anders blijven staan, ook na `expired_at`; #229 laat
`build-variants` daarop falen.

**Plaats in de bestanden.** De jobs en fixtures staan achteraan, en de variant-build ook. PR 2
(#211) voegt zijn jobs in na `rtk-version` en voor `build`. Zo voegt deze PR geen conflict
met #211 toe.

**K8S-stap (nu in `build-variants`, PR 3).** Oorspronkelijk opgezet als eigen job, naar het
voorbeeld van `build-sshd-variant` en de Go-variant uit #211:

- alleen amd64, geen push, niet op tags;
- action-pins gelijk aan `build-and-push`;
- een eigen cache-scope `k8s`.

De controlestap leest de pins uit de Dockerfile en draait `kubectl version --client -o json` en
`helm version` als `claude`, met `env -i` en zonder netwerk. Elke `docker run` wordt eerst
toegewezen, zodat een falende run telt. Trivy scant met `TRIVY_PKG_TYPES: library`; de
os-pakketten scant `build-and-push` al. De scan dekt alle language-pakketten, ook npm en pip van
de default-image; de comment bij de language-scan van `build-variants` zegt dat. `skip-dirs` voor die paden is afgewezen: meer
configuratie om een signaal weg te halen dat op main nergens anders binnenkomt.

**Suppressies voor de huidige binaries.** Trivy (lokaal, `aquasec/trivy:latest`, `rootfs` op
de twee binaries) vindt drie fixbare HIGH's:

- CVE-2026-111943 in de Go-stdlib van helm (Go 1.27.2, fix in 1.27.3);
- CVE-2026-78669 in `golang.org/x/net` 0.56.0 van kubectl;
- CVE-2026-56851 in `golang.org/x/text` 0.39.0 van kubectl.

Er is geen release met de fix: v1.35.10 is de laatste 1.35-patch, v4.3.1 de laatste v4. Zonder
suppressie komt de nieuwe job rood binnen, zonder iets dat een PR kan verhelpen. De drie regels
zijn gebonden aan het pad van de binary. Zelf bouwen met een nieuwere Go is afgewezen, omdat dan
de pin op de officiële binary vervalt.

- De helm-regel onderbouwt het risico: misbruik vraagt een positie op het netwerkpad én een
  certificaat onder een gedenyliste tussen-CA; het raakt repo- en registry-verkeer, nauwelijks
  de API-server met eigen CA. Hij verloopt op 2026-11-30, na de eerstvolgende helm-patchrelease.
  `docs/kubernetes.md` meldt de CVE aan gebruikers tot de bump.
- `x/text/secure/precis` komt in de kubectl-binary niet voor (0 treffers op de pakketnaam;
  `bidirule` en `unicode/norm` wel): de kwetsbare code van CVE-2026-56851 is onbereikbaar.
- CVE-2026-78669 treft kubectl tegenover elke vijandige HTTP/2-server, ook een URL bij `-f`.
- De kubectl-regels verlopen op 2026-12-31.
- CVE-2026-78661 in `golang.org/x/net` (fix in 0.62.0) zit in beide binaries: kubectl 0.56.0,
  helm 0.60.0. Er is geen release met de fix: `release-1.35` van Kubernetes zit op 0.56.0,
  `release-4.3` van helm op 0.60.0 en helm `main` op 0.61.0. Daarom één regel per binary, tot
  2026-12-31. De kwetsbare parser (`addText`, `fosterParent`) is in geen van beide gelinkt: helm
  bevat geen symbool uit `x/net/html`, kubectl alleen de `Tokenizer`. Er is geen
  gebruikersmelding, net als bij de andere onbereikbare kubectl-CVE.

### Verificatie

- `actionlint -shellcheck ~/.local/bin/shellcheck .github/workflows/*.yml`: schoon, op de
  workflows van de eerste commit. Daarna bleef actionlint lokaal hangen op `check-upstream.yml`,
  ook op de versie van PR 3. Hij blokkeerde bij het schrijven van het run-blok van
  `apt-security-refresh` (22 KB) naar shellcheck. Voor de laatste stand daarom:
  - actionlint zonder shellcheck: schoon;
  - alle 38 run-blokken los door shellcheck, met de opties van actionlint: schoon.
- `shellcheck --severity=warning .github/scripts/*.sh`: schoon.
- Fixtures:
  - `test-check-upstream-jobs.sh`: 179 geslaagd, 0 gefaald, waarvan 97 nieuw voor kubectl en
    helm;
  - `test-vervang-pin.sh`: 20/0;
  - `test-valideer-trivyignore.sh`: 30/0;
  - `test-apt-upgrade-beschikbaar.sh`: 22/0;
  - `valideer-trivyignore.sh` op de nieuwe lijst: rc 0.
- Mutatiecheck op een `git archive`-kopie: 55 mutaties in de twee compare-stappen en de
  PR-stappen, 54 gevangen. De eerste ronde liet een SHA-regex zonder `^` door; daar zijn
  fixtures voor bijgekomen. Niet gevangen: `\A` vervangen door `^` in het tagfilter. Dat is
  equivalent, want in jq is `^` al het begin van de string (gemeten: `"x\nv4.1.0"` matcht
  niet).
- Tegen de echte upstream, op een kopie:
  - beide jobs geven `changed=false` op de huidige pins;
  - kubectl meldt `stable.txt` op v1.37.2 als nieuwere minor;
  - een bump vanaf oude pins (kubectl v1.35.9, helm v4.2.4 met `4.2` in README en docs, nep-SHA's)
    levert een Dockerfile, README en `docs/kubernetes.md` op die byte-gelijk zijn aan de huidige.
- Conflictproef met `git merge-file`:
  - een kubectl- en een helm-bump op de nieuwe indeling mergen zonder conflict, en beide bumps
    staan in het resultaat;
  - op de indeling van PR 3 gaf dezelfde proef een conflict;
  - tegen #211 voegt deze PR geen conflict toe in de workflows, de fixtures, README, CLAUDE.md,
    `.trivyignore.yaml` en de Dockerfile. De bekende conflicten in README en Dockerfile tussen
    PR 3 en #210/#211 blijven.
- Testimage met de K8S-laag letterlijk uit de nieuwe Dockerfile (podman, amd64): beide SHA's OK,
  versiecontrole als nobody groen.
- De controlestap van `build-k8s-variant`, met yq uit de workflow gehaald en tegen die testimage
  gedraaid:
  - groen op de pins;
  - rood bij een andere kubectl-pin, een andere helm-pin, een falende `docker run` en een
    onleesbare pin.
- Trivy met de nieuwe `.trivyignore.yaml` op de twee binaries: 0 bevindingen, rc 0.

Na reviewronde 1:

- actionlint zonder shellcheck: schoon; shellcheck (ook style) op de losgetrokken run-blokken
  van `kubectl-version`, `helm-version` en `build-k8s-variant`: schoon.
- `test-check-upstream-jobs.sh` 230/0, `test-vervang-pin.sh` 20/0,
  `test-valideer-trivyignore.sh` 30/0, `test-apt-upgrade-beschikbaar.sh` 22/0,
  `valideer-trivyignore.sh` rc 0.
- Mutatiecheck (`git archive`-kopie per mutatie): 38 mutaties, 36 gevangen. Niet gevangen, en
  equivalent: de lookahead in de pin-extractie (de telling erboven dwingt hem al af) en
  `checksum "$latest"` in plaats van `"$current"` in de tak waar die gelijk zijn.
- Conflictproef in een scratch-repo: kubectl-patchbump en helm-minorbump, elk door de echte
  compare-stap, mergen zonder conflict; met de blokken aangrenzend vangt de diff3-fixture het
  conflict.
- Tegen de echte upstream: beide jobs `changed=false`, de pins kloppen met de gepubliceerde
  checksums, kubectl waarschuwt voor v1.37.2 (twee minors voor, dus nog geen fout), de helm-lijst
  komt via `--paginate` binnen en bevat de pin.

Niet geverifieerd:

- **De K8S-stap in `build-variants` heeft nog niet in CI gedraaid.** De volledige image met
  `INSTALL_K8S=true` is lokaal niet gebouwd (apt over poort 80). De Trivy-versie en -DB van
  `trivy-action` v0.36.0 kunnen afwijken van de lokale scan.
- **De `create-pull-request`-stappen.** De PR-teksten zijn alleen statisch via yq getoetst,
  inclusief de ingevulde `format()`-zinnen.
- **De echte upstream bij een nieuwe patch of release.** Dat pad is alleen tegen stubs getoetst,
  en via de bump vanaf oude pins.
