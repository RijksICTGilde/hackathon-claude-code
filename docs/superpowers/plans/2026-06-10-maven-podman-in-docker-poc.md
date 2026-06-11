# Maven Podman-in-Docker PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sandbox-container optioneel uitrusten met rootless Podman zodat Maven+Testcontainers ín de container draait, zonder host-bridge, `--privileged` of Docker-socket.

**Architecture:** Build-ARG `INSTALL_PODMAN` voegt rootless Podman + fuse-overlayfs + uidmap toe aan de image. Een compose-override levert `/dev/fuse` en de seccomp-stand. Een smoke-test + minimaal Testcontainers-project bewijst dat nested rootless containers werken. Alles los testbaar door de gebruiker op de host; deze omgeving heeft geen runtime.

**Tech Stack:** Debian 13 (trixie) `podman`/`fuse-overlayfs`/`uidmap`/`passt`/`slirp4netns`, Docker Compose, Maven, Testcontainers (JUnit 5).

**Verificatie-noot:** Geen container-runtime in deze werkomgeving. "Run"-stappen markeren wat de gebruiker op de host draait; de implementatie-agent maakt alleen de bestanden en checkt ze statisch (shellcheck/yaml-lint/`docker build` indien beschikbaar).

---

## File Structure

| Bestand | Verantwoordelijkheid |
|---|---|
| `claude-sandbox/Dockerfile` | Conditioneel rootless Podman installeren (ARG) |
| `claude-sandbox/compose.yml` | `INSTALL_PODMAN`-arg doorgeven (default false) |
| `claude-sandbox/.env.sample` | `INSTALL_PODMAN`-flag documenteren |
| `claude-sandbox/compose.override.podman.yml` | runtime: `/dev/fuse` + seccomp |
| `claude-sandbox/host-agents/maven/podman/sample/pom.xml` | minimaal Maven-project |
| `claude-sandbox/host-agents/maven/podman/sample/src/test/java/poc/SmokeIT.java` | één Testcontainers-test |
| `claude-sandbox/host-agents/maven/podman/smoke-test.sh` | rootless-podman + Testcontainers smoke |
| `claude-sandbox/host-agents/maven/podman/README.md` | run-stappen, `ALLOWED_DOMAINS`, fallbacks |

---

## Task 1: Dockerfile — rootless Podman achter een ARG

**Files:**
- Modify: `claude-sandbox/Dockerfile` (nieuwe ARG bij de andere ARGs; nieuw root-blok vóór de finale `USER claude`)

- [ ] **Step 1: ARG declareren**

Voeg bij de andere `ARG`-regels (rond regel 14) toe:

```dockerfile
ARG INSTALL_PODMAN=false
```

- [ ] **Step 2: Conditioneel install-blok toevoegen**

Direct ná het firewall-`USER root`-blok (na regel 225, `chmod 0440 ...`) en vóór de daaropvolgende `USER claude`:

```dockerfile
# Optioneel: rootless Podman voor Maven+Testcontainers ín de container
# (alternatief voor de host-agent-bridge; zie docs/superpowers/specs/
# 2026-06-10-maven-podman-in-docker-design.md). Default uit — alleen nodig als
# je Testcontainers nested wil draaien i.p.v. via de host.
RUN case "$INSTALL_PODMAN" in \
      true) apt-get update && \
            apt-get install -y --no-install-recommends \
              podman fuse-overlayfs uidmap passt slirp4netns && \
            apt-get clean && rm -rf /var/lib/apt/lists/* && \
            # subuid/subgid-range voor rootless mapping (idempotent) \
            grep -q '^claude:' /etc/subuid || echo 'claude:100000:65536' >> /etc/subuid && \
            grep -q '^claude:' /etc/subgid || echo 'claude:100000:65536' >> /etc/subgid ;; \
      false) echo "INFO: INSTALL_PODMAN=false — rootless Podman overgeslagen" ;; \
      *) echo "FOUT: INSTALL_PODMAN='$INSTALL_PODMAN' is ongeldig (verwacht: 'true' of 'false')" >&2; exit 1 ;; \
    esac
```

