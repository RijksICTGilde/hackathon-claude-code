# Fieldlab: helm en kubectl in de sandbox

**Doel:** teams op het Fieldlab soevereine basis (23-25 november 2026) kunnen in de sandbox
Helm-charts schrijven en controleren, en ze uitrollen naar een Kubernetes-cluster buiten de
container (#205). De documentatie zegt eerlijk wat Claude met die toegang kan.

## Context

- Fundament draait clusters op Gardener. Welke Kubernetes-versies een installatie aanbiedt, is
  door de beheerder ingevoerde data en staat niet in de repo. De lokale fixtures van Fundament
  bieden 1.33 en 1.34; de gepinde Gardener (v1.138) ondersteunt voor clusters tot en met 1.35, en
  1.33 valt vóór het Fieldlab uit de Gardener-ondersteuning.
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
- `functl` zit niet in de image; de documentatie laat het op de host draaien.
- De ontwikkelomgeving van Fundament vraagt Docker met minstens 16 GiB geheugen, 24 GiB met de
  plug-in-sandbox (een k3d-cluster met een willekeurige API-poort) erbij.

## Snede

| # | Branch | Inhoud | Issue |
|---|---|---|---|
| 3 | `feat/helm-kubectl` | `INSTALL_K8S`: `kubectl` en `helm`, kubeconfig-override, documentatie over koppelen, netwerk en rechten | Refs #205 |
| 4 | `ci/helm-kubectl-tracking` (op 3) | wekelijkse jobs voor `kubectl` en `helm` plus fixtures, CI-build van de K8S-variant | Refs #205 |

#205 blijft open: deployen naar een echt cluster (op de host en op afstand) is hier niet getest.

De documentatie staat in `claude-sandbox/docs/kubernetes.md`: wat je krijgt en wat niet, een
hoofdpad voor een deelnemer (charts controleren, cluster kiezen, rechten, kubeconfig, gebruiken,
opruimen) en naslag. `opstarten-en-afsluiten.md` verwijst er onder 'Na installatie' naar.

## Ontwerpkeuzes

**kubectl 1.35, niet de nieuwste (1.37).** kubectl ondersteunt één minor-versie verschil met de
API-server. 1.35 dekt 1.34 tot en met 1.36, en daarmee de versies die Gardener tijdens het
Fieldlab ondersteunt. 1.34 zou ook 1.33 dekken, maar is upstream end-of-life. De tracking-job in
PR 4 volgt dus `stable-1.35.txt`, niet `stable.txt`; een minor-bump is een bewuste keuze die de
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
- een ResourceQuota (pods, CPU, geheugen, opslag; `services.loadbalancers` en
  `services.nodeports` op 0, omdat die een pod van buiten het cluster bereikbaar maken) en een
  LimitRange met standaardwaarden, zonder welke de quota pods zonder `resources` weigert.
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

**Opruimen: de namespace verwijderen.** Het token is geen grens: Claude kan eigen
ServiceAccounts aanmaken en pods met langlevende projected tokens starten. Alleen
`kubectl delete namespace` ruimt dat allemaal op; de documentatie noemt geen andere route.

**Pod Security `restricted`**, met `baseline` + `warn=restricted` als terugval, en voor k3d
`seccomp-default=true` op de kubelet. Beschreven als risicoverkleining: bij k3d zijn de nodes
privileged containers op de host. De voorbeeldchart van `helm create` haalt `restricted` niet;
`helm install` slaagt dan, maar de pods komen er niet.

**Kubeconfig-recept: variabelen per route, één schrijfblok.** Per route zet de deelnemer `NS`,
`F`, `HOST_SERVER` (waar de host het cluster bereikt), `SERVER` (waar de sandbox het bereikt),
`CA` en een functie `token_ophalen`. Bij k3d op Docker verschilt `SERVER` van `HOST_SERVER`, ook
bij vernieuwen. De CA komt uit `--flatten`, zodat een CA-bestandspad ook werkt. Het schrijfblok is
voor alle routes gelijk:

- het controleert `F`, `NS`, `SERVER` en `HOST_SERVER` op leeg, en weigert als `F` al andere
  users dan `sandbox` bevat. Elke fout eindigt met `exit 1` in de subshell: het blok eindigt met
  een exitcode ongelijk aan 0, zonder een interactieve shell te sluiten.
- `mkdir -p` plus `chmod 700` op de map (`mkdir -m` zet geen modus op een bestaande map) en
  `umask 077`; daarna `chmod 644` op het bestand, om de reden hierboven.
- pas dan vraagt het een token aan; een leeg token is een fout. Het schrijft het hele bestand met
  een heredoc, zodat het token in geen argv komt. De CA-regel komt er alleen in als `CA` gezet is
  (`${CA:+…}`).
- het eindigt met `kubectl --kubeconfig "$F" --server "$HOST_SERVER" auth whoami`: de controle
  toont het account dat het cluster bij het token ziet, niet het label dat het blok zelf schreef.

Bewust geen `rm -f` vooraf: `cat >` schrijft op dezelfde inode, zodat een draaiende container een
vernieuwd token meteen ziet; een nieuw bestand ziet een bind-mount pas na `--force-recreate`
(gemeten). bash en zsh bewaren een heredoc mogelijk kort in een tijdelijk bestand met mode 600.

Geen `#`-commentaar in shellblokken: zsh zonder `interactivecomments` (de shell van `claude` in
de image, en vaak op de host) voert `#` als argument uit. Ook geen `"$VAR:…"`: zsh leest `:s` als
modifier (`bad substitution`); de rolebinding gebruikt daarom `"${NS}:sandbox"`.

**Fundament: `functl` op de host, apart account.** `token_ophalen` roept
`functl cluster token "$CLUSTER" | jq -er '.status.token | select(type == "string" and length > 0)'`
aan, alleen als `CLUSTER` gezet is. `CA` is expliciet leeg, zodat een CA uit een eerdere run in
dezelfde shell niet meekomt. Omdat het token een blijvende API-sleutel kan aanmaken (zie
Context), adviseert de documentatie nooit een token van het eigen account, maar een apart account
dat geen organisatiebeheerder is en alleen de nodige projectrol heeft (viewer het veiligst), en na
de sessie `functl apikey list` en `functl project member list`. Als projectbeheerder mag de
Secret-driver van helm; dan kan Claude ook NetworkPolicies wijzigen, en houdt de afscherming uit
het rechtenblok hem niet tegen.

## Verificatie

- Testimage met de K8S-laag letterlijk uit de Dockerfile (Debian-basis, podman, amd64), na de
  laatste Dockerfile-wijziging (alleen het sync-comment) opnieuw gebouwd:
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
- Alle bash-blokken uit `docs/kubernetes.md` letterlijk geëxtraheerd en geplakt in `bash -i` en
  in `zsh -i` (zonder `interactivecomments`, gecontroleerd), als niet-root, tegen etcd plus
  kube-apiserver en kube-controller-manager v1.35.10 (RBAC, PodSecurity, ResourceQuota,
  LimitRanger; geen scheduler of kubelet): 199 controles groen, per shell een eigen namespace.
  De extractie faalt op `#` in een shellblok.
  - Rechtenblok: rc 0; Role, NetworkPolicy (Ingress en Egress, DNS op 53), ResourceQuota,
    LimitRange en RoleBinding aanwezig; quota-status door de controller-manager gezet.
  - `kubectl auth can-i` als de ServiceAccount: wel workloads, pods, services, ConfigMaps,
    ServiceAccounts, logs, port-forward, jobs, PDB's; niet Secrets (get/list/create),
    `serviceaccounts/token`, `impersonate` (users en serviceaccounts), `exec`, `attach`,
    ephemeral containers, ingresses, roles/rolebindings, NetworkPolicies, ResourceQuotas en
    LimitRanges (create/update/patch/delete), de namespace (update/patch), andere namespaces,
    nodes. `delete networkpolicy` als sandbox: `forbidden`.
  - Gedrag: pod zonder `resources` toegelaten met de standaardwaarden uit de LimitRange;
    `LoadBalancer`- en `NodePort`-Service geweigerd door de quota, `ClusterIP` toegelaten; een
    pod met een Secret-volume en een pod onder ServiceAccount `sandbox` toegelaten; sandbox maakt
    een eigen ServiceAccount. `helm install/upgrade/uninstall` als sandbox slaagt met
    `HELM_DRIVER=configmap`, de Secret-driver wordt geweigerd.
  - Kubeconfig-blok: vers (rc 0, `auth whoami` toont `system:serviceaccount:<ns>:sandbox`, CA
    als bestandspad ingebed, 644 in 700-map, token in geen argv), vernieuwen (zelfde inode,
    bestaande 755-map terug op 700), k3d-variabelen (`server:` het k3d-adres, whoami via
    `HOST_SERVER`). Rc ongelijk aan 0 bij: `create token` faalt (met en zonder bestaand bestand,
    bestand ongewijzigd), leeg token, ongeldig token (whoami faalt), bestaand beheerbestand
    (ongewijzigd, geen token aangevraagd), lege `F`, `NS` of `SERVER` (geen token aangevraagd),
    lege beheer-kubeconfig.
  - Fundament-variabelen met een nep-`functl` en de proef-CA als systeem-CA: ok (rc 0, whoami,
    geen CA, geen exec, token in geen argv); `fail`, lege string, `null` en een getal: rc
    ongelijk aan 0, bestand ongewijzigd, en `token_ophalen` zelf faalt. Lege `CLUSTER`:
    `token_ophalen` faalt zonder `functl` aan te roepen. Het na-de-sessie-blok roept
    `functl apikey list` en `functl project member list <id>` aan.
  - Pod Security-terugval: label `baseline` gezet. Opruimen: `kubectl delete namespace`
    verwijdert de namespace, daarna weigert de apiserver het token van `sandbox` en dat van een
    door de sandbox aangemaakte ServiceAccount.
- Mutatiecheck op de recepten: 14 mutaties, 14 gevangen (`exit 1` weg uit de beheercheck en uit
  de leeg-check, `length > 0` weg, de hele `select` weg, de lege-token-check weg, `chmod 700`
  weg, whoami ook na een fout (`;` in plaats van `&&`), CLUSTER-check weg, `--flatten` naar
  `--raw`, NetworkPolicy zonder Egress, NetworkPolicy weg, quota zonder `services.loadbalancers`,
  ingresses terug in de Role, `"$NS:sandbox"` in plaats van `"${NS}:sandbox"`). De laatste vond
  een echte fout: zsh leest `$NS:s` als modifier en de rolebinding faalde.
- Eerder gemeten met de vorige versie van de rol, nu niet herhaald: Pod Security weigert onder
  `restricted` een pod zonder securityContext en een hostPath-pod; onder `baseline` met
  `warn=restricted` toegelaten met waarschuwing, hostPath nog steeds geweigerd.
  `system:aggregate-to-edit` bevat `serviceaccounts/token`, Secrets aanmaken en `impersonate`.

Niet geverifieerd: een echt cluster met draaiende pods (k3d op de host via beide routes, met
`--api-port 127.0.0.1:6550`, Fundament, een cluster op afstand), of de NetworkPolicy wordt
afgedwongen (de testapiserver heeft geen netwerk-plug-in), de DNS-selector op een echt cluster,
`auth whoami` via de kube-api-proxy van Fundament, de Fundament-blokken tegen echte `functl`, de
gedragsclaims over Fundament anders dan door het lezen van de broncode, Docker Desktop en
Docker Engine, arm64, en de volledige image-build.
