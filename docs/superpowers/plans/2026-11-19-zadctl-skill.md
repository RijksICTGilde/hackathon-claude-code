# Skill zadctl voor de sandbox

## Context

Wie in de container met ZAD werkt, loopt vast op drie dingen. `zadctl login` kan geen browser openen, en de callback naar `127.0.0.1` komt niet aan. Projectsleutels bestaan niet meer: `GET .../api-key` geeft 410. Een persoonlijk token vraagt een verse 2FA-code, en die is van de gebruiker, niet van Claude. De skill `zadctl` legt de werkende route vast. Het script `zad-token.sh` doet de uitgifte zonder dat de tokenwaarde op het scherm komt.

## Stappen

1. **Route bepalen.** zadctl v0.14.1 en upstream-`main` geven zelf geen token uit, en verwijzen naar de OM-pagina "Leden en tokens". De device flow staat uit bij de Keycloak-client `zad-cli` ("The flow is disabled for the client"). Dus blijft de route: de loopback-flow met `--browser --no-open`, daarna de callback-URL met de hand via `curl` naar de listener.
   *Verificatie:* `zadctl login --device --no-open` geeft die fout. Met `--browser --no-open` en de callback via `curl` volgt een geslaagde login, en `zadctl project list` werkt.
2. **Antwoordschema van de uitgifte.** De OpenAPI-spec geeft voor de 201 een leeg schema. De bron (`operations-manager/python/opi/api/token_router.py` in RIG-Cluster) geeft `UitgegevenToken {token, lid, naam}`. Uitgeven, roteren en intrekken vragen alle drie een step-up. Een tokennaam is uniek per lid.
   *Verificatie:* 201 met veld `token` bij de echte uitgifte.
3. **`zad-token.sh uitgeven|intrekken`.** Het script valideert de invoer en haalt het lid uit de `email`-claim van het SSO-token. De API-URL en de SSO-issuer staan vast, of komen uit `ZAD_OM_API_URL` en `ZAD_OM_SSO_ISSUER` in het commando, en nooit uit `.env.zadctl`: wie dat bestand schrijft, zou anders tokens en de 2FA-code naar een eigen host sturen. Het verversen via zadctl krijgt die waarden als geëxporteerde variabelen mee, en die gaan bij zadctl voor op het bestand. Een tokennaam begint met een letter of cijfer en wordt `@uri`-gecodeerd. curl draait met `--path-as-is`, zodat `..` de DELETE niet naar het lid zelf stuurt. De Bearer staat in een headerbestand en niet in de proceslijst. Het venster wordt bij afsluiten gesloten met `DELETE /api/v2/step-up`.
   *Verificatie:* shellcheck schoon. Een ongeldige projectnaam, een ongeldige code, een ontbrekende code, een ontbrekende loginmap, een tokennaam als `..`, `../x`, `.x` of `a/b`, en een API-URL met een query geven elk een eigen fout. De echte run gaf: step-up 200, token 201, step-up gesloten 204. Het projectbestand heeft mode 0600 met de sleutels `ZAD_API_URL`, `ZAD_PROJECT_ID` en `ZAD_API_KEY`. Daarna werkt `zadctl deployment list`. Een `intrekken` na meer dan 5 minuten gaf eerst een 401, omdat het SSO-access-token na ongeveer 5 minuten verloopt. Nu ververst het script dat eerst via zadctl. Daarna gaf het: step-up 200, intrekken 200, step-up gesloten 204. Een loginmap waarvan `.env.zadctl` `ZAD_API_URL` en `ZAD_SSO_ISSUER` naar `evil.example` zet: zadctl alleen faalt, en met de overrides uit het script geeft hij de 12 projecten via de echte hosts. Het token stond niet meer in de ledenlijst, en de oude key werd geweigerd.
4. **SKILL.md** met kernregels, het mappenschema, de login, het token, de ledenlijst, het intrekken en de valkuilen. Plus een regel in de skills-tabel van `claude-sandbox/README.md`.
   *Verificatie:* de ledenlijst is gelezen met de SSO-Bearer. De velden zijn `naam`, `soort`, `rollen`, `rol_labels` en `tokens`. Een druktest met een subagent (haast, een 2FA-code in de chat, een week geldigheid, een delete) leverde de juiste aanpak op. Drie onduidelijkheden zijn daarna opgelost.

## Ontwerpkeuzes

- **De gebruiker draait de uitgifte.** De 2FA-code hoort bij de gebruiker. Claude schrijft alleen het commando.
- **Het projectbestand bevat geen SSO-tokens.** Voor deploymentwerk is de API-key genoeg. De SSO-tokens blijven in `login/`.
- **Grens van de bescherming.** Het script en `zadctl` staan zelf in de container en zijn dus te wijzigen. De vaste URL's beschermen tegen een gewijzigd configbestand, niet tegen een gewijzigd script. De skill zegt dat.
- **Mappen in de scratchpad.** Die is per sessie en valt buiten elke repo, dus een `.env.zadctl` komt niet in een commit terecht.
- **De tokennaam `sandbox-<UTC-tijd>`.** Die is uniek per lid, en uit de ledenlijst blijkt waar het token vandaan komt.

## Niet geverifieerd

- De logs-omweg met `lines=1000`. Het geteste component had te weinig logregels om die te onderscheiden van `zadctl logs --tail`.
- Een image-build met de skill. Die bestanden komen via de bestaande `COPY skills/`, en de PR-build in CI dekt dat.
