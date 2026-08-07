# Host-bridge verwijderen en sandbox harden — implementatieplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** De Maven host-agent verwijderen, de podman-in-sandbox-set een eigen plek geven, en de container-escape uit de security-review op PR #76 sluiten.

**Architecture:** Twee gestapelde PR's. PR A verplaatst en verwijdert zonder gedrag te veranderen. PR B vervangt de NOPASSWD-sudoers-route door een root-entrypoint dat na de firewall onherroepelijk naar `claude` dropt, en zet een AppArmor-profiel neer dat daadwerkelijk mediateert in plaats van `flags=(unconfined)`.

**Tech Stack:** Bash, Docker Compose, Dockerfile, AppArmor, seccomp (OCI JSON), rootless Podman. Documentatie in Markdown, Nederlands.

## Global Constraints

- Ontwerpdocument: `docs/superpowers/specs/2026-08-03-host-bridge-verwijderen-en-sandbox-hardening-design.md`. Bij twijfel is de spec leidend.
- Alle documentatie, comments en commit-berichten in het Nederlands. Code, CLI-commando's, foutmeldingen en commit-type-keywords (`feat`/`fix`/`docs`/`refactor`) blijven Engels.
- Commit-berichten: conventional commits met scope en issue-referentie, bijvoorbeeld `refactor(sandbox): podman-set naar claude-sandbox/podman/ (#44)`. Elke commit eindigt op `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- `shellcheck --severity=warning` moet schoon zijn op elk gewijzigd of verplaatst shell-script. De CI draait dit op alle tracked shell scripts.
- Er is **geen docker** in de ontwikkelomgeving, wel `podman`. Elke stap die een draaiende container nodig heeft, is een handmatige stap voor de gebruiker en wordt als zodanig gemarkeerd. Nooit rapporteren dat iets werkt op grond van een niet-gedraaide test.
- Bestandsverplaatsingen met `git mv`, zodat de historie meeloopt.
- Branches: PR A op `feat/verwijder-maven-host-bridge` (base `feat/podman-multiuid-optin`), PR B op `feat/sandbox-hardening` (base `feat/verwijder-maven-host-bridge`).
- De container-user heet `claude`, aangemaakt met `useradd -m -s /bin/zsh claude` op `Dockerfile:89`. Hij zit in geen enkele extra groep.

---

## Bestandsstructuur

### PR A

| Actie | Pad | Verantwoordelijkheid na de wijziging |
|---|---|---|
| Verwijderen | `claude-sandbox/host-agents/maven/maven_agent.py` | — |
| Verwijderen | `claude-sandbox/host-agents/maven/run.sh` | — |
| Verwijderen | `claude-sandbox/host-agents/maven/requirements.in` | — |
| Verwijderen | `claude-sandbox/host-agents/maven/requirements.txt` | — |
| Verwijderen | `claude-sandbox/docs/maven-mcp-agent.md` | — |
| Verplaatsen | `claude-sandbox/host-agents/maven/podman/` → `claude-sandbox/podman/` | Alles wat podman-in-de-sandbox nodig heeft |
| Wijzigen | `claude-sandbox/compose.override.podman-linux.yml` | Seccomp-pad |
| Wijzigen | `claude-sandbox/compose.override.podman-macos.yml` | Seccomp-pad |
| Wijzigen | `claude-sandbox/Dockerfile` | Comment bij het podman-blok |
| Wijzigen | `claude-sandbox/.env.sample` | Tekst "host-agent-bridge" |
| Wijzigen | `claude-sandbox/README.md` | Verwijzingen |
| Wijzigen | `claude-sandbox/docs/opstarten-en-afsluiten.md` | Verwijzing |
| Wijzigen | `docs/maximale-isolatie-linux.md` | Verwijzing |
| Wijzigen | `docs/adr/0001-maven-testcontainers-sandbox-isolatie.md` | Status Geaccepteerd, één spoor |
| Wijzigen | `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md` | Padverwijzingen |
| Wijzigen | `docs/superpowers/plans/2026-06-10-maven-podman-in-docker-poc.md` | Padverwijzingen |
| Wijzigen | `claude-sandbox/podman/README.md` | Zelfverwijzingen, dekkingsgat |

### PR B

| Actie | Pad | Verantwoordelijkheid na de wijziging |
|---|---|---|
| Aanmaken | `claude-sandbox/entrypoint-root.sh` | Firewall opzetten als root, daarna droppen naar `claude` |
| Aanmaken | `claude-sandbox/docs/hardening-verificatie.md` | Testprotocol met negatieve tests |
| Wijzigen | `claude-sandbox/entrypoint.sh` | Alles na de drop; firewall-blok eruit |
| Wijzigen | `claude-sandbox/Dockerfile` | `USER root`, eigendom entrypoints, sudoers weg, `sudo` uit pakketlijst, root-shell-waarschuwing |
| Wijzigen | `claude-sandbox/podman/apparmor/claude-sandbox-podman` | Profiel dat mediateert |
| Wijzigen | `claude-sandbox/podman/setup-host.sh` | Profielvalidatie |
| Wijzigen | `claude-sandbox/podman/seccomp/podman-sandbox.json` | Ruimere blocklist |
| Wijzigen | `claude-sandbox/podman/README.md` | `docker compose exec -u claude` |
| Wijzigen | `claude-sandbox/docs/opstarten-en-afsluiten.md` | `docker compose exec -u claude` |
| Wijzigen | `claude-sandbox/compose.override.podman-multiuid.yml` | Security-noot bijstellen |
| Wijzigen | `docs/adr/0001-maven-testcontainers-sandbox-isolatie.md` | Security-balans |
| Wijzigen | `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md` | Onderzoeksbucket-tabel |

---

# Fase A — PR A

De branch `feat/verwijder-maven-host-bridge` bestaat al en bevat het ontwerpdocument als eerste commit.

### Task A1: Podman-set verplaatsen naar `claude-sandbox/podman/`

**Files:**
- Verplaats: `claude-sandbox/host-agents/maven/podman/` → `claude-sandbox/podman/`
- Modify: `claude-sandbox/compose.override.podman-linux.yml:48,51`
- Modify: `claude-sandbox/compose.override.podman-macos.yml` (regel met `seccomp=`)

**Interfaces:**
- Produces: het pad `claude-sandbox/podman/` met `README.md`, `setup-host.sh`, `smoke-test.sh`, `apparmor/claude-sandbox-podman`, `seccomp/podman-sandbox.json` en `sample/`. Alle latere taken verwijzen naar dit pad.

- [ ] **Step 1: Schrijf de falende controle**

Deze controle moet nú falen, want de bestanden staan er nog niet:

```bash
test -f claude-sandbox/podman/setup-host.sh \
  && test -f claude-sandbox/podman/seccomp/podman-sandbox.json \
  && ! test -d claude-sandbox/host-agents/maven/podman \
  && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Verplaats de boom**

```bash
cd /home/claude/projects/hackathon-claude-code-dev
git mv claude-sandbox/host-agents/maven/podman claude-sandbox/podman
```

- [ ] **Step 3: Werk het seccomp-pad bij in de linux-override**

In `claude-sandbox/compose.override.podman-linux.yml`, vervang:

```yaml
      - "seccomp=host-agents/maven/podman/seccomp/podman-sandbox.json"
```

door:

```yaml
      - "seccomp=podman/seccomp/podman-sandbox.json"
```

En in de comment erboven, vervang de regel:

```
      # Pad is relatief t.o.v. dit compose-bestand (draai compose vanuit claude-sandbox/).
```

door:

```
      # De Docker-CLI leest dit profiel client-side en resolvet het pad tegen de
      # huidige werkdirectory, niet tegen dit compose-bestand: draai compose dus
      # vanuit claude-sandbox/. Ontbreekt het bestand, dan faalt de start hard —
      # er is geen stille terugval naar unconfined.
```

- [ ] **Step 4: Werk het seccomp-pad bij in de macos-override**

In `claude-sandbox/compose.override.podman-macos.yml` staat het pad met `${PWD}`. Vervang `host-agents/maven/podman/seccomp/` door `podman/seccomp/` en laat de `${PWD}`-constructie ongemoeid.

- [ ] **Step 5: Draai de controle uit stap 1 opnieuw**

Verwacht nu: `PASS`

- [ ] **Step 6: Controleer dat er geen oud pad meer overblijft in de compose-bestanden**

```bash
grep -rn 'host-agents' claude-sandbox/*.yml && echo "NOG REFERENTIES" || echo "SCHOON"
```

Verwacht: `SCHOON`

- [ ] **Step 7: Shellcheck op de verplaatste scripts**

