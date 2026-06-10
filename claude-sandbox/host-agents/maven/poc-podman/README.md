# PoC: Maven + Testcontainers via rootless Podman-in-Docker

Bewijst dat de sandbox Testcontainers nested kan draaien (issue #44), zonder
host-agent, `--privileged` of Docker-socket. Ontwerp + PoC-bevindingen:
`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`.

## Status: GESLAAGD
Op een gehardende host (Tuxedo OS, Ubuntu-based, `sysctl=1`) draaide de
Testcontainers-smoke echt groen (`Tests run: 1, Failures: 0, Errors: 0`). Op een
écht project bevestigd: een Quarkus-module met Redis-stack Dev-Services +
integratietests draaide **289 + 46 tests groen** via podman in de sandbox — pas
mét `TESTCONTAINERS_HOST_OVERRIDE=localhost` (zie hieronder).

## Wat de PoC uitwees
Op gehardende Ubuntu/Tuxedo (`kernel.apparmor_restrict_unprivileged_userns=1`)
werkt de naïeve multi-uid rootless podman **niet**: de host blokkeert userns-maps
en de privileged `newuidmap`-range faalt. Daarom draait deze set in **single-uid
modus** (geen `newuidmap`) en regelt userns via een **custom AppArmor-profiel**
i.p.v. de host systeembreed te verzwakken. De volledige keten van zeven
aanpassingen + de security-balans staan in de spec
(`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`).

## Per-setup matrix
| Host-setup | Wat nodig is |
|---|---|
| Gehardend Ubuntu 23.10+ / Tuxedo (`sysctl=1`) | `setup-host.sh` (laadt AppArmor-`userns`-profiel) + override |
| Linux Docker, niet-gehardend (`sysctl=0`) | override; AppArmor-profiel onschadelijk (of override → `apparmor=unconfined`) |
| Docker Desktop / Rancher (Mac/Win) | override; nog te testen — vermoedelijk out-of-the-box |

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
   ./host-agents/maven/poc-podman/setup-host.sh
   ```
   Dit installeert `claude-sandbox-podman` in `/etc/apparmor.d/` en laadt het.
   De override verwijst ernaar; zonder dit faalt de container-start met
   "AppArmor profile not found".
3. Image bouwen + starten met de runtime-override (`/dev/fuse`, seccomp, profiel):
   ```
   cd claude-sandbox
   docker compose -f compose.yml -f compose.override.podman.yml.example up --build -d --force-recreate
   ```
4. JDK+Maven in de container (eenmalig, blijft in het claude-home volume):
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && sdk install java && sdk install maven"
   ```
5. Smoke-test:
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && \
      /home/claude/projects/<repo>/claude-sandbox/host-agents/maven/poc-podman/smoke-test.sh"
   ```
   Pas `<repo>` aan naar waar deze repo in `/home/claude/projects` gemount staat.

Verwacht: het script print `nested-ok` en eindigt met `PoC GESLAAGD`.

## Fallbacks als het niet meteen draait

| Symptoom | Oorzaak | Maatregel |
|---|---|---|
| `unshare ... uid_map: Operation not permitted` of `podman info` faalt op userns | host-hardening blokkeert userns; profiel niet (goed) geladen | `setup-host.sh` gedraaid? `cat /proc/self/attr/current` in de container → moet `claude-sandbox-podman` zijn. Container ná het laden **recreaten** (`--force-recreate`) — de AppArmor-mediatie klikt vast bij start. |
| `newuidmap: write to uid_map failed` | je draait toch multi-uid (subuid-entry aanwezig) | image is single-uid (geen subuid). Check `cat /etc/subuid` in de container → geen `claude:`-regel. |
| `podman info` faalt op storage | `/dev/fuse` niet door | override `/dev/fuse` controleren; anders `~/.config/containers/storage.conf` → `driver = "vfs"` (traag, geen fuse) |
| `pasta failed: Failed to open() /dev/net/tun` | rootless netwerk-backend mist het tun-device | override geeft `/dev/net/tun` door; ontbreekt het op de host: `sudo modprobe tun`. NET_ADMIN heeft de sandbox al. |
| `crun: open /proc/sys/net/ipv4/ping_group_range: Read-only file system` | podman zet default deze sysctl; `/proc/sys` is RO in de outer container | `~/.config/containers/containers.conf` → `[containers]\ndefault_sysctls = []` (entrypoint schrijft dit nu bij start) |
| `graphOptions: {}` / `ignore_chown_errors` ontbreekt | storage.conf landde niet (bestaand volume schaduwt de baked-in versie) | entrypoint schrijft hem nu bij start; bij een oud volume eenmalig handmatig: zie `entrypoint.sh`-blok, of recreate met een verse `claude-home` |
| image-extractie faalt op chown | single-uid kan niet naar andere uids chownen | `ignore_chown_errors=true` staat al in storage.conf; controleer dat het meekwam (`podman info` → graphOptions) |
| syscall/permission errors bij `podman run` of een build | tailored seccomp-blocklist (`seccomp/podman-sandbox.json`) blokkeert een syscall die jouw workload tóch nodig heeft | haal die syscall uit het profiel, of zet tijdelijk `seccomp=unconfined`. Pad is relatief t.o.v. het compose-bestand → draai compose vanuit `claude-sandbox/`. |
| image-pull hangt/timeout | firewall blokkeert registry | `ALLOWED_DOMAINS` uit stap 1 toevoegen en container herstarten |
| Ryuk-container faalt | reaper in nested rootless | `TESTCONTAINERS_RYUK_DISABLED=true` (staat al in de smoke-test) |
| `Timed out waiting for container port to open` (host bv. `10.88.0.1`) | rootless podman publisht op localhost; Testcontainers resolvet de netavark bridge-gateway | `TESTCONTAINERS_HOST_OVERRIDE=localhost` (staat nu in de smoke-test; zet hem ook in je eigen build-env) |

## Noteer voor de afweging (#44 DoD)

- Werkt single-uid podman onder het AppArmor-`userns`-profiel (sysctl blijft 1)?
- Draait een echte Testcontainers-build (Ryuk/Postgres) met `ignore_chown_errors`,
  of breken images die naar meerdere uids chownen?
- Welke seccomp-stand nodig was; storage-driver (fuse-overlayfs vs vfs) + build-tijd.

Slaagt dit → uitwerken als optioneel pad (alleen projecten die Testcontainers
nodig hebben), host-agent blijft fallback, #44-DoD (doc/ADR) afronden met deze
keuze en de security-trade-off van het unconfined-profiel.
