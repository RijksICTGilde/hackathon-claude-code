# CI- en security-vervolg op de apt-reparatie

**Status:** In uitvoering

## Context

De review van PR #121 (`apt-get upgrade` kwam uit de layer cache en haalde daardoor geen
Debian-security-updates meer binnen; plus een wekelijkse job `apt-security-refresh` die de
gepubliceerde image op beide architecturen herscant) leverde zeven vervolgissues op. Dit
bestand houdt bij hoe die worden afgewerkt en waar het werk staat, zodat een afgebroken
sessie op dezelfde plek verder kan.

## Basis-branch

PR #121 is nog niet gemerged. Zolang dat zo is, vertrekt elke nieuwe branch vanaf de branch
van de vorige PR in de reeks — de eerste vanaf `fix/apt-cache-bust-security-updates`, de
volgende vanaf `chore/actionlint-in-ci`, enzovoort, zodat dit voortgangsbestand meereist.
Vanaf `main` beginnen geeft gegarandeerd conflicten: #130 raakt dezelfde workflow, #124
hetzelfde scanfilter en #127 bouwt voort op de scanroute uit #125. De PR-beschrijving noemt welke PR de basis is; zodra
#121 landt wordt de hele stack gerebased. Is #121 wél gemerged, dan begint elke branch vanaf
`main`.

## Volgorde

#129 gaat voorop; daarna liggen twee paren vast (#130 vóór #126, #125 vóór #127) en is de
rest vrij.

| # | Onderwerp | Waarom hier |
|---|---|---|
| 129 | actionlint in CI | bewaakt alle volgende PR's, dus eerst |
| 124 | `.trivyignore` → `.trivyignore.yaml` met paths en `expired_at` | vrij; raakt wel hetzelfde scanbestand als #125 en #127 |
| 130 | auto-PR-jobs verifiëren hun eigen wijziging (`rtk-version`, `delta-version` eerst) | legt de vorm vast die #126 uitbreidt |
| 126 | beschikbaarheid van de fix controleren vóór er een bump-PR opengaat | zelfde jobs als #130 |
| 125 | wekelijkse scan op de gepubliceerde SBOM in plaats van de volledige image | levert de scanroute waar #127 op leunt |
| 127 | SARIF naar code scanning + step summary | bouwt op de scanroute uit #125 |
| 128 | native arm64-runners in plaats van QEMU | raakt cosign; apart en zorgvuldig |

Nevenbevindingen krijgen een eigen issue en staan onderaan de statustabel; die blokkeren de
volgorde niet. #131 en #133 komen uit #129; #131 wacht op #130, omdat de auto-PR-job die het
nodig heeft daar zijn vorm krijgt.

## Werkwijze per issue

- Lees het issue volledig, inclusief "Technische details" en latere aanvullingen.
- Eén pull request per issue, strikt tot dat ene issue beperkt. Ontdek je iets anders, maak
  er een issue van.
- Branch-prefix naar aard: `fix/`, `feat/`, `chore/`, `docs/`.
- Nederlands in commits, PR's, documentatie en comments; conventional commits.
- Nooit direct naar `main` pushen. Geen reviewer toevoegen aan de PR.
- Raak je de Dockerfile of de tool-, plugin- of skill-lijsten, werk dan
  `claude-sandbox/README.md` in dezelfde commit bij.
- Controleer vóór het committen dat commit-onderwerp en -inhoud overeenkomen: stage per
  onderwerp, niet het hele bestand als er meerdere onderwerpen in zitten.

## Verificatie per issue

- `actionlint` over elk gewijzigd workflowbestand.
- Shelllogica testen door het `run:`-blok uit de YAML te halen en tegen fixtures te draaien,
  inclusief de degeneratiegevallen: lege of onvolledige scanuitvoer, ontbrekend artefact,
  ontbrekende architectuur, ongeldige datum, nul substituties. Een guard die alleen op het
  goede pad getest is, telt niet als getest.
- Bij wijzigingen aan de image: `docker compose build --no-cache`, met het resultaat in de
  PR. Kun je niet bouwen, zeg dat expliciet in de PR in plaats van het weg te laten.
- Wachten op groene CI voor de PR als klaar gepresenteerd wordt.
- #125 heeft een harde go/no-go: beide scanroutes in één run draaien en de CVE-ID-sets van
  `Class == "os-pkgs"` diffen. Niet identiek, dan gaat de oude route niet weg.
- #128 heeft een harde go/no-go: de handtekening op de samengestelde index moet
  verifieerbaar zijn en provenance en SBOM moeten per architectuur meekomen.

## Review-loop per PR

Per PR een reviewronde met subagents vóór hij als klaar gepresenteerd wordt: `code-reviewer`,
`silent-failure-hunter` en `comment-analyzer` parallel, plus de skills `digital-waste-spotter`
en `nerds:nerds-veiligheid` wanneer de PR CI-kosten of kwetsbaarhedenbeheer raakt. Geef elke
agent mee wat er uit eerdere rondes al verwerkt is, zodat bewust afgewezen bevindingen niet
terugkomen. Verifieer elke Hoog-bevinding zelf voor je hem opvolgt. Verwerk Hoog en Medium,
weeg Laag, en zet af wat buiten scope valt als issue. Herhaal tot een ronde geen Hoog en geen
Medium meer oplevert, met een maximum van drie rondes.

## PR-beschrijving

Wat er wijzigt, waarom, wat geverifieerd is met commando en uitkomst, en expliciet wat níét
geverifieerd is. Kort houden. Koppel elke PR aan zijn issue met een verwijzing in de titel,
zoals `(#125)`. Gebruik alleen een closing keyword als álle acceptatiecriteria van dat issue
afgevinkt zijn. #108 blijft open tot #127 en #124 rond zijn — dat zijn de twee resterende
criteria.

## Status per issue

| # | Onderwerp | Status | Branch | PR | Laatste afgeronde stap |
|---|---|---|---|---|---|
| 129 | actionlint in CI | PR open | `chore/actionlint-in-ci` | #132 | drie reviewrondes verwerkt, CI groen |
| 124 | `.trivyignore.yaml` | PR open | `chore/trivyignore-yaml` | #134 | drie reviewrondes verwerkt, CI groen |
| 130 | auto-PR-jobs verifiëren hun wijziging | open | — | — | — |
| 126 | beschikbaarheid fix vóór bump-PR | open | — | — | — |
| 125 | scan op gepubliceerde SBOM | open | — | — | — |
| 127 | SARIF naar code scanning | open | — | — | — |
| 128 | native arm64-runners | open | — | — | — |
| 131 | upstream-tracking voor de actionlint- en shellcheck-pin | open | — | — | — |
| 133 | inputs van gepinde actions worden niet gecontroleerd | open | — | — | — |

Statuswaarden: open / in uitvoering / PR open / gemerged. Werk deze tabel bij vóór je aan een
stap begint en direct nadat je hem afrondt — niet aan het eind van een sessie, want een
afbreking komt midden in een stap.

## Doorgaan na een gebruikslimiet

Een gebruikslimiet breekt de lopende beurt af zonder kans om nog iets in te plannen. Daarom
draait er een terugkerende taak die dit bestand leest en verdergaat met het eerstvolgende
issue dat niet op "gemerged" staat. Ruim die taak op zodra alles in de statustabel gemerged
is.