```bash
shellcheck --severity=warning claude-sandbox/podman/setup-host.sh claude-sandbox/podman/smoke-test.sh
```

Verwacht: geen output, exit 0

- [ ] **Step 8: Commit**

```bash
git add -A claude-sandbox/
git commit -m "$(cat <<'EOF'
refactor(sandbox): podman-set naar claude-sandbox/podman/ (#44)

De podman-in-sandbox-set stond in de boom van de Maven host-agent, waardoor
wijzigingen aan podman lazen als wijzigingen aan die agent. Verplaatst naar
een eigen top-level map, met de seccomp-paden in beide overrides mee.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task A2: Maven host-bridge verwijderen

**Files:**
- Delete: `claude-sandbox/host-agents/maven/maven_agent.py`
- Delete: `claude-sandbox/host-agents/maven/run.sh`
- Delete: `claude-sandbox/host-agents/maven/requirements.in`
- Delete: `claude-sandbox/host-agents/maven/requirements.txt`
- Delete: `claude-sandbox/docs/maven-mcp-agent.md`

**Interfaces:**
- Consumes: de verplaatsing uit Task A1 — `host-agents/` bevat na die taak alleen nog bridge-bestanden.
- Produces: niets. Na deze taak bestaat `claude-sandbox/host-agents/` niet meer.

- [ ] **Step 1: Schrijf de falende controle**

```bash
! test -e claude-sandbox/host-agents \
  && ! test -e claude-sandbox/docs/maven-mcp-agent.md \
  && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Verwijder de bestanden**

```bash
cd /home/claude/projects/hackathon-claude-code-dev
git rm -r claude-sandbox/host-agents
git rm claude-sandbox/docs/maven-mcp-agent.md
```

- [ ] **Step 3: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 4: Controleer dat er geen verwijzingen naar de bridge overblijven in code of config**

Documentatie komt in Task A3 aan de beurt; hier gaat het om code en config:

```bash
grep -rn 'maven_agent\|host-agents\|maven-mcp-agent' \
  --include='Dockerfile' --include='*.yml' --include='*.yaml' \
  --include='*.sh' --include='*.sample' --include='*.json' . \
  && echo "NOG REFERENTIES" || echo "SCHOON"
```

