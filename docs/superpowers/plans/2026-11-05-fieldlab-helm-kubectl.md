# Fieldlab: helm en kubectl in de sandbox

**Doel:** teams op het Fieldlab soevereine basis (23-25 november 2026) kunnen in de sandbox
Helm-charts schrijven en controleren, en ze uitrollen naar een Kubernetes-cluster buiten de
container (#205). De documentatie zegt eerlijk wat Claude met die toegang kan.

## Context

- Fundament draait clusters op Gardener. Welke Kubernetes-versies een installatie aanbiedt, is
  door de beheerder ingevoerde data en staat niet in de repo. De lokale fixtures van Fundament
  bieden 1.33 en 1.34; de gepinde Gardener (v1.138) ondersteunt voor clusters tot en met 1.35, en
  1.33 valt vóór het Fieldlab uit de Gardener-ondersteuning.
- De kubeconfig van Fundament bevat geen token: hij roept `functl cluster token` aan. Dat werkt
  in de sandbox alleen met `functl` in de image (#204) en een API-sleutel in `claude-home`. Je
  rol bepaalt de rechten; een organisatiebeheerder krijgt `cluster-admin`.
- De testomgeving van Fundament voor plug-ins is een k3d-cluster met een willekeurige API-poort.

## Snede

| # | Branch | Inhoud | Issue |
|---|---|---|---|
| 3 | `feat/helm-kubectl` | `INSTALL_K8S`: `kubectl` en `helm`, kubeconfig-override, documentatie over koppelen, netwerk en rechten | Refs #205 |
| 4 | `ci/helm-kubectl-tracking` (op 3) | wekelijkse jobs voor `kubectl` en `helm` plus fixtures | Refs #205 |

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
versie of op bestanden die nobody in `/tmp` of `/var/tmp` achterlaat. De setuid-strip komt pas
na deze laag.

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

Het host-bestand moet `644` zijn in een `700`-map: rootless podman maakt van het bestand in de
container een root-bestand, en `claude` kan `600` dan niet lezen (gemeten).

**`extra_hosts: host.docker.internal:host-gateway` in de override.** Docker Engine op Linux kent
de naam anders niet; met deze regel werkt één recept op Docker Desktop, Docker Engine en podman.

**Cluster op de host: API op poort 443, `OPEN_HTTPS=true`.** De firewall geeft op alle poorten
alleen het subnet van de eigen container vrij (`HOST_NETWORK`). Het host-adres valt daarbuiten:
bij rootless podman (pasta) is dat `169.254.1.2` (gemeten). Bij Docker Desktop is het een adres
in `192.168.65.0/24` en bij Docker Engine het `docker0`-adres, terwijl compose een eigen subnet
aanmaakt (volgens de documentatie van Docker, niet gemeten). Met de firewall aan is de host alleen
op poort 443 bereikbaar, en alleen bij `OPEN_HTTPS=true`. `host.docker.internal` in
`ALLOWED_DOMAINS` helpt niet: de firewall resolvet via DNS, en op podman faalt dan de start van
de firewall (gemeten). Het TLS-certificaat krijgt de naam via `--tls-san`.

**Firewall: niets automatisch erbij.** De documentatie noemt per situatie welke domeinen in
`ALLOWED_DOMAINS` horen (API-server, de endpoints van `functl`, chart-repositories en
OCI-registries), met de waarschuwing dat de firewall op IP filtert. Container-images haalt het
cluster op, niet de sandbox.

**Rechten.** De documentatie geeft een recept voor een ServiceAccount met `edit` in één
namespace, een token van acht uur, en Pod Security `baseline` op de namespace. Zonder die laatste
kan `edit` een pod met hostPath starten. Bij k3d zijn de nodes privileged containers, dus dat is
een weg naar de host.

## Verificatie

- Testimage met de K8S-laag letterlijk uit de Dockerfile (Debian-basis, podman, amd64):
  - `true`: `kubectl` v1.35.10 en `helm` v4.3.1 in `/usr/local/bin`; `/tmp`, `/var/tmp` en `/root`
    schoon.
  - `false`: geen `kubectl` of `helm`.
  - Een ongeldige waarde laat de build falen.
- Mutatiecheck: 5 mutaties, 5 gevangen (beide SHA's, beide versiecontroles, de opruiming).
- Als `claude` (uid 1000): `kubectl version --client`, `helm create demo && helm lint demo &&
  helm template demo` slagen; helm schrijft daarbij niets onder HOME.
- Override: `docker compose config` met `compose.yml` lost bind-mount, `read_only`, `KUBECONFIG` en
  `extra_hosts` op; zonder `SANDBOX_KUBECONFIG` weigert compose. De mount zelf is getest met
  `docker run --mount ...,readonly`, omdat compose-netwerken op deze host niet starten (geneste
  rootless podman). `kubectl config view` leest het bestand; schrijven faalt. Een wijziging via
  `kubectl config` op het host-bestand is meteen zichtbaar, een vervangen bestand niet.
- Firewall live (podman, pasta): een gepubliceerde host-poort is via `host.containers.internal`
  bereikbaar zonder firewall; met firewall alleen op 443 bij `OPEN_HTTPS=true`.
- De kubeconfig-recepten uit de documentatie (`set-cluster`, `set-credentials`, `set-context`)
  offline in de testimage; `kubectl create token` en verder alles tegen een echt cluster niet.

Niet geverifieerd: een echt cluster (k3d op de host, Fundament, een ander cluster op afstand),
Docker Desktop en Docker Engine, arm64, en de volledige image-build.
