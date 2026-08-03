# ADR 0001 — Isolatie voor Maven/Testcontainers-builds in de sandbox

**Status:** Geaccepteerd — host-agent verwijderd. — 2026-08-03
(voorgesteld 2026-06-10)
**Bekrachtigd:** via de PR die de host-agent verwijdert, in het kader van issue
[#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44).
**Context-issue:** [#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)
**Zie ook:** `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`
— historisch ontwerpdocument (2026-06-10) met de meetresultaten en werkende
config; de security-balans hieronder is leidend.

## Context

De sandbox-container bevat geen Docker-daemon, dus Maven-builds met
Testcontainers werken niet rechtstreeks. De oplossing wás een **host-side Maven
MCP-agent** die `mvn` op de host draaide namens Claude — per ontwerp een
container→host code-execution-bridge. Die agent is met deze beslissing
verwijderd.

Waarom dat moest (uit #44): Claude beheerst `pom.xml` en `mvnw` in de gedeelde
`projects`-map, en `mvn` voerde die plugins ongezien uit als de host-user die
`run.sh` startte. Draaide die user in de `docker`-group of met sudo, dan was
host-escalatie mogelijk. Op Linux bond de agent bovendien auth-loos op
`0.0.0.0:7777`.

## Beslissing

### Podman-in-de-sandbox
Rootless Podman **ín** de sandbox draait Testcontainers genest. Geen host-bridge,
geen Docker-socket, geen `--privileged`. `mvn`/pom-plugins draaien in de sandbox
(non-root `claude`); Testcontainers-children zijn geneste rootless-userns-children.
Daarmee verdwijnt de container→host code-execution van #44.

Werkt — ook op gehardende Ubuntu/Tuxedo (`apparmor_restrict_unprivileged_userns=1`)
— via een per-setup configset (zie spec/README): single-uid (geen `newuidmap`),
custom AppArmor-`userns`-profiel, `/dev/net/tun`, `vfs`-storage met
`ignore_chown_errors` (default; fuse-overlayfs + `/dev/fuse` optioneel via `.env`),
tailored seccomp-blocklist, `systempaths=unconfined`, `firewall_driver=iptables`,
`TESTCONTAINERS_HOST_OVERRIDE=localhost`. **Opt-in** (`INSTALL_PODMAN=false`
default + aparte `compose.override.podman-linux.yml`).
Geverifieerd: echte Quarkus/Redis-build 289+46 tests groen.

### Sysbox / microVM (out-of-scope als default)
Voor wie de kernel-escape-laag tóch wil sluiten (écht onvertrouwde /
multi-tenant code): op **Linux-native** het makkelijkst door de sandbox in een
**VM** te draaien (podman in Lima/Multipass) — zie
`docs/maximale-isolatie-linux.md` (met Kata/gVisor als alternatieven). Op
**Mac/Windows is die kernel-grens er al** (Docker Desktop/Rancher/`podman machine`
draaien in een VM), dus daar is niets te doen.

## Overwogen en verworpen

- **Host-side Maven-agent** (de vorige oplossing). Verworpen als
  container→host code-execution-bridge (zie Context). Ook géén aantrekkelijk
  *alternatief* voor wie de outer-sandbox-relaxaties wil mijden: die relaxaties
  verbreden het kernel-oppervlak van de *container* (een escape vereist nog een
  kernel-exploit), terwijl de host-agent code **direct op de host** uitvoert als
  de host-user. Voor wie beducht is op container-escape is dat juist een
  zwakker, niet sterker model. Daarom niet bewaard als terugvaloptie.
- **Runner-container met gemounte Docker-socket.** Verworpen: dat is host-root
  en reproduceert exact de rondgaande Copilot-bug.

## Security-balans

**Dicht.**

- De container→host code-execution-bridge van #44. Er is geen host-agent meer
  en geen Docker-socket; alle projectcode draait in de sandbox.
- De route van uid 1000 naar container-root. De firewall draait in de root-fase
  van de entrypoint en dropt daarna met `setpriv` naar `claude`; de
  NOPASSWD-sudoers-regel met de SETENV-tag is weg, evenals `sudo` zelf. Die tag
  liet `BASH_ENV` de `env_reset` van sudo overleven.
- De egress-allowlist als self-service. `OPEN_HTTPS` en `ALLOWED_DOMAINS` worden
  alleen nog gelezen vóór de drop, dus `claude` kan de firewall niet meer
  heropenen.
- Schrijven naar `/proc/sys` vanuit de container, ook met
  `systempaths=unconfined`. Het AppArmor-profiel is afgeleid van docker-default
  en behoudt de `/proc/sys`-denies, waarmee de `core_pattern`-route naar
  host-root dicht is.

**Open.**

- Relaxaties op de *outer* container: seccomp is een blocklist en geen allowlist
  (een allowlist zet `clone`/`unshare`/`mount`/`setns` achter `CAP_SYS_ADMIN` en
  breekt rootless podman; de blocklist re-blokkeert wél module-load/kexec/reboot/
  bpf/perf/`open_by_handle_at`/`userfaultfd`/`io_uring_*`/kernel-keyring/quotactl
  — `ptrace` bewust toegestaan), `systempaths=unconfined` staat nog aan, en op
  SELinux-hosts `label=disable`.
- In de multi-uid opt-in staat `CAP_SYS_ADMIN` in de bounding set. `claude` heeft
  `CapEff=0` en krijgt hem niet rechtstreeks; alleen setuid-root
  `newuidmap`/`newgidmap` trekken hem eruit. Maar er is geen userns-remap, dus
  áls er ooit tóch een escalatie naar container-root is, is dat host-root-uid.
- Kernel-escapes blijven buiten bereik van deze maatregelen. Wie volledig
  vijandige, kernel-exploit-capabele code moet draaien, hoort bij de
  sysbox/microVM-route.

**Welke laag welke escape sluit.** De root-entrypoint sluit het *bereiken* van
container-root. Het AppArmor-profiel sluit wat container-root zou *kunnen* áls
dat tóch lukt. Die twee lagen zijn onafhankelijk: elk sluit de escape op
zichzelf. Zet het AppArmor-profiel dus niet terug op `flags=(unconfined)` omdat
"de sudo-route toch al dicht is".

**Verificatie.** `claude-sandbox/docs/hardening-verificatie.md` bevat het
testprotocol, inclusief de negatieve tests die aantonen dat de escape dicht is.
Drie vragen staan nog open (`systempaths` versmallen, userns-remap, de bounding
set); die staan in de meettabel van
`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`.

**Weging.** Geschikt voor het reële #44-dreigingsbeeld (Claude rogue /
prompt-injectie, semi-vertrouwd). Niet geschikt voor volledig vijandige,
kernel-exploit-capabele code → daar hoort de sysbox/microVM-route.

## Consequenties

- Projecten die Testcontainers nodig hebben: gebruik de podman-set
  (`claude-sandbox/podman/README.md`).
- **Host-agent verwijderd.** Hosts waar podman-in-de-sandbox niet bevestigd is —
  Docker Desktop op Mac/Windows, WSL2, rootless `podman machine` — hebben geen
  Testcontainers-route meer. Dat is een bewuste afweging: het risico van een
  container→host code-execution-bridge weegt zwaarder dan de dekking, en
  **binnen dit team** zijn er geen gebruikers op die platforms. Een hergebruiker
  met wél zulke werkplekken (Windows/WSL2 is bij veel overheidsorganisaties de
  standaard) moet deze afweging opnieuw maken en de opzet daar eerst bevestigen
  met `podman/setup-host.sh` + `podman/smoke-test.sh`. Welke platforms bevestigd
  zijn, staat in `claude-sandbox/podman/README.md`.
- Sysbox/microVM: uitgesteld, niet nu.
