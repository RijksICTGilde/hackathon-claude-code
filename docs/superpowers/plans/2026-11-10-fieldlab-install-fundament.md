# Eén schakelaar voor het Fieldlab: `INSTALL_FUNDAMENT`

**Doel:** één build-toggle die alles in de image zet wat de aan-de-slagpagina van het Fieldlab
(`fieldlab2026.projects.digilab.network/aan-de-slag`) vraagt, en `functl` in de sandbox laat
inloggen. Vervangt `INSTALL_GO` (op `main`) en `INSTALL_K8S` (in deze PR). Refs #204, #205.

## Context

- De pagina vraagt `functl` en `kubectl` (stap 1), inloggen met Pleio in de browser (stap 2), en
  voor een eigen plug-in git, mise, just en Docker (stap 7). De scaffold van `functl plugin create`
  pint in `mise.toml` Go, just 1.42.4, skaffold 2.17.0 en kubectl 1.36.6; bun alleen bij
  `--console vite`, en de standaard is `none`.
- Deelnemers krijgen één Fundament-account per persoon. Een apart account voor de sandbox kan
  dus niet; de opdrachtgever kiest ervoor `functl` in de sandbox te laten inloggen.
- De kubeconfig van Fundament roept `functl cluster token <id>` aan als exec-plugin. `functl`
  bewaart de API-sleutel in `~/.config/fundament/credentials` en praat met
  `organization-api.fundament-poc.nl` en `authn.fundament-poc.nl`; `kubectl` met de
  kube-api-proxy uit de regel `server:`.
- De `Justfile` van de scaffold bouwt het image met `docker buildx build --load`.

## Ontwerpkeuzes

**Eén ARG, drie lagen.** `ARG INSTALL_FUNDAMENT` staat boven de Go-laag; de Go-, de K8S- en een
nieuwe laag met just lezen hem alle drie. Aparte lagen houden de tracking-jobs per
afhankelijkheid los, en een bump van één pin bouwt alleen zijn eigen laag en wat erna komt.

**`INSTALL_GO` blijft werken.** compose geeft `${INSTALL_FUNDAMENT:-${INSTALL_GO:-false}}` door,
zodat een `.env` van vóór deze wijziging niet stil zonder Go bouwt. `INSTALL_K8S` stond nooit op
`main` en krijgt geen terugval.

**Geen mise.** mise haalt tijdens het werk zelf toolchains op, buiten de pins om, en dubbel met
de Go uit de image. In de sandbox wordt `mise exec -- just build` gewoon `just build`.

**Geen bun.** Alleen nodig bij `--console vite`; de standaard heeft het niet nodig.

**Geen skaffold.** De scaffold gebruikt skaffold alleen voor `functl plugin dev`, tegen het lokale
k3d-cluster van Fundament, dat niet in de sandbox draait. De release-binary van skaffold 2.17.0
(de versie uit de `mise.toml`) is gebouwd met Go 1.25.4 en geeft in Trivy 69 HIGH/CRITICAL;
suppressies daarvoor zouden de scan van de variant uithollen voor een tool zonder functie hier.

**Fundament: inloggen in de sandbox.** `functl auth login` in de sandbox, en
`functl cluster kubeconfig` naar `~/.kube/config` daar. Het recept dat op de host een token
ophaalt, en het advies voor een apart account, vervallen. De documentatie zegt eerlijk wat dat
betekent: Claude kan alles wat het account kan, de API-sleutel staat in `claude-home`, en na
afloop trek je hem in.

**De kubeconfig-controle blijft token-only.** Die geldt voor de gemounte kubeconfig van k3d of
een cluster op afstand. Fundament gebruikt de mount niet; een gemounte kubeconfig die `functl`
aanroept, wordt geweigerd met een verwijzing naar de Fundament-route in de sandbox.

**`podman-docker` onder `INSTALL_PODMAN`.** Geeft een `docker`-commando voor `docker build` uit
stap 7. Hoort bij podman, niet bij `INSTALL_FUNDAMENT`: podman vraagt een platform-override met
extra rechten, en dat blijft een eigen keuze. `just docker` werkt er niet mee: podman kent
`--provenance` van `docker buildx build` niet. De documentatie wijst naar `docker build`.

**Review op de kubeconfig-mount.** `bind.create_host_path: false` laat Docker de start weigeren
als het bestand ontbreekt, in plaats van er een lege map voor aan te maken. podman maakt die map
toch aan; de controle bij de start en het schrijfblok noemen een map daarom met naam.

**Documentatie.** Een nieuwe `claude-sandbox/docs/fundament.md` volgt de stappen van de pagina
voor wie in de sandbox werkt, en neemt de Fundament-delen over uit `opstarten-en-afsluiten.md`
(plug-ins, netwerk, licentie) en `kubernetes.md` (rollen, na de sessie). `kubernetes.md` houdt
k3d, een cluster op afstand, de rechten en de kubeconfig-mount.

## Stappen

1. Dockerfile: `INSTALL_FUNDAMENT` boven de Go-laag, de K8S-laag zonder eigen ARG, een
   just-laag met versiecontrole als nobody, `podman-docker` in de podman-laag.
2. compose, `.env.sample`, README-tabellen, `opstarten-en-afsluiten.md`, `kubernetes.md`,
   `fundament.md`, `compose.override.kubeconfig.yml`, de melding van `controleer-kubeconfig.sh`.
3. CI: `build-variants` bouwt met `INSTALL_FUNDAMENT=true` en toetst just en `docker` tegen de
   pin en podman; de Go-job in `check-upstream.yml` noemt `INSTALL_FUNDAMENT` in zijn PR-body.
4. Fixtures bijwerken (`test-controleer-kubeconfig.sh`, `test-check-upstream-jobs.sh`).

Tracking van just volgt in #213, naast die van kubectl en helm.

## Verificatie

- Image bouwen met `INSTALL_FUNDAMENT=true` en met `false`; versies van go, functl, kubectl,
  helm en just tegen de pins; geen nieuwe build-waarschuwingen.
- `INSTALL_GO=true` zonder `INSTALL_FUNDAMENT` geeft via compose `true`.
- Trivy (library) op de binaries met de suppressielijst.
- Fixtures, shellcheck en actionlint.
