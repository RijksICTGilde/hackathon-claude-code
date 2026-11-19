#!/usr/bin/env bash
# Persoonlijke ZAD-tokens uitgeven, intrekken en bekijken. Gebruik: zie gebruik().
#
# <basis>/login/.env.zadctl bevat de SSO-tokens van `zadctl login`. Per project
# schrijft `uitgeven` <basis>/<project>/.env.zadctl met ZAD_API_URL, ZAD_PROJECT_ID
# en ZAD_API_KEY, plus de tokennaam als commentaar. Uitgeven en intrekken draait de gebruiker zelf, want de 2FA-code
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
# De URL's staan vast, en proxy-, CA-, keylog- en curlrc-instellingen tellen niet mee:
# .env.zadctl, ~/.bashrc, ~/.curlrc en de env van Claude zijn allemaal door een agent
# te schrijven, en zouden tokens en de 2FA-code anders naar een eigen host sturen.
# Een omgeving die code meelaadt (PATH, BASH_ENV, geëxporteerde functies, LD_PRELOAD)
# houdt dit niet tegen.
api=https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api
issuer=https://keycloak.rijksapp.nl/realms/operations-manager
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy \
  CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE CURL_HOME SSLKEYLOGFILE

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

stepup_open=0 nieuw="" rc=0 bezig=""
tmp=$(mktemp -d)
# Geeft 1 als het step-up-venster open bleef, zodat de exitcode dat ook zegt.
opruimen() {
  local r=0 s
  if [ "$stepup_open" = 1 ]; then
    # Anders kan elk proces met het SSO-token tot het venster verloopt zonder code
    # tokens uitgeven.
    s=$(curl -q -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
      -H @"$tmp/auth" "$api/v2/step-up" || true)
    if [[ "$s" == 2* ]]; then
      echo "step-up gesloten: HTTP $s" >&2
    else
      echo "WAARSCHUWING: step-up niet gesloten (HTTP $s); het venster blijft open tot het verloopt" >&2
      r=1
    fi
  fi
  # Onderbroken tijdens een uitgifte: het token bestaat mogelijk al.
  [ -n "$bezig" ] && echo "$bezig" >&2
  rm -rf "$tmp" "${nieuw:-}"
  return "$r"
}
trap 'rc=$?; opruimen || rc=1; exit "$rc"' EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
# De Bearer via een headerbestand en de body via stdin, zodat het SSO-token en de
# 2FA-code niet in de argv van curl staan. De code staat wel in de argv van dit
# script; die is eenmalig en verloopt binnen een minuut.
printf 'Authorization: Bearer %s\n' "$sso" > "$tmp/auth"

# Roept de OM-API aan, schrijft de body naar $tmp/antwoord en de HTTP-status naar
# stdout. `|| true`: bij een verbindingsfout schrijft -w zelf 000.
om() {
  local methode=$1 pad=$2 body=${3:-}
  rm -f "$tmp/antwoord"
  # --path-as-is: tweede verdediging naast de naamvalidatie, zodat geen punt-segment
  # het pad inkort.
  # -q: ~/.curlrc niet lezen.
  local args=(-q -sS --max-time 30 --path-as-is -o "$tmp/antwoord" -w '%{http_code}'
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
  if [ "$status" != 200 ]; then
    echo "$p: leden: HTTP $status" >&2
    [ "$status" = 401 ] && echo "  SSO-token geweigerd; opnieuw inloggen met zadctl login" >&2
    toon_fout; exit 1
  fi
  # Zonder stderr: een jq-fout citeert de waarde waarop hij struikelt.
  jq '[.leden[] | {naam, soort, rollen, tokens: [(.tokens // [])[] | {naam, vervalt, verlopen}]}]' \
    "$tmp/antwoord" 2>/dev/null || fout "onverwacht antwoord op de ledenlijst"
  exit 0
fi

# Vóór de aanroep open: ook zonder antwoord, bij een 5xx of bij een onderbreking kan
# de server het venster geopend hebben. Alleen een 4xx zegt zeker van niet.
stepup_open=1
status=$(om POST /v2/step-up "$(CODE=$code jq -cn '{code: env.CODE}')")
echo "step-up: HTTP $status" >&2
if [[ "$status" != 2* ]]; then
  case "$status" in
    4*) stepup_open=0 ;;&
    400|422) echo "  2FA-code geweigerd of verlopen" >&2 ;;
    401) echo "  SSO-token geweigerd; opnieuw inloggen met zadctl login" >&2 ;;
    403) echo "  step-up geweigerd" >&2 ;;
  esac
  toon_fout
  exit 1
fi

# Een kopieerbaar intrekcommando, gequote: basis en naam kunnen uit een bestand komen
# dat een agent kan schrijven.
intrekcommando() { # project tokennaam
  printf 'bash %q intrekken %q %q %q <2FA-code>' "$0" "$basis" "$1" "$2"
}

mislukt=()
if [ "$actie" = uitgeven ]; then
  naam="sandbox-$(date -u +%Y%m%d-%H%M%S)"
  for p in "${lijst[@]}"; do
    intrek="  token '$naam' bestaat mogelijk; trek het in met: $(intrekcommando "$p" "$naam")"
    bezig=$intrek
    status=$(om POST "/v2/projects/$p/leden/$lid_url/tokens" \
      "$(jq -cn --arg n "$naam" --argjson d "$dagen" '{naam: $n, dagen: $d}')")
    bezig=""
    echo "$p: token '$naam' ($dagen dag): HTTP $status" >&2
    # Alleen een 4xx zegt dat er geen token is. Na elke andere status noemt elke fout
    # de naam, zodat de gebruiker het kan intrekken.
    if [[ "$status" != 2* ]]; then
      toon_fout
      [[ "$status" == 4* ]] || echo "$intrek" >&2
      mislukt+=("$p"); continue
    fi
    token=$(jq -r '.token | strings' "$tmp/antwoord" 2>/dev/null) || token=""
    rm -f "$tmp/antwoord"
    # Alleen token-tekens: een newline of quote zou extra regels of syntax in
    # .env.zadctl schrijven.
    if ! [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
      echo "  antwoord zonder geldig token-veld" >&2; echo "$intrek" >&2
      mislukt+=("$p"); unset token; continue
    fi
    doel="$basis/$p/.env.zadctl"
    oud=$(sed -n 's/^# tokennaam: //p' "$doel" 2>/dev/null | tail -1 || true)
    if [ -e "$doel" ] && [ ! -r "$doel" ]; then
      echo "  $doel is niet leesbaar; een vorig token daarin blijft mogelijk geldig" >&2
    elif [[ "$oud" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$ ]]; then
      echo "  vorig token '$oud' blijft geldig tot het verloopt; intrekken met: $(intrekcommando "$p" "$oud")" >&2
    elif [ -n "$oud" ]; then
      echo "  $doel noemt een ongeldige tokennaam; kijk in de ledenlijst welk token nog geldig is" >&2
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
    unset token; nieuw=""
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
