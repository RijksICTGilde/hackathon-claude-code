# Ontwerp — Maven host-bridge verwijderen en de sandbox harden

**Datum:** 2026-08-03
**Context-issue:** [#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)
**Bouwt voort op:** PR [#76](https://github.com/RijksICTGilde/hackathon-claude-code/pull/76)
(multi-uid opt-in), `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`
(ontwerp en meetresultaten), `docs/adr/0001-maven-testcontainers-sandbox-isolatie.md`

## Aanleiding

Podman-in-de-sandbox werkt. Daarmee vervalt de reden om de Maven host-agent te
laten staan, en die agent is het grootste resterende risico: hij voert `mvn` uit
op de host als de host-user, met `pom.xml` en `mvnw` uit de gedeelde
`projects`-map die de sandbox kan schrijven. ADR 0001 beschreef dat al als een
container→host code-execution-bridge en kondigde aan dat de agent kon vervallen
zodra de podman-opzet bevestigd was.

Daar komt bij dat de podman-set nu ín de boom van die agent staat
(`claude-sandbox/host-agents/maven/podman/`). Wijzigingen aan podman lezen
daardoor als wijzigingen aan de host-agent. Dat is verwarrend en het maakt de
scheiding tussen "draait op de host" en "draait in de sandbox" onnodig troebel.

Een security-review op PR #76 leverde daarnaast één bevestigde HIGH-bevinding op:
een container-escape naar host-root. Die staat los van de opruiming en krijgt een
eigen PR.

## Scope

Twee gestapelde PR's.

```
feat/podman-multiuid-optin            (PR #76, bestaand)
└── feat/verwijder-maven-host-bridge  → PR A, base = #76
    └── feat/sandbox-hardening        → PR B, base = PR A
```

PR A verandert geen gedrag. PR B is de enige die dat wel doet. Zo kan PR A landen
zonder te wachten op de hosttests die PR B nodig heeft.

## PR A — host-bridge weg, podman op een eigen plek

### Verwijderen

| Pad | Omvang |
|---|---|
| `claude-sandbox/host-agents/maven/maven_agent.py` | 139 regels — MCP-server die `mvn` op de host draait |
| `claude-sandbox/host-agents/maven/run.sh` | 116 regels |
| `claude-sandbox/host-agents/maven/requirements.in` | 10 regels |
| `claude-sandbox/host-agents/maven/requirements.txt` | 509 regels |
| `claude-sandbox/docs/maven-mcp-agent.md` | 135 regels |

`dependabot.yml` heeft geen pip-entry; PR #62 en #58 kwamen van Dependabot
security-updates, die manifests repo-breed scannen los van de config. Het
verwijderen van `requirements.txt` ruimt die alert-stroom dus op zonder dat er
iets aan de config hoeft te veranderen.

### Verhuizen

`git mv` van `claude-sandbox/host-agents/maven/podman/` naar
`claude-sandbox/podman/`, met de bestaande platte indeling:

```
claude-sandbox/podman/
├── README.md                        de operationele gids
├── setup-host.sh
├── smoke-test.sh
├── apparmor/claude-sandbox-podman
├── seccomp/podman-sandbox.json
└── sample/                          maven-project voor de smoke-test
```

### Verwijzingen bijwerken

Elf plekken verwijzen naar het oude pad of naar de host-agent:

- `claude-sandbox/compose.override.podman-linux.yml` — seccomp-pad
- `claude-sandbox/compose.override.podman-macos.yml` — seccomp-pad
- `claude-sandbox/Dockerfile` — comment bij het podman-blok
- `claude-sandbox/.env.sample` — de tekst "host-agent-bridge"
- `claude-sandbox/README.md` — twee verwijzingen
- `claude-sandbox/docs/opstarten-en-afsluiten.md`
- `docs/maximale-isolatie-linux.md`
- `docs/adr/0001-maven-testcontainers-sandbox-isolatie.md`
- `docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`
- `docs/superpowers/plans/2026-06-10-maven-podman-in-docker-poc.md`
- de zelfverwijzingen ín `claude-sandbox/podman/README.md`

### Documentatie: één ingang

| Document | Rol na PR A |
|---|---|
| `claude-sandbox/podman/README.md` | Hoe je het draait: per-OS-matrix, stappen, multi-uid, troubleshooting. Enige plek met stappen |
| `docs/adr/0001-...md` | Waarom. Status naar **Geaccepteerd**, spoor 2 (host-agent) eruit |
| `docs/superpowers/specs/2026-06-10-...design.md` | Ontwerp en meetresultaten. Blijft historisch document |
| `claude-sandbox/README.md`, `docs/opstarten-en-afsluiten.md` | Eén regel die naar de gids wijst, geen herhaling |

### Dekkingsgat

Eén alinea in `podman/README.md` en in ADR 0001. Bevestigd: gehardend
Ubuntu/Tuxedo, Rancher Desktop op macOS, macOS `podman machine` (rootful). Niet
bevestigd en daarmee niet ondersteund: Docker Desktop Mac/Windows, rootless
`podman machine`, WSL2. Geen verwijzing naar de git-historie — de bridge was
intern gebruik en er zijn geen gebruikers die er nu op wachten.

### Buiten scope van PR A

Geen gedragswijzigingen aan de podman-opzet en geen hernoeming van
`INSTALL_PODMAN` of `PODMAN_MULTIUID`. Puur verwijderen, verplaatsen en
verwijzingen rechttrekken.

### Verificatie PR A

- `shellcheck --severity=warning` over de verhuisde scripts. De CI-workflow
  draait op tracked shell scripts, dus de paden moeten kloppen
- `docker compose config` op alle vier de override-combinaties, om te
  controleren dat de seccomp-paden nog resolven
- Een grep die aantoont dat er geen verwijzing naar `host-agents` of
  `maven-mcp-agent` meer bestaat
- De echte smoke-test op een host is een handmatige stap

## PR B — hardening

### Uitgangspunt uit de security-review

De review op PR #76 bevestigde één HIGH: een container-escape naar host-root.
De keten is `compose.override.podman-linux.yml` (`systempaths=unconfined`,
AppArmor-profiel met `flags=(unconfined)`) plus de sudoers-regel
`claude ALL=(root) NOPASSWD: SETENV: /usr/local/bin/init-firewall.sh`. Met
`SETENV` overleeft `BASH_ENV` de `env_reset` van sudo, en omdat er geen
userns-remap is, is container-uid 0 gelijk aan host-uid 0. Daarmee is
`/proc/sys/kernel/core_pattern` schrijfbaar en levert een core-dump
usermode-helper host-root.

De multi-uid opt-in uit PR #76 maakt dit erger: met `CAP_SYS_ADMIN` in de
bounding set kan container-root ook `mount -o remount,rw /proc/sys` doen, zodat
de escape niet meer afhangt van `systempaths=unconfined`.

Tijdens het uitwerken kwam er een tweede punt bij, dat dezelfde sudoers-regel
raakt: `entrypoint.sh` draait `sudo -E /usr/local/bin/init-firewall.sh`, en die
regel staat dat NOPASSWD toe. `claude` kan dat commando dus zelf opnieuw draaien
met `OPEN_HTTPS=true` in zijn eigen omgeving. De egress-allowlist is daarmee
self-service voor precies de agent die hij moet beperken. Dit is pre-existing en
viel buiten de review, maar het bepaalt welke oplossing juist is: alleen `SETENV`
schrappen sluit `BASH_ENV`, maar laat dit gat open.

### B1. Root-entrypoint met privilege-drop

Twee bestanden in plaats van één, elk met één rol:

| Bestand | Eigenaar | Draait als | Doet |
|---|---|---|---|
| `entrypoint-root.sh` | `root:root` `0755` | root | Firewall initialiseren, daarna `exec setpriv` naar `claude` |
| `entrypoint.sh` | `root:root` `0755` | claude | Al het bestaande minus het firewall-blok: podman-config, socket, marketplaces, `exec "$@"` |

Wijzigingen in de Dockerfile:

- `USER root` vóór `ENTRYPOINT`
- `COPY --chown=claude:claude` weg bij beide entrypoints. Een door `claude`
  schrijfbaar bestand dat bij de volgende start als root draait, zou zelf een
  privilege-escalatie zijn
- `/etc/sudoers.d/claude-firewall` verdwijnt
- `sudo` uit de pakketlijst. Zonder sudoers-regel doet die binary niets, en het
  scheelt een setuid-root-binary in een container die in multi-uid
  `CAP_SYS_ADMIN` in de bounding set heeft

De drop wordt `setpriv --reuid=claude --regid=claude --init-groups --inh-caps=-all`.
`setpriv` zit al in de image via util-linux. Twee bewuste keuzes:

- **Geen `--no-new-privs`.** Ziet eruit als gratis hardening, maar PR #76 heeft
  gemeten dat setuid-root `newuidmap` er precies op stukloopt
  (`write to uid_map failed`). Dit komt als comment in de code te staan, met de
  meting erbij, anders zet iemand het er later alsnog bij
- **Bounding set voorlopig ongemoeid.** `NET_ADMIN` weghalen ná de firewall zou
  aantrekkelijk zijn, maar `compose.override.podman-linux.yml` stelt dat pasta
  het nodig heeft voor de tap op `/dev/net/tun`. Dat gaat naar B4 in plaats van
  dat het gegokt wordt

Wat dit sluit: de `BASH_ENV`-route naar container-root, en daarmee ook de
self-service egress-allowlist. `OPEN_HTTPS` en `ALLOWED_DOMAINS` worden alleen
nog gelezen in de root-fase, voordat `claude` bestaat.

Terugvaloptie als de root-entrypoint ergens vastloopt: `SETENV` schrappen en sudo
behouden, met
`Defaults!/usr/local/bin/init-firewall.sh env_keep += "OPEN_HTTPS ALLOWED_DOMAINS"`.
Dat sluit `BASH_ENV` met twee regels, maar laat de self-service allowlist open.
Alleen inzetten als B1 niet werkt.

### B2. AppArmor-profiel dat daadwerkelijk mediateert

`flags=(unconfined)` eruit, een profiel afgeleid van docker-default ervoor in de
plaats.

- Behouden uit docker-default: `deny @{PROC}/sys/** w`,
  `deny @{PROC}/sysrq-trigger rwklx`, `deny @{PROC}/kcore rwklx`
- Weggelaten: `deny mount,`. Geneste podman heeft `mount`, `umount` en
  `pivot_root` nodig
- Toegevoegd: `userns,`

Hiermee is de `core_pattern`-write dicht, ook als `systempaths=unconfined` blijft
staan: AppArmor mediateert het schrijfpad los van de vraag of de mount read-only
is. Deze maatregel hangt dus niet af van de uitkomst van B4.

Dit is de maatregel met de meeste kans op iteratie — te strak en podman breekt.
PR B levert daarom een debug-recept mee (`aa-complain` voor klaagmodus,
`dmesg | grep DENIED` om te zien wat er geweigerd wordt), en `setup-host.sh`
houdt het oude profiel installeerbaar zolang het nieuwe niet bevestigd is.

### B3. Seccomp-blocklist uitbreiden

Toevoegen aan de bestaande deny-lijst: `keyctl`, `add_key`, `request_key`,
`quotactl`, `syslog`, `uselib`, `ustat`, `sysfs`, `pciconfig_read`,
`pciconfig_write`, `pciconfig_iobase`. Geen daarvan wordt door podman, crun of
pasta gebruikt.

De blocklist-vorm blijft. Een allowlist zou `clone`, `unshare`, `mount` en
`setns` achter `CAP_SYS_ADMIN` zetten, en dat breekt rootless podman — dat is in
de vorige reviewronde vastgesteld en staat gedocumenteerd in
`compose.override.podman-linux.yml`.

Daarnaast de kleine bevinding uit die review: `setup-host.sh` gaat controleren
dat het profielbestand geen andere `^profile `-regel bevat dan
`claude-sandbox-podman`, zodat `apparmor_parser -r` niet ongemerkt
`docker-default` kan vervangen.

### B4. Onderzoeksbucket

Drie vragen die een echte host nodig hebben. Elk levert óf een codewijziging, óf
een rij in de meettabel van de spec met de conclusie "kan niet, want":

1. Werkt de geneste proc-mount zonder `systempaths=unconfined`, of met een
   smallere unmask?
2. Wat doet userns-remap op de outer container met deze opzet?
3. Kan `NET_ADMIN`/`NET_RAW` uit de bounding set bij de drop, of heeft pasta het
   echt nodig?

Dit past bij hoe de bestaande spec werkt: die documenteert bevindingen met
probe-tabellen.

### B5. Documentatie bijwerken

- ADR 0001, sectie security-balans: `CAP_SYS_ADMIN` uit PR #76 en de maatregelen
  uit deze PR
- `compose.override.podman-multiuid.yml`: de security-noot stelt nu dat
  `CAP_SYS_ADMIN` "de impact van een root-escalatie ín de container vergroot".
  Zonder userns-remap is container-root gelijk aan host-root-uid; de impact is
  host-breed, niet container-breed. Dat moet er staan

### Verificatie PR B

Statisch: shellcheck, `docker compose config`, en een parse-check van het
AppArmor-profiel voor zover mogelijk zonder `apparmor_parser`.

Daarnaast levert PR B een testprotocol met negatieve tests, want "de escape is
dicht" is een bewering die bewijs nodig heeft. Handmatig te draaien op een host:

```
# moet FALEN na PR B:
sudo -E /usr/local/bin/init-firewall.sh            # "claude is not allowed to run sudo"
sudo BASH_ENV=/tmp/p.sh /usr/local/bin/init-firewall.sh

# moet FALEN, ook als je op een andere manier root wordt:
echo '|/tmp/x' > /proc/sys/kernel/core_pattern      # Permission denied (AppArmor)

# moet SLAGEN, anders is de hardening te strak:
id -un                                              # claude
./podman/smoke-test.sh                              # groen, incl. PostgresSmokeTest in multi-uid
podman info --format '{{.Host.IDMappings.UIDMap}}'  # twee mappings in multi-uid
```

## Reviewrondes

Reviewers draaien parallel als subagents, elk op de diff van die PR.

| Reviewer | PR A | PR B | Kijkt naar |
|---|---|---|---|
| `nerds-opensource` | ✓ | ✓ | Publieke code, licenties, geen secrets, herbruikbaarheid |
| `nerds-cloud` | ✓ | ✓ | Containers, IaC, reproduceerbaarheid |
| `nerds-veiligheid` | ✓ | ✓ | BIO, informatiebeveiliging |
| `don-leidraad` | ✓ | ✓ | NeRDS-richtlijnen voor overheidssoftware |
| `don-security` | | ✓ | Authenticatie, beveiligingspatronen |
| `digital-waste-spotter` | ✓ | ✓ | Overbodige compute, I/O, dode bestanden |
| Security-review, meertraps | | ✓ | Vinden, daarna parallel false-positives filteren |

**De lus.** Elke bevinding wordt gefixt — HIGH, MEDIUM én LOW. Uitzondering is
een fix die te groot wordt, scherp afgebakend als: hij raakt bestanden buiten de
scope van die PR, hij verandert gedrag dat de PR niet beoogt, of hij vergt een
eigen ontwerpbeslissing. Zo'n geval wordt niet stil opgelost en niet laten
vallen, maar voorgelegd met de afweging erbij; blijft hij liggen, dan gaat hij
als expliciete follow-up in de PR-beschrijving.

**Afrondcriterium.** Doorgaan tot een volledige ronde niets belangrijks meer
oplevert — geen vast maximum aantal rondes. Een ronde telt als schoon wanneer
alle reviewers gedraaid hebben op de actuele diff en er geen nieuwe bevindingen
uit komen, afgezien van de aan de gebruiker voorgelegde te-grote gevallen en
bevindingen die in een eerdere ronde met reden zijn afgewezen. Die afgewezen
bevindingen worden bijgehouden, zodat een reviewer die er in een volgende ronde
opnieuw mee komt geen nieuwe ronde afdwingt.

Beperking: de reviewers hebben geen docker tot hun beschikking. Hun oordeel is
statisch. Het testprotocol hierboven blijft de scherpste verificatie en is een
handmatige stap.

## Consequenties

- Hosts waar podman-in-de-sandbox niet bevestigd is, hebben na PR A geen
  Testcontainers-route meer. Dat is een bewuste keuze: het risico van de bridge
  weegt zwaarder dan de dekking, en er zijn nu geen gebruikers op die platforms
- ADR 0001 gaat naar **Geaccepteerd** en beschrijft nog één spoor
- Na PR A is de sandbox de enige plek waar projectcode draait. Er is geen
  ondersteund pad meer waarlangs code uit de sandbox iets op de host uitvoert.
  PR B sluit daarbovenop de escape-route binnen de sandbox zelf
- PR B is pas af als het testprotocol op een echte host groen is. Tot dat moment
  staat de PR met de statische verificatie erin, expliciet gemarkeerd als nog
  niet op een host bevestigd
