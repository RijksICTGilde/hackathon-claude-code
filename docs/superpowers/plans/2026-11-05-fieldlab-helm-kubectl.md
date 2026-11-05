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
- `functl` zit niet in deze branch; het komt met `INSTALL_GO` (#210).
- De ontwikkelomgeving van Fundament vraagt Docker met minstens 16 GiB geheugen, 24 GiB met de
  plug-in-sandbox (een k3d-cluster met een willekeurige API-poort) erbij.

## Snede

| # | Branch | Inhoud | Issue |
|---|---|---|---|
| 3 | `feat/helm-kubectl` | `INSTALL_K8S`: `kubectl` en `helm`, kubeconfig-override, documentatie over koppelen, netwerk en rechten | Refs #205 |
| 4 | `ci/helm-kubectl-tracking` (op 3) | wekelijkse jobs voor `kubectl` en `helm` plus fixtures, CI-build van de K8S-variant | Refs #205 |

#205 blijft open: deployen naar een echt cluster (op de host en op afstand) is hier niet getest.

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

**Cluster op de host: twee routes, geen isolatieclaim.** Hoe verkeer van de sandbox naar de host
loopt, verschilt per runtime; de documentatie zegt alleen dat je er niet op moet rekenen dat de
firewall je machine afschermt.

- *Docker (voorkeur):* `k3d cluster create … --network claude-sandbox_default`, server-URL
  `https://k3d-<naam>-server-0:6443`, die naam via `--tls-san` in het certificaat. Het cluster
  staat op het containernetwerk van de sandbox; `OPEN_HTTPS=false` kan blijven. Sandbox en
  cluster bereiken elkaar dan op alle poorten; dat staat erbij. De netwerknaam is bevestigd met
  `docker compose config`; de route zelf is niet getest (geen Docker of k3d beschikbaar).
- *Rootless podman (alternatief):* API-server op poort 443 van de host, `host.containers.internal`
  in de TLS-SAN, `OPEN_HTTPS=true`. De documentatie zegt wat dat opent (al het uitgaande verkeer
  over 443) en dat poort 443 onder rootless podman een host-instelling vraagt. Gemeten: een
  host-poort is met deze instellingen bereikbaar; k3d zelf niet.

**Firewall: niets automatisch erbij.** De documentatie noemt per situatie welke domeinen in
`ALLOWED_DOMAINS` horen (API-server, bij `functl` in de container ook de endpoints daarvan,
chart-repositories en OCI-registries), met de waarschuwing dat de firewall op IP filtert. Een
geblokkeerde verbinding faalt direct (`REJECT`, `no route to host`). Container-images haalt het
cluster op, niet de sandbox.

**Rechten: een eigen Role, geen `edit`.** De ingebouwde `edit` geeft `create` op
`serviceaccounts/token`, schrijven van Secrets en `impersonate`; daarmee maakt Claude zelf een
langer geldend token. De Role `sandbox` geeft CRUD op pods, services, ConfigMaps, PVC's,
ServiceAccounts, workloads (apps, batch), ingresses, HPA's en PDB's, plus lezen van logs, events
en endpoints, en port-forward. Geen Secrets, geen `serviceaccounts/token`, geen `impersonate`,
geen RBAC, geen `exec`/`attach`/ephemeral containers, geen wijziging van de namespace (dus ook niet
van de Pod Security-labels). Een Secret aanmaken zou volstaan voor een token zonder einddatum
(`kubernetes.io/service-account-token`), dus ook schrijven van Secrets valt weg. Omdat helm
releases standaard in Secrets bewaart, zet de override `HELM_DRIVER=configmap`; charts die zelf
Secrets aanmaken krijgen die van de beheerder (`existingSecret`).

**Opruimen is verplicht, het token is geen grens.** Ook met deze rol kan Claude een pod onder de
ServiceAccount `sandbox` starten en zo een nieuw token krijgen. Alleen het verwijderen van de
ServiceAccount (of de namespace) trekt alle tokens in.

**Pod Security `restricted`**, met `baseline` + `warn=restricted` als terugval, en voor k3d
`seccomp-default=true` op de kubelet. Beschreven als risicoverkleining: bij k3d zijn de nodes
privileged containers op de host. De voorbeeldchart van `helm create` haalt `restricted` niet;
`helm install` slaagt dan, maar de pods komen er niet.

**Kubeconfig-recept: één blok voor aanmaken en vernieuwen.** Het blok leest server en CA uit de
beheer-kubeconfig (`--flatten`, zodat een CA-bestandspad ook werkt), controleert dat `F`, `NS`,
server en CA niet leeg zijn, weigert als `F` al andere users dan `sandbox` bevat, vraagt dan pas
het token aan en schrijft het hele bestand met een heredoc: het token komt in geen argv. Daarna
toont een controleregel de users. Bewust geen `rm -f` vooraf: `cat >` schrijft op dezelfde inode,
zodat een draaiende container een vernieuwd token meteen ziet; een nieuw bestand ziet een
bind-mount pas na `--force-recreate` (gemeten). Het "lege bestand" volgt uit het volledig
overschrijven plus de weigering bij vreemde users. `umask 077` en `mkdir -p -m 700` in een
subshell; daarna `chmod 644` om de reden hierboven. bash en zsh bewaren een heredoc mogelijk kort
in een tijdelijk bestand met mode 600.

**Fundament: `functl` op de host.** Een apart blok zet alleen een kortlevend token (uit
`functl cluster token … | jq -er .status.token`) in de sandbox-kubeconfig, zonder CA. De
API-sleutel blijft op de host. `functl` in de container (via `INSTALL_GO`) kan ook, maar dan staat
de API-sleutel in `claude-home`.

## Verificatie

- Testimage met de K8S-laag letterlijk uit de Dockerfile (Debian-basis, podman, amd64):
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
- Kubeconfig-blokken letterlijk uit de docs, offline met shims voor `kubectl create token` en
  `functl`, in bash en zsh: 78 controles groen. Gevallen: vers bestand, vernieuwen (zelfde inode),
  `create token` faalt (met en zonder bestaand bestand), bestaand beheerbestand en gemengd
  bestand op `F` (geweigerd, ongewijzigd, geen token aangevraagd), lege `F`, CA als bestandspad,
  server zonder CA, lege beheer-kubeconfig, Fundament ok/fout/`null`. Het token staat in geen
  argv van een aangeroepen programma. Mutaties op het blok (`--raw`, geen beheercheck, token als
  argument, geen CA-check, `rm -f` vooraf): 5 van 5 gevangen.
- Tegen een lokale kube-apiserver v1.35.10 met etcd (RBAC, PodSecurity, TokenRequest; geen
  controller-manager, scheduler of kubelet), met het rechten- en het kubeconfig-blok letterlijk:
  43 controles groen. `kubectl auth can-i` als de ServiceAccount: wel workloads, pods, services,
  ConfigMaps, ServiceAccounts, logs, port-forward, ingresses, jobs, PDB's; niet Secrets
  (get/list/create), `serviceaccounts/token`, `impersonate`, `exec`, `attach`, ephemeral
  containers, RBAC, quota, networkpolicies, de namespace, andere namespaces, nodes.
  `system:aggregate-to-edit` bevat wel `serviceaccounts/token`, Secrets aanmaken en
  `impersonate`. Pod Security: pod zonder securityContext en hostPath-pod geweigerd onder
  `restricted`, nette pod toegelaten; onder `baseline` + `warn=restricted` toegelaten met
  waarschuwing, hostPath nog steeds geweigerd. De sandbox mag een pod onder ServiceAccount
  `sandbox` aanmaken, met een projected token. `helm install/upgrade/uninstall` als sandbox slaagt
  met `HELM_DRIVER=configmap` en faalt met de Secret-driver. Na `delete serviceaccount` weigert
  de apiserver het token (`Unauthorized`).

Niet geverifieerd: een echt cluster met draaiende pods (k3d op de host via beide routes,
Fundament, een cluster op afstand), de Fundament-blokken tegen echte `functl`, Docker Desktop en
Docker Engine, arm64, en de volledige image-build.
