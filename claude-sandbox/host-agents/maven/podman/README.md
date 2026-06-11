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
| Docker Desktop / Rancher Desktop (Mac/Win) | nog te verifiëren — VM is Linux zonder de Ubuntu-userns-restrictie; macOS-override is een startpunt |

Check je host: `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns`.

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
   `PODMAN_STORAGE_DRIVER=overlay` + `PODMAN_FUSE_DEVICE=/dev/fuse` (fuse-overlayfs;
   groter kernel-aanvaloppervlak) en recreate. Wisselen vereist eenmalig
   `podman system reset` in de container.
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

## Fallbacks als het niet meteen draait

| Symptoom | Oorzaak | Maatregel |
|---|---|---|
| `unshare ... uid_map: Operation not permitted` of `podman info` faalt op userns | host-hardening blokkeert userns; profiel niet (goed) geladen | `setup-host.sh` gedraaid? `cat /proc/self/attr/current` in de container → moet `claude-sandbox-podman` zijn. Container ná het laden **recreaten** (`--force-recreate`) — de AppArmor-mediatie klikt vast bij start. |
| `newuidmap: write to uid_map failed` | je draait toch multi-uid (subuid-entry aanwezig) | image is single-uid (geen subuid). Check `cat /etc/subuid` in de container → geen `claude:`-regel. |
| `podman info` faalt op storage / `overlay` werkt niet | `PODMAN_STORAGE_DRIVER=overlay` maar `/dev/fuse` ontbreekt | entrypoint valt automatisch terug op vfs + waarschuwt; zet `PODMAN_FUSE_DEVICE=/dev/fuse` in `.env` of blijf op `vfs` (default) |
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
- Docker Desktop / Rancher Desktop (Mac/Windows) verifiëren.
- seccomp/apparmor verder verfijnen van de huidige stand (zie spec).
