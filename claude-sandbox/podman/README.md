# Maven + Testcontainers via rootless Podman-in-Docker

Draai Testcontainers **ín** de sandbox via rootless Podman — zonder host-agent,
`--privileged` of Docker-socket. `mvn` en pom-plugins draaien in de sandbox als
non-root `claude`, Testcontainers-containers zijn geneste
rootless-userns-children. Dit is de enige ondersteunde route: de Maven
host-agent is verwijderd, omdat die per ontwerp een container→host
code-execution-bridge was (issue #44, ADR 0001).

## Migratie vanaf de host-agent

Draaide je eerder de host-agent? Die code is uit de repo, maar dat stopt geen
proces of registratie op je eigen machine. Ruim die eenmalig op:

1. Stop een draaiende `run.sh` en controleer dat er niets meer op poort 7777
   luistert: `ss -ltnp | grep 7777` (leeg = goed). Die listener bond auth-loos
   op `0.0.0.0`.
2. Verwijder de MCP-registratie in de container:
   `docker exec -u claude claude-sandbox claude mcp remove maven`. Die
   registratie zit in het `claude-home` volume en overleeft een rebuild.
3. Had je alleen voor de host-agent een `compose.override.yml` met
   `host.docker.internal`? Die is niet meer nodig.

## Ondersteunde platforms

| Platform | Status | Wat je nodig hebt |
|---|---|---|
| Gehardend Ubuntu 23.10+ / Tuxedo (`apparmor_restrict_unprivileged_userns=1`) | bevestigd | `setup-host.sh` (laadt AppArmor-`userns`-profiel) + `compose.override.podman-linux.yml` |
| Linux Docker, niet-gehardend (`sysctl=0`) | bevestigd | `compose.override.podman-linux.yml`; AppArmor-profiel onschadelijk (of override → `apparmor=unconfined`) |
| Rancher Desktop op macOS (Lima → Alpine, moby) | bevestigd | `compose.override.podman-macos.yml` via Rancher's eigen `docker compose`; geen `setup-host.sh`, geen `podman-compose`. Zie "Rancher Desktop" |
| macOS `podman machine` (applehv → Fedora CoreOS, rootful) | bevestigd, ook multi-uid | `compose.override.podman-macos.yml` + `podman-compose`; geen `setup-host.sh`. Zie "macOS" |
| Docker Desktop Mac/Windows, rootless `podman machine`, WSL2 | **niet ondersteund** | niet bevestigd; geen terugvaloptie meer — bevestig eerst zelf met `setup-host.sh` + `smoke-test.sh` |

Check je host: `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns`.

Ontwerp, bevindingen en security-balans:
`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md` en
`docs/adr/0001-maven-testcontainers-sandbox-isolatie.md`.

Bevestigd op een echt project: een Quarkus-module met Redis-stack Dev-Services +
integratietests draaide **289 + 46 tests groen** via podman in de sandbox.

## Hoe het werkt
Op gehardende Ubuntu/Tuxedo (`kernel.apparmor_restrict_unprivileged_userns=1`)
werkt naïeve multi-uid rootless podman niet (host blokkeert userns-maps; de
privileged `newuidmap`-range faalt). Daarom draait deze opzet in **single-uid
modus** (geen `newuidmap`) en regelt userns via een **custom AppArmor-profiel**
i.p.v. de host systeembreed te verzwakken. De volledige keten van aanpassingen
staat in de spec.

**Beperking van de default (single-uid):** images die naar een tweede uid
chownen starten niet — `chown: ...: Invalid argument`. Dat treft postgres, mysql,
mariadb en de meeste DB-images. Heb je die nodig: zie "Multi-uid" hieronder.

## Stappen (op de host)

Draai alle commando's hieronder vanuit `claude-sandbox/`. Padverwijzingen naar
`docs/` zijn vanaf de repo-root.

1. In `.env` zetten (vóór de build):
   ```
   INSTALL_PODMAN=true
   # Firewall whitelist bevat geen registries; Testcontainers pullt van docker.io.
   ALLOWED_DOMAINS=registry-1.docker.io,auth.docker.io,production.cloudflare.docker.com,docker.io
   ```
2. **AppArmor-profiel laden** (gehardende host; onschadelijk elders):
   ```
   ./podman/setup-host.sh
   ```
   Dit installeert `claude-sandbox-podman` in `/etc/apparmor.d/` en laadt het.
   De override verwijst ernaar; zonder dit faalt de container-start met
   "AppArmor profile not found". **Vereist sudo op de host** (installeert een
   profiel in `/etc/apparmor.d/` en laadt de kernelmodules `fuse`/`tun`) — op
   een beheerde werkplek zonder lokale admin lukt deze stap niet.
3. Image bouwen + starten met de runtime-override (seccomp, apparmor, netwerk):
   ```
   cd claude-sandbox
   docker compose -f compose.yml -f compose.override.podman-linux.yml up --build -d --force-recreate
   ```
   Storage is default `vfs` (veilig, geen `/dev/fuse`). Sneller? Zet in `.env`
   `PODMAN_STORAGE_DRIVER=overlay` én uncomment de `/dev/fuse`-device in de
   override (fuse-overlayfs; groter kernel-aanvaloppervlak), en recreate. Wisselen
   vereist eenmalig `podman system reset` in de container.
4. JDK+Maven in de container (eenmalig, blijft in het claude-home volume):
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && sdk install java && sdk install maven"
   ```
5. Verificatie (sample Testcontainers-build):
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && \
      /home/claude/projects/<repo>/claude-sandbox/podman/smoke-test.sh"
   ```
   Pas `<repo>` aan naar waar deze repo in `/home/claude/projects` gemount staat.
   Staat deze repo niet onder je `PROJECTS_DIR`, kopieer de map dan naar binnen:
   `docker cp podman claude-sandbox:/home/claude/podman-smoke`
   (of `podman cp`) en draai `/home/claude/podman-smoke/smoke-test.sh`.

Verwacht: het script print `nested-ok` en eindigt met `OK — Testcontainers werkt`.

## macOS (Podman-machine)

Bevestigd op een Mac met een **Podman-machine** (`applehv` → Fedora CoreOS VM):
rootless podman-in-podman draait, nested containers werken (`nested-ok`) en de
volledige Maven+Testcontainers-smoke-test slaagt end-to-end. De VM heeft **geen
AppArmor** en **geen userns-hardening**, maar SELinux staat wél op `Enforcing`.
Drie afwijkingen t.o.v. de Linux-stappen:

1. **Gebruik `compose.override.podman-macos.yml`** i.p.v. de Linux-override. Die
   zet `apparmor=unconfined` (het Linux-AppArmor-profiel bestaat hier niet en zou
   de container-start breken) en houdt `label=disable` voor SELinux. **Sla
   `setup-host.sh` over** — er is geen AppArmor om te laden.
2. **Draai via `podman-compose`, niet via `podman compose`.** Dat laatste
   delegeert naar Rancher's `docker-compose`, die het seccomp-profiel *inline* (als
   JSON) meestuurt; podman's API weigert dat met `opening seccomp profile failed:
   ... file name too long`. De echte `podman-compose` (`brew install
   podman-compose`) geeft het als pad door. Het seccomp-pad in de macOS-override is
   daarom **absoluut** (`${PWD}/...`) — podman leest het profiel client-side op de
   Mac; draai compose dus vanuit `claude-sandbox/`.
3. **Bouw met `BUILDAH_FORMAT=docker`.** Podman's eigen builder bouwt default in
   OCI-formaat en negeert dan de `SHELL [... bash ...]`-instructie uit de
   Dockerfile → bash-isms breken (`/bin/sh: [[: not found`). Docker-formaat
   honoreert `SHELL`.

```
cd claude-sandbox
# .env: INSTALL_PODMAN=true  (OPEN_HTTPS=true laat docker.io-pulls over 443 toe)
BUILDAH_FORMAT=docker podman-compose -f compose.yml -f compose.override.podman-macos.yml \
  up --build -d --force-recreate
# JDK + Maven (eenmalig, blijft in het claude-home volume)
podman exec claude-sandbox bash -lc \
  "source ~/.sdkman/bin/sdkman-init.sh && sdk install java && sdk install maven"
# verificatie
podman exec claude-sandbox bash -lc \
  "source ~/.sdkman/bin/sdkman-init.sh && \
   /home/claude/projects/<repo>/claude-sandbox/podman/smoke-test.sh"
```

De `single mapping`/`Additional gid ... not present`-warnings zijn verwacht: de
image draait bewust single-uid (geen `claude:`-regel in `/etc/subuid`).

Multi-uid (Postgres e.d.) is hier ook bevestigd (2026-07-31): stapel
`compose.override.podman-multiuid.yml` erbovenop en bouw met
`PODMAN_MULTIUID=true` — zie "Multi-uid (opt-in)" hieronder. De
Podman-machine is rootful (`podman machine inspect ... {{.Rootful}}` → `true`),
dus `cap_add: SYS_ADMIN` komt daadwerkelijk in de bounding set. Op een rootless
machine is dat niet verifieerd.

### Eigen build draaien
Niets voorbereiden: `./mvnw test` werkt. De entrypoint start bij container-start
de podman-socket op `/tmp/podman-run-1000/podman/podman.sock`, en de
podman-override zet `DOCKER_HOST`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`,
`TESTCONTAINERS_RYUK_DISABLED` en `TESTCONTAINERS_HOST_OVERRIDE` op
container-niveau — dus elk proces erft ze, ook een kale `bash -c`.

**Start niet zelf een tweede `podman system service` op datzelfde pad.** Die kan
niet binden en ruimt bij het afsluiten de socket van de eerste op; daarna faalt
Testcontainers met `Could not find a valid Docker environment` (het valt terug op
`/var/run/docker.sock`).

Waarom de entrypoint dit doet in plaats van jij per build: het éérste
podman-commando maakt het pause-proces aan dat de user-namespace vastlegt, en
alles daarna joint dat proces. Lukt die eerste aanmaak niet met de volledige
subuid-range, dan blijft de hele container in single-uid hangen — ook nadat de
oorzaak weg is. Zie de `no_new_privs`-rij in de fallback-tabel.

## Rancher Desktop op macOS

Bevestigd (2026-07-31). Rancher draait een Lima-VM met Alpine en rootful dockerd;
de container zit in de init-userns. Die VM heeft **geen AppArmor en geen SELinux**
(`/sys/kernel/security/lsm` → `lockdown,capability,landlock`), geen
userns-hardening, en `/dev/net/tun` + `/dev/fuse` staan er allebei. Er is dus
**niets op de host in te stellen** — geen `setup-host.sh`, geen sysctl, geen
subuid-range op de host.

Gebruik de macOS-override, maar met Rancher's eigen `docker compose`:

```
cd claude-sandbox
docker compose -f compose.yml -f compose.override.podman-macos.yml up -d --force-recreate
```

Twee verschillen met de Podman-machine-route hierboven: `docker compose` stuurt
het seccomp-profiel **inline** mee en dockerd accepteert dat (podman's API
weigert het met `file name too long`), en `BUILDAH_FORMAT=docker` is niet nodig
omdat je met de Docker-builder bouwt. Draai wel vanuit `claude-sandbox/`, want de
macOS-override gebruikt `${PWD}` in het seccomp-pad.

## Multi-uid (opt-in): DB-images zoals Postgres

In de default single-uid modus is alleen uid 0 gemapt. Het postgres-entrypoint
chownt `$PGDATA` naar de postgres-uid, die daar niet bestaat → `chown:
/var/lib/postgresql/data: Invalid argument`, container stopt direct, en
Testcontainers meldt alleen `Container did not start correctly`.
`ignore_chown_errors` in `storage.conf` helpt niet: dat dekt image-extractie, niet
een runtime-chown door een proces ín de container.

Multi-uid lost dat op. Twee dingen aanzetten:

1. `.env`: `PODMAN_MULTIUID=true` (zet de subuid-range in de image) — vereist een
   rebuild.
2. `compose.override.podman-multiuid.yml` **stapelen op** je platform-override
   (geeft `CAP_SYS_ADMIN`):
   ```
   docker compose -f compose.yml -f compose.override.podman-macos.yml \
                  -f compose.override.podman-multiuid.yml up --build -d --force-recreate
   ```

Vergeet je de override, dan waarschuwt de entrypoint bij de start; zonder
`CAP_SYS_ADMIN` faalt élke podman-actie met `newuidmap: write to uid_map failed`.

Waarom die capability nodig is en wat hij kost, staat in de kop van
`compose.override.podman-multiuid.yml`; de meting erachter in de spec, blokkade
&#35;2. Kort: `newuidmap` is setuid-root en de kernel eist `CAP_SYS_ADMIN` zodra
je een namespace mapt die je niet zelf bezit — Docker laat die capability per
default uit de bounding set. `claude` krijgt hem niet rechtstreeks in handen
(`CapEff=0`), maar een root-escalatie ín de container wordt er wel krachtiger
van. Op Mac/Windows zit er nog een VM-kernelgrens onder, op Linux met bare Docker
niet. Daarom opt-in.

`smoke-test.sh` detecteert de modus zelf en draait `PostgresSmokeTest` alleen in
multi-uid; in single-uid meldt hij die als overgeslagen.

Bevestigd op Rancher Desktop/macOS en op een macOS Podman-machine (2026-07-31):
`PostgresSmokeTest` + `SmokeTest` groen, `postgres:16-alpine` gepulld en gestart
in de sandbox.

## Fallbacks als het niet meteen draait

| Symptoom | Oorzaak | Maatregel |
|---|---|---|
| `unshare ... uid_map: Operation not permitted` of `podman info` faalt op userns | host-hardening blokkeert userns; profiel niet (goed) geladen | `setup-host.sh` gedraaid? `cat /proc/self/attr/current` in de container → moet `claude-sandbox-podman` zijn. Container ná het laden **recreaten** (`--force-recreate`) — de AppArmor-mediatie klikt vast bij start. |
| `newuidmap: write to uid_map failed: Operation not permitted` | multi-uid (subuid-entry aanwezig) zonder `CAP_SYS_ADMIN` | óf `compose.override.podman-multiuid.yml` meestapelen, óf terug naar single-uid (`PODMAN_MULTIUID=false` + rebuild). Check `cat /etc/subuid` in de container: `claude:`-regel = multi-uid. De entrypoint waarschuwt hier bij de start al voor. |
| `chown: ...: Invalid argument` bij een DB-image, of Testcontainers meldt `Container did not start correctly` | single-uid: de image chownt naar een uid die niet in de namespace bestaat | multi-uid aanzetten — zie "Multi-uid (opt-in)" hierboven |
| `podman info` faalt op storage / `overlay` werkt niet | `PODMAN_STORAGE_DRIVER=overlay` maar `/dev/fuse`-device niet doorgegeven | entrypoint valt automatisch terug op vfs + waarschuwt; uncomment de `/dev/fuse`-device in de override of blijf op `vfs` (default) |
| `pasta failed: Failed to open() /dev/net/tun` | rootless netwerk-backend mist het tun-device | override geeft `/dev/net/tun` door; ontbreekt het op de host: `sudo modprobe tun`. NET_ADMIN heeft de sandbox al. |
| `crun: open /proc/sys/net/ipv4/ping_group_range: Read-only file system` | podman zet default deze sysctl; `/proc/sys` is RO in de outer container | `~/.config/containers/containers.conf` → `[containers]\ndefault_sysctls = []` (entrypoint schrijft dit bij start) |
| `podman info` toont `uidmap=[{0 1000 1}]` terwijl `/etc/subuid` een `claude:`-regel heeft én `CAP_SYS_ADMIN` er is; DB-images falen op `chown: Invalid argument` | een pause-proces dat single-uid is aangemaakt. Alle latere podman-commando's joinen dat proces, dus de degradatie plakt vast. Ontstaat als het éérste podman-commando `newuidmap` niet kon gebruiken — bv. onder `no_new_privs`, waar een setuid-root-binary geen privileges meer wint (reproduceerbaar met `setpriv --no-new-privs podman info`) | `podman system migrate` en de podman-socket herstarten; of simpelweg de container recreaten — de entrypoint zet de namespace bij de start goed. Draait er een gezond pause-proces, dan joinen ook `no_new_privs`-aanroepen dát en gaat het weer goed |
| Testcontainers: `Could not find a valid Docker environment ... NoSuchFileException (/var/run/docker.sock)` terwijl `DOCKER_HOST` gezet is | er is een tweede `podman system service` op hetzelfde socket-pad gestart; die kan niet binden en verwijdert bij het afsluiten de socket van de eerste | gebruik de socket die de entrypoint al draait (zie "Eigen build draaien"); controleer met `ls -l /tmp/podman-run-1000/podman/podman.sock` en recreate de container als hij weg is |
| `error creating temporary file: No such file or directory` + `open .../libpod/tmp/pause.pid: no such file or directory` | een handmatig aangepaste `containers.conf` in het `claude-home` volume (bv. met een eigen `tmp_dir`/`static_dir`) — de entrypoint schrijft die alleen aan als hij **ontbreekt**, dus zulke drift blijft staan en schaduwt de bedoelde config | vergelijk met de entrypoint-versie (`[containers] default_sysctls = []` + `[network] firewall_driver = "iptables"`); back-uppen en terugzetten naar die versie, daarna opnieuw `podman info`. Helpt dat niet: `podman system migrate`, in het uiterste geval `podman system reset` |
| `mount proc: Operation not permitted` | Docker maskeert `/proc`; geneste procfs-mount geweigerd | override staat op `systempaths=unconfined` |
| `graphOptions: {}` / `ignore_chown_errors` ontbreekt | storage.conf landde niet (bestaand volume schaduwt de baked-in versie) | entrypoint schrijft hem bij start; bij een oud volume eenmalig handmatig: zie `entrypoint.sh`-blok, of recreate met een verse `claude-home` |
| image-extractie faalt op chown | single-uid kan niet naar andere uids chownen | `ignore_chown_errors=true` staat al in storage.conf; controleer dat het meekwam (`podman info` → graphOptions) |
| syscall/permission errors bij `podman run` of een build | tailored seccomp-blocklist (`seccomp/podman-sandbox.json`) blokkeert een syscall die jouw workload tóch nodig heeft | haal die syscall uit het profiel, of zet tijdelijk `seccomp=unconfined`. Compose resolvet dit pad tegen de projectdirectory (de map van het eerste `-f`-bestand) → draai compose vanuit `claude-sandbox/` met `compose.yml` als eerste `-f`. |
| `opening seccomp profile failed: open {"defaultAction"...}: file name too long` (macOS) | `podman compose` delegeert naar `docker-compose`, dat het profiel inline (als JSON) meestuurt i.p.v. als pad | draai via `podman-compose` (zie macOS-sectie); die geeft het pad door |
| `opening seccomp profile failed: open ...: no such file or directory` (macOS) | relatief seccomp-pad; podman leest client-side op de Mac | macOS-override gebruikt absoluut pad (`${PWD}/...`); draai compose vanuit `claude-sandbox/` |
| `/bin/sh: [[: not found` / `SHELL is not supported for OCI image format` (podman build) | podman's builder bouwt OCI-formaat en negeert de `SHELL`-bash-instructie | bouw met `BUILDAH_FORMAT=docker` |
| image-pull hangt/timeout | firewall blokkeert registry | `ALLOWED_DOMAINS` uit stap 1 toevoegen en container herstarten |
| Ryuk-container faalt | reaper in nested rootless | `TESTCONTAINERS_RYUK_DISABLED=true` (staat al in de smoke-test) |
| `Timed out waiting for container port to open` (host bv. `10.88.0.1`) | rootless podman publisht op localhost; Testcontainers resolvet de netavark bridge-gateway | `TESTCONTAINERS_HOST_OVERRIDE=localhost` (staat in de smoke-test; zet hem ook in je eigen build-env) |

## Openstaand
- Multi-uid is niet getest op gehardend Ubuntu. Blokkade #1 — de
  AppArmor-userns-restrictie — staat daar los van en blijft gelden.
- `containers.conf` wordt alleen aangemaakt als hij ontbreekt, `storage.conf`
  elke start herschreven. Overwegen om beide gelijk te trekken: dat maakt
  handmatige drift onmogelijk, maar neemt ook de ontsnappingsklep weg om
  podman-instellingen zelf bij te stellen.
- seccomp/apparmor verder verfijnen van de huidige stand (zie spec).

## Maximale isolatie (eigen kernel)
Deze opzet deelt de host-kernel (restrisico: kernel-escape). Wil je die laag óók
sluiten: op **Linux** het makkelijkst door de sandbox in een **VM** te draaien
(podman in Lima/Multipass) — `docs/maximale-isolatie-linux.md` (met Kata/gVisor
als alternatieven). Op **Mac/Windows** is die kernel-grens er al (Docker
Desktop/Rancher/`podman machine` draaien in een VM).
