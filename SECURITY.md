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

Bij elke gepubliceerde release tekent de `release-sign` workflow het bron-archief met cosign keyless. De release bevat vier assets:

- `<repo>-<tag>.tar.gz` — het ondertekende bron-archief
- `<repo>-<tag>.tar.gz.sig` — handtekening
- `<repo>-<tag>.tar.gz.pem` — Sigstore-certificaat
- `<repo>-<tag>.tar.gz.sha256` — SHA256-checksum

**Belangrijk:** verifieer alleen het `<repo>-<tag>.tar.gz` asset uit de release. GitHub's automatisch gegenereerde "Source code (tar.gz)" download is een ander archief en heeft een andere checksum — die handtekening werkt daar niet op.

```bash
TAG=v1.2.3
REPO=hackathon-claude-code
gh release download "$TAG" --repo RijksICTGilde/$REPO \
  --pattern "$REPO-$TAG.tar.gz*"
sha256sum -c "$REPO-$TAG.tar.gz.sha256"
cosign verify-blob \
  --certificate "$REPO-$TAG.tar.gz.pem" \
  --signature "$REPO-$TAG.tar.gz.sig" \
  --certificate-identity-regexp "https://github.com/RijksICTGilde/$REPO/.github/workflows/release-sign.yml@.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "$REPO-$TAG.tar.gz"
```

Zie het [volledige MinBZK-beleid](https://github.com/MinBZK/.github/blob/main/SECURITY.md) voor de complete tekst, do's en don'ts, en wat wij beloven.