- [ ] **Step 3: rootless storage.conf als `claude` schrijven**

Ná het install-blok, onder `USER claude` (de bestaande finale switch), de fuse-overlayfs-config neerzetten. `/home/claude` wordt op een named volume gepopulate bij eerste run (zelfde mechanisme als sdkman/.claude), dus dit komt mee:

```dockerfile
RUN if [ "$INSTALL_PODMAN" = "true" ]; then \
      mkdir -p /home/claude/.config/containers && \
      printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' \
        > /home/claude/.config/containers/storage.conf ; \
    fi
```

- [ ] **Step 4: Statisch checken**

Run (host, indien Docker aanwezig): `docker build --build-arg INSTALL_PODMAN=true -t sb-podman-test claude-sandbox`
Expected: build slaagt; `docker run --rm sb-podman-test command -v podman` → pad.
In deze omgeving: alleen visuele review + `grep -n INSTALL_PODMAN claude-sandbox/Dockerfile` toont 3 plekken.

- [ ] **Step 5: Commit**

```bash
git add claude-sandbox/Dockerfile
git commit -m "feat(sandbox): optioneel rootless Podman via INSTALL_PODMAN (#44)"
```

---

## Task 2: compose.yml + .env.sample — ARG doorgeven

**Files:**
- Modify: `claude-sandbox/compose.yml` (build.args)
- Modify: `claude-sandbox/.env.sample`

- [ ] **Step 1: build-arg toevoegen**

In `compose.yml` onder `build.args`, ná `INSTALL_CAVEMAN`. Afwijkend van het `:?`-patroon gebruiken we hier een default zodat bestaande `.env`-bestanden niet breken op een nieuwe optionele flag:

```yaml
        # Optioneel, default false: nieuwe flag mag bestaande .env niet breken.
        INSTALL_PODMAN: "${INSTALL_PODMAN:-false}"
```

- [ ] **Step 2: .env.sample documenteren**

Voeg een regel toe bij de andere `INSTALL_*`-flags:

```
# Rootless Podman in de container (Maven+Testcontainers zonder host-agent). Default false.
INSTALL_PODMAN=false
```

- [ ] **Step 3: Check**

Run: `cd claude-sandbox && docker compose config >/dev/null && echo OK` (host).
In deze omgeving: `grep -n INSTALL_PODMAN claude-sandbox/compose.yml claude-sandbox/.env.sample`.

- [ ] **Step 4: Commit**

```bash
git add claude-sandbox/compose.yml claude-sandbox/.env.sample
git commit -m "feat(sandbox): INSTALL_PODMAN doorgeven via compose + .env.sample (#44)"
```

---

## Task 3: compose-override voor runtime-capabilities

**Files:**
- Create: `claude-sandbox/compose.override.podman.yml`

- [ ] **Step 1: Bestand schrijven**

```yaml
# Runtime-vereisten voor rootless Podman ín de sandbox (zie
# docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md).
# Gebruik:  docker compose -f compose.yml -f compose.override.podman.yml up --build -d
# of kopieer naar compose.override.yml (let op: overschrijft de Linux-host-override).
services:
  claude:
    devices:
      # fuse-overlayfs storage voor rootless podman
      - "/dev/fuse"
    security_opt:
      # PoC-startpunt: default-seccomp blokkeert syscalls die nested rootless
      # podman nodig heeft. Begin met unconfined; verfijn naar een gericht
      # profiel zodra de PoC draait (verzwakt anders de outer sandbox).
      - "seccomp=unconfined"
      # Nodig op SELinux-hosts (Fedora/RHEL); no-op elders.
      - "label=disable"
```

- [ ] **Step 2: Check**

Run (host): `docker compose -f claude-sandbox/compose.yml -f claude-sandbox/compose.override.podman.yml config >/dev/null && echo OK`.
In deze omgeving: YAML laadt zonder syntaxfout (`python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' <file>`).

- [ ] **Step 3: Commit**

```bash
git add claude-sandbox/compose.override.podman.yml
git commit -m "feat(sandbox): compose-override voor rootless podman runtime (#44)"
```

---

