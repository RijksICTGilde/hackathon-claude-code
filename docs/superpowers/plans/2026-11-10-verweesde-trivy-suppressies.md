# Verweesde Trivy-suppressies zichtbaar maken

## Context

Een regel in `.trivyignore.yaml` die niets meer raakt, houdt elke gate groen. Dat blijft ook zo na `expired_at`, want er valt niets te onderdrukken. Lost een kubectl-, helm- of npm-release een CVE op, dan komt de bump binnen, maar de regel en een eventuele melding aan gebruikers (zoals die over CVE-2026-111943 in `claude-sandbox/docs/kubernetes.md`) blijven staan. Alleen de tekst in de auto-PR vraagt erom ze op te ruimen.

Gestapeld op #213.

## Stappen

1. **`controleer-verweesde-suppressies.sh <rapport> [lijst]`.** Krijgt een Trivy-JSON-rapport dat zonder suppressies is gemaakt. Per regel onder `vulnerabilities` past het script met `trivy convert --ignorefile` alleen die regel toe, zonder `expired_at`. Telt het rapport daarna niet minder bevindingen, dan is de regel verweesd.
   *Verificatie:* `test-controleer-verweesde-suppressies.sh` (18 gevallen), en een rootfs-scan van de echte helm-v4.3.1- en kubectl-v1.35.10-binaries.
2. **`controleer-suppressie-verwijzingen.sh [lijst] [map]`.** Elke HTML-comment-marker `trivyignore: <id>` in een getrackt `*.md`-bestand moet naar een id in de lijst verwijzen. Een marker in een afwijkende vorm faalt ook.
   *Verificatie:* `test-controleer-suppressie-verwijzingen.sh` (17 gevallen). Tegen de repo is de uitkomst groen, en rood met een lege lijst.
3. **`build-variants`.** Na de twee scans volgt een JSON-scan zonder suppressies, over os- en language-pakketten, met dezelfde DB. Daarna draait de controle uit stap 1. Beide stappen draaien ook als een eerdere scan faalt, net als de rest van die job.
4. **`scriptcontroles`.** `setup-trivy` (dezelfde pin als in trivy-action v0.36.0, Trivy v0.70.0), beide fixture-sets, en de controle uit stap 2 op de repo.
5. **Marker** bij de helm-melding in `docs/kubernetes.md`. Verder de comments in `.trivyignore.yaml`, de PR-teksten van de npm-, kubectl- en helm-jobs, en `CLAUDE.md` bijgewerkt.

## Ontwerpkeuzes

- **Matching via Trivy, niet nagebouwd.** Trivy matcht paden met doublestar-globs en purls met optionele versie. Nabouwen in bash of jq wijkt af in randgevallen. `trivy convert` werkt op het rapport, dus zonder netwerk en zonder DB.
- **Alleen in `build-variants`.** Die image bevat alles van de default-image en elke opt-in-laag, dus elke `vulnerabilities`-regel hoort daar iets te raken. In `build-and-push` zouden de regels voor kubectl en helm altijd verweesd lijken. Die job is bovendien required, en een DB-update mag de merge queue niet blokkeren.
- **Os- én language-pakketten in de JSON-scan**, zoals de twee scans van `build-variants` samen. Zo vallen ook regels voor apt-pakketten onder de controle.
- **Een leeg ignorefile in plaats van `--ignorefile ''`.** Trivy 0.70.0 weigert een lege waarde. Zonder vlag leest hij een `.trivyignore` uit de werkmap.
- **Markers alleen in Markdown, alleen in getrackte bestanden.** Een melding aan gebruikers staat in de docs. Ongetrackte bestanden, zoals andere worktrees onder `.claude/`, horen niet mee te tellen.
- **Misconfig-regels vallen erbuiten.** De scans in `build-variants` draaien alleen de vuln-scanner. De twee misconfig-regels leggen een architectuurkeuze vast en hangen niet aan een release.

## Mutatiecheck

22 mutaties, 21 gevangen. De overlever (`-ne` naar `-lt` in de markervergelijking) is equivalent: het strikte patroon matcht nooit vaker dan het losse.
