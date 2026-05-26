# Maven MCP-agent (host-side)

De image bevat geen Docker daemon, dus Maven-builds met Testcontainers (of
andere tests die een Docker-daemon nodig hebben) werken niet rechtstreeks
vanuit de container. De oplossing is een MCP-server
(`host-agents/maven/maven_agent.py`) die **op de host** draait en een
`run_maven`-tool aanbiedt; Claude Code in de container roept die aan via
`host.docker.internal:7777` (SSE transport) en gebruikt zo de host-Docker.

## Cross-platform setup
| Omgeving                       | `host.docker.internal` werkt out-of-the-box | Override nodig |
|--------------------------------|----------------------------------------------|----------------|
| Docker Desktop (Mac/Windows)   | Ja, ingebouwd                                | Geen           |
| Rancher Desktop (Mac/Windows)  | Ja, ingebouwd                                | Geen — en juist NIET `host-gateway` toevoegen |
| Vanilla Docker (Linux)         | Nee                                          | `compose.override.linux.yml.example` → `compose.override.yml` |
| Podman 4.0+ (alle platforms)   | Alleen `host.containers.internal`; alias via `extra_hosts` | Idem als Linux Docker |
| Rancher Desktop (Linux)        | Versieafhankelijk; recente builds: ja        | Eerst testen, anders zoals Linux Docker |

Voor Linux Docker / Podman:
```
cp compose.override.linux.yml.example compose.override.yml
docker compose up --build --detach
```

## Host-agent starten
Het makkelijkst is het meegeleverde launcher-script. Dat zet de venv klaar,
installeert/controleert de deps, regelt `JAVA_HOME` via SDKman en kiest op
Linux automatisch het juiste bind-adres:
```
cd host-agents/maven
./run.sh /pad/naar/jouw/maven-project
```
Het pad-argument is verplicht; zonder pad print het script een gebruiksregel en
stopt met exit-code 2. Overige instellingen blijven via env vars werken, bv.
`MAVEN_AGENT_PORT=8888 ./run.sh /pad/...`. Het script
draait `pip install` elke keer (snel als alles er al staat) zodat gewijzigde
requirements vanzelf meekomen.

### Handmatig (wat het script doet)
1. venv aanmaken (eenmalig) en deps installeren:
   ```
   cd host-agents/maven
   python3 -m venv .venv          # eenmalig
   .venv/bin/pip install --require-hashes -r requirements.txt
   ```
   Of activeer de venv in elke nieuwe shell met `source .venv/bin/activate`
   (per shell opnieuw nodig) en gebruik daarna `python3` direct.
2. Start de agent met de project-directory:
   ```
   PROJECT_DIR=/pad/naar/jouw/maven-project .venv/bin/python maven_agent.py
   ```

   `JAVA_HOME` moet in de omgeving van de agent staan, anders kan Maven (of
   `./mvnw`) geen JVM vinden. SDKman zet die alleen in interactieve shells;
   start de agent dus vanuit zo'n shell of source eerst de SDKman-init:
   ```
   source ~/.sdkman/bin/sdkman-init.sh
   PROJECT_DIR=/pad/... .venv/bin/python maven_agent.py
   ```

   Op Linux Docker / Podman moet je ook het bind-adres openzetten zodat de
   container de agent via het bridge-IP kan bereiken:
   ```
   MAVEN_AGENT_HOST=0.0.0.0 PROJECT_DIR=/pad/... .venv/bin/python maven_agent.py
   ```
   Op Docker Desktop / Rancher Desktop (Mac/Windows) volstaat de default
   `127.0.0.1` — die bridge forwardt host-loopback automatisch.

   Configuratie via env vars:

   | Variabele                    | Default     | Omschrijving                                                         |
   |------------------------------|-------------|----------------------------------------------------------------------|
   | `PROJECT_DIR`                | `cwd`       | Maven-projectroot (waar `pom.xml` staat). Alleen bij directe invocatie van `maven_agent.py`; `run.sh` eist een expliciet pad-argument en overschrijft `PROJECT_DIR`. |
   | `MAVEN_AGENT_HOST`           | `127.0.0.1` | Bind-adres; `0.0.0.0` voor Linux Docker/Podman                       |
   | `MAVEN_AGENT_PORT`           | `7777`      | TCP-poort                                                            |
   | `MVN_TIMEOUT`                | `600`       | Timeout per Maven-aanroep (seconden)                                 |
   | `MAVEN_AGENT_ALLOWED_HOSTS`  | _(leeg)_    | Komma-gescheiden extra hostnames voor de DNS-rebinding-allowlist; `host.docker.internal`, `localhost`, `127.0.0.1` en `::1` staan al standaard. Alleen nodig als je via een andere DNS-naam verbindt. |

## MCP-registratie in de container
Eenmalig in de container registreren zodat Claude Code de tool kan aanroepen:
```
docker compose exec claude bash -lc \
  "claude mcp add --transport sse maven http://host.docker.internal:7777/sse"
```
Verifieer met `claude mcp list`. De firewall (`init-firewall.sh`) staat
verkeer naar `host.docker.internal` automatisch toe — geen extra
`ALLOWED_DOMAINS`-aanpassing nodig.

> **Linux + actieve host-firewall (UFW/firewalld):** als `curl
> http://host.docker.internal:7777/` in de container blijft hangen (geen
> snelle "Connection refused"), wordt het pakket op de host gedropt. Sta
> het compose-bridge-subnet toe op poort 7777, bijvoorbeeld met UFW:
> ```
> docker inspect claude-sandbox \
>   --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
> # → bv. 172.20.0.2 ⇒ subnet 172.20.0.0/16
> sudo ufw allow from 172.20.0.0/16 to any port 7777 proto tcp
> ```
> Of dek alle Docker-RFC1918-subnets in één regel: `from 172.16.0.0/12`.

> **Veiligheid:** de agent voert `mvn` uit op je host met de rechten van de
> gebruiker die hem start. Run hem niet als root en wees bewust van wat er in
> `pom.xml` plugins zit — `mvn` voert die ongezien uit.

## Troubleshooting

- **`Failed to validate request: Received request before initialization was complete`** in de agent-log: de MCP-sessie van Claude Code is stale (vrijwel altijd doordat de agent net is herstart, terwijl Claude nog de oude `session_id` gebruikt). Fix: in de container `claude mcp remove maven` + `claude mcp add ...` opnieuw, of in `/mcp` → **Reconnect**.
- **`SDK auth failed: HTTP 404: ... Raw body: Not Found`** in Claude na klikken op **Authenticate** in `/mcp`: deze host-agent heeft bewust geen auth-laag (alleen DNS-rebinding-bescherming). De client doet dan OAuth-discovery die niet bestaat → 404. Kies **Reconnect**, niet **Authenticate**.
