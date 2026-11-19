#!/usr/bin/env bash
# Persoonlijke ZAD-tokens uitgeven, intrekken en bekijken. Gebruik: zie gebruik().
#
# <basis>/login/.env.zadctl bevat de SSO-tokens van `zadctl login`. Per project
# schrijft `uitgeven` <basis>/<project>/.env.zadctl met ZAD_API_URL, ZAD_PROJECT_ID
# en ZAD_API_KEY. Uitgeven en intrekken draait de gebruiker zelf, want de 2FA-code
# is van de gebruiker. De tokenwaarde komt nooit op het scherm.
set -euo pipefail
umask 077

fout() { echo "FOUT: $*" >&2; exit 1; }

gebruik() {
  cat >&2 <<'EOF'
bash zad-token.sh uitgeven  <basis> <project>[,<project>...] <2FA-code> [dagen]
bash zad-token.sh intrekken <basis> <project> <tokennaam> <2FA-code>
bash zad-token.sh leden     <basis> <project>
EOF
  exit 2
}

[ $# -ge 1 ] || gebruik
actie=$1; shift
code="" dagen=1 tokennaam=""
case "$actie" in
  uitgeven)  [ $# -eq 2 ] && fout "2FA-code ontbreekt: zet de code achter het commando"
             [ $# -ge 3 ] && [ $# -le 4 ] || gebruik
             basis=$1 projecten=$2 code=$3 dagen=${4:-1} ;;
  intrekken) [ $# -eq 3 ] && fout "2FA-code ontbreekt: zet de code achter het commando"
             [ $# -eq 4 ] || gebruik
             basis=$1 projecten=$2 tokennaam=$3 code=$4 ;;
  leden)     [ $# -eq 2 ] || gebruik
             basis=$1 projecten=$2 ;;
  *) gebruik ;;
esac

for cmd in curl jq zadctl; do
  command -v "$cmd" >/dev/null || fout "'$cmd' ontbreekt"
done

# Alles hieronder belandt in een URL of JSON-body; valideren voor gebruik.
if [ "$actie" != leden ]; then
  [[ "$code" =~ ^[0-9]{6,8}$ ]] || fout "2FA-code moet 6 tot 8 cijfers zijn"
fi
[[ "$dagen" =~ ^[1-9][0-9]*$ ]] || fout "dagen moet een positief geheel getal zijn"
IFS=, read -r -a lijst <<<"$projecten"
[ "${#lijst[@]}" -ge 1 ] || fout "geen project opgegeven"
declare -A gezien=()
for p in "${lijst[@]}"; do
  [[ "$p" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fout "ongeldige projectnaam '$p'"
  [ -z "${gezien[$p]:-}" ] || fout "project '$p' staat er twee keer in"
  gezien[$p]=1
done
if [ "$actie" != uitgeven ]; then
  [ "${#lijst[@]}" -eq 1 ] || fout "$actie werkt op één project"
fi
if [ "$actie" = intrekken ]; then
  # Begint met letter of cijfer: een naam als `..` zou de DELETE naar het lid zelf sturen.
  [[ "$tokennaam" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$ ]] || fout "ongeldige tokennaam '$tokennaam'"
fi

loginmap="$basis/login"
envbestand="$loginmap/.env.zadctl"
[ -f "$envbestand" ] || fout "$envbestand ontbreekt; eerst inloggen met zadctl login"
# De URL's staan vast, ook niet via de omgeving: .env.zadctl, ~/.bashrc en de env
# van Claude zijn allemaal door een agent te schrijven, en zouden tokens en de
# 2FA-code anders naar een eigen host sturen.
api=https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api
issuer=https://keycloak.rijksapp.nl/realms/operations-manager

# Het access-token leeft enkele minuten; zadctl ververst het met het refresh-token.
# Geëxporteerde variabelen gaan bij zadctl voor op .env.zadctl, dus zo praat ook die
# aanroep alleen met de vaste hosts en de vaste client.
(cd "$loginmap" && ZAD_API_URL="$api" ZAD_SSO_ISSUER="$issuer" ZAD_KEYCLOAK_CLIENT_ID=zad-cli \
   zadctl -o json project list >/dev/null) \
  || fout "SSO-sessie verversen mislukt; opnieuw inloggen met zadctl login"
sso=$(sed -n 's/^ZAD_SSO_TOKEN=//p' "$envbestand" | tail -1 | tr -d "\"'")
[ -n "$sso" ] || fout "geen ZAD_SSO_TOKEN in $envbestand"

# Het lid is het e-mailadres uit het SSO-token zelf: zo geeft het script alleen
# tokens uit aan wie er ingelogd is.
payload=$(cut -d. -f2 <<<"$sso" | tr '_-' '/+')
while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload+="="; done
lid=$(base64 -d <<<"$payload" 2>/dev/null | jq -r '.email // empty' 2>/dev/null) || true
[ -n "$lid" ] || fout "het SSO-token bevat geen email-claim; opnieuw inloggen"
lid_url=$(jq -rn --arg v "$lid" '$v | @uri')

tmp=$(mktemp -d)
# De Bearer via een headerbestand en de body via stdin, zodat het SSO-token en de
# 2FA-code niet in de argv van curl staan. De code staat wel in de argv van dit
# script; die is eenmalig en verloopt binnen een minuut.
printf 'Authorization: Bearer %s\n' "$sso" > "$tmp/auth"
stepup_open=0
opruimen() {
  if [ "$stepup_open" = 1 ]; then
    # Anders kan elk proces met het SSO-token tot het venster verloopt zonder code
    # tokens uitgeven.
    local s
    s=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
      -H @"$tmp/auth" "$api/v2/step-up" || true)
    if [[ "$s" == 2* ]]; then
      echo "step-up gesloten: HTTP $s" >&2
    else
      echo "WAARSCHUWING: step-up niet gesloten (HTTP $s); het venster blijft open tot het verloopt" >&2
    fi
  fi
  rm -rf "$tmp"
}
trap opruimen EXIT

# Roept de OM-API aan, schrijft de body naar $tmp/antwoord en de HTTP-status naar
# stdout. `|| true`: bij een verbindingsfout schrijft -w zelf 000.
om() {
  local methode=$1 pad=$2 body=${3:-}
  rm -f "$tmp/antwoord"
  # --path-as-is: tweede verdediging naast de naamvalidatie, zodat geen punt-segment
  # het pad inkort.
  local args=(-sS --max-time 30 --path-as-is -o "$tmp/antwoord" -w '%{http_code}'
              -X "$methode" -H @"$tmp/auth" -H 'Accept: application/json')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
    curl "${args[@]}" "$api$pad" <<<"$body" || true
  else
    curl "${args[@]}" "$api$pad" || true
  fi
}

# Toont bij een fout alleen de beschrijvende velden, nooit de hele body.
toon_fout() {
  local tekst
  tekst=$(jq -r '[.title, .detail, .remedy] | map(strings) | join(" — ")' \
    "$tmp/antwoord" 2>/dev/null || true)
  echo "  ${tekst:-geen leesbare foutbody}" >&2
}

if [ "$actie" = leden ]; then
  p=${lijst[0]}
  status=$(om GET "/v2/projects/$p/leden")
  if [ "$status" != 200 ]; then echo "$p: leden: HTTP $status" >&2; toon_fout; exit 1; fi
  jq '[.leden[] | {naam, soort, rollen, tokens: [.tokens[] | {naam, vervalt, verlopen}]}]' \
    "$tmp/antwoord" || fout "onverwacht antwoord op de ledenlijst"
  exit 0
fi

status=$(om POST /v2/step-up "$(CODE=$code jq -cn '{code: env.CODE}')")
echo "step-up: HTTP $status" >&2
# Zonder antwoord kan de server het venster toch geopend hebben: dan ook sluiten.
[[ "$status" == 2* || "$status" == 000 || "$status" == 5* ]] && stepup_open=1
if [[ "$status" != 2* ]]; then
  [[ "$status" == 4* ]] && echo "  2FA-code geweigerd of verlopen" >&2
  toon_fout
  exit 1
fi

mislukt=()
if [ "$actie" = uitgeven ]; then
  naam="sandbox-$(date -u +%Y%m%d-%H%M%S)"
  for p in "${lijst[@]}"; do
    status=$(om POST "/v2/projects/$p/leden/$lid_url/tokens" \
      "$(jq -cn --arg n "$naam" --argjson d "$dagen" '{naam: $n, dagen: $d}')")
    echo "$p: token '$naam' ($dagen dag): HTTP $status" >&2
    # Vanaf een 2xx, of zonder antwoord, bestaat het token mogelijk. Elke fout noemt
    # dan de naam, zodat de gebruiker het kan intrekken.
    intrek="  token '$naam' bestaat mogelijk; trek het in met: bash $0 intrekken $basis $p $naam <2FA-code>"
    if [[ "$status" != 2* ]]; then
      toon_fout
      [[ "$status" == 000 || "$status" == 5* ]] && echo "$intrek" >&2
      mislukt+=("$p"); continue
    fi
    token=$(jq -r '.token | strings' "$tmp/antwoord" 2>/dev/null) || token=""
    rm -f "$tmp/antwoord"
    # Een newline in de waarde zou extra regels in .env.zadctl schrijven.
    if ! [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
      echo "  antwoord zonder geldig token-veld" >&2; echo "$intrek" >&2
      mislukt+=("$p"); unset token; continue
    fi
    doel="$basis/$p/.env.zadctl"
    oud=$(sed -n 's/^# tokennaam: //p' "$doel" 2>/dev/null | tail -1 || true)
    if [ -n "$oud" ]; then
      echo "  vorig token '$oud' blijft geldig tot het verloopt; intrekken met: bash $0 intrekken $basis $p $oud <2FA-code>" >&2
    fi
    # Naar een tijdelijk bestand en dan mv: een bestaand bestand met ruimere rechten
    # of een half geschreven bestand blijft zo nooit achter.
    if mkdir -p "$basis/$p" && nieuw=$(mktemp "$doel.XXXXXX") \
       && printf 'ZAD_API_URL=%s\nZAD_PROJECT_ID=%s\nZAD_API_KEY=%s\n# tokennaam: %s\n' \
            "$api" "$p" "$token" "$naam" > "$nieuw" \
       && chmod 600 "$nieuw" && mv -fT "$nieuw" "$doel"; then
      echo "  geschreven: $doel" >&2
    else
      rm -f "${nieuw:-}"
      echo "  kon $doel niet schrijven" >&2; echo "$intrek" >&2
      mislukt+=("$p")
    fi
    unset token nieuw
  done
else
  p=${lijst[0]}
  status=$(om DELETE "/v2/projects/$p/leden/$lid_url/tokens/$(jq -rn --arg v "$tokennaam" '$v | @uri')")
  echo "$p: token '$tokennaam' intrekken: HTTP $status" >&2
  [[ "$status" == 2* ]] || { toon_fout; mislukt+=("$p"); }
fi

if [ "${#mislukt[@]}" -gt 0 ]; then
  echo "FOUT: mislukt voor ${mislukt[*]}" >&2
  exit 1
fi
