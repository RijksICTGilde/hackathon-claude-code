# Security Policy

Voor verantwoorde melding van kwetsbaarheden volgen we het beleid van het Ministerie van Binnenlandse Zaken en Koninkrijksrelaties (MinBZK):

- **Beleid**: <https://github.com/MinBZK/.github/blob/main/SECURITY.md>
- **Meldpunt**: het Nationaal Cyber Security Centrum (NCSC) — <https://www.ncsc.nl/contact/kwetsbaarheid-melden>

Vermeld in je melding **beide** referenties zodat de melding via MinBZK CIO-office bij de juiste maintainers terechtkomt:

1. "MinBZK/CIO-office github security response" — conform het MinBZK-beleid (vrije-tekstreferentie, geen GitHub-pad)
2. de repository [`RijksICTGilde/hackathon-claude-code`](https://github.com/RijksICTGilde/hackathon-claude-code) — voor directe routering naar de maintainers

## Reactietermijn

Conform het MinBZK-beleid (gebaseerd op NCSC) streven we naar:

- inhoudelijke reactie binnen enkele werkdagen
- coördinatie van publicatie binnen **60 dagen** na de melding

> Vulnerability disclosure follows a coordinated 60-day timeline. Please report vulnerabilities via the NCSC link above.

## Niet doen

- Publiceer de kwetsbaarheid niet voordat deze is opgelost.
- Misbruik de kwetsbaarheid niet verder dan nodig om het bestaan ervan aan te tonen.
- Wijzig of verwijder geen data op systemen.

## Verifiëren van release-artefacten

Bij elke gepubliceerde release tekent de `release-sign` workflow zowel het bron-archief als de checksum met cosign keyless. De release bevat zes assets:

- `<repo>-<tag>.tar.gz` — het ondertekende bron-archief
- `<repo>-<tag>.tar.gz.sig` — handtekening over het archief
- `<repo>-<tag>.tar.gz.pem` — Sigstore-certificaat voor de archief-handtekening
- `<repo>-<tag>.tar.gz.sha256` — SHA256-checksum
- `<repo>-<tag>.tar.gz.sha256.sig` — handtekening over de checksum
- `<repo>-<tag>.tar.gz.sha256.pem` — Sigstore-certificaat voor de checksum-handtekening

**Belangrijk:** verifieer alleen het `<repo>-<tag>.tar.gz` asset uit de release. GitHub's automatisch gegenereerde "Source code (tar.gz)" download is een ander archief en heeft een andere checksum — die handtekening werkt daar niet op.

> De regex hieronder is gebonden aan de bestandsnaam `release-sign.yml`. Een vergelijkbare zelf-referentie zit in `build-image.yml` (gebonden aan dat bestand zelf). Bij hernoemen van een van beide workflows breken consumer-verifies zonder duidelijke foutmelding — update zowel deze SECURITY.md als het verify-blok in de andere workflow mee.

```bash
TAG=v1.2.3
REPO=hackathon-claude-code
# De regex accepteert alleen handtekeningen die voortkomen uit een run
# op `refs/heads/main` of een `refs/tags/v*`-tag. De `release-sign`
# workflow weigert workflow_dispatch op andere refs, dus dit is in lijn
# met wat maintainers daadwerkelijk publiceren. Anchored (^...$) zodat
# substring-matches geen sluiproute zijn.
IDENTITY_REGEXP="^https://github\.com/RijksICTGilde/$REPO/\.github/workflows/release-sign\.yml@refs/(heads/main|tags/v[0-9A-Za-z._+-]+)$"
ISSUER="https://token.actions.githubusercontent.com"

gh release download "$TAG" --repo RijksICTGilde/$REPO \
  --pattern "$REPO-$TAG.tar.gz*"

# Verifieer dat de checksum zelf authentiek is voordat we hem vertrouwen.
cosign verify-blob \
  --certificate "$REPO-$TAG.tar.gz.sha256.pem" \
  --signature "$REPO-$TAG.tar.gz.sha256.sig" \
  --certificate-identity-regexp "$IDENTITY_REGEXP" \
  --certificate-oidc-issuer "$ISSUER" \
  "$REPO-$TAG.tar.gz.sha256"

sha256sum -c "$REPO-$TAG.tar.gz.sha256"

cosign verify-blob \
  --certificate "$REPO-$TAG.tar.gz.pem" \
  --signature "$REPO-$TAG.tar.gz.sig" \
  --certificate-identity-regexp "$IDENTITY_REGEXP" \
  --certificate-oidc-issuer "$ISSUER" \
  "$REPO-$TAG.tar.gz"
```

Zie het [volledige MinBZK-beleid](https://github.com/MinBZK/.github/blob/main/SECURITY.md) voor de complete tekst, do's en don'ts, en wat wij beloven.
