# Verweesde Trivy-suppressies zichtbaar maken

## Context

Een regel in `.trivyignore.yaml` die niets meer raakt, houdt elke gate groen, ook na `expired_at`: er valt niets te onderdrukken. Lost een kubectl-, helm-, functl- of npm-release een CVE op, dan komt de bump binnen, maar de regel en een eventuele melding aan gebruikers (zoals die over CVE-2026-111943 in `claude-sandbox/docs/kubernetes.md`) blijven staan.

Gestapeld op #213.

## Stappen

1. **`controleer-verweesde-suppressies.sh <lijst> <rapport>...`.** Krijgt een of meer Trivy-JSON-rapporten die zonder suppressies zijn gemaakt. Per regel onder `vulnerabilities` past het script met `trivy convert --ignorefile` alleen die regel toe, zonder `expired_at`, op elk rapport. Telt geen enkel rapport daarna minder bevindingen, dan is de regel verweesd. De uitvoer gaat via `--output` naar een bestand en moet een getal opleveren.
   *Verificatie:* `test-controleer-verweesde-suppressies.sh` (27 gevallen, Trivy 0.70.0), en lokale scans van de echte helm-v4.3.1-, kubectl-v1.35.10- en functl-binaries plus `trivy fs` op de repo: alle K8S- en functl-regels raken iets.
2. **`controleer-suppressie-verwijzingen.sh [lijst] [map]`.** Elke HTML-comment-marker `trivyignore: <id> <pad-of-purl>` in een getrackt Markdown-bestand (ook `.MD`) moet naar een regel met dat id en die binding verwijzen. Alles wat op een marker lijkt (`trivy-ignore`, hoofdletters, afwijkende spaties) maar die vorm niet heeft, faalt.
   *Verificatie:* `test-controleer-suppressie-verwijzingen.sh` (29 gevallen). Tegen de repo is de uitkomst groen, en rood met een lege lijst.
3. **`valideer-trivyignore.sh`** eist precies één pad of purl per regel onder `vulnerabilities`.
   *Verificatie:* `test-valideer-trivyignore.sh` (33 gevallen), groen op de huidige lijst.
4. **`build-variants`.** Na de scans volgen twee JSON-rapporten zonder suppressies: de image (os- en language-pakketten) en de repo (`trivy fs`), met de DB van de scans. Daarna draait de controle uit stap 1. Beide stappen draaien ook als een eerdere scan faalt, net als de rest van die job.
   *Verificatie:* actionlint met shellcheck schoon. De stappen zelf hebben niet in CI gedraaid: build-image draait alleen op een PR naar `main`.
5. **`scriptcontroles`.** `setup-trivy` (dezelfde pin als in trivy-action v0.36.0, Trivy v0.70.0), de fixture-sets en de controle uit stap 2 op de repo. De workflow draait ook op `merge_group`.
   *Verificatie:* groen in CI op deze PR.
6. **Marker** bij de helm-melding in `docs/kubernetes.md`. Verder de comments in `.trivyignore.yaml`, de PR-teksten van de npm-, kubectl- en helm-jobs, en `CLAUDE.md` bijgewerkt.

## Ontwerpkeuzes

- **Matching via Trivy, niet nagebouwd.** Trivy matcht paden met doublestar-globs en purls met optionele versie. Nabouwen in bash of jq wijkt af in randgevallen. `trivy convert` werkt op het rapport, dus zonder netwerk en zonder DB.
- **Twee rapporten, tot MEDIUM.** De lijst wordt gelezen door de image-gates, de fs-gate en de SARIF-scan in `trivy.yml` (die MEDIUM meeneemt). Een regel die alleen een bevinding in de repo of een MEDIUM onderdrukt, is dus niet verweesd. Het image-rapport komt van `build-variants`: die image bevat alles van de default-image en elke opt-in-laag.
- **Niet in `build-and-push`.** Daar zouden de regels voor kubectl, helm en functl altijd verweesd lijken.
- **Een leeg ignorefile in plaats van `--ignorefile ''`.** Trivy 0.70.0 weigert een lege waarde. Zonder vlag leest hij een `.trivyignore` uit de werkmap.
- **De marker draagt de binding.** CVE-2026-78661 staat op drie binaries. Een marker met alleen het id zou blijven kloppen zolang één van die regels bestaat, ook als de regel waar de melding over gaat weg is. Om dezelfde reden bindt elke `vulnerabilities`-regel aan één pad of purl: een tweede binding zou blijven onderdrukken nadat de eerste niets meer raakt.
- **Markers alleen in getrackte Markdown.** Een melding aan gebruikers staat in de docs. Ongetrackte bestanden, zoals andere worktrees onder `.claude/`, tellen niet mee.
- **Misconfig-regels vallen erbuiten.** De scans draaien alleen de vuln-scanner. De twee misconfig-regels leggen een architectuurkeuze vast en hangen niet aan een release.
- **Required checks.** `build-variants` en `Fixtures van de CI-scripts` zijn geen required check. Zonder dat blokkeert een rode controle de merge niet. De ruleset hoort niet bij deze PR.

## Mutatiecheck

Eerste versie: 22 mutaties, 21 gevangen. De overlever (`-ne` naar `-lt` in de markervergelijking) is equivalent: het strikte patroon matcht nooit vaker dan het losse.

Na de review: 19 mutaties op de herziene scripts, 17 gevangen. De overlevers zijn `break` weglaten (alleen meer werk) en `inherit_errexit` weglaten (de getalcontrole na elke telling vangt hetzelfde).
