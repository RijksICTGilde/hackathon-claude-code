# Maven via rootless Podman-in-Docker (PoC)

**Datum:** 2026-06-10
**Status:** PoC GESLAAGD op gehardende host (Tuxedo/Ubuntu, sysctl=1). Testcontainers-build draaide echt (`Tests run: 1, Failures: 0, Errors: 0`). Zie "PoC-bevindingen" + "Werkende configuratie" onderaan.
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

---

## PoC-bevindingen (2026-06-10)

PoC gedraaid op een host met **TUXEDO OS** (Ubuntu-based), native rootful Docker
Engine. Resultaat: de kale aanpak (multi-uid rootless podman) **werkt niet** op
gehardende Ubuntu-hosts. Twee onafhankelijke blokkades gevonden via systematisch
debuggen (eliminatie: userns-ownership, capabilities, NoNewPrivs, seccomp,
container-AppArmor-profiel, nosuid — allemaal uitgesloten):

1. **`kernel.apparmor_restrict_unprivileged_userns=1`** (Ubuntu 23.10+ hardening).
   Blokkeert **élke** unprivileged userns-map — zelfs een single-line self-map
   (`unshare -U -r` faalt). Bewezen: faalt bij sysctl=1; werkt bij sysctl=0
   **mits de container wordt gerecreëerd** (de AppArmor-mediatie klikt vast bij
   container-start; een runtime-sysctl-flip pakt niet op een draaiende container).
   `apparmor=unconfined` op de container helpt **niet** — de restrictie zit op
   host-kernelniveau.

2. **Privileged multi-uid `newuidmap`-range-write** faalt met
   `write to uid_map failed: Operation not permitted`, óók met sysctl=0+recreate,
   terwijl de single-line self-map dan wél werkt. Oorzaak niet sluitend herleid;
   omzeild door newuidmap helemaal niet te gebruiken (single-uid modus).

### Gevolg voor het ontwerp
De kernclaim "host-OS maakt niet uit / lichtgewicht" is **gefalsifieerd** voor
gehardende Ubuntu (de overheids-Linux-basis + veel dev-laptops): podman-in-docker
vereist daar een **host-level wijziging**. Wel blijft het buiten `--privileged`
en zonder Docker-socket, dus het reproduceert de Copilot-bug niet.

### Herziene aanpak: single-uid + AppArmor-userns-profiel (per-setup set)
Besluit (gebruiker, 2026-06-10): uitwerken als een **set configs die per
host-setup werkt**. Weinig projecten hebben dit nodig, dus per-setup is acceptabel.

- **Engine: single-uid modus.** Geen `/etc/subuid`/`/etc/subgid`-entry voor
  `claude` → podman mapt alleen de eigen uid als root (count 1), gebruikt
  `newuidmap` niet → omzeilt blokkade #2. `ignore_chown_errors=true` in
  `storage.conf` zodat multi-uid images tóch extracten.
- **Blokkade #1: custom AppArmor-profiel met `userns,`** i.p.v. host-sysctl
  versoepelen. Host-profiel `flags=(unconfined) { userns, }`, geladen met
  `apparmor_parser`, container draait eronder via `--security-opt
  apparmor=<profiel>`. De restrictie blijft systeembreed aan; alleen deze
  container krijgt userns. Geen `sysctl=0` nodig.

### Per-setup matrix
| Host-setup | userns-status | Maatregel |
|---|---|---|
| Linux Docker, niet-gehardend (sysctl=0 / oudere kernel) | open | alleen `/dev/fuse` + seccomp + single-uid engine |
| Gehardend Ubuntu 23.10+ (sysctl=1) | restrictie | **custom AppArmor-`userns`-profiel** (geen host-verzwakking) — voorkeur; of `sysctl=0` permanent (verzwakt host) |
| Docker Desktop / Rancher (Mac/Win) | VM, rootful | vermoedelijk out-of-the-box; nog te testen |

### Trade-off van de AppArmor-route (security)
`flags=(unconfined) { userns, }` = effectief unconfined voor déze container + userns
toegestaan. Verzwakt dus de container-MAC-laag (zoals eerder geanalyseerd: `mount`,
`/proc`/`/sys`-writes, ptrace-scoping vervallen), maar Docker's masked paths +
capability-set + namespaces blijven. De host-hardening blijft voor al het andere
intact (andere containers blijven `docker-default`). Voor het #44-dreigingsbeeld
(Claude rogue / prompt-injection) acceptabel; voor volledig vijandige code niet.

