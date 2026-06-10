# Maven host-agent hardenen (Linux, macOS, Windows)

De Maven MCP-agent (`host-agents/maven/maven_agent.py`) is **per ontwerp** een
container→host code-execution-bridge: hij draait `mvn` **op de host** namens
Claude in de sandbox (zie [`maven-mcp-agent.md`](maven-mcp-agent.md) en
[issue #44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)).
Alles wat Claude in de sandbox kan, kan het via deze bridge uitvoeren als de
host-user die `run.sh` startte.

Deze handleiding beschrijft de **goedkope hardening**: een set maatregelen die
goed past bij het reële dreigingsbeeld (Claude rogue / prompt-injection,
semi-vertrouwd) en daar grofweg het leeuwendeel van het risico afdekt tegen
lage kosten. Wil je ook volledig **onvertrouwde** code afschermen, dan is dit
niet genoeg — kies dan podman-in-de-sandbox (geen host-bridge) of sterkere
isolatie (sysbox / microVM); zie issue #44.

> **Scope.** `run.sh` draait native op het echte OS — óók op macOS en Windows
> draait hij op de host, niet in de Docker-VM. De maatregelen hieronder gelden
> dus op alle drie de platforms; alleen de _uitvoering_ verschilt.

## Het dreigingsbeeld in één alinea

Claude controleert de inhoud van de gedeelde `projects/`-map (bind-mount) en
daarmee de `pom.xml` en `mvnw` die de host uitvoert. Willekeurige host-code via
Maven is triviaal: een plugin gebonden aan de `validate`-phase draait bij élke
goal, `exec-maven-plugin` draait een willekeurig executable, en een
overschreven `mvnw` wordt direct als host-user uitgevoerd. Draait die host-user
in de `docker` group of met sudo-rechten, dan ligt host-escalatie open — niet
via de container, maar via de host-user.

De hardening snijdt op drie assen: **wie** draait de agent (least-privilege
user), **wat** kan hij zien/schrijven (projecten buiten de gedeelde map), en
**wie** kan hem bereiken (bind address / firewall).

---

## Maatregel A — Draai `run.sh` als dedicated least-privilege user

Start de agent **niet** vanuit je eigen account. Maak een aparte user aan met
zo min mogelijk rechten: **geen sudo**, en niet zomaar in de `docker` group.
Zo is de blast-radius van een rogue build beperkt tot wat die ene user mag, in
plaats van je volledige werkaccount.

> **Spanning met Testcontainers.** Heeft je build Testcontainers (of andere
> Docker-afhankelijke tests) nodig, dan moet de user de Docker-daemon kunnen
> bereiken. Op Linux is `docker` group ≈ host-root, wat "least-privilege"
> tenietdoet. Twee uitwegen: (1) gebruik **rootless Docker** of **rootless
> Podman** voor die user, zodat daemon-toegang géén host-root is; of (2) draai
> Testcontainers liever helemaal **ín** de sandbox (podman-in-docker) en gebruik
> deze host-agent alleen voor builds zónder Docker-afhankelijke tests. Builds
> zonder Testcontainers hebben sowieso geen `docker` group nodig.

### Linux

```bash
# Dedicated user, geen shell-login nodig, geen sudo, geen docker group
sudo useradd --create-home --shell /usr/sbin/nologin maven-agent

# Controleer: geen sudo, geen docker group
groups maven-agent          # mag 'docker' en 'sudo'/'wheel' NIET tonen

# Draai de agent als die user (via een interactieve shell zodat SDKman laadt)
sudo -u maven-agent -i bash -lc \
  '/pad/naar/host-agents/maven/run.sh /pad/naar/maven-project'
```

Heb je tóch Docker nodig: zet **rootless Docker** op voor `maven-agent`
(`dockerd-rootless-setuptool.sh install` als die user) in plaats van de
group-membership. De daemon draait dan in de user-namespace van `maven-agent`
en is geen host-root.

### macOS

Docker Desktop draait de daemon in een LinuxKit-VM, dus "`docker` group =
host-root" geldt hier niet één-op-één. Het reële host-risico is dat Maven-code
host-bestanden raakt waar jouw account bij kan. Beperk dat met een aparte user:

```bash
# Standard (geen Admin) gebruiker via Systeeminstellingen → Users & Groups,
# of headless met sysadminctl:
sudo sysadminctl -addUser maven-agent -fullName "Maven Agent" -password -
# Laat 'maven-agent' GEEN admin zijn (geen lid van groep 'admin').

# Draai de agent als die user:
sudo -u maven-agent -i bash -lc \
  '/pad/naar/host-agents/maven/run.sh /pad/naar/maven-project'
```

Beperk daarnaast in Docker Desktop → **Settings → Resources → File sharing**
de gedeelde paden tot het minimum — dat bepaalt welke host-mappen
Testcontainers/Maven via Docker kunnen mounten.

### Windows

Docker Desktop draait op het WSL2-backend; daemon-toegang loopt via de
`docker-users` group. Net als op macOS is dat geen directe host-root, maar een
aparte, niet-admin user beperkt wat Maven-code op je host kan.

```powershell
# Lokale, niet-administratieve user (PowerShell als Admin)
net user maven-agent /add
# NIET toevoegen aan 'Administrators'. Alleen aan 'docker-users' als je
# Testcontainers nodig hebt:
net localgroup docker-users maven-agent /add
```

Start `run.sh` als die user vanuit Git Bash / WSL (de agent verwacht een
bash-omgeving). Beperk ook hier de **File sharing**-paden in Docker Desktop.

---

## Maatregel B — Houd Maven-projecten buiten de gedeelde `projects/`-map

De kern van het lek: Claude kan schrijven in de bind-gemounte `projects/`-map,
dus elke `pom.xml`/`mvnw` daarin is door Claude te manipuleren en wordt door de
host uitgevoerd. Wijs `run.sh` daarom naar een project dat **buiten** die
gedeelde map ligt en waar Claude geen schrijftoegang toe heeft.

Het principe is op alle platforms identiek; alleen de paden verschillen:

| Platform | Gedeelde map (vermijden) | Veilige projectlocatie (voorbeeld) |
|----------|--------------------------|-------------------------------------|
| Linux    | `<repo>/projects/`       | `~/maven-projecten/mijn-app`        |
| macOS    | `<repo>/projects/`       | `~/maven-projecten/mijn-app`        |
| Windows  | `<repo>\projects\`       | `C:\Users\<jij>\maven-projecten\mijn-app` |

```bash
# Goed: project buiten de sandbox-bind-mount
./run.sh ~/maven-projecten/mijn-app

# Vermijd: project ín de gedeelde projects/-map die Claude kan schrijven
./run.sh /pad/naar/<repo>/projects/mijn-app     # ← Claude controleert pom.xml/mvnw
```

> Maak de projectmap bovendien eigendom van de `maven-agent`-user uit
> maatregel A, en geef Claude/je eigen account er geen schrijfrechten op, zodat
> de scheiding ook op filesystem-niveau klopt.

---

## Maatregel C — Beperk het bind address / firewall poort 7777

De agent luistert standaard op `127.0.0.1:7777`. Op vanilla Docker (Linux) moet
hij echter op `0.0.0.0` binden zodat de container hem via het bridge-IP bereikt
— en dan is poort 7777 **zonder auth** ook voor je LAN bereikbaar. `run.sh`
waarschuwt hier al voor. Sluit dat af.

### Linux (vanilla Docker)

`run.sh` kiest hier automatisch `0.0.0.0`. Laat alléén het Docker-bridge-subnet
toe op poort 7777 en blokkeer de rest:

```bash
# Bepaal het bridge-subnet van de sandbox-container
docker inspect claude-sandbox \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
# → bv. 172.20.0.2  ⇒ subnet 172.20.0.0/16

# UFW: sta alleen het bridge-subnet toe, deny de rest op 7777
sudo ufw allow from 172.20.0.0/16 to any port 7777 proto tcp
sudo ufw deny 7777/tcp
```

firewalld-equivalent:

```bash
sudo firewall-cmd --add-rich-rule \
  'rule family=ipv4 source address=172.20.0.0/16 port port=7777 protocol=tcp accept'
sudo firewall-cmd --add-rich-rule \
  'rule family=ipv4 port port=7777 protocol=tcp drop'
```

Draai de agent sowieso **niet op een onvertrouwd netwerk**.

### macOS (Docker Desktop / Rancher Desktop)

Docker Desktop forwardt host-loopback naar de container, dus hier hoeft de agent
**niet** op `0.0.0.0`. Houd de default:

```bash
MAVEN_AGENT_HOST=127.0.0.1 ./run.sh ~/maven-projecten/mijn-app
```

Met een loopback-bind is 7777 niet vanaf het LAN bereikbaar. Wil je
defense-in-depth: zet de macOS Application Firewall aan
(**Systeeminstellingen → Network → Firewall**) in plaats van de poort open te
zetten.

### Windows (Docker Desktop / WSL2)

Ook hier forwardt Docker Desktop loopback; houd de default `127.0.0.1`:

```bash
MAVEN_AGENT_HOST=127.0.0.1 ./run.sh /c/Users/<jij>/maven-projecten/mijn-app
```

Als defense-in-depth een inbound block-rule op 7777 in Windows Defender
Firewall:

```powershell
New-NetFirewallRule -DisplayName "Block Maven agent 7777 inbound" `
  -Direction Inbound -Protocol TCP -LocalPort 7777 -Action Block
```

---

## Maatregel D (optioneel) — Egress-firewall + ephemeral werkdir

Voor wie verder wil dan de basis:

- **Egress-firewall** voor de `maven-agent`-user: sta alleen uitgaand verkeer
  toe naar je Maven-repository/mirror (en wat de build echt nodig heeft), zodat
  een rogue plugin niet vrij naar buiten kan exfiltreren. Op Linux via
  `iptables`/`nftables` owner-match op de uid van `maven-agent`; op macOS/Windows
  via de host-firewall of een outbound-policy.
- **Ephemeral werkdir**: draai elke build in een wegwerp-kopie van het project
  en gooi die daarna weg, zodat artefacten van de ene run niet in de volgende
  lekken. Combineer met een schone Maven local repo per run
  (`-Dmaven.repo.local=<tmp>`).

Deze twee zijn niet nodig voor het basis-dreigingsbeeld, maar verkleinen de
blast-radius verder als je dat wilt.

---

## Checklist

- [ ] **A** — `run.sh` draait als dedicated user zonder sudo; niet in `docker`
  group (of via rootless Docker/Podman als Testcontainers nodig is).
- [ ] **B** — Het project-pad ligt **buiten** de gedeelde `projects/`-map en
  Claude heeft er geen schrijftoegang toe.
- [ ] **C** — Linux/vanilla Docker: poort 7777 alleen open voor het
  Docker-bridge-subnet (firewall). macOS/Windows: bind op `127.0.0.1`.
- [ ] **D** (optioneel) — Egress-firewall + ephemeral werkdir voor extra
  afscherming.

> Wil je de container→host-bridge hélemaal kwijt: draai Testcontainers ín de
> sandbox via rootless Podman (geen host-agent nodig). Zie issue #44 en
> `host-agents/maven/podman/`.
