# Maven via rootless Podman-in-Docker (PoC)

**Datum:** 2026-06-10
**Status:** Ontwerp — PoC, klaar voor implementatie
**Context:** [issue #44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)

## Probleem

De Maven host-agent (`claude-sandbox/host-agents/maven/maven_agent.py`) bestaat
omdat de sandbox-container zelf geen Testcontainers kan draaien: rootless Docker
in de container kan niet betrouwbaar sibling-containers starten. De agent draait
daarom `mvn` **op de host**, namens Claude in de container, via een MCP-bridge
(SSE op poort 7777).

Issue #44 legt het risico bloot: die bridge is per ontwerp container→host
code-execution. Claude controleert `pom.xml`/`mvnw` in de gedeelde `projects`-map,
en `mvn` voert plugins daaruit ongezien uit als de host-user die `run.sh` startte.
Draait die user in de `docker`-group of met sudo, dan is host-escalatie mogelijk.
De voorgestelde sterkere isolatie (Optie C sysbox, Optie D microVM) is Linux-only
en zwaar.

## Kerninzicht

De aanname onder de host-agent — "de container kan geen siblings starten" — geldt
voor rootless **Docker**, niet voor rootless **Podman**. Podman is daemonless,
fork-exec, en expliciet ontworpen om rootless en genest te draaien; Testcontainers
heeft eersteklas Podman-support.

Twee gevolgen:

1. **Engine wisselen ontgrendelt nested execution.** Rootless Podman ín de
   sandbox-container kan wél siblings (eigenlijk: nested children) starten voor
   Testcontainers. Dan is er **geen host-bridge meer nodig**: `mvn` draait waar
   Claude al zit (de sandbox, als non-root `claude`), en Testcontainers-containers
   zijn geneste rootless-podman-children.

2. **De Podman-socket is géén host-root.** Rootless Podman mapt container-processen
   via user-namespaces naar een unprivileged host-subuid. De socket en alle
   children blijven binnen die userns. Dit is precies waarom de #44-waarschuwing
   ("runner mét gemounte Docker-socket = host-root, reproduceert de Copilot-bug")
   hier **niet** geldt — er is geen Docker-socket en geen privileged daemon.

Daarmee verdwijnt de hele dreigingsklasse van #44: er is geen host-stap meer die
mvn/pom-plugins als host-user uitvoert. Wat Claude in de sandbox kan, blijft in de
sandbox-userns.

## Architectuur

```
Host (Docker Desktop / Rancher / Linux Docker)
└── sandbox-container  (claude, non-root)
    ├── Claude Code
    ├── mvn / mvnw            ← draait hier, niet op de host
    └── rootless podman
        └── Testcontainers children (Ryuk, Postgres, …)
            └── geneste rootless userns → unprivileged host-subuid
```

- Geen poort 7777, geen auth-loze bind, geen `host.docker.internal`, geen
  `run.sh` op de host. De MCP-bridge vervalt voor dit pad.
- Geen Docker-socket-mount, geen `--privileged`.
- Host-OS maakt niet uit: werkt overal waar de sandbox al draait
  (Docker Desktop/Rancher op Mac/Win, Docker/Podman op Linux).

### Vergelijking met de issue-opties

| Optie | Isolatie | Host-eis | Cross-platform | Gewicht |
|---|---|---|---|---|
| Host-agent (huidig) | geen (host-user) | native mvn + JDK | ja | licht, maar onveilig |
| **Podman-in-Docker (dit)** | rootless userns in container | `/dev/fuse` + seccomp-tweak | **ja** | licht |
| C — sysbox | sterke (eigen dockerd) | sysbox-runtime, recente kernel | Linux-only | middel |
| D — microVM | sterkste (eigen kernel) | KVM/nested virt | Linux-only | zwaar |

Podman-in-Docker zit qua isolatie boven de host-agent en onder sysbox, maar is als
enige sterkere optie cross-platform en vereist geen speciale host-runtime.

## PoC-scope

Doel: bewijzen dat rootless Podman ín de sandbox-container een Maven build met
Testcontainers kan draaien, zonder `--privileged` en zonder socket-mount.

**Wel:**
- Sandbox-image optioneel uitrusten met rootless Podman (build-ARG, default uit).
- Runtime-vereisten regelen via een compose-override (`/dev/fuse`, seccomp).
- Smoke-test: `podman info` → kale nested container → minimale Maven+Testcontainers
  build groen.

**Niet (pas ná geslaagde PoC):**
- Host-agent verwijderen of MCP-tool herschrijven.
- Documentatie in `maven-mcp-agent.md`/`SECURITY.md` als definitieve aanbeveling
  (DoD van #44) — dat volgt op de PoC-uitslag.
- Optie C/D besluit.

## Artefacten

| Bestand | Inhoud |
|---|---|
| `claude-sandbox/Dockerfile` | `ARG INSTALL_PODMAN=false`; bij `true`: `podman fuse-overlayfs uidmap passt slirp4netns` installeren, `/etc/subuid`+`/etc/subgid` voor `claude`, rootless `storage.conf` (fuse-overlayfs) + `containers.conf` |
| `claude-sandbox/compose.override.podman.yml.example` | `devices: [/dev/fuse]`, `security_opt: [seccomp=...]` (zie onzekerheden), env-hints |
| `claude-sandbox/host-agents/maven/poc-podman/smoke-test.sh` | in de container: `podman info`; `podman run --rm` smoke; daarna `mvn test` op het sample-project |
| `claude-sandbox/host-agents/maven/poc-podman/sample/` | minimaal Maven-project: `pom.xml` + één Testcontainers-test (lichte image, bv. `alpine` via `GenericContainer`) |
| `claude-sandbox/host-agents/maven/poc-podman/README.md` | exacte run-stappen + benodigde `ALLOWED_DOMAINS` + `.env`-flag |

## Bekende onzekerheden (wat de PoC moet uitwijzen)

1. **seccomp.** Het default-Docker-seccomp-profiel blokkeert mogelijk syscalls die
   nested rootless podman nodig heeft. Eerst proberen met een gericht profiel;
   `seccomp=unconfined` als de PoC anders niet draait — afweging documenteren
   (unconfined verzwakt de outer sandbox).
2. **`/dev/fuse`.** fuse-overlayfs vereist `--device /dev/fuse`. Werkt de
   Docker/Rancher-VM mee? Zo niet: terugval op `vfs`-storage (werkt overal, traag
   en schijf-vretend) — meten of dat acceptabel is.
3. **subuid/subgid + `newuidmap`/`newgidmap`.** `claude` heeft een subuid-range
   nodig (`/etc/subuid`) én de setuid-helpers met file-caps. Werkt dat in de outer
   container? Zo niet: single-uid mapping (`--userns=keep-id`/host) als fallback —
   sommige images verwachten meerdere uids en kunnen dan breken.
4. **Firewall/egress.** `init-firewall.sh` whitelist bevat **geen** registries.
   Testcontainers pullt van `docker.io` (+ Ryuk). Vereist uitbreiding van
   `ALLOWED_DOMAINS` (bv. `registry-1.docker.io`, `auth.docker.io`,
   `production.cloudflare.docker.com`). Nested egress loopt via de
   sandbox-iptables, dus dezelfde whitelist geldt.
5. **Ryuk.** Op sommige nested setups werkt de Ryuk-resource-reaper niet; mogelijk
   `TESTCONTAINERS_RYUK_DISABLED=true` nodig voor de PoC.
6. **Performance.** Nested rootless + fuse-overlayfs (of vfs) is trager dan native.
   Globaal meten of een typische build acceptabel blijft.

## Succescriteria

- `podman info` werkt rootless in de container, zonder `--privileged`.
- Een nested container start en draait (`podman run --rm … echo ok`).
- Het sample Maven+Testcontainers-project gaat groen via `mvn test` in de
  container.
- Vastgelegd: welke seccomp-stand, storage-driver en `ALLOWED_DOMAINS` nodig waren.

## Verificatie

De huidige werkomgeving heeft géén container-runtime, geen `/dev/fuse` en geen
sudo — de PoC is hier **niet** live te draaien. De artefacten zijn zo gebouwd dat
de gebruiker ze op de eigen host (waar Docker/Rancher de sandbox-image bouwt)
uitvoert via `poc-podman/README.md`. De uitkomst (logs/uitslag) bepaalt de
vervolgstap.

## Beslis-criteria na de PoC

- **Slaagt zonder `--privileged`/socket** → uitwerken als aanbevolen pad; host-agent
  degraderen tot fallback; #44-DoD (doc + ADR) afronden met deze keuze.
- **Slaagt alleen met seccomp=unconfined** → afwegen of de verzwakking van de outer
  sandbox acceptabel is t.o.v. het sluiten van de host-bridge; documenteren.
- **Slaagt niet** → terug naar de goedkope hardening uit #44 voor de host-agent, en
  C/D als losse afweging.

## Out of scope (YAGNI)

- Host-agent verwijderen vóór de PoC slaagt.
- Mac/Windows-specifieke `podman machine`-variant (niet nodig: Podman draait ín de
  Linux-container, niet op de host).
- Productie-harden van de nested setup (egress-policy per build, image-allowlist) —
  pas relevant als dit het gekozen pad wordt.