## Task 4: Sample Maven+Testcontainers-project

**Files:**
- Create: `claude-sandbox/host-agents/maven/podman/sample/pom.xml`
- Create: `claude-sandbox/host-agents/maven/podman/sample/src/test/java/poc/SmokeIT.java`

- [ ] **Step 1: pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>poc</groupId>
  <artifactId>podman-testcontainers-smoke</artifactId>
  <version>0.1.0</version>
  <properties>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.testcontainers</groupId>
        <artifactId>testcontainers-bom</artifactId>
        <version>1.20.4</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <version>5.11.3</version>
      <scope>test</scope>
    </dependency>
    <dependency>
      <groupId>org.testcontainers</groupId>
      <artifactId>junit-jupiter</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.2</version>
      </plugin>
    </plugins>
  </build>
</project>
```

- [ ] **Step 2: SmokeIT.java** — lichte image (`alpine`), geen DB, om de pull klein te houden:

```java
package poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers
class SmokeIT {

    @Container
    GenericContainer<?> alpine =
            new GenericContainer<>("alpine:3.20").withCommand("sleep", "300");

    @Test
    void containerStartsViaPodman() {
        assertTrue(alpine.isRunning(), "Testcontainers kon geen nested container starten");
    }
}
```

- [ ] **Step 3: Check**

Run (host, in de container): via `smoke-test.sh` (Task 5). Standalone: `mvn -q -f .../sample test`.
In deze omgeving: XML/Java visueel reviewen; `python3 -c 'import xml.dom.minidom as m; m.parse(sys.argv[1])'` op de pom.

- [ ] **Step 4: Commit**

```bash
git add claude-sandbox/host-agents/maven/podman/sample
git commit -m "test(maven-podman): sample Testcontainers-project voor PoC (#44)"
```

---

## Task 5: smoke-test.sh

**Files:**
- Create: `claude-sandbox/host-agents/maven/podman/smoke-test.sh`

- [ ] **Step 1: Script schrijven**

```bash
#!/usr/bin/env bash
# Draai BINNEN de sandbox-container (met INSTALL_PODMAN=true gebouwd en de
# podman compose-override actief). Bewijst dat rootless Podman nested containers
# en een Testcontainers-build kan draaien.
set -euo pipefail

# Rootless podman heeft een schrijfbare XDG_RUNTIME_DIR nodig; in een container
# zonder systemd bestaat /run/user/<uid> vaak niet. Maak er zelf een.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/podman-run-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "== 1. podman info (rootless) =="
podman info --format '{{.Host.Security.Rootless}} driver={{.Store.GraphDriverName}}'

echo "== 2. nested container =="
podman run --rm alpine:3.20 echo "nested-ok"

echo "== 3. podman socket service =="
SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"
podman system service --time=0 "unix://$SOCK" &
SVC=$!
trap 'kill "$SVC" 2>/dev/null || true' EXIT
# Wachten tot de socket er is (max ~10s)
for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "FOUT: podman-socket kwam niet op" >&2; exit 1; }

echo "== 4. Maven + Testcontainers =="
export DOCKER_HOST="unix://$SOCK"
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="$SOCK"
# Ryuk (resource-reaper) is in nested rootless setups vaak instabiel; uit voor de PoC.
export TESTCONTAINERS_RYUK_DISABLED=true
cd "$(dirname "$0")/sample"
mvn -B --no-transfer-progress test

echo "== PoC GESLAAGD =="
```

- [ ] **Step 2: Uitvoerbaar maken**

```bash
chmod +x claude-sandbox/host-agents/maven/podman/smoke-test.sh
```

- [ ] **Step 3: Check**

Run: `shellcheck claude-sandbox/host-agents/maven/podman/smoke-test.sh` (indien beschikbaar) → geen errors.
Echt draaien: in de container `./smoke-test.sh` (host-stap).

- [ ] **Step 4: Commit**

```bash
git add claude-sandbox/host-agents/maven/podman/smoke-test.sh
git commit -m "test(maven-podman): smoke-test rootless podman + Testcontainers (#44)"
```

---

## Task 6: podman/README.md

**Files:**
- Create: `claude-sandbox/host-agents/maven/podman/README.md`

- [ ] **Step 1: README schrijven** — exacte run-stappen, `ALLOWED_DOMAINS` voor registry-egress, en de fallbacks uit de spec (vfs-storage, seccomp, single-uid, Ryuk). Inhoud:

```markdown
# PoC: Maven + Testcontainers via rootless Podman-in-Docker

