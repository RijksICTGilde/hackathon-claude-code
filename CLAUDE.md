# CLAUDE.md - Projectcontext voor AI-assistentie

## Project

Claude Code Container — hackathon-editie. Een sandboxed Docker-image met Claude Code, bedoeld om `claude --dangerously-skip-permissions` veiliger te draaien dan op de host: netwerkrestricties via iptables-firewall, geïsoleerd `claude-home`-volume. Geen productiesetup; leer- en hackathon-omgeving.

Er is geen applicatiecode: het repo bestaat uit een Dockerfile, shellscripts, GitHub Actions-workflows en Nederlandstalige documentatie.

## Taal

Communicatie, documentatie, comments en commit-berichten in het Nederlands. Code, identifiers en technische termen in het Engels waar gangbaar.

Vaste technische idiomen blijven Engels en worden NIET vertaald: vendoring, pinning, firewall, rate limit, entrypoint, layer cache, keyless signing. Vertalen maakt ze minder leesbaar, niet meer.

## Structuur

| Pad | Wat |
|---|---|
| `claude-sandbox/Dockerfile` | De image: apt-tools, runtimes, plugins, skills, `INSTALL_*`-toggles |
| `claude-sandbox/compose.yml` | Compose-service, volumes, capabilities voor de firewall |
| `claude-sandbox/init-firewall.sh`, `entrypoint.sh` | Netwerkrestricties en containerstart |
| `claude-sandbox/vendor/install-scripts/` | Gevendorde upstream install-scripts (byte-identiek) |
| `claude-sandbox/docs/` | Opstarten/afsluiten, host-side agents |
| `oefeningen/`, `docs/verantwoording.md` | Deelnemersmateriaal en toetsing Overheidsbreed Standpunt Generatieve AI |
| `.github/workflows/` | actionlint, build-image, check-upstream, release-sign, scorecard, scriptcontroles, shellcheck, trivy |

## Commando's

Draaien vanuit `claude-sandbox/`:

```bash
cp .env.sample .env                            # eenmalig
docker volume create claude-home               # eenmalig
docker compose up --build --detach             # bouwen en starten
docker compose build --no-cache                # volledige rebuild (verifieert install-scripts echt)
docker exec -tiu claude claude-sandbox bash    # de container in
shellcheck --severity=warning <script>         # zoals CI (vendor/** uitgesloten)
```

Vanuit de repo-wortel, voor workflowwijzigingen:

```bash
# shellcheck expliciet meegeven: zonder dat pad slaat actionlint de run-blokken stil over
actionlint -shellcheck "$(command -v shellcheck)" .github/workflows/*.yml .github/workflows/*.yaml
.github/scripts/test-valideer-trivyignore.sh  # fixtures van de suppressie-validatie (vereist yq)
.github/scripts/test-vervang-pin.sh            # fixtures van de pin-vervanging
.github/scripts/test-check-upstream-jobs.sh    # fixtures van de wekelijkse versiejobs (vereist yq)
```

Bij wijziging in environment-variabelen moet het volume verwijderd en opnieuw aangemaakt worden; dat reset alle configuratie en data in de container.

## Dependency-onderhoud

Twee mechanismen, allebei gericht op reproduceerbaarheid en een gereviewde upgrade in plaats van een stille:

- **Vendoring** voor install-scripts. De Dockerfile `COPY`t uit `vendor/install-scripts/`, nooit een `curl | sh` naar upstream. Gevendorde bestanden blijven byte-identiek aan hun bron; geen eigen patches, anders loopt de herkomstcontrole vast en overschrijft de wekelijkse job je wijziging.
- **Versie-pinning** voor binaries: exacte versie plus SHA-256, tenzij het install-script de binary zelf tegen een checksum van dezelfde release verifieert.

`.github/workflows/check-upstream.yml` draait wekelijks en opent een PR per gedetecteerde wijziging. Kies per afhankelijkheid het juiste mechanisme: een ongeversioneerde upstream-URL wordt gevolgd via sha256-vergelijking; een per-tag gevendord script vereist een eigen release-tracking-job, omdat een tag-URL inhoudelijk nooit wijzigt.

GitHub Actions worden op commit-SHA gepind, met de versie als comment erachter. Dependabot dekt Docker, GitHub Actions en pip — een GitHub-release-binary valt in geen enkel ecosysteem en heeft dus eigen tracking nodig.

Externe input in een workflow (tagnamen, API-velden) valideren voor hij in `curl`-, `sed`- of shell-argumenten belandt.

