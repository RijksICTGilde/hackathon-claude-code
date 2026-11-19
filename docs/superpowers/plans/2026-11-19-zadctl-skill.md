# Skill zadctl voor de sandbox

## Context

Wie in de container met ZAD werkt, loopt vast op drie dingen. `zadctl login` kan geen browser openen, en de callback naar `127.0.0.1` komt niet aan. Projectsleutels bestaan niet meer: `GET .../api-key` geeft 410. Een persoonlijk token vraagt een verse 2FA-code, en die is van de gebruiker, niet van Claude. De skill `zadctl` legt de werkende route vast. Het script `zad-token.sh` doet de uitgifte zonder dat de tokenwaarde op het scherm komt.

## Stappen

1. **Route bepalen.** zadctl v0.14.1 en upstream-`main` geven zelf geen token uit, en verwijzen naar de OM-pagina "Leden en tokens". De device flow staat uit bij de Keycloak-client `zad-cli` ("The flow is disabled for the client"). Dus blijft de route: de loopback-flow met `--browser --no-open`, daarna de callback-URL met de hand via `curl` naar de listener.
   *Verificatie:* `zadctl login --device --no-open` geeft die fout. Met `--browser --no-open` en de callback via `curl` volgt een geslaagde login, en `zadctl project list` werkt.
2. **Antwoordschema van de uitgifte.** De OpenAPI-spec geeft voor de 201 een leeg schema. De bron (`operations-manager/python/opi/api/token_router.py` in RIG-Cluster) geeft `UitgegevenToken {token, lid, naam}`. Uitgeven, roteren en intrekken vragen alle drie een step-up. Een tokennaam is uniek per lid.
   *Verificatie:* 201 met veld `token` bij de echte uitgifte.
3. **`zad-token.sh uitgeven|intrekken|leden`.** Het script valideert de invoer en haalt het lid uit de `email`-claim van het SSO-token. De API-URL en de SSO-issuer staan vast, ook niet via de omgeving. `.env.zadctl`, `~/.bashrc` en de env van Claude zijn allemaal door een agent te schrijven, en zouden tokens en de 2FA-code anders naar een eigen host sturen. Het access-token leeft ongeveer 5 minuten. Het script ververst het daarom eerst via zadctl, met die vaste waarden als geëxporteerde variabelen; die gaan bij zadctl voor op het bestand. Een tokennaam begint met een letter of cijfer en wordt `@uri`-gecodeerd. curl draait met `--path-as-is`, zodat `..` de DELETE niet naar het lid zelf stuurt. De Bearer staat in een headerbestand en de body gaat via stdin, dus het SSO-token en de 2FA-code staan niet in de argv van curl. De code staat wel in de argv van het script zelf; die is eenmalig. Het projectbestand wordt atomair geschreven, met mode 600. Een tokenwaarde met een newline wordt geweigerd. Faalt er iets na de uitgifte, of blijft een antwoord uit, dan noemt het script de tokennaam om in te trekken, en gaat het door met het volgende project. Een project dat twee keer in de lijst staat, wordt geweigerd. Het step-up-venster sluit bij afsluiten, ook als de step-up zelf geen antwoord kreeg. Mislukt het sluiten, dan waarschuwt het script.
   *Verificatie:* `.github/scripts/test-zad-token.sh` (41 gevallen, in `scriptcontroles`). De nep-curl bedient alleen de vaste OM-host en een Bearer uit een headerbestand, en de nep-zadctl logt de omgeving waarmee hij wordt aangeroepen. Mutatiecheck: twaalf mutaties op het script, alle twaalf gevangen. Echte runs: uitgifte (step-up 200, token 201 met veld `token`, gesloten 204), `zadctl deployment list` met het nieuwe token, en intrekken (200). Daarna stond het token niet meer in de ledenlijst, en de oude key werd geweigerd. Een loginmap waarvan `.env.zadctl` naar `evil.example` wijst: zadctl alleen faalt, met de overrides uit het script gaat hij naar de echte hosts.
4. **SKILL.md** met kernregels, het mappenschema, de login, het token, de ledenlijst, het intrekken en de valkuilen. Plus de skills-tabel van `claude-sandbox/README.md` en de toggle-tabel in `docs/opstarten-en-afsluiten.md`.
   *Verificatie:* de ledenlijst is gelezen met de SSO-Bearer. De velden zijn `naam`, `soort`, `rollen`, `rol_labels` en `tokens`. Een druktest met een subagent (haast, een 2FA-code in de chat, een week geldigheid, een delete): de agent geeft zelf geen token uit, toont geen waarde en vraagt per delete om instemming.

## Ontwerpkeuzes

- **De gebruiker draait de uitgifte.** De 2FA-code hoort bij de gebruiker. Claude schrijft alleen het commando.
- **Het projectbestand bevat geen SSO-tokens.** Voor deploymentwerk is de API-key genoeg. De SSO-tokens blijven in `login/`.
- **Grens van de bescherming.** Het script en `zadctl` staan zelf in de container en zijn dus te wijzigen. De vaste URL's beschermen tegen een gewijzigd configbestand, niet tegen een gewijzigd script. De skill zegt dat.
- **Mappen in de scratchpad.** Die is per sessie en valt buiten elke repo, dus een `.env.zadctl` komt niet in een commit terecht.
- **De tokennaam `sandbox-<UTC-tijd>`.** De OM eist een unieke naam per lid; de UTC-seconde maakt een botsing onwaarschijnlijk. In de ledenlijst is te zien waar het token vandaan komt.
- **Geen override van de URL's.** Een andere OM vraagt een wijziging van het script, en die komt dan in een review.

## Niet geverifieerd

- De logs-omweg met `lines=1000`. Het geteste component had te weinig logregels om die te onderscheiden van `zadctl logs --tail`.
- Een volledige image-build lokaal. De COPY- en install-stap van de skills is los gebouwd op de gepinde Debian-base: `zad-token.sh` staat met mode 755 en eigenaar `claude` in `~/.claude/skills/zadctl/` en draait. `build-variants` in CI bouwt de hele image, alleen op amd64.