Verwacht: `SCHOON`

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(sandbox): Maven host-agent verwijderd (#44)

De host-agent draaide mvn op de host als de host-user, met pom.xml en mvnw
uit de projects-map die de sandbox kan schrijven — een container→host
code-execution-bridge. Podman-in-de-sandbox vervangt hem, dus hij kan weg.

Verwijdert ook requirements.txt (509 regels). Dependabot heeft geen
pip-entry in de config, maar security-updates scannen manifests repo-breed;
die alert-stroom vervalt hiermee.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task A3: Verwijzingen en documentatiestructuur rechttrekken

**Files:**
- Modify: `claude-sandbox/Dockerfile` (comment rond regel 230)
- Modify: `claude-sandbox/.env.sample` (regel ~50)
- Modify: `claude-sandbox/README.md` (regels 21 en 25)
- Modify: `claude-sandbox/docs/opstarten-en-afsluiten.md` (regel ~72)
- Modify: `docs/maximale-isolatie-linux.md` (regel ~8)
- Modify: `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`
- Modify: `docs/superpowers/plans/2026-06-10-maven-podman-in-docker-poc.md`
- Modify: `claude-sandbox/podman/README.md`

**Interfaces:**
- Consumes: het pad `claude-sandbox/podman/` uit Task A1.
- Produces: `claude-sandbox/podman/README.md` als enige plek met bedieningsstappen. Task A4 en alle PR B-taken verwijzen ernaar.

- [ ] **Step 1: Schrijf de falende controle**

```bash
grep -rn 'host-agents/maven\|maven-mcp-agent\|host-agent-bridge' \
  --include='*.md' --include='Dockerfile' --include='*.sample' . \
  | grep -v 'docs/superpowers/specs/2026-08-03' \
  | grep -v 'docs/superpowers/plans/2026-08-03' \
  && echo FAIL || echo PASS
```

Verwacht nu: `FAIL` met een lijst treffers. Die lijst is de werkvoorraad voor deze taak.

De twee `2026-08-03`-documenten zijn uitgezonderd omdat ze de historische situatie beschrijven en de oude paden dus mogen noemen.

- [ ] **Step 2: Dockerfile-comment**

Vervang in `claude-sandbox/Dockerfile`:

```
# Optioneel: rootless Podman voor Maven+Testcontainers ín de container
# (alternatief voor de host-agent-bridge; zie docs/superpowers/specs/
# 2026-06-10-maven-podman-in-docker-design.md). Default uit — alleen nodig als
```

door:

```
# Optioneel: rootless Podman voor Maven+Testcontainers ín de container.
# Bediening: claude-sandbox/podman/README.md. Ontwerp en meetresultaten:
# docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md.
# Default uit — alleen nodig als
```

- [ ] **Step 3: `.env.sample`**

Vervang het blok bij `INSTALL_PODMAN`:

```
# Rootless Podman in de container: Maven+Testcontainers nested draaien zonder de
# host-agent-bridge (issue #44). Default false. Bij true ook de runtime-override
# nodig (compose.override.podman.yml) voor seccomp/apparmor + netwerk.
```

door:

```
# Rootless Podman in de container: Maven+Testcontainers nested draaien (issue
# #44). Default false. Bij true is ook de runtime-override nodig voor
# seccomp/apparmor + netwerk — zie claude-sandbox/podman/README.md.
```

- [ ] **Step 4: `claude-sandbox/README.md`**

Regel 21 verwijst naar `host-agents/maven/podman/README.md`; maak daar `podman/README.md` van.

Regel 25 luidt nu:

```
- [Maven MCP-agent (host-side)](docs/maven-mcp-agent.md) — voor Maven-builds die de host-Docker nodig hebben (Testcontainers e.d.).
```

Vervang door:

```
- [Maven en Testcontainers via podman](podman/README.md) — Testcontainers draait ín de sandbox, via rootless podman. Er is geen host-side agent meer.
```

- [ ] **Step 5: `claude-sandbox/docs/opstarten-en-afsluiten.md`**

Regel ~72 verwijst naar `../host-agents/maven/podman/README.md`; maak daar `../podman/README.md` van.

- [ ] **Step 6: `docs/maximale-isolatie-linux.md`**

Regel ~8 verwijst naar `host-agents/maven/podman/README.md`; maak daar `claude-sandbox/podman/README.md` van.

- [ ] **Step 7: De twee 2026-06-10-documenten**

Vervang in beide bestanden elke voorkomen van `host-agents/maven/podman/` door `podman/`. Laat de inhoudelijke tekst verder ongemoeid — het zijn historische documenten.

```bash
sed -i 's#host-agents/maven/podman/#podman/#g' \
  docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md \
  docs/superpowers/plans/2026-06-10-maven-podman-in-docker-poc.md
```

- [ ] **Step 8: `claude-sandbox/podman/README.md` — zelfverwijzingen**

Vervang `./host-agents/maven/podman/setup-host.sh` door `./podman/setup-host.sh`, en elke andere `host-agents/maven/podman/`-verwijzing door `podman/`.

- [ ] **Step 9: `claude-sandbox/podman/README.md` — kop en dekkingsgat**

Vervang de openingsalinea, die nu nog de host-agent als terugvaloptie noemt:

```markdown
Draai Testcontainers **ín** de sandbox via rootless Podman — zonder host-agent,
`--privileged` of Docker-socket. Hiermee vervalt de container→host
code-execution-bridge van de Maven host-agent (issue #44): `mvn`/pom-plugins
draaien in de sandbox (non-root `claude`), Testcontainers-containers zijn geneste
rootless-userns-children. Dit **beoogt de Maven host-agent te vervangen**: als
deze opzet breed bevestigd is (zie "Openstaand"), kan de host-agent weg. Tot die
tijd blijft de host-agent beschikbaar (zie ADR 0001).
```

door:

```markdown
Draai Testcontainers **ín** de sandbox via rootless Podman — zonder host-agent,
`--privileged` of Docker-socket. `mvn` en pom-plugins draaien in de sandbox als
non-root `claude`, Testcontainers-containers zijn geneste
rootless-userns-children. Dit is de enige ondersteunde route: de Maven
host-agent is verwijderd, omdat die per ontwerp een container→host
code-execution-bridge was (issue #44, ADR 0001).

## Ondersteunde platforms

Bevestigd op een echt project:

| Platform | Status |
|---|---|
| Gehardend Ubuntu 23.10+ / Tuxedo (`apparmor_restrict_unprivileged_userns=1`) | bevestigd |
| Linux Docker, niet-gehardend | bevestigd |
| Rancher Desktop op macOS (Lima → Alpine, moby) | bevestigd |
| macOS `podman machine` (applehv → Fedora CoreOS, rootful) | bevestigd, ook multi-uid |

Niet bevestigd en daarmee **niet ondersteund**: Docker Desktop op Mac/Windows,
rootless `podman machine`, WSL2. Wie op zo'n platform Testcontainers nodig
heeft, zal de opzet daar eerst moeten bevestigen — er is geen terugvaloptie
meer.
```

Verwijder daarna de rij "Docker Desktop (Mac/Win) — nog te verifiëren" uit de bestaande per-setup matrix verderop in het bestand, en verwijs vanuit die matrix naar de nieuwe sectie in plaats van de status te herhalen.

- [ ] **Step 10: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 11: Controleer dat er geen kapotte interne links zijn**

```bash
for f in $(git ls-files '*.md'); do
  grep -oE '\]\([^)#][^)]*\.md[^)]*\)' "$f" 2>/dev/null | tr -d '()' | sed 's/^\]//' | while read -r link; do
    target="$(dirname "$f")/${link%%#*}"
    [ -f "$target" ] || echo "GEBROKEN: $f → $link"
  done
done
```

Verwacht: geen output

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs(sandbox): podman-gids als enige ingang, verwijzingen rechtgetrokken (#44)

Alle paden naar de oude host-agents-boom bijgewerkt. De podman-README is nu
de enige plek met bedieningsstappen; de rest verwijst ernaar. Voegt een
expliciete lijst ondersteunde platforms toe, inclusief wat niet bevestigd
is nu er geen terugvaloptie meer is.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task A4: ADR 0001 afronden

**Files:**
- Modify: `docs/adr/0001-maven-testcontainers-sandbox-isolatie.md`

**Interfaces:**
- Consumes: de platformlijst uit Task A3, stap 9. Herhaal die lijst niet — verwijs ernaar.

- [ ] **Step 1: Schrijf de falende controle**

```bash
grep -q '^\*\*Status:\*\* Geaccepteerd' docs/adr/0001-maven-testcontainers-sandbox-isolatie.md \
  && ! grep -q 'Host-agent — blijft als fallback' docs/adr/0001-maven-testcontainers-sandbox-isolatie.md \
  && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Statusregel**

Vervang:

```markdown
**Status:** Voorgesteld — werkend op Linux, in review (PR). Breekt door zodra
breed bevestigd (collega-tests); dan kan de host-agent vervallen. — 2026-06-10
```

door:

```markdown
**Status:** Geaccepteerd — host-agent verwijderd. — 2026-08-03
(voorgesteld 2026-06-10)
```

- [ ] **Step 3: Context bijwerken**

Vervang de contextsectie:

```markdown
De sandbox-container bevat geen Docker-daemon, dus Maven-builds met Testcontainers
werken niet rechtstreeks. De bestaande oplossing is een **host-side Maven
MCP-agent** (`claude-sandbox/host-agents/maven/`) die `mvn` op de host draait
namens Claude — per ontwerp een container→host code-execution-bridge.

Risico (uit #44): Claude controleert `pom.xml`/`mvnw` in de gedeelde
`projects`-map, en `mvn` voert die plugins ongezien uit als de host-user die
`run.sh` startte. Draait die user in de `docker`-group of met sudo, dan is
host-escalatie mogelijk. Op Linux bindt de agent bovendien auth-loos op
`0.0.0.0:7777`.
```

door:

```markdown
De sandbox-container bevat geen Docker-daemon, dus Maven-builds met
Testcontainers werken niet rechtstreeks. De oplossing wás een **host-side Maven
MCP-agent** die `mvn` op de host draaide namens Claude — per ontwerp een
container→host code-execution-bridge. Die agent is met deze beslissing
verwijderd.

Waarom dat moest (uit #44): Claude beheerst `pom.xml` en `mvnw` in de gedeelde
`projects`-map, en `mvn` voerde die plugins ongezien uit als de host-user die
`run.sh` startte. Draaide die user in de `docker`-group of met sudo, dan was
host-escalatie mogelijk. Op Linux bond de agent bovendien auth-loos op
`0.0.0.0:7777`.
```

De blockquote **Niet doen** over de gemounte Docker-socket blijft ongewijzigd staan — die waarschuwing geldt nog steeds.

- [ ] **Step 4: Beslissing terugbrengen tot één spoor**

Verwijder de kop `### 2. Host-agent — blijft als fallback` inclusief de blockquote eronder, en hernoem `### 1. Podman-in-Docker — voorkeur waar mogelijk (nieuw)` naar `### Podman-in-de-sandbox`. Optie C/D (sysbox, microVM) blijft ongewijzigd staan.

- [ ] **Step 5: Sectie "Goedkope hardening host-agent" verwijderen**

Die sectie gaat volledig over een component die niet meer bestaat.

- [ ] **Step 6: Consequenties bijwerken**

Vervang de bullet die begint met `**Intentie: de host-agent vervangen.**` door:

```markdown
- **Host-agent verwijderd.** Hosts waar podman-in-de-sandbox niet bevestigd is,
  hebben geen Testcontainers-route meer. Dat is een bewuste afweging: het
  risico van een container→host code-execution-bridge weegt zwaarder dan de
  dekking, en er zijn geen gebruikers op die platforms. Welke platforms
  bevestigd zijn, staat in `claude-sandbox/podman/README.md`.
```

- [ ] **Step 7: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 8: Commit**

```bash
git add docs/adr/0001-maven-testcontainers-sandbox-isolatie.md
git commit -m "$(cat <<'EOF'
docs(adr): 0001 naar Geaccepteerd, host-agent-spoor eruit (#44)

Het ADR was voorwaardelijk geformuleerd: de host-agent zou vervallen zodra
de podman-opzet breed bevestigd was. Dat is gebeurd, dus dit is de afronding
die het document zelf aankondigde.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task A5: Reviewlus PR A

**Files:** afhankelijk van de bevindingen.

**Interfaces:**
- Consumes: de volledige diff `feat/podman-multiuid-optin..HEAD`.

- [ ] **Step 1: Draai de reviewers parallel**

Dispatch in één bericht, elk met de diff van PR A als scope:

| Reviewer | Opdracht |
|---|---|
| `nerds-opensource` | Publieke code, licenties, geen achtergebleven secrets, herbruikbaarheid |
| `nerds-cloud` | Containers, IaC, reproduceerbaarheid van de opzet |
| `nerds-veiligheid` | BIO, informatiebeveiliging — let op wat er met het verwijderen van de bridge aan controles verdwijnt |
| `don-leidraad` | NeRDS-richtlijnen voor overheidssoftware |
| `digital-waste-spotter` | Overbodige compute, I/O, achtergebleven dode bestanden en verwijzingen |

Geef elke reviewer mee: de branch, de base, en dat er geen docker beschikbaar is zodat ze geen runtime-verificatie voorstellen als blokkerende bevinding.

- [ ] **Step 2: Triageer de bevindingen**

Elke bevinding wordt gefixt, ongeacht severity. Uitzondering is alleen een fix die buiten de scope van PR A valt, gedrag verandert dat PR A niet beoogt, of een eigen ontwerpbeslissing vergt. Zulke gevallen gaan naar de gebruiker met de afweging erbij; blijven ze liggen, dan komen ze als expliciete follow-up in de PR-beschrijving.

Houd een lijst bij van bevindingen die met reden zijn afgewezen, zodat een reviewer die er in een volgende ronde opnieuw mee komt geen nieuwe ronde afdwingt.

- [ ] **Step 3: Fix en commit per thema**

Aparte commits per onderwerp, niet één verzamelcommit.

- [ ] **Step 4: Herhaal tot een ronde schoon is**

Draai de betrokken reviewers opnieuw op de bijgewerkte diff. Klaar wanneer een volledige ronde niets nieuws oplevert, afgezien van de afgewezen en de aan de gebruiker voorgelegde gevallen. Geen maximum aantal rondes.

- [ ] **Step 5: Eindverificatie**

```bash
shellcheck --severity=warning $(git ls-files '*.sh')
grep -rn 'host-agents\|maven-mcp-agent' --include='*.md' --include='Dockerfile' \
  --include='*.yml' --include='*.sample' . \
  | grep -v '2026-08-03' && echo "NOG REFERENTIES" || echo "SCHOON"
```

Verwacht: shellcheck stil, `SCHOON`

---

### Task A6: PR A openen

- [ ] **Step 1: Push de branch**

```bash
git push -u origin feat/verwijder-maven-host-bridge
```

- [ ] **Step 2: Open de PR met base `feat/podman-multiuid-optin`**

De beschrijving bevat: aanleiding (bridge is het grootste resterende risico, ADR 0001 kondigde de verwijdering aan), wat er weg is, waar de podman-set nu staat, de platformlijst met wat niet ondersteund is, en de statische verificatie die is gedraaid. Sluit af met de standaard `🤖 Generated with [Claude Code](https://claude.com/claude-code)`-regel.

- [ ] **Step 3: Meld de gebruiker dat PR A klaarstaat**

Inclusief de expliciete mededeling dat de smoke-test op een echte host nog niet gedraaid is.

---

# Fase B — PR B

### Task B0: Branch aanmaken

- [ ] **Step 1: Vertak van PR A**

```bash
git checkout -b feat/sandbox-hardening
```

---

### Task B1: Root-entrypoint met privilege-drop

**Files:**
- Create: `claude-sandbox/entrypoint-root.sh`
- Modify: `claude-sandbox/entrypoint.sh:4-17` (firewall-blok eruit, HOME-comment erin)
- Modify: `claude-sandbox/Dockerfile:28` (`sudo` uit de pakketlijst), `:222-227` (sudoers weg), `:267` en `:284-286` (USER en COPY)

**Interfaces:**
- Produces: `/opt/entrypoint-root.sh` als `ENTRYPOINT`, dat `exec setpriv … /opt/entrypoint.sh "$@"` aanroept. `/opt/entrypoint.sh` behoudt zijn bestaande contract: het draait als `claude` en eindigt op `exec sleep infinity`.

**Terugvaloptie als deze aanpak op een host vastloopt.** Niet nu bouwen, wel weten dat hij er is. Houd `USER claude` en de sudo-aanroep, maar schrap de `SETENV`-tag en beperk de doorgegeven omgeving expliciet:

```
Defaults!/usr/local/bin/init-firewall.sh env_keep += "OPEN_HTTPS ALLOWED_DOMAINS"
claude ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh
```

Dat sluit de `BASH_ENV`-route met twee regels en zonder structurele wijziging, maar laat de self-service egress-allowlist open — `OPEN_HTTPS` is dan juist de variabele die bewaard blijft. Alleen inzetten als de privilege-drop hierboven aantoonbaar niet werkt, en dan met een expliciete notitie in de PR dat het gat rond de allowlist blijft bestaan.

- [ ] **Step 1: Schrijf de falende controles**

```bash
test -f claude-sandbox/entrypoint-root.sh \
  && ! grep -q 'sudo' claude-sandbox/entrypoint.sh \
  && ! grep -q 'sudoers' claude-sandbox/Dockerfile \
  && ! grep -qE '^\s+sudo \\$' claude-sandbox/Dockerfile \
  && grep -q 'ENTRYPOINT \["/opt/entrypoint-root.sh"\]' claude-sandbox/Dockerfile \
  && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Maak `claude-sandbox/entrypoint-root.sh`**

```bash
#!/bin/bash
set -euo pipefail

# Draait als root, uitsluitend om de firewall op te zetten, en dropt daarna
# onherroepelijk naar `claude`.
#
# WAAROM DEZE SPLITSING
# De firewall liep eerder via `sudo -E`, met een sudoers-regel die de SETENV-tag
# droeg. Die tag laat BASH_ENV de env_reset van sudo overleven, waarmee
# `sudo BASH_ENV=/tmp/p.sh /usr/local/bin/init-firewall.sh` willekeurige code als
# root draaide — een directe route van uid 1000 naar container-root. Omdat er
# geen userns-remap is, is container-root gelijk aan host-root-uid.
# Daarnaast kon `claude` datzelfde commando zelf opnieuw draaien met
# OPEN_HTTPS=true in zijn eigen omgeving, waarmee de egress-allowlist
# self-service was voor precies de agent die hij moet beperken.
# Beide zijn dicht doordat OPEN_HTTPS en ALLOWED_DOMAINS alleen hier worden
# gelezen, vóór de drop, en er daarna geen weg terug naar root is.

echo "entrypoint OPEN_HTTPS: ${OPEN_HTTPS:-false}"
echo "entrypoint ALLOWED_DOMAINS: ${ALLOWED_DOMAINS:-}"
if ! /usr/local/bin/init-firewall.sh; then
    {
        echo "FATAL: Firewall-initialisatie mislukt."
        echo "Veelvoorkomende oorzaken:"
        echo "  - OPEN_HTTPS heeft geen waarde 'true' of 'false'"
        echo "  - Container mist NET_ADMIN/NET_RAW (controleer cap_add in compose.yml)"
        echo "  - iptables/ipset modules niet beschikbaar op host-kernel"
        echo "Zie de output hierboven voor het concrete iptables/ipset-commando dat faalde."
    } >&2
    exit 1
fi

# HOME expliciet zetten: de container draait nu als root, dus Docker zet HOME op
# /root. setpriv laat de omgeving ongemoeid, en entrypoint.sh schrijft
# podman-config naar $HOME/.config/containers — zonder deze regel belandt die op
# de verkeerde plek en verliest de sandbox zijn storage.conf.
export HOME=/home/claude
export USER=claude
export LOGNAME=claude

# Numerieke id's, niet de naam: niet elke setpriv-versie accepteert een
# gebruikersnaam bij --reuid/--regid.
claude_uid="$(id -u claude)"
claude_gid="$(id -g claude)"

# GEEN --no-new-privs. Dat lijkt gratis hardening, maar PR #76 heeft gemeten dat
# setuid-root `newuidmap` er precies op stukloopt ("newuidmap: write to uid_map
# failed"), waarna podman naar single-uid degradeert en DB-images falen met
# "chown: Invalid argument". Zie de meettabel in
# docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md.
#
# --inh-caps=-all leegt de inheritable set. De bounding set blijft staan, want
# setuid-root newuidmap moet daar in multi-uid CAP_SYS_ADMIN uit kunnen trekken.
exec setpriv --reuid="$claude_uid" --regid="$claude_gid" --init-groups \
    --inh-caps=-all /opt/entrypoint.sh "$@"
```

- [ ] **Step 3: Haal het firewall-blok uit `claude-sandbox/entrypoint.sh`**

Verwijder regels 4 t/m 17 (van `# Start firewall` tot en met de sluitende `fi`) en zet er dit voor in de plaats:

```bash
# Draait als `claude`, gestart door /opt/entrypoint-root.sh nadat die de firewall
# heeft opgezet en naar deze user is gedropt. Hier is geen root meer bereikbaar:
# er is geen sudo en geen sudoers-regel. Zie entrypoint-root.sh voor het waarom.
if [[ "$(id -u)" -eq 0 ]]; then
    echo "FATAL: entrypoint.sh draait als root. Dit script hoort als 'claude' te draaien," \
         "gestart via /opt/entrypoint-root.sh. Start de container via de ENTRYPOINT," \
         "niet door dit script rechtstreeks aan te roepen." >&2
    exit 1
fi
```

- [ ] **Step 4: Dockerfile — `sudo` uit de pakketlijst**

Verwijder op regel 28 de regel `    sudo \`. De comment op `claude-sandbox/README.md:41` zegt al dat sudo bewust niet in de tools-lijst staat omdat het alleen intern door de firewall werd gebruikt; die reden vervalt nu volledig.

- [ ] **Step 5: Dockerfile — sudoers-regel weg**

Vervang:

```dockerfile
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "claude ALL=(root) NOPASSWD: SETENV: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/claude-firewall && \
  chmod 0440 /etc/sudoers.d/claude-firewall
```

door:

```dockerfile
# Geen sudoers-regel: de firewall draait in de root-fase van de entrypoint, vóór
# de drop naar `claude`. Een NOPASSWD-regel met SETENV was hier eerder een
# directe route van uid 1000 naar container-root — zie entrypoint-root.sh.
RUN chmod +x /usr/local/bin/init-firewall.sh
```

- [ ] **Step 6: Dockerfile — entrypoints en runtime-user**

Vervang:

```dockerfile
# Startup script voor firewall
COPY --chown=claude:claude entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR /home/claude/projects

ENTRYPOINT ["/opt/entrypoint.sh"]
```

door:

```dockerfile
# De container start als root zodat de firewall kan worden opgezet;
# entrypoint-root.sh dropt daarna naar `claude`. Gevolg voor bediening: `docker
# exec` zonder -u geeft een root-shell. Gebruik `docker exec -u claude` — de
# root-shell waarschuwt daar zelf ook voor.
USER root

# Beide entrypoints zijn root-eigendom en niet schrijfbaar voor `claude`. Dat is
# geen detail: entrypoint-root.sh draait als root bij elke container-start, dus
# een door `claude` schrijfbaar bestand zou een privilege-escalatie zijn die bij
# de volgende herstart afgaat.
#
# Geen COPY --chown/--chmod: die vlaggen vergen een recente BuildKit- of
# buildah-frontend, en op macOS bouwen gebruikers met podman-compose. Een kale
# COPY landt sowieso als root:root; de chmod doen we expliciet.
COPY entrypoint-root.sh /opt/entrypoint-root.sh
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod 0755 /opt/entrypoint-root.sh /opt/entrypoint.sh

WORKDIR /home/claude/projects

ENTRYPOINT ["/opt/entrypoint-root.sh"]
```

Let op de volgorde: `USER root` moet vóór de `RUN chmod`, anders draait die als
`claude` en faalt hij op bestanden die van root zijn.

- [ ] **Step 7: Root-shell-waarschuwing als vangnet**

Voeg toe direct ná de `RUN chmod`-regel uit stap 6:

```dockerfile
# Vangnet tegen de footgun hierboven: wie per ongeluk als root de container in
# exec't, krijgt het te zien in plaats van ongemerkt als root te werken en
# root-eigendom achter te laten in het claude-home volume.
RUN { \
      echo 'if [ -t 1 ]; then'; \
      echo '  echo "LET OP: je bent root in de sandbox. Claude en projectcode horen als claude te draaien."'; \
      echo '  echo "Gebruik: docker exec -tiu claude claude-sandbox zsh"'; \
      echo 'fi'; \
    } | tee -a /root/.bashrc >> /root/.profile
```

- [ ] **Step 8: Draai de controles uit stap 1**

Verwacht: `PASS`

- [ ] **Step 9: Shellcheck**

```bash
shellcheck --severity=warning claude-sandbox/entrypoint-root.sh claude-sandbox/entrypoint.sh
```

Verwacht: geen output, exit 0

- [ ] **Step 10: Controleer dat `sudo` nergens meer in de container-keten zit**

```bash
grep -rn 'sudo' claude-sandbox/Dockerfile claude-sandbox/entrypoint.sh \
  claude-sandbox/entrypoint-root.sh claude-sandbox/init-firewall.sh \
  && echo "NOG SUDO" || echo "SCHOON"
```

Verwacht: `SCHOON`. Treffers in `claude-sandbox/podman/setup-host.sh` zijn correct — dat script draait op de host.

- [ ] **Step 11: Commit**

```bash
git add claude-sandbox/entrypoint-root.sh claude-sandbox/entrypoint.sh claude-sandbox/Dockerfile
git commit -m "$(cat <<'EOF'
feat(sandbox): root-entrypoint met privilege-drop i.p.v. sudoers SETENV (#44)

De firewall liep via een NOPASSWD-sudoers-regel met de SETENV-tag. Die tag
laat BASH_ENV de env_reset van sudo overleven, waarmee uid 1000 in één
commando container-root werd — en zonder userns-remap is dat host-root-uid.
Dezelfde regel maakte de egress-allowlist self-service: claude kon
init-firewall.sh opnieuw draaien met OPEN_HTTPS=true.

De container start nu als root, zet de firewall op en dropt met setpriv naar
claude. sudo en de sudoers-regel zijn weg. Beide entrypoints zijn
root-eigendom, want een door claude schrijfbaar bestand dat als root start
zou het gat gewoon verplaatsen.

Bewust geen --no-new-privs: setuid-root newuidmap loopt daarop stuk
(gemeten in #76), waarna multi-uid podman degradeert.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B2: Bedieningscommando's naar `-u claude`

**Files:**
- Modify: `claude-sandbox/docs/opstarten-en-afsluiten.md:75-76`
- Modify: `claude-sandbox/podman/README.md:67,72`
- Modify: `docs/superpowers/plans/2026-06-10-maven-podman-in-docker-poc.md:362,367`

**Interfaces:**
- Consumes: de `USER root`-wijziging uit Task B1.

- [ ] **Step 1: Schrijf de falende controle**

Zoek elk `exec`-commando dat de service `claude` binnengaat zonder `-u`:

```bash
grep -rnE '(docker|podman)(-| )compose exec ([^-]|$)' --include='*.md' . \
  && echo FAIL || echo PASS
```

Verwacht nu: `FAIL` met vier treffers.

- [ ] **Step 2: Werk de commando's bij**

Vervang overal `docker compose exec claude` door `docker compose exec -u claude claude`. De eerste `claude` is de user, de tweede de service-naam — zet er waar het commando op zichzelf staat een korte noot bij:

```markdown
> De eerste `claude` is de user, de tweede de service. Zonder `-u claude` krijg
> je een root-shell: de container start als root om de firewall op te zetten en
> dropt daarna naar `claude`.
```

- [ ] **Step 3: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs(sandbox): exec-commando's met -u claude (#44)

De container start sinds de vorige commit als root, dus `docker compose exec
claude bash` geeft een root-shell. Alle gedocumenteerde commando's gaan naar
`exec -u claude`.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B3: AppArmor-profiel dat mediateert

**Files:**
- Modify: `claude-sandbox/podman/apparmor/claude-sandbox-podman`

**Interfaces:**
- Produces: profielnaam blijft `claude-sandbox-podman`, zodat `compose.override.podman-linux.yml` ongewijzigd kan blijven verwijzen.

- [ ] **Step 1: Schrijf de falende controle**

```bash
grep -q 'deny @{PROC}/sys/\*\* w' claude-sandbox/podman/apparmor/claude-sandbox-podman \
  && ! grep -q 'flags=(unconfined)' claude-sandbox/podman/apparmor/claude-sandbox-podman \
  && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Vervang de inhoud van het profiel**

```
# AppArmor-profiel voor de sandbox-container met rootless Podman.
#
# Afgeleid van docker-default, met drie afwijkingen:
#   1. `userns,` toegevoegd. Nodig op gehardende Ubuntu/Tuxedo
#      (kernel.apparmor_restrict_unprivileged_userns=1) zodat alleen deze
#      container userns mag gebruiken, zonder de host-hardening systeembreed uit
#      te zetten.
#   2. docker-defaults `deny mount,` weggelaten en mount/umount/pivot_root
#      expliciet toegestaan. Geneste rootless podman kan niet zonder.
#   3. De rest van docker-defaults deny-regels blijft staan — met name de
#      /proc/sys-denies.
#
# WAAROM DIE /proc/sys-DENIES HIER HET WERK DOEN
# De podman-override zet `systempaths=unconfined`, waardoor Docker's masked en
# read-only /proc-paden vervallen en /proc/sys read-write gemount is. Er is geen
# userns-remap, dus container-root is host-root-uid, en
# /proc/sys/kernel/core_pattern is enkel DAC-beschermd (0644 root:root): geen
# capability-check. Wie root wordt in de container kan daar een
# usermode-helper in schrijven en die draait bij de eerstvolgende core-dump als
# echte host-root, buiten alle namespaces.
# AppArmor mediateert dat schrijfpad los van de vraag of de mount read-only is.
# Deze regels zijn dus de laatste laag die de escape sluit, ook als
# systempaths=unconfined blijft staan.
#
# Installeren op de HOST:  ./podman/setup-host.sh
# Draaien:  docker ... --security-opt apparmor=claude-sandbox-podman
#
# ITEREREN ALS PODMAN BREEKT
# Te strak en podman start geen geneste containers meer. Diagnose:
#   sudo aa-complain /etc/apparmor.d/claude-sandbox-podman   # klaagmodus
#   sudo dmesg | grep -i 'apparmor.*DENIED'                  # wat wordt geweigerd
#   sudo aa-enforce /etc/apparmor.d/claude-sandbox-podman    # terug naar enforce
# Verruim gericht op basis van die output; val niet terug op flags=(unconfined),
# want dan is de escape hierboven weer open.
#
# abi 4.0 hoort bij AppArmor op Ubuntu 24.04+. Faalt het laden op een oudere
# parser, dan strijkt setup-host.sh deze regel er automatisch uit.
abi <abi/4.0>,
include <tunables/global>

profile claude-sandbox-podman flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>

  network,
  capability,
  file,

  # Geneste rootless podman heeft deze nodig; docker-default weigert mount.
  mount,
  umount,
  pivot_root,
  userns,

  signal (receive) peer=unconfined,
  signal (send,receive) peer=claude-sandbox-podman,

  # /proc-afscherming, overgenomen uit docker-default. Zie de noot hierboven.
  deny @{PROC}/* w,
  deny @{PROC}/{[^1-9],[^1-9][^1-9],[^1-9s][^1-9y][^1-9s],[^1-9][^1-9][^1-9][^1-9]*}/** w,
  deny @{PROC}/sys/[^k]** w,
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  # /sys-afscherming, overgenomen uit docker-default. De patronen laten
  # /sys/fs/cgroup met rust, dat heeft de container nodig.
  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/kernel/security/** rwklx,

  ptrace (trace,read,tracedby,readby) peer=claude-sandbox-podman,
}
```

- [ ] **Step 3: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 4: Controleer haakjes-balans en profielnaam**

`apparmor_parser` ontbreekt in deze omgeving, dus dit is een structuurcontrole, geen parse:

```bash
f=claude-sandbox/podman/apparmor/claude-sandbox-podman
[ "$(grep -c '{' "$f")" -eq "$(grep -c '}' "$f")" ] && echo "haakjes ok" || echo "HAAKJES SCHEEF"
[ "$(grep -c '^profile ' "$f")" -eq 1 ] && echo "één profiel" || echo "MEER DAN ÉÉN PROFIEL"
grep -q '^profile claude-sandbox-podman ' "$f" && echo "naam ok" || echo "NAAM FOUT"
```

Verwacht: `haakjes ok`, `één profiel`, `naam ok`

- [ ] **Step 5: Commit**

```bash
git add claude-sandbox/podman/apparmor/claude-sandbox-podman
git commit -m "$(cat <<'EOF'
feat(podman): AppArmor-profiel afgeleid van docker-default (#44)

Het profiel was flags=(unconfined) met één userns-regel: de MAC-laag deed
niets. Samen met systempaths=unconfined en het ontbreken van userns-remap
maakte dat /proc/sys/kernel/core_pattern schrijfbaar voor container-root, en
dat is host-root code-execution via de core-dump usermode-helper.

Nu afgeleid van docker-default met behoud van de /proc/sys- en
/sys-denies, plus userns en mount/umount/pivot_root omdat geneste podman
daar niet zonder kan. Sluit de core_pattern-write ook als
systempaths=unconfined blijft staan.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B4: `setup-host.sh` — profielvalidatie en iteratie-ondersteuning

**Files:**
- Modify: `claude-sandbox/podman/setup-host.sh:56-72`

**Interfaces:**
- Consumes: het profielbestand uit Task B3.

- [ ] **Step 1: Schrijf de falende controle**

```bash
grep -q 'profile_count' claude-sandbox/podman/setup-host.sh && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Voeg de validatie toe vóór de `install`-regel**

Zet dit blok direct boven `echo "→ profiel laden: $PROFILE_SRC → $PROFILE_DST"`:

```bash
# Valideer wat we straks als root in de kernel laden. `apparmor_parser -r`
# vervangt élk profiel dat in het bestand gedeclareerd staat, op naam. Een
# toegevoegde stanza `profile docker-default flags=(unconfined) { }` zou dus
# stilletjes de AppArmor-afscherming van alle containers op deze host slopen.
# Een kwaadaardige bewerking in een .sh valt op bij review; een extra stanza in
# een configbestand niet.
profile_count="$(grep -c '^profile ' "$PROFILE_SRC" || true)"
if [[ "$profile_count" -ne 1 ]] || ! grep -q '^profile claude-sandbox-podman ' "$PROFILE_SRC"; then
    echo "✗ $PROFILE_SRC declareert niet precies één profiel 'claude-sandbox-podman'." >&2
    echo "  Gevonden:" >&2
    grep '^profile ' "$PROFILE_SRC" >&2 || echo "  (geen enkele profile-regel)" >&2
    echo "  Geweigerd: apparmor_parser -r vervangt profielen op naam, dus dit kan" >&2
    echo "  andere profielen op deze host overschrijven." >&2
    exit 1
fi
```

- [ ] **Step 3: Voeg een slotmelding toe over iteratie**

Vervang de slotregels:

```bash
echo "Start nu de sandbox met de podman-override:"
echo "  docker compose -f compose.yml -f compose.override.podman-linux.yml up -d --force-recreate"
echo "== klaar =="
```

door:

```bash
echo "Start nu de sandbox met de podman-override:"
echo "  docker compose -f compose.yml -f compose.override.podman-linux.yml up -d --force-recreate"
echo
echo "Breekt podman hierna op een AppArmor-weigering, zet het profiel dan tijdelijk"
echo "in klaagmodus en kijk wat er geweigerd wordt:"
echo "  sudo aa-complain $PROFILE_DST"
echo "  sudo dmesg | grep -i 'apparmor.*DENIED'"
echo "  sudo aa-enforce $PROFILE_DST"
echo "== klaar =="
```

- [ ] **Step 4: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 5: Test de validatie met een vervalst profiel**

```bash
cp claude-sandbox/podman/apparmor/claude-sandbox-podman /tmp/aa-test
printf '\nprofile docker-default flags=(unconfined) {\n}\n' >> /tmp/aa-test
count="$(grep -c '^profile ' /tmp/aa-test)"
[ "$count" -eq 2 ] && echo "detectie werkt: $count profielen gevonden" || echo "DETECTIE FAALT"
rm /tmp/aa-test
```

Verwacht: `detectie werkt: 2 profielen gevonden`

- [ ] **Step 6: Shellcheck**

```bash
shellcheck --severity=warning claude-sandbox/podman/setup-host.sh
```

Verwacht: geen output, exit 0

- [ ] **Step 7: Commit**

```bash
git add claude-sandbox/podman/setup-host.sh
git commit -m "$(cat <<'EOF'
fix(podman): setup-host.sh weigert profielbestanden met vreemde stanzas (#44)

apparmor_parser -r vervangt profielen op de naam die in het bestand staat.
Een toegevoegde `profile docker-default flags=(unconfined) { }` zou dus de
afscherming van alle containers op de host slopen — en dat valt in een
configbestand veel minder op dan in een script. Nu wordt geweigerd wat niet
precies één claude-sandbox-podman-profiel is.

Voegt ook het aa-complain/dmesg-recept toe aan de slotmelding, voor als het
strakkere profiel podman breekt.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B5: Seccomp-blocklist uitbreiden

**Files:**
- Modify: `claude-sandbox/podman/seccomp/podman-sandbox.json`

- [ ] **Step 1: Schrijf de falende controle**

```bash
python3 -c "
import json,sys
d=json.load(open('claude-sandbox/podman/seccomp/podman-sandbox.json'))
names=set(d['syscalls'][0]['names'])
want={'keyctl','add_key','request_key','quotactl','syslog','uselib','ustat','sysfs',
      'pciconfig_read','pciconfig_write','pciconfig_iobase'}
missing=want-names
print('FAIL, ontbreekt:',sorted(missing)) if missing else print('PASS')
"
```

Verwacht nu: `FAIL` met de volledige lijst.

- [ ] **Step 2: Voeg de syscalls toe**

Voeg aan de `names`-array toe, op alfabetische plek zodat de lijst gesorteerd blijft: `add_key`, `keyctl`, `pciconfig_iobase`, `pciconfig_read`, `pciconfig_write`, `quotactl`, `request_key`, `syslog`, `uselib`, `ustat`, `sysfs`.

Werk tegelijk de comment in `compose.override.podman-linux.yml` bij die de blocklist beschrijft, zodat de opsomming klopt: voeg "kernel-keyring" toe aan de opsomming van wat geblokkeerd wordt.

- [ ] **Step 3: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 4: Controleer dat het JSON geldig blijft en gesorteerd is**

```bash
python3 -c "
import json
d=json.load(open('claude-sandbox/podman/seccomp/podman-sandbox.json'))
n=d['syscalls'][0]['names']
assert d['defaultAction']=='SCMP_ACT_ALLOW', d['defaultAction']
assert n==sorted(n), 'niet gesorteerd'
assert len(n)==len(set(n)), 'duplicaten'
print('ok,',len(n),'syscalls geblokkeerd')
"
```

Verwacht: `ok, 53 syscalls geblokkeerd`

- [ ] **Step 5: Commit**

```bash
git add claude-sandbox/podman/seccomp/podman-sandbox.json claude-sandbox/compose.override.podman-linux.yml
git commit -m "$(cat <<'EOF'
feat(podman): keyring- en legacy-syscalls op de seccomp-blocklist (#44)

keyctl, add_key en request_key openen de kernel-keyring, een terugkerend
LPE-oppervlak dat via userns bereikbaar is. quotactl, syslog, uselib, ustat,
sysfs en de pciconfig-familie zijn legacy-oppervlak. Rootless podman, crun
en pasta gebruiken geen van alle.

De blocklist-vorm blijft: een allowlist zet clone/unshare/mount/setns achter
CAP_SYS_ADMIN en breekt daarmee rootless podman.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B6: Testprotocol en onderzoeksbucket

**Files:**
- Create: `claude-sandbox/docs/hardening-verificatie.md`
- Modify: `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md` (onderzoeksbucket-tabel toevoegen)
- Modify: `claude-sandbox/podman/README.md` (verwijzing naar het testprotocol)

**Interfaces:**
- Consumes: alle wijzigingen uit B1 t/m B5.
- Produces: `claude-sandbox/docs/hardening-verificatie.md`, waarnaar de PR-beschrijving verwijst.

- [ ] **Step 1: Maak `claude-sandbox/docs/hardening-verificatie.md`**

```markdown
# Hardening verifiëren

De hardening uit PR B doet twee dingen die je niet op het woord moet geloven:
hij sluit een escape, en hij mag de sandbox niet breken. Dit protocol test
allebei. Draai het op een echte host, ná `docker compose … up --build -d
--force-recreate`.

De statische controles (shellcheck, JSON-validatie, compose-parse) zijn al in CI
gedraaid. Wat hieronder staat, kan alleen op een draaiende container.

## 1. De escape moet dicht zijn

Open een shell als `claude`:

```
docker exec -tiu claude claude-sandbox bash
```

| Commando | Verwacht |
|---|---|
| `id -un` | `claude` |
| `sudo -E /usr/local/bin/init-firewall.sh` | `bash: sudo: command not found` |
| `command -v sudo` | geen output, exit 1 |
| `ls /etc/sudoers.d/` | leeg, of geen `claude-firewall` |
| `echo test > /proc/sys/kernel/core_pattern` | `Permission denied` |
| `cat /proc/self/status \| grep CapEff` | `0000000000000000` |

De laatste twee zijn de kern. Slaagt de `core_pattern`-write wél, dan
mediateert het AppArmor-profiel niet — controleer of de container met
`--security-opt apparmor=claude-sandbox-podman` draait en of het profiel in
enforce-modus staat:

```
sudo aa-status | grep claude-sandbox-podman
```

## 2. De egress-allowlist mag niet meer self-service zijn

Nog steeds als `claude`:

| Commando | Verwacht |
|---|---|
| `OPEN_HTTPS=true /usr/local/bin/init-firewall.sh` | faalt op ontbrekende rechten voor iptables |
| `iptables -L` | `Permission denied` of `must be root` |

## 3. De sandbox moet blijven werken

| Commando | Verwacht |
|---|---|
| `docker logs claude-sandbox \| head -30` | firewall-regels opgezet, geen FATAL |
| `id -un` in de container | `claude`, niet `root` |
| `echo $HOME` | `/home/claude` |
| `ls -la /home/claude/.config/containers/storage.conf` | bestaat, eigendom `claude` |
| `podman info --format '{{.Host.Security.Rootless}}'` | `true` |
| `./podman/smoke-test.sh` | groen |

Draai je multi-uid, dan hoort de smoke-test ook `PostgresSmokeTest` te doen:

| Commando | Verwacht |
|---|---|
| `podman info --format '{{.Host.IDMappings.UIDMap}}'` | twee mappings, bv. `[{0 1000 1} {1 100000 65536}]` |
| `./podman/smoke-test.sh` | `Tests run: 2, Failures: 0, Errors: 0` |

Eén mapping in plaats van twee betekent dat setuid-root `newuidmap` geen
privileges meer wint. Controleer dan of er ergens `no_new_privs` is
binnengeslopen — dat is precies de reden dat de privilege-drop in
`entrypoint-root.sh` `--no-new-privs` bewust weglaat.

## 4. Als het AppArmor-profiel te strak blijkt

```
sudo aa-complain /etc/apparmor.d/claude-sandbox-podman
# reproduceer de fout
sudo dmesg | grep -i 'apparmor.*DENIED'
sudo aa-enforce /etc/apparmor.d/claude-sandbox-podman
```

Verruim het profiel gericht op basis van die output. Val niet terug op
`flags=(unconfined)`: dan is de escape uit sectie 1 weer open.

## Uitkomst rapporteren

Noteer per sectie wat je zag. Een half gedraaid protocol is geen bevestiging —
sectie 1 en 3 moeten allebei volledig groen zijn voordat deze hardening als
werkend geldt.
```

- [ ] **Step 2: Voeg de onderzoeksbucket toe aan de 2026-06-10-spec**

Voeg onderaan een sectie toe. De uitkomstkolom blijft leeg tot de metingen gedaan zijn; dat is het punt van de tabel.

```markdown
## Openstaand onderzoek na de hardening (2026-08-03)

Drie vragen die een echte host nodig hebben. Elk levert óf een codewijziging, óf
een regel hieronder met de conclusie waarom het niet kan.

| Vraag | Waarom het uitmaakt | Uitkomst |
|---|---|---|
| Werkt de geneste proc-mount zonder `systempaths=unconfined`, of met een smallere unmask? | `systempaths=unconfined` heft alle masked en read-only /proc-paden op. Kan het smaller, dan wordt de outer container fors minder blootgesteld | nog te meten |
| Wat doet userns-remap op de outer container met deze opzet? | Met userns-remap is container-root niet langer host-root-uid, waarmee de hele klasse escapes via host-globale sysctls vervalt | nog te meten |
| Kan `NET_ADMIN`/`NET_RAW` uit de bounding set bij de drop naar `claude`? | De firewall is dan al opgezet. `compose.override.podman-linux.yml` stelt echter dat pasta `NET_ADMIN` nodig heeft voor de tap op `/dev/net/tun` | nog te meten |
```

- [ ] **Step 3: Verwijs vanuit de podman-README naar het testprotocol**

Voeg in de troubleshooting-sectie van `claude-sandbox/podman/README.md` een regel toe die naar `../docs/hardening-verificatie.md` wijst.

- [ ] **Step 4: Controleer de interne links**

```bash
test -f claude-sandbox/docs/hardening-verificatie.md && echo ok
grep -q 'hardening-verificatie' claude-sandbox/podman/README.md && echo "verwijzing ok"
```

Verwacht: `ok`, `verwijzing ok`

- [ ] **Step 5: Commit**

```bash
git add claude-sandbox/docs/hardening-verificatie.md \
  docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md \
  claude-sandbox/podman/README.md
git commit -m "$(cat <<'EOF'
docs(sandbox): testprotocol voor de hardening + openstaand onderzoek (#44)

"De escape is dicht" is een bewering die bewijs nodig heeft, en die kan
alleen op een draaiende container geleverd worden. Dit protocol test zowel
dat de escape sluit als dat de sandbox blijft werken, met de negatieve tests
expliciet erbij.

Legt ook de drie openstaande onderzoeksvragen vast (systempaths versmallen,
userns-remap, bounding set) in de meettabel van de spec.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B7: Security-noten in ADR en override bijstellen

**Files:**
- Modify: `claude-sandbox/compose.override.podman-multiuid.yml:19-25`
- Modify: `docs/adr/0001-maven-testcontainers-sandbox-isolatie.md` (sectie Security-balans)

- [ ] **Step 1: Schrijf de falende controle**

```bash
grep -q 'host-root-uid' claude-sandbox/compose.override.podman-multiuid.yml \
  && grep -q 'entrypoint-root' docs/adr/0001-maven-testcontainers-sandbox-isolatie.md \
  && echo PASS || echo FAIL
```

Verwacht nu: `FAIL`

- [ ] **Step 2: Stel de noot in de multiuid-override bij**

De huidige tekst zegt dat `CAP_SYS_ADMIN` "de impact van een root-escalatie ín de container vergroot". Dat is te mild: zonder userns-remap is container-root gelijk aan host-root-uid. Vervang het `WAT HET KOST`-blok door:

```
# WAT HET KOST
# `claude` draait als uid 1000 met CapEff=0 en krijgt CAP_SYS_ADMIN dus niet
# rechtstreeks in handen; alleen setuid-root-binaries kunnen hem uit de bounding
# set trekken (hier: newuidmap/newgidmap). Sinds de hardening is er geen sudo en
# geen sudoers-regel meer, dus de bekende route van uid 1000 naar container-root
# is dicht.
#
# Wat je wél vergroot is de impact áls die escalatie er ooit tóch is. Er is geen
# userns-remap, dus container-root is host-root-uid. Met CAP_SYS_ADMIN erbij kan
# container-root dan ook `mount -o remount,rw /proc/sys` doen, waarmee de escape
# niet meer afhangt van systempaths=unconfined. Het AppArmor-profiel is de laag
# die dat sluit: het weigert schrijven naar /proc/sys ongeacht de mount-opties.
# Draai deze opt-in dus niet met een profiel dat op flags=(unconfined) staat.
```

- [ ] **Step 3: Werk de security-balans in ADR 0001 bij**

De sectie stelt nu "**Géén** `CAP_SYS_ADMIN`, `--privileged` of socket". Dat klopt niet meer sinds de multi-uid opt-in. Vervang de hele sectie `## Security-balans (podman-in-docker)` door:

```markdown
## Security-balans

**Dicht.**

- De container→host code-execution-bridge van #44. Er is geen host-agent meer
  en geen Docker-socket; alle projectcode draait in de sandbox
- De route van uid 1000 naar container-root. De firewall draait in de root-fase
  van de entrypoint en dropt daarna met `setpriv` naar `claude`; de
  NOPASSWD-sudoers-regel met de SETENV-tag is weg, evenals `sudo` zelf. Die tag
  liet `BASH_ENV` de `env_reset` van sudo overleven
- De egress-allowlist als self-service. `OPEN_HTTPS` en `ALLOWED_DOMAINS` worden
  alleen nog gelezen vóór de drop, dus `claude` kan de firewall niet meer
  heropenen
- Schrijven naar `/proc/sys` vanuit de container, ook met
  `systempaths=unconfined`. Het AppArmor-profiel is afgeleid van docker-default
  en behoudt de `/proc/sys`-denies, waarmee de `core_pattern`-route naar
  host-root dicht is

**Open.**

- Relaxaties op de *outer* container: seccomp is een blocklist en geen
  allowlist (een allowlist zet `clone`/`unshare`/`mount`/`setns` achter
  `CAP_SYS_ADMIN` en breekt rootless podman), `systempaths=unconfined` staat nog
  aan, en op SELinux-hosts `label=disable`
- In de multi-uid opt-in staat `CAP_SYS_ADMIN` in de bounding set. `claude`
  heeft `CapEff=0` en krijgt hem niet rechtstreeks; alleen setuid-root
  `newuidmap`/`newgidmap` trekken hem eruit. Maar er is geen userns-remap, dus
  áls er ooit tóch een escalatie naar container-root is, is dat host-root-uid
- Kernel-escapes blijven buiten bereik van deze maatregelen. Wie volledig
  vijandige, kernel-exploit-capabele code moet draaien, hoort bij optie C/D

**Welke laag welke escape sluit.** De root-entrypoint sluit het bereiken van
container-root. Het AppArmor-profiel sluit wat container-root zou kunnen áls dat
tóch lukt. Die twee lagen zijn onafhankelijk: elk sluit de escape op zichzelf.
Zet het AppArmor-profiel dus niet terug op `flags=(unconfined)` omdat "de
sudo-route toch al dicht is".

**Verificatie.** `claude-sandbox/docs/hardening-verificatie.md` bevat het
testprotocol, inclusief de negatieve tests die aantonen dat de escape dicht is.
Drie vragen staan nog open (`systempaths` versmallen, userns-remap, de bounding
set); die staan in de meettabel van
`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`.
```

- [ ] **Step 4: Draai de controle uit stap 1 opnieuw**

Verwacht: `PASS`

- [ ] **Step 5: Commit**

```bash
git add claude-sandbox/compose.override.podman-multiuid.yml \
  docs/adr/0001-maven-testcontainers-sandbox-isolatie.md
git commit -m "$(cat <<'EOF'
docs(sandbox): security-noten bijgesteld op de werkelijke impact (#44)

De multiuid-override stelde dat CAP_SYS_ADMIN "de impact van een
root-escalatie ín de container" vergroot. Zonder userns-remap is
container-root gelijk aan host-root-uid, dus die impact is host-breed. ADR
0001 stelde nog "géén CAP_SYS_ADMIN", wat sinds de multi-uid opt-in niet
meer klopt.

Beide teksten benoemen nu welke laag welke escape sluit.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B8: Reviewlus PR B

**Files:** afhankelijk van de bevindingen.

- [ ] **Step 1: Draai de reviewers parallel**

Dispatch in één bericht, elk met de diff `feat/verwijder-maven-host-bridge..HEAD`:

| Reviewer | Opdracht |
|---|---|
| `nerds-opensource` | Publieke code, licenties, secrets, herbruikbaarheid |
| `nerds-cloud` | Containers, IaC, reproduceerbaarheid |
| `nerds-veiligheid` | BIO, informatiebeveiliging |
| `don-leidraad` | NeRDS-richtlijnen |
| `don-security` | Authenticatie- en beveiligingspatronen |
| `digital-waste-spotter` | Overbodige compute, I/O, dode bestanden |

- [ ] **Step 2: Draai de meertraps security-review**

Zelfde opzet als op PR #76: eerst één agent die kwetsbaarheden zoekt in de volledige diff, daarna per bevinding een parallelle agent die hem probeert te weerleggen. Alleen bevindingen die de weerlegging overleven tellen mee.

Geef de security-review expliciet mee dat de privilege-drop, het AppArmor-profiel en de seccomp-uitbreiding de te toetsen wijzigingen zijn, en dat de vraag is of PR B nieuwe gaten introduceert — met name:
- of `/opt/entrypoint-root.sh` en `/opt/entrypoint.sh` echt niet schrijfbaar zijn voor `claude`
- of de privilege-drop volledig is en er geen weg terug naar root bestaat
- of `USER root` iets anders raakt dan `docker exec`
- of het AppArmor-profiel gaten laat die docker-default wél dicht heeft

- [ ] **Step 3: Triageer, fix, herhaal**

Zelfde regel als in Task A5: alles wordt gefixt, behalve wat buiten scope valt, ongewenst gedrag verandert of een eigen ontwerpbeslissing vergt. Die gevallen gaan naar de gebruiker. Bijhouden welke bevindingen met reden zijn afgewezen. Doorgaan tot een volledige ronde niets nieuws oplevert.

- [ ] **Step 4: Eindverificatie**

```bash
shellcheck --severity=warning $(git ls-files '*.sh')
python3 -c "import json;json.load(open('claude-sandbox/podman/seccomp/podman-sandbox.json'));print('seccomp json ok')"
f=claude-sandbox/podman/apparmor/claude-sandbox-podman
[ "$(grep -c '{' "$f")" -eq "$(grep -c '}' "$f")" ] && echo "apparmor haakjes ok"
grep -rn 'sudo' claude-sandbox/Dockerfile claude-sandbox/entrypoint*.sh \
  && echo "NOG SUDO IN CONTAINER" || echo "container sudo-vrij"
```

Verwacht: shellcheck stil, `seccomp json ok`, `apparmor haakjes ok`, `container sudo-vrij`

---

### Task B9: PR B openen

- [ ] **Step 1: Push**

```bash
git push -u origin feat/sandbox-hardening
```

- [ ] **Step 2: Open de PR met base `feat/verwijder-maven-host-bridge`**

De beschrijving bevat:
- De bevinding uit de security-review op PR #76, met de volledige keten
- De self-service egress-allowlist als tweede reden voor de root-entrypoint
- Wat elke maatregel sluit, en welke laag welke escape afdekt
- De bewuste keuze om `--no-new-privs` weg te laten, met de meting uit #76 erbij
- De gedragswijziging voor bediening: `docker exec` zonder `-u` geeft nu een root-shell
- Een blok **Nog niet op een host bevestigd**, met de link naar
  `claude-sandbox/docs/hardening-verificatie.md` en de expliciete vermelding dat
  alleen statische verificatie is gedraaid
- De drie openstaande onderzoeksvragen als follow-up
- Sluit af met `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

- [ ] **Step 3: Meld de gebruiker dat beide PR's klaarstaan**

Met de nadruk op wat er handmatig getest moet worden, in welke volgorde, en wat de meest waarschijnlijke breuk is (het AppArmor-profiel).

---

## Verificatie-overzicht

| Wat | Hoe | Waar |
|---|---|---|
| Shell-scripts | `shellcheck --severity=warning` | CI en lokaal |
| Seccomp-profiel | JSON-parse, sortering, geen duplicaten | Task B5 |
| AppArmor-profiel | Haakjes-balans, precies één profielnaam | Task B3, B4 |
| Padverwijzingen | grep op oude paden | Task A1, A2, A3 |
| Interne links | link-checker over alle tracked markdown | Task A3 |
| Compose-bestanden | `docker compose config` | handmatig, geen docker lokaal |
| Escape gesloten | negatieve tests | handmatig, `claude-sandbox/docs/hardening-verificatie.md` |
| Sandbox werkt nog | smoke-test incl. PostgresSmokeTest | handmatig, idem |
