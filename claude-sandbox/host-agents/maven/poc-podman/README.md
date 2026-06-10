# PoC: Maven + Testcontainers via rootless Podman-in-Docker

Bewijst dat de sandbox Testcontainers nested kan draaien (issue #44), zonder
host-agent, `--privileged` of Docker-socket. Ontwerp:
`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`.

## Stappen (op de host)

1. In `.env` zetten (vóór de build):
   ```
   INSTALL_PODMAN=true
   # Firewall whitelist bevat geen registries; Testcontainers pullt van docker.io.
   ALLOWED_DOMAINS=registry-1.docker.io,auth.docker.io,production.cloudflare.docker.com,docker.io
   ```
2. Image bouwen met Podman erin en de runtime-override (geeft `/dev/fuse` + seccomp):
   ```
   cd claude-sandbox
   docker compose -f compose.yml -f compose.override.podman.yml.example up --build -d
   ```
3. In de container een JDK+Maven regelen (eenmalig, blijft in het claude-home volume):
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && sdk install java && sdk install maven"
   ```
4. Smoke-test draaien:
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
| `podman info` faalt op storage | `/dev/fuse` niet door | override `/dev/fuse` controleren; anders `~/.config/containers/storage.conf` → `driver = "vfs"` (traag, geen fuse nodig) |
| syscall/permission errors bij `podman run` | seccomp | override staat al op `seccomp=unconfined`; controleer dat de override actief is (`docker inspect`) |
| `newuidmap: write to uid_map failed: Operation not permitted` | AppArmor `docker-default` blokkeert de write naar `/proc/<pid>/uid_map` (Debian/Ubuntu) | override staat op `apparmor=unconfined`; check `cat /proc/self/attr/current` in de container → moet `unconfined` zijn, niet `docker-default (enforce)`. Caps/subuid zijn hier NIET de oorzaak als `/proc/self/uid_map` = `0 0 4294967295`. |
| image-pull hangt/timeout | firewall blokkeert registry | `ALLOWED_DOMAINS` uit stap 1 toevoegen en container herstarten |
| Ryuk-container faalt | reaper in nested rootless | `TESTCONTAINERS_RYUK_DISABLED=true` (staat al in de smoke-test) |

## Noteer voor de afweging (#44 DoD)

- Welke seccomp-stand nodig was (unconfined vs gericht profiel).
- Storage-driver (overlay/fuse-overlayfs vs vfs) en globale build-/test-tijd.
- Of subuid-mapping werkte of de single-uid fallback nodig was.

Slaagt de PoC → uitwerken als aanbevolen pad, host-agent degraderen tot fallback,
en de #44-DoD (doc + ADR) afronden met deze keuze.
