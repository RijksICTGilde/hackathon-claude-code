# ADR 0001 — Isolatie voor Maven/Testcontainers-builds in de sandbox

**Status:** Geaccepteerd — host-agent verwijderd. — 2026-08-03
(voorgesteld 2026-06-10)
**Context-issue:** [#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)
**Zie ook:** `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`
(ontwerp, bevindingen, volledige werkende config, security-balans).

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

**Niet doen:** een runner-container mét gemounte Docker-socket (= host-root,
reproduceert exact de rondgaande Copilot-bug).

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

### Optie C (sysbox) / D (microVM)
Out-of-scope als default. Voor wie de kernel-escape-laag tóch wil sluiten (écht
onvertrouwde / multi-tenant code): op **Linux-native** het makkelijkst door de
sandbox in een **VM** te draaien (podman in Lima/Multipass) — zie
`docs/maximale-isolatie-linux.md` (met Kata/gVisor als alternatieven). Op
**Mac/Windows is die kernel-grens er al** (Docker Desktop/Rancher/`podman machine`
draaien in een VM), dus daar is niets te doen.

## Security-balans (podman-in-docker)

- **Dicht:** container→host code-execution van #44.
- **Open:** relaxaties op de *outer* sandbox-container — seccomp (tailored
  blocklist i.p.v. unconfined: re-blokkeert module-load/kexec/reboot/bpf/perf/
  `open_by_handle_at`/`userfaultfd`/`io_uring_*`/NUMA/`kcmp`/`pidfd_getfd`/…;
  `ptrace` bewust toegestaan), AppArmor (`userns`-profiel, effectief ~unconfined
  voor deze container), `systempaths=unconfined` (masked/RO `/proc` weg, nodig
  voor de geneste proc-mount), en op SELinux-hosts `label=disable`. **Géén**
  `CAP_SYS_ADMIN`, `--privileged` of socket; de host-userns-hardening blijft
  systeembreed aan; opt-in + aparte override houden de blast-radius klein.
- **Weging:** geschikt voor het reële #44-dreigingsbeeld (Claude rogue /
  prompt-injectie, semi-vertrouwd). Niet geschikt voor volledig vijandige,
  kernel-exploit-capabele code → daar horen Optie C/D.

## Consequenties

- Projecten die Testcontainers nodig hebben: gebruik de podman-set
  (`claude-sandbox/podman/README.md`).
- **Host-agent verwijderd.** Hosts waar podman-in-de-sandbox niet bevestigd is,
  hebben geen Testcontainers-route meer. Dat is een bewuste afweging: het
  risico van een container→host code-execution-bridge weegt zwaarder dan de
  dekking, en er zijn geen gebruikers op die platforms. Welke platforms
  bevestigd zijn, staat in `claude-sandbox/podman/README.md`.
- Beslissing C/D: uitgesteld, niet nu.
