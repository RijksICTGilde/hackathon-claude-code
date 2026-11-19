---
name: zadctl
description: Gebruik bij zadctl of de ZAD Operations Manager (OM) vanuit deze container. Bijvoorbeeld inloggen zonder browser, een persoonlijk projecttoken met 2FA, "No API key for", "urn:zad:step-up-required", een 410 op api-key, of deployments, logs en env-variabelen van een ZAD-project bekijken.
---

# zadctl in de sandbox

zadctl bedient ZAD (Zelfservice Applicatie Deployment) via de Operations Manager (OM).
Voor de CLI zelf: `zadctl guide` en `zadctl <commando> --help`. Deze skill dekt wat in de
container anders gaat: inloggen zonder browser, persoonlijke tokens met 2FA, en de
valkuilen bij het uitlezen.

Kijk met `command -v zadctl` en `zadctl --version` welke zadctl draait. Ontbreekt hij, dan
staat de standalone binary op de releasepagina van `RijksICTGilde/zad-cli`.

## Kernregels

- **De 2FA-code is van de gebruiker.** Geef nooit zelf een token uit en doe nooit zelf een
  step-up. Jij schrijft het commando, de gebruiker draait het met `! bash ...`.
- **Een tokenwaarde komt nooit in de transcriptie.** Geen `cat`, `grep`, `echo` of `-v` op
  een `.env.zadctl` of een token-antwoord. Lees hooguit de sleutelnamen:
  `sed 's/=.*//' .env.zadctl`.
- **Eén map per project, buiten elke repo.** zadctl bewaart alles in `.env.zadctl` in de
  huidige map, en `zadctl project use <ander>` wist de key van het vorige project.
- **Tokens leven 1 dag.** Langer alleen als de gebruiker daar om vraagt.
- **Verwijderen alleen na expliciete instemming.** `zadctl deployment delete` en
  `DELETE`-aanroepen op de OM zijn onomkeerbaar. Een deployment met een database-dienst
  neemt zijn data mee. Vraag het per actie, ook als `--yes` technisch kan.

## Mappen

Kies een basismap in je scratchpad, bijvoorbeeld `<scratchpad>/zad`:

```
<basis>/login/.env.zadctl       SSO-tokens van zadctl login
<basis>/<project>/.env.zadctl   ZAD_API_URL, ZAD_PROJECT_ID, ZAD_API_KEY
```

Draai elk projectcommando vanuit `<basis>/<project>`. Een tweede project vraagt geen tweede
login: het tokenscript neemt meerdere projecten tegelijk.

## 1. Inloggen

De device flow staat uit bij de OM-client, en de container kan geen browser openen. De
callback naar `127.0.0.1` komt ook niet aan. Werkende route: de loopback-flow met de hand.

1. Vraag de gebruiker of die klaar zit om in te loggen. De listener wacht precies 5 minuten
   en dat is niet instelbaar. Start pas na een ja.
2. Start op de achtergrond (`run_in_background`), vanuit `<basis>/login`:
   `zadctl login --browser --no-open`
3. Lees de uitvoer en geef de gebruiker de inlog-URL. De gebruiker logt in. De browser
   eindigt op een falende `http://127.0.0.1:<poort>/callback?...`-pagina. Vraag die URL.
4. Stuur die URL direct naar de listener, binnen ongeveer 1 minuut: daarna verloopt de
   `code`. Gebruik `curl -s '<url>'` met enkele quotes, want de URL bevat `&`.
5. Controleer met `zadctl project list` vanuit `<basis>/login`. De rolkolom kan leeg zijn:
   zadctl leest een veld `role` dat de API niet geeft. Rollen staan in de ledenlijst
   (sectie 3).

## 2. Een persoonlijk token

Een project heeft geen eigen sleutel: `GET .../api-key` geeft 410 Gone, en `zadctl project use`
meldt "No API key for '<p>'". Een token hoort bij een lid, en uitgeven vraagt een verse
2FA-code. `zad-token.sh` naast deze skill doet de step-up, geeft per project een token
uit en schrijft `<basis>/<project>/.env.zadctl`. Daarna sluit het script het step-up-venster.
Het lid is het e-mailadres uit het SSO-token.

