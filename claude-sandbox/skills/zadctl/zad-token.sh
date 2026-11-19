#!/usr/bin/env bash
# Persoonlijke ZAD-tokens uitgeven en intrekken met een verse 2FA-code.
#
#   bash zad-token.sh uitgeven  <basis> <project>[,<project>...] <2FA-code> [dagen]
#   bash zad-token.sh intrekken <basis> <project> <tokennaam> <2FA-code>
#
# <basis>/login/.env.zadctl bevat de SSO-tokens van `zadctl login`. Per project
# schrijft `uitgeven` <basis>/<project>/.env.zadctl met ZAD_API_URL, ZAD_PROJECT_ID
# en ZAD_API_KEY. De gebruiker draait dit script zelf, want de 2FA-code is van de
# gebruiker. De tokenwaarde komt nooit op het scherm, alleen HTTP-statussen en
# foutteksten.
set -euo pipefail
umask 077

fout() { echo "FOUT: $*" >&2; exit 1; }

gebruik() {
  sed -n '4,5p' "$0" | sed 's/^# *//' >&2
  exit 2
}

[ $# -ge 1 ] || gebruik
actie=$1; shift
case "$actie" in
  uitgeven)  [ $# -eq 2 ] && fout "2FA-code ontbreekt: zet de code achter het commando"
             [ $# -ge 3 ] && [ $# -le 4 ] || gebruik
             basis=$1 projecten=$2 code=$3 dagen=${4:-1} ;;
  intrekken) [ $# -eq 3 ] && fout "2FA-code ontbreekt: zet de code achter het commando"
             [ $# -eq 4 ] || gebruik
             basis=$1 projecten=$2 tokennaam=$3 code=$4 dagen=1 ;;
  *) gebruik ;;
esac

for cmd in curl jq zadctl; do
  command -v "$cmd" >/dev/null || fout "'$cmd' ontbreekt"
done

# Alles hieronder belandt in een URL of JSON-body; valideren voor gebruik.
[[ "$code" =~ ^[0-9]{6,8}$ ]] || fout "2FA-code moet 6 tot 8 cijfers zijn"
[[ "$dagen" =~ ^[1-9][0-9]*$ ]] || fout "dagen moet een positief geheel getal zijn"
IFS=, read -r -a lijst <<<"$projecten"
for p in "${lijst[@]}"; do
  [[ "$p" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fout "ongeldige projectnaam '$p'"
done
if [ "$actie" = intrekken ]; then
  [ "${#lijst[@]}" -eq 1 ] || fout "intrekken werkt op één project"
  # Begint met letter of cijfer: een naam als `..` zou de DELETE naar het lid zelf sturen.
  [[ "$tokennaam" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$ ]] || fout "ongeldige tokennaam '$tokennaam'"
fi

loginmap="$basis/login"
envbestand="$loginmap/.env.zadctl"
[ -f "$envbestand" ] || fout "$envbestand ontbreekt; eerst inloggen met zadctl login"
# Het access-token leeft enkele minuten. Een zadctl-aanroep met SSO ververst het met het
# refresh-token in hetzelfde bestand. Die gaat niet via de vaste URL hieronder, maar
# raakt alleen tokens die al in dat bestand staan, niet de 2FA-code.
(cd "$loginmap" && zadctl -o json project list >/dev/null) \
  || fout "SSO-sessie verversen mislukt; opnieuw inloggen met zadctl login"
sso=$(sed -n 's/^ZAD_SSO_TOKEN=//p' "$envbestand" | tail -1 | tr -d "\"'")
[ -n "$sso" ] || fout "geen ZAD_SSO_TOKEN in $envbestand"

# De API-URL staat vast en komt niet uit .env.zadctl: wie dat bestand kan schrijven,
# zou het SSO-token en de 2FA-code anders naar een eigen host sturen. Een andere OM
# kan alleen met ZAD_OM_API_URL in het commando dat de gebruiker zelf draait.
api=${ZAD_OM_API_URL:-https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api}
[[ "$api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*/?$ ]] || fout "onverwachte API-URL '$api'"
api=${api%/}
echo "OM: $api"

# Het lid is het e-mailadres uit het SSO-token zelf: zo geeft het script alleen
# tokens uit aan wie er ingelogd is.
payload=$(cut -d. -f2 <<<"$sso" | tr '_-' '/+')
while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload+="="; done
lid=$(base64 -d <<<"$payload" 2>/dev/null | jq -r '.email // empty') || true
[ -n "$lid" ] || fout "het SSO-token bevat geen email-claim; opnieuw inloggen"
lid_url=$(jq -rn --arg v "$lid" '$v | @uri')

tmp=$(mktemp -d)
# De Bearer via een headerbestand, zodat het SSO-token niet in de proceslijst staat.
printf 'Authorization: Bearer %s\n' "$sso" > "$tmp/auth"
sluit_stepup() {
  # Het step-up-venster dichtzetten: anders kan elk proces met het SSO-token
  # tot valid_until zonder code tokens uitgeven.
  status=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H @"$tmp/auth" "$api/v2/step-up" || true)
  echo "step-up gesloten: HTTP $status"
  rm -rf "$tmp"
}
trap sluit_stepup EXIT

# Roept de OM-API aan, schrijft de body naar $tmp/antwoord en geeft de status terug.
om() {
  local methode=$1 pad=$2 body=${3:-}
  # --path-as-is: curl normaliseert dan geen punt-segmenten weg uit het pad.
  local args=(-s --path-as-is -o "$tmp/antwoord" -w '%{http_code}' -X "$methode"
              -H @"$tmp/auth" -H 'Accept: application/json')
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
  # Bij een verbindingsfout schrijft -w zelf 000.
  curl "${args[@]}" "$api$pad" || true
}

# Toont bij een fout alleen de beschrijvende velden, nooit de hele body.
toon_fout() {
  jq -r '[.title, .detail, .remedy] | map(select(. != null)) | join(" — ")' \
    "$tmp/antwoord" 2>/dev/null || true
}

status=$(om POST /v2/step-up "$(jq -cn --arg c "$code" '{code: $c}')")
echo "step-up: HTTP $status"
[[ "$status" == 2* ]] || { toon_fout; exit 1; }

mislukt=0
if [ "$actie" = uitgeven ]; then
  naam="sandbox-$(date -u +%Y%m%d-%H%M%S)"
  for p in "${lijst[@]}"; do
    status=$(om POST "/v2/projects/$p/leden/$lid_url/tokens" \
      "$(jq -cn --arg n "$naam" --argjson d "$dagen" '{naam: $n, dagen: $d}')")
    echo "$p: token '$naam' ($dagen dag): HTTP $status"
    if [ "$status" != 201 ]; then toon_fout; mislukt=1; continue; fi
    token=$(jq -r '.token // empty' "$tmp/antwoord")
    rm -f "$tmp/antwoord"
    [ -n "$token" ] || { echo "  antwoord zonder token-veld" >&2; mislukt=1; continue; }
    mkdir -p "$basis/$p"
    printf 'ZAD_API_URL=%s\nZAD_PROJECT_ID=%s\nZAD_API_KEY=%s\n# tokennaam: %s\n' \
      "$api" "$p" "$token" "$naam" > "$basis/$p/.env.zadctl"
    unset token
    echo "  geschreven: $basis/$p/.env.zadctl"
  done
else
  p=${lijst[0]}
  status=$(om DELETE "/v2/projects/$p/leden/$lid_url/tokens/$(jq -rn --arg v "$tokennaam" '$v | @uri')")
  echo "$p: token '$tokennaam' intrekken: HTTP $status"
  [[ "$status" == 2* ]] || { toon_fout; mislukt=1; }
fi
exit "$mislukt"