## Werkende configuratie (geverifieerd 2026-06-10)

Op een gehardende host (Tuxedo OS, Ubuntu-based, `sysctl=1`) draaide de
Testcontainers-smoke echt groen. De volledige keten van zeven aanpassingen,
elk debug-stap voor stap gevonden:

| # | Aanpassing | Lost op |
|---|---|---|
| 1 | AppArmor-profiel `flags=(unconfined) { userns, }` (host, via `setup-host.sh`), container draait eronder | userns-restrictie (`apparmor_restrict_unprivileged_userns=1`) zonder host-sysctl te versoepelen |
| 2 | Single-uid: geen `/etc/subuid`-entry voor `claude` | privileged `newuidmap`-range-write faalt → vermeden (podman mapt alleen eigen uid) |
| 3 | `storage.conf`: `ignore_chown_errors=true` + fuse-overlayfs | image-extractie chownt naar niet-gemapte uids in single-uid modus |
| 4 | `/dev/net/tun` device + bestaande `NET_ADMIN` | pasta rootless-netwerk (tap-device) |
| 5 | `containers.conf`: `default_sysctls = []` | crun schrijft `net.ipv4.ping_group_range` → `/proc/sys` is RO in outer container |
| 6 | `--security-opt systempaths=unconfined` | nieuwe procfs in geneste mountns geweigerd (Docker maskeert `/proc` → `mount_too_revealing`) |
| 7 | `containers.conf`: `[network] firewall_driver = "iptables"` | netavark roept default `nft` aan (niet in image); iptables-nft is wél aanwezig |

`storage.conf`/`containers.conf` worden door `entrypoint.sh` idempotent op het
`claude-home` volume geschreven (baked-in image-versie wordt door een bestaand
named volume geschaduwd). Het AppArmor-profiel + de override-`security_opt`/
`devices` zijn host-/compose-zaken (`setup-host.sh` + `compose.override.podman.yml`).

## Security-balans (cruciaal voor de #44-afweging)

Wat dit pad **dichtzet**: de container→host code-execution van #44. Geen
host-agent, geen Docker-socket, geen `--privileged`. mvn/pom-plugins draaien in
de sandbox (non-root `claude`), Testcontainers-children in geneste rootless
userns. De Copilot-bug wordt niet gereproduceerd.

Wat dit pad **openzet** op de *outer* sandbox-container (de prijs van de zeven
aanpassingen): `apparmor=unconfined` (via profiel) + `seccomp=unconfined` +
`systempaths=unconfined` (masked/RO `/proc` weg) + `/dev/fuse` + `/dev/net/tun`.
Dat pelt de defense-in-depth van de buitenste container fors af: de
kernel-attack-surface (syscalls, `/proc`-writes) groeit. Capability-set (geen
`CAP_SYS_ADMIN`), namespaces en de host-userns-hardening (blijft voor al het
andere aan) staan nog wél.

**Weging:** voor het reële #44-dreigingsbeeld (Claude rogue / prompt-injectie,
semi-vertrouwd) is dit een netto verbetering — host-user-escalatie dicht, in ruil
voor meer kernel-oppervlak dat alleen een kernel-exploit-capabele aanval benut.
Voor *volledig vijandige* code (kernel-escape in scope) is het pad te zwak; daar
horen Optie C (sysbox) / D (microVM). De outer-sandbox-relaxaties gelden alleen
voor containers die met de podman-override draaien; een normale sandbox blijft
ongewijzigd.

## Resterende vragen (out of scope PoC)
- Zwaardere Testcontainers-images (Postgres/Ryuk) onder single-uid +
  `ignore_chown_errors` — alpine-GenericContainer is bewezen; DB-images nog niet.
- `seccomp`/`apparmor` verfijnen van `unconfined` naar gerichte profielen om de
  outer-sandbox-relaxatie te beperken.
- abi-versie van het AppArmor-profiel op andere kernels (werkte op Tuxedo).
