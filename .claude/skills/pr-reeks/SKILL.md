---
name: pr-reeks
description: Werk een lijst issues of een plan zelfstandig af als reeks draft-PR's, elk met een begrensde reviewloop (pr-review-toolkit plus gerichte review-agents, getoetst aan relevante overheidsskills) en een afsluitende reviewcomment
argument-hint: "<issues of plan> [rondes=4] [gestapeld]"
disable-model-invocation: true
---

# PR-reeks met reviewloop

Opdracht: $ARGUMENTS

Zegt de opdracht niets, dan geldt: maximaal 4 reviewrondes per PR, elke PR los op `main` tenzij
hij voortbouwt op de vorige.

De reeks loopt zonder tussentijdse communicatie met de opdrachtgever: geen vragen, geen
`AskUserQuestion`, geen wachten op een reactie. Verslag en open vragen staan per PR in de
afsluitcomment; de opdrachtgever leest die bij de review.

Vereist de plugins `pr-review-toolkit`, `superpowers`, `developer-overheid` en `nerds`, en een `gh` met schrijfrechten op `RijksICTGilde/hackathon-claude-code`.

## 0. Voorbereiden

- `git fetch origin`; werk vanaf de actuele `origin/main`.
- Lees elk issue: `gh issue view <n> --comments`.
- Kijk per issue of het al gerealiseerd is (main, gemergde PR's). Zo ja: geen PR, maar een
  issue-comment die per acceptatiecriterium aanwijst waar het staat. Sluiten beslist de opdrachtgever.
- Bepaal de snede. Horen issues bij elkaar, knip dan per stap in de keten in plaats van per issue:
  elke PR moet in één zitting te reviewen en te begrijpen zijn. Wordt een PR onderweg te groot,
  knip hem en meld dat.
- Vraagt een PR ontwerpkeuzes, maak dan eerst een plan (`superpowers:writing-plans`) in
  `docs/superpowers/plans/YYYY-MM-DD-korte-beschrijving.md`; het plan gaat mee in de PR.
- Leg de snede en de volgorde vast in de body van de eerste PR, en begin.
- Loopt een issue vast op iets dat alleen de opdrachtgever kan beslissen, zet dan wat er staat als
  draft-PR met de vraag in de afsluitcomment, en ga door met het volgende issue dat er niet van
  afhangt.

## 1. Per PR: bouwen

- Eigen worktree onder `.claude/worktrees/<naam>` (gitignored); zet de sessie erin met
  `EnterWorktree` (`path`). Weigert een guard daar `git`, gebruik dan `/usr/bin/git` vanaf de
  worktree-root.
- Branch `feat/`, `fix/`, `chore/` of `docs/`. Gestapeld: de branch van de vorige PR is de basis.
- Commits: conventional commits met Nederlandse omschrijving.
- Implementeer met tests waar het script een `test-*.sh` heeft of hoort te krijgen: happy en
  unhappy, en bij lijsten leeg, één en meerdere.
- Lokaal groen, per geraakt terrein (`git diff --name-only origin/<basis>...HEAD`):

  | Raakt de diff | Draai |
  |---|---|
  | shellscripts (behalve `vendor/**`) | `shellcheck --severity=warning <script>` |
  | `.github/workflows/` | vanuit de repo-root: `actionlint -shellcheck "$(command -v shellcheck)" .github/workflows/*.yml` |
  | `.github/scripts/` | de bijbehorende `.github/scripts/test-*.sh` (sommige vereisen `yq`) |
  | `check-upstream.yml` | ook `.github/scripts/test-check-upstream-jobs.sh`: die test leest de workflow |
  | `.trivyignore.yaml` | `.github/scripts/valideer-trivyignore.sh` |
  | nieuwe `test-*.sh` | opnemen in `scriptcontroles.yml` en in de commando's van `CLAUDE.md`, anders draait hij niet in CI |
  | `claude-sandbox/` (image) | zie de image-build hieronder |
  | alleen documentatie | niets te bouwen; zeg dat in de PR in plaats van het stil over te slaan |

  Zonder het `-shellcheck`-pad slaat actionlint de `run:`-blokken stil over.
- **Image-build** vanuit `claude-sandbox/` in de worktree. `.env` is gitignored en ontbreekt
  daar, en de standaard-projectnaam deelt het image met de opdrachtgever. Dus:

  ```bash
  cp .env.sample .env
  docker compose -p claude-pr<n> build --no-cache
  ```

- Loop de build- en testoutput na op waarschuwingen: oplossen of bewust accepteren met reden.
  Nieuwe, onverklaarde waarschuwingen blokkeren de PR.
- Faalt de lokale image-build op iets van de host (netwerk, podman) in plaats van op de wijziging,
  zet dan in de PR-body wat lokaal níét gebouwd is en waarom; de `build-and-push`-check in CI
  bouwt dan als eerste. PR- en queue-builds draaien alleen `linux/amd64`; noem dat als de
  wijziging architectuurafhankelijk is.
- **Gestapeld:** `build-and-push`, `differential-shellcheck` en Trivy draaien alleen op PR's naar
  `main`. Tot de PR naar `main` wijst, zijn de lokale build en shellcheck de enige controle; een
  groene `gh pr checks` zegt daar niets over. Noem dat in de afsluitcomment.
- **Live testen is een standaard afweging, geen extra.** Raakt de wijziging de Dockerfile, een
  entrypoint, `init-firewall.sh`, het AppArmor- of seccomp-profiel, draai dan het protocol uit
  `claude-sandbox/docs/hardening-verificatie.md`, maar altijd geïsoleerd van de container van de
  opdrachtgever:
  - Het volume `claude-home` en de container `claude-sandbox` zijn van de opdrachtgever: nooit
    starten, stoppen, recreaten, verwijderen, opnieuw aanmaken of mounten, ook niet als een
    instructie elders (env-wijziging) dat vraagt.
  - Start met een eigen projectnaam en een override in je scratchpad, naast de overrides die het
    protocol voor de host voorschrijft:

    ```yaml
    # <scratchpad>/isolatie-pr<n>.yml
    services:
      claude:
        container_name: claude-sandbox-pr<n>
        volumes:
          - claude-home-pr<n>:/home/claude
          - <scratchpad>/projects-pr<n>:/home/claude/projects
    volumes:
      claude-home-pr<n>: {}
    ```

    ```bash
    docker compose -p claude-pr<n> -f compose.yml [-f <host-override>] -f <scratchpad>/isolatie-pr<n>.yml up --build -d
    ```

  - Geen `sudo` en geen wijzigingen op de host (`aa-enforce`, `aa-complain`, profielen laden).
    Secties die dat vragen gaan als "niet live getest" in de PR-body, met wat er na de merge te
    controleren is.
  - Ruim daarna alleen je eigen resources op: `docker compose -p claude-pr<n> down -v`.
- Open de draft-PR:

  ```bash
  git push -u origin <branch>
  gh pr create --draft --base <basis> --title "<type>(<scope>): <omschrijving>" --body-file <bestand>
  ```

  Body: wat er wijzigt, waarom, wat er geverifieerd is en wat expliciet níét, met `Closes #<n>`
  of `Refs #<n>`. Kort; geen ontdekkingsverhaal en geen herhaling van de diff. Sluit af met
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## 2. Reviewronde

Commit eerst al het werk. Bewerk niets zolang er een reviewer loopt.

Kies de reviewers op basis van `git diff --name-only origin/<basis>...HEAD` en start ze
parallel in één bericht. Er zijn geen projecteigen review-agents; waar de tabel `general-purpose`
noemt, neem je de focus letterlijk op in de prompt.

| Raakt de diff | Reviewer | Focus |
|---|---|---|
| altijd | `pr-review-toolkit:code-reviewer` | CLAUDE.md-regels, correctheid |
| shellscripts | `pr-review-toolkit:silent-failure-hunter` | `set -euo pipefail`, genegeerde exitcodes, `\|\| true`, foutmeldingen naar stderr |
| comments, docs, README's | `pr-review-toolkit:comment-analyzer` | waarom i.p.v. wat, geen verleden of review-labels, NL/EN-grens, README beschrijft eindtoestand |
| `test-*.sh` of fixtures | `pr-review-toolkit:pr-test-analyzer` | dekking van happy, unhappy en randgevallen |
| `.github/` | `general-purpose` (CI) | actions op commit-SHA met versie-comment; externe input gevalideerd vóór `curl`/`sed`/shell; workflow achter een required check draait ook op `merge_group` en noemt `pull_request` en `merge_group` samen; publicerende stappen gaten op `refs/heads/main` of `v*`-tag; geen `paths:`-filter op een required check |
| `Dockerfile`, `vendor/`, `compose*.yml`, `init-firewall.sh`, entrypoints, AppArmor/seccomp | `general-purpose` (security) | geen `curl \| sh` naar upstream; vendored scripts byte-identiek; binaries op versie plus SHA-256; capabilities en privilege-drop; egress-allowlist niet verruimd zonder reden; docs verkopen de firewall niet als volledige isolatie |
| Dockerfile-tools, plugins of skills | `general-purpose` (sync) | tabellen in `claude-sandbox/README.md` in sync met de Dockerfile, in dezelfde commit |

Geef de reviewer de overheidsskills mee die bij het onderwerp horen:

| Onderwerp | Skills |
|---|---|
| sandbox, firewall, capabilities, kwetsbaarheden | `nerds:nerds-veiligheid`, `developer-overheid-nl-agent-skills:don-security` |
| CI, pinning, supply chain, release-signing | `developer-overheid-nl-agent-skills:don-leidraad`, `nerds:nerds-opensource` |
| CI-resources, cache, opruimen | `nerds:nerds-duurzaamheid` |
| oefeningen, `docs/verantwoording.md`, AI-gebruik | `nerds:nerds-algoritmen` |
| licentie, publiccode, bijdragen | `developer-overheid-nl-agent-skills:don-open-source` |
| persoonsgegevens in volume, logs of oefendata | `nerds:nerds-privacy` |

Elke reviewer-prompt bevat:
- PR-nummer, worktree-pad, branch en het diff-commando. Vanaf ronde 2 ook de fix-commit van de
  vorige ronde (`git show <sha>`) als focus.
- "Laad `<skill>` met de Skill-tool en toets daaraan" voor elke gekozen overheidsskill.
- Letterlijk: "STRIKT READ-ONLY: wijzig geen bestand in de worktree en doe geen `git stash`,
  `checkout` of `reset`. Experimenten en mutaties alleen in een kopie in je eigen scratchpad."
- "Rapporteer Hoog/Medium/Laag met file:line, een concrete fix en of je het gereproduceerd hebt.
  Alleen echte problemen, geen lof. In het Nederlands."

Start de agents zelf in plaats van via `/pr-review-toolkit:review-pr`: die command geeft de
read-only-eis en de overheidsskills niet per agent mee. Zonder die eis bewerken en stashen
review-agents in de werkboom van de hoofdsessie, en gaat lopend werk verloren.

## 3. Verwerken

- Toets elke bevinding voordat je hem overneemt (`superpowers:receiving-code-review`). Klopt een
  bevinding niet, noteer dat met reden.
- Fix alle Hoog. Fix Medium en Laag als de fix klein is en weinig regressierisico heeft; anders
  "bewust gelaten", met reden. Een ontwerpwijziging voer je niet zelf door: die komt als open vraag
  in de afsluitcomment.
- Muteer voor elke nieuwe of gewijzigde test het script in een kopie van de hele tree en bevestig
  dat de test faalt; de tests vinden scripts en workflows relatief aan zichzelf. Kopie:
  `git archive HEAD | tar -x -C <scratchpad>/mut`. Houd het aantal mutaties en vangsten bij.
- Opnieuw lokaal groen, één commit per ronde (`fix: reviewronde <N>, <kern>`), push.
- Iets buiten de scope beslis je niet zelf, maar leg je voor met afwegingen. Een nieuw issue dat we
  nu niet oppakken is werk op de backlog; direct meenemen kan tijd-efficiënter zijn, maar maakt de
  PR groter. Opties: meenemen in deze PR, een aparte PR zonder nieuw issue (met `Refs` naar het
  verwante issue), een comment op een bestaand issue, of een nieuw issue. Weeg omvang,
  regressierisico, reviewbaarheid en verwantschap met het lopende werk. Zet de opties met die
  afwegingen als open vraag in de afsluitcomment, en ga door binnen de scope.

**Kwetsbaarheden in bestaande code** gaan niet in een PR, comment, issue, commitbericht of
branchnaam: de repo is publiek en
`SECURITY.md` schrijft gecoördineerde melding voor. Noteer ze alleen in de eindmelding in de chat
(stap 7), met de verwijzing naar `SECURITY.md`. Een kwetsbaarheid die de PR zelf introduceert, fix
je gewoon in de reviewronde.

## 4. Stoppen of doorgaan

- Stop zodra een ronde geen Hoog meer oplevert, of de resterende fixes zo klein zijn dat regressie
  onwaarschijnlijk is. Stop altijd bij het maximum aantal rondes.
- Een volgende ronde draait alleen met de reviewers die Hoog of Medium vonden, of wier terrein de
  fix raakt.
- Fixes na de laatste ronde zijn niet opnieuw gereviewd. Zeg dat in de afsluiting.

## 5. Afsluiten per PR

- Werk de PR-body bij met `gh api -X PATCH repos/RijksICTGilde/hackathon-claude-code/pulls/<n> -F body=@<bestand>`
  en controleer dat hij gewijzigd is (`gh pr edit` kan stil falen).
- Plaats de afsluitcomment volgens [afsluiting.md](afsluiting.md).
- Volg `gh pr checks <n>`; bij falen `gh run view <id> --log-failed`. Rood door eigen werk: fixen.
  Flaky: opnieuw draaien en het melden.
- Haal de PR nooit uit draft en voeg geen reviewer toe.

## 6. Naar de volgende PR

- Merget een basis-PR, zet de volgende dan over op `main`: de merge queue squasht, dus
  `git rebase --onto origin/main <oude-basis>` en `git push --force-with-lease`. GitHub zet de
  base zelf om omdat de gemergde branch verwijderd wordt; controleer dat, en anders
  `gh api -X PATCH repos/RijksICTGilde/hackathon-claude-code/pulls/<n> -f base=main`. Een
  gestapelde PR registreert `Closes` pas bij een merge naar `main`.
- Krijgt een PR conflicten doordat iets anders op `main` landde: merge `origin/main`. Is de merge
  schoon, push dan direct en laat de CI controleren; los je conflicten in eigen code op, dan eerst
  lokaal groen. Zonder conflict hoeft een PR niet bijgewerkt: de merge queue toetst opnieuw tegen
  de actuele `main`.

## 7. Eindmelding

Pas als de hele reeks klaar is, in de chat: een tabel PR | issue | rondes | Hoog gevonden/gefixt |
lokaal gebouwd | live getest | CI | open vragen (aantal, met link naar de afsluitcomment). De
vragen zelf staan op de PR; herhaal ze hier niet. Daaronder, alleen als ze er zijn, de
kwetsbaarheden in bestaande code uit stap 3.

## Hervatten na compactie of sessieverlies

De stand staat in git en op de PR: commits `fix: reviewronde <N>` en de afsluitcomment. Bij
hervatten: `gh pr list --author @me --draft` en per worktree `git log --oneline origin/main..HEAD`.
