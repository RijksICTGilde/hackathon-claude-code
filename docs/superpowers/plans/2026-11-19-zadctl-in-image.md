# zadctl in de image, met wekelijkse tracking

## Context

Wie met ZAD werkte, zette zadctl tot nu toe met de hand in `~/.local/bin`. Zo'n binary volgt geen enkele release. Hij liep daardoor ongemerkt achter: 0.13.4 tegen 0.14.1. zadctl komt nu in de image, op versie plus SHA-256, achter de bestaande toggle `INSTALL_OVERHEID_ZAD_ACTIONS`. Een job in `check-upstream.yml` opent een PR bij elke nieuwe release.

## Stappen

1. **Dockerfile-laag** na de just-laag, vóór de setuid-strip. De laag haalt de officiële release-asset `zadctl_linux_<arch>.tar.gz` op, controleert de SHA-256 per architectuur, en installeert naar `/usr/local/bin/zadctl`. De versiecontrole draait als nobody met een wegwerp-`HOME` en `TMPDIR`, omdat de onefile-binary zich bij de eerste start uitpakt in `~/.cache`. Een `find` controleert daarna dat nobody niets heeft achtergelaten.
   *Verificatie:* de laag zelf, uit de Dockerfile geknipt, op de gepinde `debian:13.7-slim` (podman, `--format docker`, apt via https). Met `true` geeft `zadctl --version` als gewone gebruiker `zadctl 0.14.1`, en `/tmp` blijft leeg. Met `jaja` faalt de build op de FOUT-melding. Met `false` slaat de laag zadctl over. De SHA's zijn met `sha256sum -c` gecontroleerd tegen de `SHA256SUMS` van v0.14.1.
2. **Job `zadctl-version`.** Die leest `releases/latest` van `RijksICTGilde/zad-cli` en valideert de tag op `^v[0-9]+\.[0-9]+\.[0-9]+$`. De SHA's komen met awk uit de `SHA256SUMS` van die release, op de exacte bestandsnaam. Bij een gelijke versie toetst de job ook de pins. Een bump gaat via `vervang-pin.sh` naar een PR op `deps/zadctl`.
   *Verificatie:* actionlint met shellcheck is schoon.
3. **Fixtures** in `test-check-upstream-jobs.sh`, 26 gevallen: gelijk, bump, afwijkende pin, vier ongeldige tags, een release die niet op te halen is, ontbrekende `SHA256SUMS`, een ongeldige checksum, een dubbele pin, en de PR-stap.
   *Verificatie:* 379 geslaagd, 0 gefaald. Mutatiecheck op de job: een losser tagpatroon, de pincontrole uit, een awk-match op deel van de naam, en de arm64-pin met de amd64-SHA. Alle vier worden gevangen. De awk-mutatie werd pas gevangen na `.sbom`-lokregels in de fixture-`SHA256SUMS`.
4. **Docs**: de tools-tabel en de pinning- en check-upstream-secties in `claude-sandbox/README.md`, de toggle-tabel in `docs/opstarten-en-afsluiten.md`, en `.env.sample`.

## Ontwerpkeuzes

- **De toggle `INSTALL_OVERHEID_ZAD_ACTIONS`.** zadctl en de zad-actions-plugin horen bij dezelfde keuze, met ZAD werken, en de default blijft uit. Dat is een keuze van de gebruiker. Een eigen build-arg en een eigen build-variant had geen meerwaarde.
- **De laag laat in de Dockerfile.** De ARG staat al bovenaan. Een bump van de pin laat de lagen ervóór in de cache.
- **Geen versienummer in de README.** zadctl brengt vaak releases uit. Zonder nummer hoeft de job de README niet te bumpen.
- **`~/.local/bin` gaat voor.** `PATH` begint met `/home/claude/.local/bin`, dus een eigen binary in het `claude-home`-volume wint van de image-versie. De README noemt dat.

## Niet geverifieerd

- Een volledige image-build lokaal. Apt over http is hier dicht. De PR-build `build-variants` bouwt met `INSTALL_OVERHEID_ZAD_ACTIONS=true`, alleen op amd64.
- arm64. Dat komt pas bij de push naar `main`. De arm64-SHA is wel gecontroleerd tegen `SHA256SUMS`.