## Commentaar

- Leg het _waarom_ vast — de niet-evidente beslissing, de security- of contract-invariant — niet het _wat_ dat de code al toont.
- **Houd het kort.** Condenseer rationale tot enkele regels. Laat opsommingen en voorbeelden weg die niets verduidelijken.
- **Geen verwijzingen naar het verleden.** Beschrijf de huidige situatie en waarom die zo is, niet hoe het vroeger was, wat er misging of hoe het ontdekt werd. "Deze job gaf altijd `changed=false` en de pin liep negen releases achter" is morgen ruis; "een per-tag gevendord script heeft een eigen release-job nodig" blijft kloppen.
- Geen verwijzingen naar review-iteratie-labels (`K1`, `B7`, `W3`) in comments of testnamen — die zijn buiten de review-sessie niet terug te vinden en rotten.
- Verwijs niet naar CLAUDE.md-regels of -secties; beschrijf de regel zelf, zodat een comment zonder CLAUDE.md leesbaar blijft.
- Ga uit van werken-naar-productie: geen "PoC", "voorlopig" of productie-twijfel in comments. Verwijs naar toekomstig werk alleen via `TODO(#ticket)`.
- Herhaal aan een aanroeplocatie niet wat bij de definitie al staat.
- Sync-comments (`<!-- Houd deze lijst in sync met ... -->`) zijn een uitzondering: die dragen een onderhoudsafspraak en blijven staan.

## Documentatie

- README's beschrijven de eindtoestand, niet de weg ernaartoe.
- De tool-, plugin- en skill-tabellen in `claude-sandbox/README.md` moeten in sync blijven met de Dockerfile; wijzig je de een, wijzig dan de ander in dezelfde commit.
- Geen spaties in bestands- of mapnamen: `kebab-case` voor documentatie en configuratie, zodat shellscripts en CI zonder quoting werken.

## Git-werkwijze

- **Nooit direct pushen naar `main`.** Alles via een branch en een pull request.
- Branch-prefix: `feat/`, `fix/`, `chore/`, `docs/`.
- Commit-berichten: conventional commits met Nederlandse omschrijving (`fix(deps): bump rtk naar v0.44.1`).
- Bij het aanmaken van een pull request **nooit** een reviewer toevoegen.
- PR-beschrijving: wat er wijzigt, waarom, en wat er geverifieerd is — inclusief wat expliciet níét geverifieerd is. Kort houden; geen ontdekkingsverhaal en geen herhaling van wat de diff al toont.
- CI moet groen zijn voor merge.

## Issues

- Titel en inleiding zijn functioneel en niet-technisch: aanleiding, effect voor gebruikers, wenselijk gedrag, acceptatiecriteria — te volgen zonder Docker- of CI-kennis.
- Technische details (bestandspaden, scriptnamen, concrete opties) in een aparte sectie verderop.
- Koppel een issue aan zijn parent via de GitHub-issue-relatie, niet via een `> Onderdeel van #N.`-regel in de tekst.

## Plannen

Implementatieplannen staan in `docs/superpowers/plans/` als `YYYY-MM-DD-korte-beschrijving.md`, met context, stappen, ontwerpkeuzes en verificatie per stap. Sla een plan op bij het afronden, zodat beslissingen traceerbaar blijven.

## Verificatie

- Elke wijziging aan de image daadwerkelijk bouwen (`docker compose build --no-cache` voor lagen die anders uit de cache komen) en het resultaat in de PR benoemen.
- Build- en CI-output op waarschuwingen nalopen: per stuk oplossen of bewust accepteren met reden. "Build groen" is alleen een betrouwbaar signaal als er geen onverklaarde nieuwe waarschuwingen bij komen.
- PR-builds draaien alleen `linux/amd64`; arm64 komt pas bij de push naar `main`. Noem dat expliciet als het relevant is voor de wijziging.
- Claim niets als geverifieerd zonder het commando en de uitkomst te hebben gezien.

## Review-aanpak

Bevindingen classificeren op ernst (Hoog/Medium/Laag) met een samenvattingstabel. Hoog direct oppakken, Medium in overleg, Laag later.

## Beveiliging

- Meld kwetsbaarheden nooit via een issue of PR; volg `SECURITY.md`.
- De container is een sandbox, geen garantie: gecloonde of geïnstalleerde code blijft schadelijk als hij dat is. Beschrijf beperkingen eerlijk in documentatie, verkoop de firewall niet als volledige isolatie.
