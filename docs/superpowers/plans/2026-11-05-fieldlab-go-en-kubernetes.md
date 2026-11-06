# Fieldlab: Go, functl, helm en kubectl in de sandbox

**Doel:** teams op het Fieldlab soevereine basis (23-25 november 2026) kunnen in de sandbox plug-ins
voor Fundament ontwikkelen (#204) en Helm-charts naar een cluster buiten de container uitrollen
(#205), met dezelfde pinning en wekelijkse tracking als de rest van de image.

## Snede

Vier PR's. Elke installatie-PR heeft een tracking-PR die erop stapelt, omdat de tracking-job en zijn
fixtures de pins uit de Dockerfile lezen.

| # | Branch | Inhoud | Issue |
|---|---|---|---|
| 1 | `feat/go-functl` | `INSTALL_GO`: Go-toolchain en `functl`, documentatie inclusief de benodigde Go-domeinen | Refs #204 |
| 2 | `ci/go-functl-tracking` (op 1) | jobs `go-version` en `functl-version` in `check-upstream.yml` plus fixtures; CI-build met `INSTALL_GO=true` | Closes #204 |
| 3 | `feat/helm-kubectl` | `INSTALL_K8S`: `helm` en `kubectl`, kubeconfig-mount, documentatie over koppelen en rechten | Refs #205 |
| 4 | `ci/helm-kubectl-tracking` (op 3) | jobs `kubectl-version` en `helm-version` plus fixtures | Refs #205 |

#205 blijft open: deployen naar een cluster op de host en op afstand is hier niet live te testen.

## Ontwerpkeuzes

**Eén toggle voor Go en functl.** Het issue vraagt om één optie voor plug-inontwikkeling, en
`functl` bouwen kan alleen met Go. `INSTALL_GO=true` installeert dus beide.

**functl vanaf de bron op een gepinde pseudo-versie.** Upstream publiceert alleen de rolling
pre-release `functl-latest`, waarvan de assets bij elke push naar master vervangen worden. Een
SHA-pin op die assets breekt de image-build bij elke upstream-push, tot de wekelijkse job een PR
opent. De pseudo-versie legt de commit vast. De Dockerfile pint daarnaast de h1-hash van de
module en controleert die na `go mod download`. `functl` wordt daarna als hoofdmodule gebouwd met
`-mod=readonly`, zodat Go elke dependency toetst aan de `go.sum` van Fundament, die onder de h1
valt. `go install pkg@versie` leest die `go.sum` niet. De versie-stempel
(`-X …/functl/pkg/cli.version`) is de pseudo-versie, zodat `functl version` direct als
`--sdk-version` bruikbaar is. De versiecontrole draait als `nobody`, zonder capabilities en met
`no_new_privs`, omdat de setuid-strip pas na deze laag komt.

**Go via de officiële tarball** van `go.dev/dl`, versie plus SHA-256 per architectuur, net als
Node.js. De versie volgt de `go`-regel in de `go.mod` van Fundament en het `golang:`-image in de
plug-in-scaffold (nu beide 1.27.3).

**Symlinks in `/usr/local/bin`** voor `go` en `gofmt`. Een non-interactieve SSH-sessie erft de
Docker-`ENV` niet; via `/usr/local/bin` vindt hij Go zonder extra PATH-regels.

**`GOTOOLCHAIN=local` in `$GOROOT/go.env`**, niet als `ENV`: een SSH-sessie erft de Docker-`ENV`
niet. Zonder deze waarde haalt Go bij een hogere `go`-regel in een `go.mod` stil een andere
toolchain op, buiten de pin en de tracking om.

**Firewall: geen automatische Go-domeinen.** Go heeft bij `OPEN_HTTPS=false` drie domeinen nodig:
`proxy.golang.org`, `sum.golang.org` en `storage.googleapis.com`. Het laatste is nodig omdat de
proxy grote module-zips, waaronder Fundament, doorstuurt naar Cloud Storage. Dat is live gemeten
met de firewall in een testcontainer. Daarmee wordt Cloud Storage bereikbaar. Omdat de firewall op
IP filtert, gaan via de gedeelde Google-frontends ook andere Google-diensten open. Bovendien haalt
de proxy modules op van elke host. Wie `OPEN_HTTPS=false` kiest, kiest bewust voor een smalle
whitelist. De documentatie noemt de drie domeinen daarom met die waarschuwing erbij, en de
gebruiker zet ze zelf in `ALLOWED_DOMAINS`.

**ARG direct boven de laag.** Elke `RUN` na een `ARG`-declaratie krijgt die mee. Een `ARG`
bovenaan laat een flip dus de hele image opnieuw bouwen.

**CI-build van de Go-variant.** De PR-build gebruikt de defaults en raakt de Go-laag dus nooit. PR 2
voegt een build met `INSTALL_GO=true` toe, met een Trivy-scan op de Go-binaries.

**Modulecache in `claude-home`.** `GOPATH` blijft op de default `~/go`, en dat valt onder het volume.

**SDK-versie van de scaffold.** `functl plugin create` pint de SDK standaard op een revisie die
upstream niet meer bestaat (`unknown revision 454dc6e5d341`). De documentatie geeft de werkende
aanroep: `--sdk-version "$(functl version)"`.

## Verificatie per PR

- PR 1: lokale proef met Go 1.27.3 buiten de image (`go install` van `functl`, `functl plugin
  create`, `go mod tidy`, `go build`, `go test`); de Go-laag in een testimage met de toggle aan,
  uit en ongeldig; de firewall live met de Go-domeinen in `ALLOWED_DOMAINS`.
- PR 2 en 4: `.github/scripts/test-check-upstream-jobs.sh`, actionlint, mutatiecheck op de nieuwe
  fixtures.
- PR 3: `helm lint` en `helm template` op een voorbeeldchart; image-build met de toggle aan en uit.
