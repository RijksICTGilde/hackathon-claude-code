# ADR 0001 — Isolatie voor Maven/Testcontainers-builds in de sandbox

**Status:** Voorgesteld — werkend op Linux, in review (PR). Breekt door zodra
breed bevestigd (collega-tests); dan kan de host-agent vervallen. — 2026-06-10
**Context-issue:** [#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)
**Zie ook:** `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`
(ontwerp, bevindingen, volledige werkende config, security-balans).

## Context

De sandbox-container bevat geen Docker-daemon, dus Maven-builds met Testcontainers
werken niet rechtstreeks. De bestaande oplossing is een **host-side Maven
MCP-agent** (`claude-sandbox/host-agents/maven/`) die `mvn` op de host draait
namens Claude — per ontwerp een container→host code-execution-bridge.

Risico (uit #44): Claude controleert `pom.xml`/`mvnw` in de gedeelde
`projects`-map, en `mvn` voert die plugins ongezien uit als de host-user die
`run.sh` startte. Draait die user in de `docker`-group of met sudo, dan is
host-escalatie mogelijk. Op Linux bindt de agent bovendien auth-loos op
`0.0.0.0:7777`.

**Niet doen:** een runner-container mét gemounte Docker-socket (= host-root,
reproduceert exact de rondgaande Copilot-bug).

## Beslissing

Twee sporen, gekozen naar dreigingsbeeld:

### 1. Podman-in-Docker — voorkeur waar mogelijk (nieuw)
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
default + aparte `compose.override.podman.yml`).
Geverifieerd: echte Quarkus/Redis-build 289+46 tests groen.

### 2. Host-agent — blijft als fallback
Voor hosts waar podman-in-docker (nog) niet kan: geen userns/`/dev/fuse`/
AppArmor-mogelijkheid, dichtgetimmerde kernels, of Docker/Rancher Desktop op
Mac/Windows (nog te verifiëren). Met de goedkope hardening hieronder.

> **Niet** als "veiliger alternatief voor wie de outer-sandbox-relaxaties
> mijdt": die relaxaties verbreden het kernel-oppervlak van de *container*
> (escape vereist nog een kernel-exploit). De host-agent voert daarentegen code
> **direct op de host** uit als de host-user — dat is voor een op container-escape
> beduchte gebruiker juist een zwakker, niet sterker model. De host-agent is een
> *dekkings*-fallback (waar podman niet kan), geen security-upgrade.

### Optie C (sysbox) / D (microVM)
Out-of-scope voor nu. Alleen overwegen bij écht onvertrouwde of multi-tenant code
met kernel-escape in scope. Genoteerd in de spec.

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

## Goedkope hardening host-agent (indien gebruikt)

- Draai `run.sh` als **dedicated least-privilege host-user** — niet in de
  `docker`-group, geen sudo.
- Houd host-maven-projecten **buiten** de gedeelde `projects`-map (Claude kan dan
  geen `pom.xml`/`mvnw` schrijven die de host draait).
- Linux: bind op `127.0.0.1` of firewall poort 7777; draai niet op een onvertrouwd
  netwerk.

## Consequenties

- Projecten die Testcontainers nodig hebben: gebruik de podman-set
  (`host-agents/maven/podman/README.md`).
- **Intentie: de host-agent vervangen.** De host-agent blijft tijdelijk
  beschikbaar (gedocumenteerd als fallback in `docs/maven-mcp-agent.md`) totdat
  de podman-opzet breed bevestigd is (collega-tests, en Mac/Windows
  geverifieerd). Lukt dat en is de oplossing objectief beter → host-agent
  verwijderen. Lukt het niet → dan is dit geen oplossing en gaat de PR niet door.
- Beslissing C/D: uitgesteld, niet nu.