Bewijst dat de sandbox Testcontainers nested kan draaien (issue #44), zonder
host-agent, `--privileged` of Docker-socket. Ontwerp:
`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`.

## Stappen (op de host)

1. Image bouwen met Podman erin en JDK/Maven beschikbaar:
   ```
   echo "INSTALL_PODMAN=true" >> claude-sandbox/.env   # of in .env.sample-kopie
   cd claude-sandbox
   docker compose -f compose.yml -f compose.override.podman.yml up --build -d
   ```
2. Registry-egress toestaan (firewall whitelist bevat geen registries). Zet in
   `.env` vóór stap 1:
   ```
   ALLOWED_DOMAINS=registry-1.docker.io,auth.docker.io,production.cloudflare.docker.com,docker.io
   ```
3. In de container een JDK+Maven regelen (eenmalig):
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && sdk install java && sdk install maven"
   ```
4. Smoke-test draaien:
   ```
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && \
      host-agents/maven/podman/smoke-test.sh"
   ```
   (pad relatief vanaf `/home/claude/projects` als de repo daar gemount staat;
   anders het absolute pad gebruiken.)

Verwacht: stappen 1–4 in het script printen `nested-ok` en eindigen met
`PoC GESLAAGD`.

## Fallbacks als het niet meteen draait

| Symptoom | Oorzaak | Maatregel |
|---|---|---|
| `podman info` faalt op storage | `/dev/fuse` niet door | override `/dev/fuse` controleren; anders `storage.conf` → `driver = "vfs"` (traag) |
| syscall/permission errors bij `podman run` | seccomp | override staat al op `seccomp=unconfined`; controleer dat de override actief is |
| `newuidmap: write to uid_map failed` | subuid/caps in outer container | terugval: podman met `--userns=keep-id` of single-uid mapping |
| image-pull hangt/timeout | firewall blokkeert registry | `ALLOWED_DOMAINS` uit stap 2 toevoegen en container herstarten |
| Ryuk-container faalt | reaper in nested rootless | `TESTCONTAINERS_RYUK_DISABLED=true` (staat al in de smoke-test) |

## Noteer voor de afweging (#44 DoD)

- Welke seccomp-stand nodig was (unconfined vs gericht profiel).
- Storage-driver (overlay/fuse vs vfs) en globale build-tijd.
- Of subuid-mapping werkte of single-uid fallback nodig was.
```

- [ ] **Step 2: Commit**

```bash
git add claude-sandbox/host-agents/maven/podman/README.md
git commit -m "docs(maven-podman): PoC run-instructies + fallbacks (#44)"
```

---

## Self-Review

- **Spec coverage:** Dockerfile/compose/override/sample/smoke-test/README ⇄ artefacten-tabel spec → compleet. Onzekerheden (seccomp/fuse/subuid/egress/Ryuk/performance) ⇄ override-comment + README-fallbacktabel + "noteer voor afweging". Succescriteria ⇄ smoke-test stappen 1–4.
- **Placeholders:** geen TBD/TODO; alle code voluit.
- **Type/naam-consistentie:** `INSTALL_PODMAN` identiek in Dockerfile/compose/.env; socket-pad `$XDG_RUNTIME_DIR/podman/podman.sock` consistent in smoke-test; `seccomp=unconfined` consistent override↔README.

## Out of scope (YAGNI)

- Host-agent verwijderen of MCP-tool aanpassen (pas ná geslaagde PoC).
- `maven-mcp-agent.md`/`SECURITY.md`/ADR definitief bijwerken (#44-DoD volgt op PoC-uitslag).
- `podman machine` voor Mac/Windows-host (niet nodig — Podman draait ín de Linux-container).
