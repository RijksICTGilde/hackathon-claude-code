# Maven via rootless Podman-in-Docker (ontwerp + bevindingen)

**Datum:** 2026-06-10
**Status:** Historisch ontwerpdocument. De host-agent is inmiddels verwijderd;
het besluit en de actuele stand staan in
`docs/adr/0001-maven-testcontainers-sandbox-isolatie.md` en
`claude-sandbox/podman/README.md`. Dit document bewaart het ontwerp, de
bevindingen en de meetresultaten; passages die de host-agent als bestaand of als
fallback beschrijven, zijn achterhaald.
**Context:** [issue #44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)

> De ontwerp-secties hieronder ("Oorspronkelijke scope/onzekerheden",
> "Verificatie", "Beslis-criteria") beschrijven de opzet tijdens de uitwerking;
> de uitkomst staat in "Bevindingen" en verder.

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
| **Podman-in-Docker (dit)** | rootless userns in container | AppArmor-userns-profiel + tailored seccomp + `systempaths=unconfined` (vfs default, géén `/dev/fuse`) | **ja** | licht |
| C — sysbox | sterke (eigen dockerd) | sysbox-runtime, recente kernel | Linux-only | middel |
| D — microVM | sterkste (eigen kernel) | KVM/nested virt | Linux-only | zwaar |

Podman-in-Docker zit qua isolatie boven de host-agent en onder sysbox, maar is als
enige sterkere optie cross-platform en vereist geen speciale host-runtime.

## Oorspronkelijke scope

Doel: bewijzen dat rootless Podman ín de sandbox-container een Maven build met
Testcontainers kan draaien, zonder `--privileged` en zonder socket-mount.

**Wel:**
- Sandbox-image optioneel uitrusten met rootless Podman (build-ARG, default uit).
- Runtime-vereisten regelen via een compose-override (`/dev/fuse`, seccomp).
- Smoke-test: `podman info` → kale nested container → minimale Maven+Testcontainers
  build groen.

**Niet (pas ná brede bevestiging):**
- Host-agent verwijderen of MCP-tool herschrijven.
- Documentatie in `maven-mcp-agent.md`/`SECURITY.md` als definitieve aanbeveling
  (DoD van #44) — dat volgde op de uitkomst.
- Optie C/D besluit.

## Artefacten

| Bestand | Inhoud |
|---|---|
| `claude-sandbox/Dockerfile` | `ARG INSTALL_PODMAN=false`; bij `true`: `podman fuse-overlayfs uidmap passt slirp4netns` installeren, subuid/subgid-regel voor `claude` **verwijderd** (single-uid), rootless `storage.conf` (vfs) |
| `claude-sandbox/compose.override.podman-linux.yml` | `devices: [/dev/net/tun]` (+ uitgecommentarieerde `/dev/fuse` voor overlay), `security_opt: [seccomp=<profiel>, apparmor=<profiel>, systempaths=unconfined, label=disable]`, `PODMAN_STORAGE_DRIVER`-env |
| `claude-sandbox/podman/smoke-test.sh` | in de container: `podman info`; `podman run --rm` smoke; daarna `mvn test` op het sample-project |
| `claude-sandbox/podman/sample/` | minimaal Maven-project: `pom.xml` + één Testcontainers-test (lichte image, bv. `alpine` via `GenericContainer`) |
| `claude-sandbox/podman/README.md` | exacte run-stappen + benodigde `ALLOWED_DOMAINS` + `.env`-flag |

## Oorspronkelijke onzekerheden (inmiddels opgelost — zie Bevindingen)

1. **seccomp.** Het default-Docker-seccomp-profiel blokkeert mogelijk syscalls die
   nested rootless podman nodig heeft. Eerst proberen met een gericht profiel;
   `seccomp=unconfined` als het anders niet draait — afweging documenteren
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
   `TESTCONTAINERS_RYUK_DISABLED=true` nodig in deze opzet.
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
sudo — dit kon daar niet live gedraaid worden. De artefacten zijn zo gebouwd dat
de gebruiker ze op de eigen host (waar Docker/Rancher de sandbox-image bouwt)
uitvoert via `podman/README.md`. De uitkomst (logs/uitslag) bepaalt de
vervolgstap.

## Beslis-criteria (gevolgd)

- **Slaagt zonder `--privileged`/socket** → uitwerken als aanbevolen pad; host-agent
  degraderen tot fallback; #44-DoD (doc + ADR) afronden met deze keuze.
- **Slaagt alleen met seccomp=unconfined** → afwegen of de verzwakking van de outer
  sandbox acceptabel is t.o.v. het sluiten van de host-bridge; documenteren.
- **Slaagt niet** → terug naar de goedkope hardening uit #44 voor de host-agent, en
  C/D als losse afweging.

## Out of scope (YAGNI)

- Host-agent verwijderen vóór brede bevestiging.
- Mac/Windows-specifieke `podman machine`-variant (niet nodig: Podman draait ín de
  Linux-container, niet op de host).
- Productie-harden van de nested setup (egress-policy per build, image-allowlist) —
  pas relevant als dit het gekozen pad wordt.

---

## Bevindingen (2026-06-10)

Uitgevoerd op een host met **TUXEDO OS** (Ubuntu-based), native rootful Docker
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
   terwijl de single-line self-map dan wél werkt. Omzeild door newuidmap helemaal
   niet te gebruiken (single-uid modus).

   **Oorzaak herleid (2026-07-31, op Rancher Desktop/macOS): ontbrekende
   `CAP_SYS_ADMIN`.** De kernel laat een `uid_map`-write toe aan wie
   `CAP_SYS_ADMIN` heeft in de doel-namespace óf er de eigenaar van is
   (`ns->owner == euid`). `newuidmap` is setuid-root, dus euid 0 terwijl de
   namespace van uid 1000 is — de eigenaars-route valt weg en de capability is
   vereist. Op een gewone host levert setuid-root die vanzelf; Docker laat
   `CAP_SYS_ADMIN` per default uit de bounding set (`CapBnd=…a80435fb`, bit 21
   uit), dus setuid-root kán hem niet krijgen. Dit is **host-onafhankelijk** —
   het geldt voor elke Docker-container, niet alleen gehardend Ubuntu — en staat
   los van blokkade #1, die daar bovenop komt.

   Metingen die dit vastpinnen (allemaal in dezelfde container):

   | Probe | Uitkomst |
   |---|---|
   | setuid-binary gestart door `claude` | `CapEff` = volledige bounding set → setuid werkt, `NoNewPrivs=0` |
   | container-userns | `0 0 4294967295`, init-ns, dockerd rootful → geen userns-remap |
   | `newuidmap` als root op **root's eigen** userns | rc=0 — via de eigenaars-route, niet via de capability |
   | `newuidmap` als root op **claude's** userns | EPERM — eigenaars-route valt weg |
   | `newuidmap` als claude, **zonder** `SYS_ADMIN` | EPERM, `uid_map` leeg |
   | `newuidmap` als claude, **mét** `SYS_ADMIN` | `uid_map: 0 1000 1 \| 1 100000 65536` |

   Let op de derde regel: die lijkt te bewijzen dat het mechanisme werkt, maar
   test de eigenaars-route. Dat is waarschijnlijk waarom "capabilities" bij de
   oorspronkelijke eliminatie hierboven als uitgesloten is genoteerd.

   **Gevolg voor het ontwerp.** Single-uid was niet de enige uitweg, wel de
   uitweg die geen capability kost. Multi-uid is nu opt-in beschikbaar
   (`PODMAN_MULTIUID=true` + `compose.override.podman-multiuid.yml`) omdat
   single-uid images die naar een tweede uid chownen niet kan draaien —
   `chown: ...: Invalid argument` bij postgres, mysql, mariadb. Bevestigd:
   met multi-uid start postgres wél en levert `select 42` gewoon `42`.

   **Security-afweging bij die opt-in.** `claude` draait als uid 1000 met
   `CapEff=0` en krijgt `CAP_SYS_ADMIN` dus niet rechtstreeks in handen; alleen
   setuid-root-binaries kunnen hem uit de bounding set trekken (hier
   `newuidmap`/`newgidmap` en `sudo`, met een sudoers die enkel
   `init-firewall.sh` toestaat). Wat wél groeit is de impact van een
   root-escalatie ín de container (mount, pivot_root), boven op de
   `systempaths=unconfined` die de podman-override al zet. Op Mac/Windows zit er
   nog een VM-kernelgrens onder; op Linux met bare Docker niet. Daarom opt-in en
   niet default.

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
| Docker Desktop / Rancher (Mac/Win) | VM, rootful | **Rancher/macOS bevestigd** (2026-07-31): geen AppArmor/SELinux in de Alpine-VM, `max_user_namespaces` open, `/dev/net/tun` + `/dev/fuse` aanwezig. `compose.override.podman-macos.yml` volstaat, via Rancher's `docker compose` — dat stuurt het seccomp-profiel inline mee en dockerd accepteert dat (podman's API weigert het, zie README) |
| macOS `podman machine` (applehv → Fedora CoreOS) | VM, rootful | **bevestigd, incl. multi-uid** (2026-07-31): SELinux Enforcing → `label=disable`, geen AppArmor. `compose.override.podman-macos.yml` + `compose.override.podman-multiuid.yml` via `podman-compose`; `cap_add: SYS_ADMIN` landt in de bounding set omdat de machine rootful is. Rootless machine niet getest |

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
| 3 | `storage.conf`: `vfs` + `ignore_chown_errors=true` (default; `overlay`/fuse-overlayfs optioneel via `.env`) | image-extractie chownt naar niet-gemapte uids in single-uid modus; vfs vermijdt `/dev/fuse` |
| 4 | `/dev/net/tun` device + bestaande `NET_ADMIN` | pasta rootless-netwerk (tap-device) |
| 5 | `containers.conf`: `default_sysctls = []` | crun schrijft `net.ipv4.ping_group_range` → `/proc/sys` is RO in outer container |
| 6 | `--security-opt systempaths=unconfined` | nieuwe procfs in geneste mountns geweigerd (Docker maskeert `/proc` → `mount_too_revealing`) |
| 7 | `containers.conf`: `[network] firewall_driver = "iptables"` | netavark roept default `nft` aan (niet in image); iptables-nft is wél aanwezig |

`storage.conf` wordt door `entrypoint.sh` elke start gegenereerd uit
`PODMAN_STORAGE_DRIVER` (.env); `containers.conf` alleen aangemaakt als hij
ontbreekt — handmatige aanpassingen blijven dus staan. Keerzijde, gezien op een
macOS Podman-machine (2026-07-31): een met de hand aangepaste `containers.conf`
(eigen `tmp_dir`/`static_dir`, zónder `default_sysctls`) blijft stil in het
volume schaduwen en brak podman met `error creating temporary file` +
`open .../libpod/tmp/pause.pid: no such file or directory`. Beide op
het `claude-home` volume (baked-in image-versie wordt door een bestaand named
volume geschaduwd). Het AppArmor-profiel + de override-`security_opt`/
`devices` zijn host-/compose-zaken (`setup-host.sh` + `compose.override.podman-linux.yml`).

## Security-balans (cruciaal voor de #44-afweging)

Wat dit pad **dichtzet**: de container→host code-execution van #44. Geen
host-agent, geen Docker-socket, geen `--privileged`. mvn/pom-plugins draaien in
de sandbox (non-root `claude`), Testcontainers-children in geneste rootless
userns. De Copilot-bug wordt niet gereproduceerd.

Wat dit pad **openzet** op de *outer* sandbox-container: `apparmor=unconfined`
(via profiel) + tailored seccomp + `systempaths=unconfined` (masked/RO `/proc`
weg) + `/dev/net/tun`. `/dev/fuse` is **niet** standaard open — alleen als je
bewust de fuse-overlayfs-driver kiest (`PODMAN_STORAGE_DRIVER=overlay` in `.env`
én de `/dev/fuse`-device uncomment in de override); default is `vfs` zonder device.
Op SELinux-hosts (Fedora/RHEL) zet `label=disable` bovendien de SELinux-confinement
van déze container uit (no-op op AppArmor-hosts).
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

## Bevestigd
- **Het pause-proces bepaalt de namespace voor de hele container** (2026-07-31).
  Het eerste podman-commando maakt het pause-proces aan dat de user-namespace
  vastlegt; alles daarna joint dat proces. Komt dat proces single-uid op, dan
  blijft de container single-uid — ook nadat de oorzaak weg is — en falen
  DB-images op `chown: Invalid argument`, met een `podman info` die
  `uidmap=[{0 1000 1}]` toont terwijl subuid-range én `CAP_SYS_ADMIN` er gewoon
  zijn. Herstel: `podman system migrate`.

  Eén bewezen manier waarop dat gebeurt is `no_new_privs`: `newuidmap` is
  setuid-root en wint onder die vlag geen privileges meer, dus de range-write
  faalt met dezelfde EPERM als bij een ontbrekende `CAP_SYS_ADMIN`. Meting:
  `setpriv --no-new-privs podman info` reproduceert het één op één, en met een
  gezond pause-proces geeft diezelfde aanroep wél de volledige mapping — joinen
  vergt de capability niet, aanmaken wel.

  **Gevolg voor het ontwerp:** `entrypoint.sh` zet de podman-socket bij
  container-start op, in een schone omgeving vóór er iets anders draait, en
  waarschuwt als de mapping dan tóch single-uid is. De client-env (`DOCKER_HOST`,
  `TESTCONTAINERS_*`) staat in de podman-overrides op container-niveau: een
  shell-profiel zou het mis doen, want `/etc/profile.d` geldt alleen voor
  login-shells en `~/.bashrc` alleen voor interactieve — een build die via
  `bash -c` start, krijgt uit geen van beide iets mee.
- **Multi-uid op een macOS Podman-machine** (2026-07-31, applehv → Fedora
  CoreOS, rootful): `compose.override.podman-macos.yml` +
  `compose.override.podman-multiuid.yml` via `podman-compose`, image gebouwd met
  `PODMAN_MULTIUID=true`. `podman info` → `uidmap=[{0 1000 1} {1 100000 65536}]`,
  nested container ok, `smoke-test.sh` groen incl. `PostgresSmokeTest`
  (`postgres:16-alpine`). Bevestigt de meting bij blokkade #2 op een tweede
  macOS-runtime.
- Volledige Testcontainers-build draaide groen in een aparte sessie op een écht
  project: een Quarkus-module met Redis-stack Dev-Services + integratietests,
  **289 + 46 tests groen**, image-pull van `redis/redis-stack-server` (521 MB) en
  containerstart via podman. Single-uid + `ignore_chown_errors` is in de praktijk
  geen blokker voor DB-achtige images.
- **Extra nodig voor containers met port-wait** (Postgres/Redis/Quarkus
  Dev-Services): `TESTCONTAINERS_HOST_OVERRIDE=localhost`. Rootless podman
  publisht gepublishte poorten op localhost, maar Testcontainers resolvet de
  container-host default als de netavark bridge-gateway (bv. `10.88.0.1`) →
  port-wait timeout. De alpine-GenericContainer in de smoke heeft geen port-wait
  en miste dit; nu toegevoegd aan `smoke-test.sh`.
- Env-samenvatting voor een echte build in de sandbox:
  ```
  export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"; mkdir -p "$XDG_RUNTIME_DIR"
  podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" &
  export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
  export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="$XDG_RUNTIME_DIR/podman/podman.sock"
  export TESTCONTAINERS_RYUK_DISABLED=true
  export TESTCONTAINERS_HOST_OVERRIDE=localhost
  ```
- Hiermee is de host-side Maven MCP-agent in deze sandbox **niet meer nodig**.

## Hardening-verfijning (geprobeerd / vervolg)
- **Docker-default seccomp werkt niet** (geverifieerd): `cannot clone: Operation
  not permitted` — podman's re-exec in een nieuwe userns gebruikt
  `clone(CLONE_NEW*)`, wat de default-profiel-gating blokkeert.
- **Opgelost met een tailored blocklist-profiel** (`seccomp/podman-sandbox.json`):
  `defaultAction = SCMP_ACT_ALLOW` (dus `clone`/`unshare`/`mount`/`setns`/`keyctl`
  werken — geen argument-gating zoals de default), met `SCMP_ACT_ERRNO` op de
  escape-relevante syscalls die Docker-default óók blokkeert (en die rootless
  podman + JVM-Testcontainers niet nodig hebben): module-load
  (`init_module`/`finit_module`/`delete_module`/`create_module`/`query_module`/
  `get_kernel_syms`), `kexec_*`, `reboot`, `iopl`/`ioperm`, `swapon`/`swapoff`,
  klok-zetten (`settimeofday`/`clock_settime`/`clock_adjtime`), `bpf`,
  `perf_event_open`, `open_by_handle_at`, `userfaultfd`, `io_uring_*`,
  NUMA (`mbind`/`set_mempolicy`/`migrate_pages`/`move_pages`), `process_vm_readv`/
  `process_vm_writev`, `process_madvise`, `fanotify_init`, `kcmp`, `pidfd_getfd`,
  `acct`, `_sysctl`, `vm86*`, `nfsservctl`, `lookup_dcookie`. Strikt veiliger dan
  `unconfined`. Override verwijst ernaar via
  `seccomp=podman/seccomp/podman-sandbox.json`.
  Breekt een build op een geblokkeerde syscall → uit de blocklist halen.
  **Bewust níét geblokkeerd:** `ptrace` (Docker-default láát het toe; sommige
  JVM-tooling gebruikt het) — kan als verdere tightening alsnog toegevoegd.
  **Geverifieerd** op de gehardende host: `Seccomp: 2` (filter actief, niet
  unconfined) én de Testcontainers-smoke groen. De uitgebreide blocklist
  (io_uring/userfaultfd/NUMA/…) is op een recreate opnieuw te bevestigen.
- **AppArmor**: een echt confined profiel (docker-default + `userns,`) botst met
  wat nested podman nodig heeft — docker-default `deny mount` blokkeert crun's
  mounts, en `deny @{PROC}/sys/...w` blokkeert netavark's `/proc/sys/net`-writes.
  Een werkend confined profiel moet die deny's gericht openen; vergt iteratie.
- **systempaths=unconfined**: grof (heft alle masked/RO `/proc`-paden op), maar de
  geneste procfs-mount vereist dat de maskering weg is; nauwelijks te versmallen.
- abi-versie van het AppArmor-profiel: werkte op Tuxedo; `setup-host.sh` heeft nu
  een abi-fallback voor oudere AppArmor.

**Conclusie verfijning:** de vier relaxaties zijn grotendeels inherent aan nested
rootless podman, niet overbodig. De veiligheid zit in de *scoping* (opt-in, aparte
override, geen `CAP_SYS_ADMIN`/`--privileged`/socket, host-userns-hardening blijft
voor al het andere aan), niet in het wegpoetsen van de relaxaties. Een tailored
seccomp-profiel is de enige verfijning met noemenswaardige winst en staat als
vervolg genoteerd.
