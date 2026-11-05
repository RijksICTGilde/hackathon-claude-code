# Fieldlab: Go, functl, helm en kubectl in de sandbox

**Doel:** teams op het Fieldlab soevereine basis (23-25 november 2026) kunnen in de sandbox plug-ins
voor Fundament ontwikkelen (#204) en Helm-charts naar een cluster buiten de container uitrollen
(#205), met dezelfde pinning en wekelijkse tracking als de rest van de image.

## Snede

Vier PR's. Elke installatie-PR heeft een tracking-PR die erop stapelt, omdat de tracking-job en zijn
fixtures de pins uit de Dockerfile lezen.

| # | Branch | Inhoud | Issue |
|---|---|---|---|
| 1 | `feat/go-functl` | `INSTALL_GO`: Go-toolchain en `functl`, firewall-domeinen, documentatie | Refs #204 |
| 2 | `ci/go-functl-tracking` (op 1) | jobs `go-version` en `functl-version` in `check-upstream.yml` plus fixtures | Closes #204 |
| 3 | `feat/helm-kubectl` | `INSTALL_K8S`: `helm` en `kubectl`, kubeconfig-mount, documentatie over koppelen en rechten | Refs #205 |
| 4 | `ci/helm-kubectl-tracking` (op 3) | jobs `kubectl-version` en `helm-version` plus fixtures | Refs #205 |

#205 blijft open: deployen naar een cluster op de host en op afstand is hier niet live te testen.

## Ontwerpkeuzes

**Eén toggle voor Go en functl.** Het issue vraagt om één optie voor plug-inontwikkeling, en
`functl` bouwen kan alleen met Go. `INSTALL_GO=true` installeert dus beide.

**functl vanaf de bron op een gepinde commit.** Upstream publiceert alleen de rolling pre-release
`functl-latest`, waarvan de assets bij elke push naar master vervangen worden. Een SHA-pin op die
assets breekt de image-build bij elke upstream-push, tot de wekelijkse job een PR opent. Een
`go install …/functl/cmd/functl@<commit>` is reproduceerbaar: de commit ligt vast, en Go controleert
de module en alle dependencies tegen `sum.golang.org` en de `go.sum` van upstream. De
`-X …/functl/pkg/cli.version`-stempel volgt het formaat van de upstream-release.

**Go via de officiële tarball** van `go.dev/dl`, versie plus SHA-256 per architectuur, net als
Node.js. De versie volgt de `go`-regel in de `go.mod` van Fundament en het `golang:`-image in de
plug-in-scaffold (nu beide 1.27.3).

**Symlinks in `/usr/local/bin`** voor `go` en `gofmt`. De root-fase van de entrypoint en
non-interactieve SSH-sessies hebben een eigen PATH; via `/usr/local/bin` vinden ze Go zonder extra
PATH-regels, ook `init-firewall.sh`.

**`GOTOOLCHAIN=local`.** Zonder deze waarde haalt Go bij een hogere `go`-regel in een `go.mod`
stilletjes een andere toolchain op, buiten de pin en de tracking om.

**Firewall:** bij `command -v go` voegt `init-firewall.sh` `proxy.golang.org` en `sum.golang.org`
toe, zoals bij podman de registries. Gemeten met `go mod tidy -x` op een gescaffolde plug-in: alle
downloads lopen via `proxy.golang.org`, zonder redirect naar een andere host.

**Modulecache in `claude-home`.** `GOPATH` blijft op de default `~/go`, en dat valt onder het volume.

**SDK-versie van de scaffold.** `functl plugin create` pint de SDK standaard op een revisie die
upstream niet meer bestaat (`unknown revision 454dc6e5d341`). De documentatie geeft de werkende
aanroep met `--sdk-version`, afgeleid van de gepinde `functl`-commit.

## Verificatie per PR

- PR 1: lokale proef met Go 1.27.3 buiten de image (`go install` van `functl`, `functl plugin
  create`, `go mod tidy`, `go build`, `go test`); shellcheck op `init-firewall.sh`; image-build met
  de toggle aan en uit, lokaal of in CI.
- PR 2 en 4: `.github/scripts/test-check-upstream-jobs.sh`, actionlint, mutatiecheck op de nieuwe
  fixtures.
- PR 3: `helm lint` en `helm template` op een voorbeeldchart; image-build met de toggle aan en uit.
