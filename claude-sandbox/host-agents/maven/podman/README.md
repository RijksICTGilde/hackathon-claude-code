# Maven + Testcontainers via rootless Podman-in-Docker

Draai Testcontainers **ín** de sandbox via rootless Podman — zonder host-agent,
`--privileged` of Docker-socket. Hiermee vervalt de container→host
code-execution-bridge van de Maven host-agent (issue #44): `mvn`/pom-plugins
draaien in de sandbox (non-root `claude`), Testcontainers-containers zijn geneste
rootless-userns-children. Dit **beoogt de Maven host-agent te vervangen**: als
deze opzet breed bevestigd is (zie "Openstaand"), kan de host-agent weg. Tot die
tijd blijft de host-agent beschikbaar (zie ADR 0001).

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

## Per-setup matrix
| Host-setup | Wat nodig is |
|---|---|
| Gehardend Ubuntu 23.10+ / Tuxedo (`sysctl=1`) | `setup-host.sh` (laadt AppArmor-`userns`-profiel) + `compose.override.podman-linux.yml` |
| Linux Docker, niet-gehardend (`sysctl=0`) | `compose.override.podman-linux.yml`; AppArmor-profiel onschadelijk (of override → `apparmor=unconfined`) |
| **macOS Podman-machine** (`applehv` → Fedora CoreOS) | **bevestigd** — `compose.override.podman-macos.yml` + `podman-compose`; geen `setup-host.sh`. Zie "macOS" hieronder |
| **Rancher Desktop op macOS** (Lima → Alpine, moby) | **bevestigd** — `compose.override.podman-macos.yml` via Rancher's eigen `docker compose`; geen `setup-host.sh`, geen `podman-compose`. Zie "Rancher Desktop" hieronder |
| Docker Desktop (Mac/Win) | nog te verifiëren — zelfde vorm als Rancher Desktop; die route is een startpunt |

Check je host: `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns`.

**Beperking van de default (single-uid):** images die naar een tweede uid
chownen starten niet — `chown: ...: Invalid argument`. Dat treft postgres, mysql,
mariadb en de meeste DB-images. Heb je die nodig: zie "Multi-uid" hieronder.

## Stappen (op de host)

1. In `.env` zetten (vóór de build):
   ```
   INSTALL_PODMAN=true
   # Firewall whitelist bevat geen registries; Testcontainers pullt van docker.io.
   ALLOWED_DOMAINS=registry-1.docker.io,auth.docker.io,production.cloudflare.docker.com,docker.io
   ```
2. **AppArmor-profiel laden** (gehardende host; onschadelijk elders):
   ```
   ./host-agents/maven/podman/setup-host.sh
   ```
   Dit installeert `claude-sandbox-podman` in `/etc/apparmor.d/` en laadt het.
   De override verwijst ernaar; zonder dit faalt de container-start met
   "AppArmor profile not found".
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
      /home/claude/projects/<repo>/claude-sandbox/host-agents/maven/podman/smoke-test.sh"
   ```
   Pas `<repo>` aan naar waar deze repo in `/home/claude/projects` gemount staat.

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
   /home/claude/projects/<repo>/claude-sandbox/host-agents/maven/podman/smoke-test.sh"
```

De `single mapping`/`Additional gid ... not present`-warnings zijn verwacht: de
image draait bewust single-uid (geen `claude:`-regel in `/etc/subuid`).

### Eigen build draaien (env-samenvatting)
Voor een echte Maven-build met Testcontainers in de container:
```
export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"; mkdir -p "$XDG_RUNTIME_DIR"
podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" &
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="$XDG_RUNTIME_DIR/podman/podman.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
export TESTCONTAINERS_HOST_OVERRIDE=localhost
```

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

## Fallbacks als het niet meteen draait

| Symptoom | Oorzaak | Maatregel |
|---|---|---|
| `unshare ... uid_map: Operation not permitted` of `podman info` faalt op userns | host-hardening blokkeert userns; profiel niet (goed) geladen | `setup-host.sh` gedraaid? `cat /proc/self/attr/current` in de container → moet `claude-sandbox-podman` zijn. Container ná het laden **recreaten** (`--force-recreate`) — de AppArmor-mediatie klikt vast bij start. |
| `newuidmap: write to uid_map failed: Operation not permitted` | multi-uid (subuid-entry aanwezig) zonder `CAP_SYS_ADMIN` | óf `compose.override.podman-multiuid.yml` meestapelen, óf terug naar single-uid (`PODMAN_MULTIUID=false` + rebuild). Check `cat /etc/subuid` in de container: `claude:`-regel = multi-uid. De entrypoint waarschuwt hier bij de start al voor. |
| `chown: ...: Invalid argument` bij een DB-image, of Testcontainers meldt `Container did not start correctly` | single-uid: de image chownt naar een uid die niet in de namespace bestaat | multi-uid aanzetten — zie "Multi-uid (opt-in)" hierboven |
| `podman info` faalt op storage / `overlay` werkt niet | `PODMAN_STORAGE_DRIVER=overlay` maar `/dev/fuse`-device niet doorgegeven | entrypoint valt automatisch terug op vfs + waarschuwt; uncomment de `/dev/fuse`-device in de override of blijf op `vfs` (default) |
| `pasta failed: Failed to open() /dev/net/tun` | rootless netwerk-backend mist het tun-device | override geeft `/dev/net/tun` door; ontbreekt het op de host: `sudo modprobe tun`. NET_ADMIN heeft de sandbox al. |
| `crun: open /proc/sys/net/ipv4/ping_group_range: Read-only file system` | podman zet default deze sysctl; `/proc/sys` is RO in de outer container | `~/.config/containers/containers.conf` → `[containers]\ndefault_sysctls = []` (entrypoint schrijft dit bij start) |
| `mount proc: Operation not permitted` | Docker maskeert `/proc`; geneste procfs-mount geweigerd | override staat op `systempaths=unconfined` |
| `graphOptions: {}` / `ignore_chown_errors` ontbreekt | storage.conf landde niet (bestaand volume schaduwt de baked-in versie) | entrypoint schrijft hem bij start; bij een oud volume eenmalig handmatig: zie `entrypoint.sh`-blok, of recreate met een verse `claude-home` |
| image-extractie faalt op chown | single-uid kan niet naar andere uids chownen | `ignore_chown_errors=true` staat al in storage.conf; controleer dat het meekwam (`podman info` → graphOptions) |
| syscall/permission errors bij `podman run` of een build | tailored seccomp-blocklist (`seccomp/podman-sandbox.json`) blokkeert een syscall die jouw workload tóch nodig heeft | haal die syscall uit het profiel, of zet tijdelijk `seccomp=unconfined`. Pad is relatief t.o.v. het compose-bestand → draai compose vanuit `claude-sandbox/`. |
| `opening seccomp profile failed: open {"defaultAction"...}: file name too long` (macOS) | `podman compose` delegeert naar `docker-compose`, dat het profiel inline (als JSON) meestuurt i.p.v. als pad | draai via `podman-compose` (zie macOS-sectie); die geeft het pad door |
| `opening seccomp profile failed: open ...: no such file or directory` (macOS) | relatief seccomp-pad; podman leest client-side op de Mac | macOS-override gebruikt absoluut pad (`${PWD}/...`); draai compose vanuit `claude-sandbox/` |
| `/bin/sh: [[: not found` / `SHELL is not supported for OCI image format` (podman build) | podman's builder bouwt OCI-formaat en negeert de `SHELL`-bash-instructie | bouw met `BUILDAH_FORMAT=docker` |
| image-pull hangt/timeout | firewall blokkeert registry | `ALLOWED_DOMAINS` uit stap 1 toevoegen en container herstarten |
| Ryuk-container faalt | reaper in nested rootless | `TESTCONTAINERS_RYUK_DISABLED=true` (staat al in de smoke-test) |
| `Timed out waiting for container port to open` (host bv. `10.88.0.1`) | rootless podman publisht op localhost; Testcontainers resolvet de netavark bridge-gateway | `TESTCONTAINERS_HOST_OVERRIDE=localhost` (staat in de smoke-test; zet hem ook in je eigen build-env) |

## Openstaand
- Docker Desktop (Mac/Windows) verifiëren. Rancher Desktop op macOS is bevestigd.
- Multi-uid is bevestigd op Rancher/macOS; op gehardend Ubuntu nog niet getest
  (blokkade #1 — de AppArmor-userns-restrictie — staat daar los van en blijft).
- seccomp/apparmor verder verfijnen van de huidige stand (zie spec).

## Maximale isolatie (eigen kernel)
Deze opzet deelt de host-kernel (restrisico: kernel-escape). Wil je die laag óók
sluiten: op **Linux** het makkelijkst door de sandbox in een **VM** te draaien
(podman in Lima/Multipass) — `docs/maximale-isolatie-linux.md` (met Kata/gVisor
als alternatieven). Op **Mac/Windows** is die kernel-grens er al (Docker
Desktop/Rancher/`podman machine` draaien in een VM).