Geef de gebruiker dit commando, met `<basis>` (de map boven `login/`) en de projecten
ingevuld. De gebruiker zet een verse code er zelf achter:

```
! bash ~/.claude/skills/zadctl/zad-token.sh uitgeven <basis> <project>[,<project>...] <2FA-code> [dagen]
```

`dagen` is standaard 1. Het script praat alleen met de vaste OM- en Keycloak-URL, en niet
met URL's uit een `.env.zadctl`. Een andere OM kan met `ZAD_OM_API_URL=<url>` en
`ZAD_OM_SSO_ISSUER=<url>` als omgevingsvariabelen.

Het script draait in de container, en alles daar kan een agent wijzigen: het script zelf,
`zadctl` op het `PATH`, en de mappen. De vaste URL's houden een gewijzigd configbestand
tegen, maar geen gewijzigd script. Noem dat als de gebruiker twijfelt, en wijzig het script
nooit tussen het uitleggen en het draaien. Een code die de gebruiker in de chat zet,
gebruik je niet: die is dan meestal al verlopen, en het commando draait toch de gebruiker.

Het script toont de OM-URL, HTTP-statussen, de tokennaam (`sandbox-<datum>-<tijd>`), de
geschreven paden en bij een fout `title`/`detail`/`remedy`, nooit de tokenwaarde. Bestond er
al een projectbestand, dan noemt het de vorige tokennaam: dat token blijft geldig tot het
verloopt. Faalt er iets nadat een token is aangemaakt, dan noemt het script het
intrekcommando. Daarna, vanuit `<basis>/<project>`: `zadctl deployment list`.

Een 403 op de uitgifte zonder step-up-type betekent meestal: geen lid van het project, of een
rol die het niet toestaat. Kijk dan in de ledenlijst.

## 3. Leden en tokens bekijken

Lezen vraagt geen step-up, dus dit draai je zelf. Het script ververst het SSO-token en
praat met dezelfde vaste hosts:

```bash
bash ~/.claude/skills/zadctl/zad-token.sh leden <basis> <project>
```

Per lid toont het `naam`, `soort`, `rollen` en `tokens` (`naam`, `vervalt`, `verlopen`),
zonder waarden.

## 4. Een token intrekken

Intrekken vraagt ook een step-up, dus ook dit draait de gebruiker. De tokennaam staat als
commentaar in de `.env.zadctl` van het project en in de ledenlijst:

```
! bash ~/.claude/skills/zadctl/zad-token.sh intrekken <basis> <project> <tokennaam> <2FA-code>
```

Dit doet `DELETE /api/v2/projects/<p>/leden/<e-mail, %40-gecodeerd>/tokens/<tokennaam>`.
Verwijder daarna de projectmap.

## Valkuilen bij het uitlezen

| Symptoom | Oorzaak en omweg |
|---|---|
| Bash weigert een commando met het woord `alias` ("can't be verified to stay inside the worktree") | Geldt in een worktree, ook voor `zadctl alias ...`. Zet het commando in een scriptbestand en draai dat. |
| `zadctl logs` geeft maar een paar regels | `zadctl logs <deployment> -c <component> --tail 1000`. Meer: `GET /api/logs/<p>?deployment=<d>&component=<c>&lines=1000` met header `X-API-Key`. |
| `zadctl env list` toont "(set, not returned by the API)" | Geheime waarden geeft de API niet terug. Per deployment: `--deployment <d>`, niet `-d`. |
| "Service 'aliases' has no values at target 'deployment-component'" | Aliassen bestaan alleen op componentniveau. |
| Tabel afgekapt | `ZAD_TABLE_WIDTH=200` of `-o json`. |
| `401` "Authentication required" met de SSO-Bearer | Het access-token leeft ongeveer 5 minuten. `zad-token.sh` ververst het zelf. Faalt het verversen, log dan opnieuw in. |
| `403` met `urn:zad:step-up-required` | Die handeling vraagt 2FA. Laat de gebruiker hem uitvoeren. |
