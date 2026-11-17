# Shell in de sandbox openen in de huidige projectmap

## Context

Na `docker exec -tiu claude claude-sandbox bash` land je altijd in `/home/claude/projects` en navigeer je zelf naar je project. Omdat Claude zijn historie onthoudt per map waarin hij gestart is, gebeurt dat bij elke sessie opnieuw.

## Stappen

1. **`claude-sandbox/sandbox-shell.sh`.** Leest via `docker inspect --type container` de hostbron van de mount op `/home/claude/projects`. Ligt de huidige map (`pwd -P`) daaronder, dan krijgt `docker exec -w` het bijbehorende containerpad. Anders start de shell in `/home/claude/projects`, met een melding. Argumenten worden als commando uitgevoerd in plaats van `bash`. `-t` gaat alleen mee als stdin en stdout een terminal zijn.
   *Verificatie:* tegen de draaiende container: de root van de mount, een submap en een diepere submap landen op het juiste pad. `~/dev` en `/tmp` buiten de mount geven de melding. Een pad via een symlink werkt en de shell draait als `claude`. Zonder terminal werken `| cat` en stdin via een pipe. Een onbekende container geeft de foutmelding van docker en exit 1. shellcheck schoon op alle niveaus. Onder `bash:3.2`: `bash -n` en de padlogica, inclusief `/a/bc` naast `/a/b`.
2. **Documentatie.** Een sectie in `docs/opstarten-en-afsluiten.md` en een verwijzing in de quick start van `claude-sandbox/README.md`.

## Ontwerpkeuzes

- **Hostpad uit de container, niet uit `.env`.** `docker inspect` geeft de mount zoals de container echt gestart is, ook met een aangepaste `PROJECTS_DIR` of een override. `.env` lezen zou ook relatieve paden moeten oplossen ten opzichte van `claude-sandbox/`.
- **`pwd -P` aan beide kanten.** Symlinks (zoals `/tmp` naar `/private/tmp` op macOS) laten de prefixvergelijking anders mislukken.
- **Prefix met afsluitende `/`.** `case "$hier/" in "$bron"/*)` voorkomt dat `/a/bc` als submap van `/a/b` telt en dekt de root van de mount zonder aparte tak.
- **Altijd een melding bij terugvallen.** Een remote Docker-context of een runtime die paden vertaalt, levert een bron op die op deze host niet bestaat. De gebruiker moet zien dat de shell niet in de verwachte map start.
- **Bash 3.2-compatibel.** Geen `mapfile` of associatieve arrays, zodat het met de standaard-bash van macOS draait.

## Niet geverifieerd

Draaien op een echte Mac (alleen bash 3.2 in een container nagebootst) en een echte interactieve sessie. De tests liepen met `pwd`, `whoami` en `cat` via een pseudo-terminal en via pipes.
