# jdtls in de image

## Context

De image installeert de `jdtls-lsp`-plugin bij `INSTALL_JVM=true` en `INSTALL_ANTHROPIC_PLUGINS=true`. De plugin is alleen configuratie: hij start het commando `jdtls`, en dat programma zat niet in de image. Claude Code meldt dan `Language server "plugin:jdtls-lsp:jdtls" couldn't start: its program "jdtls" wasn't found`.

## Stappen

1. **Dockerfile.** De officiële milestone-tarball van download.eclipse.org, gepind op versie, build-stempel en SHA-256, uitgepakt in `/opt/jdtls` met genormaliseerde modes en een symlink in `/usr/local/bin`. Dezelfde voorwaarde als de plugin.
   *Verificatie:* lokale build (podman, apt via https in een scratchpad-kopie van de Dockerfile). In de container, als `claude`, met een JDK van de host gemount: met JDK 25 beantwoordt jdtls een LSP-`initialize` met `capabilities`; met JDK 21 faalt de start (`osgi.ee ... version=25`).
2. **`.trivyignore.yaml`.** De tarball bundelt Guava 33.7.1 (CVE-2026-102554, HIGH, fix in 33.7.2). Suppressie op het jar-pad, tot 2027-02-28.
   *Verificatie:* `valideer-trivyignore.sh` groen; `controleer-suppressie-verwijzingen.sh` groen.
3. **`check-upstream.yml`, job `jdtls-version`.** Leest de hoogste `X.Y.Z`-map uit de milestone-index, de tarballnaam uit `latest.txt`, downloadt, controleert gzip-magic, `bin/jdtls` in het archief en de `.sha256` van upstream, en bumpt de drie pins.
   *Verificatie:* 17 nieuwe gevallen in `test-check-upstream-jobs.sh` (370 geslaagd, 0 gefaald). Live tegen download.eclipse.org met de pins op 1.62.0 en nep-build/-SHA: de job komt uit op precies de pins in de Dockerfile.
4. **Docs.** README-tooltabel en plugintabel, de toggle-tabel en de SDKman-sectie in `docs/opstarten-en-afsluiten.md`, `.env.sample`.

## Ontwerpkeuzes

- **Geen JDK in de image.** Installeren vraagt alleen `curl`, `tar` en `sha256sum`; de launcher is Python. Java 25+ is pas nodig bij het starten, en `sdk install java` levert dat (Temurin 25). Een JDK in de image zou de keuze van de deelnemer overrulen.
- **Onder `/opt`, niet in `/home/claude`.** Een bump komt zo binnen zonder volume-recreate.
- **Milestone-index als bron, niet de GitHub-tags.** Het project publiceert geen GitHub-releases, en een tag kan bestaan voordat de milestone-map er is.
- **De `.sha256` van upstream is geen herkomstbewijs.** Hij staat op dezelfde server; de pin in de Dockerfile en review van de auto-PR zijn de controle. De vergelijking vangt een afgebroken of vervangen download.
- **`tar -tzf <archief> bin/jdtls` in plaats van `tar -t | grep -q`.** grep sluit de pipe bij de eerste treffer; onder `pipefail` faalt dan juist de echte tarball. De fixture-tarball heeft daarom 4000 namen na `bin/jdtls`.
- **Java 25, niet 21.** De launcher controleert op 21, maar de gebundelde Eclipse-plugins eisen `osgi.ee` 25. De auto-PR vraagt de reviewer dat per milestone na te gaan.
- **Modes normaliseren.** De tarball zet setgid op zijn mappen. De setuid/setgid-strip van de image pakt alleen bestanden; zonder effect op een root-map, maar de image hoort geen bits van een externe tarball over te nemen. `chmod -R u=rwX,go=rX` alleen laat setgid op mappen staan (GNU-gedrag); `ug-s` haalt het weg. Na de build staat er onder `/opt/jdtls` geen setuid- of setgid-bit meer.
- **kotlin-lsp valt erbuiten.** Die plugin start `kotlin-lsp`, dat ook niet in de image zit. De docs zeggen dat eerlijk.

## Mutatiecheck

De oude `grep -q`-controle teruggezet: de bump-fixture faalt (365 geslaagd, 5 gefaald). Hersteld: 370/0.
