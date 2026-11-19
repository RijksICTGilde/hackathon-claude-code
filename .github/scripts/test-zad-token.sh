#!/usr/bin/env bash
# Fixtures voor claude-sandbox/skills/zadctl/zad-token.sh, met een nep-curl en een
# nep-zadctl op PATH: geen netwerk. Vereist jq.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
script="${hier}/../../claude-sandbox/skills/zadctl/zad-token.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

command -v jq >/dev/null 2>&1 || { echo "FOUT: jq ontbreekt" >&2; exit 1; }

geslaagd=0
gefaald=0
controle() { # naam exitcode-van-de-controle
  if [ "$2" -eq 0 ]; then
    echo "ok   $1"; geslaagd=$((geslaagd + 1))
  else
    echo "FOUT $1"; sed 's/^/     | /' "${STUB}/err" 2>/dev/null; gefaald=$((gefaald + 1))
  fi
}

mkdir -p "${werkmap}/bin"
# Nep-zadctl logt de omgeving waarmee het script hem aanroept.
cat > "${werkmap}/bin/zadctl" <<'EOF'
#!/usr/bin/env bash
printf 'api=%s issuer=%s client=%s\n' "${ZAD_API_URL:-}" "${ZAD_SSO_ISSUER:-}" \
  "${ZAD_KEYCLOAK_CLIENT_ID:-}" >> "$STUB/zadctl.log"
[ ! -e "$STUB/zadctl.faalt" ]
EOF
# Nep-curl antwoordt per methode en pad uit $STUB/<sleutel>.status en .body, en logt
# argv en stdin. Zonder .status: verbindingsfout, zoals curl dan zelf 000 schrijft.
# Alleen een aanroep met -q, naar de vaste OM-host en met een Bearer uit een
# headerbestand wordt bediend.
cat > "${werkmap}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" meth=GET url="" stdin=0 bearer=0
printf '%s\n' "$*" >> "$STUB/argv.log"
[ "$1" = -q ] || { printf 000; exit 2; }
# Een proxy, eigen CA of keylog uit de omgeving zou het verkeer elders laten lopen
# of leesbaar maken.
for v in HTTPS_PROXY https_proxy ALL_PROXY all_proxy CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR SSLKEYLOGFILE CURL_HOME; do
  [ -z "${!v:-}" ] || { printf 000; exit 5; }
done
while [ $# -gt 0 ]; do case "$1" in
  -o) out=$2; shift 2;; -w|--max-time) shift 2;; -X) meth=$2; shift 2;;
  -H) case "$2" in @*) grep -qx "Authorization: Bearer $SSO" "${2#@}" && bearer=1;; esac; shift 2;;
  --data-binary) [ "$2" = @- ] && stdin=1; shift 2;; -*) shift;; *) url=$1; shift;; esac; done
[ "$stdin" = 1 ] && cat >> "$STUB/stdin.log"
basis=https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api
case "$url" in "$basis"/*) ;; *) printf 000; exit 6;; esac
[ "$bearer" = 1 ] || { printf 401; exit 0; }
pad=${url#"$basis"}
sleutel=$(printf '%s_%s' "$meth" "$pad" | tr '/%@.' '____')
# Een trage aanroep, om een onderbreking halverwege te testen.
[ -e "$STUB/$sleutel.traag" ] && { touch "$STUB/bezig" "$STUB/bezig-$sleutel"; sleep 2; }
status=$(cat "$STUB/$sleutel.status" 2>/dev/null || echo 000)
if [ "$status" = 000 ]; then printf 000; exit 7; fi
if [ -n "$out" ] && [ "$out" != /dev/null ]; then cat "$STUB/$sleutel.body" > "$out"; fi
printf '%s' "$status"
EOF
chmod +x "${werkmap}/bin/"*

# Een SSO-token met alleen de email-claim; de handtekening controleert de OM.
claim=$(printf '{"email":"a@b.nl"}' | base64 | tr -d '\n=' | tr '+/' '-_')
SSO="kop.${claim}.handtekening"; export SSO
n=0
geval() {
  n=$((n + 1)); STUB="${werkmap}/geval${n}"; export STUB
  mkdir -p "${STUB}/zad/login"
  printf 'ZAD_SSO_TOKEN=%s\n' "${SSO}" > "${STUB}/zad/login/.env.zadctl"
}
antwoord() { printf '%s' "$2" > "${STUB}/$1.status"; printf '%s' "$3" > "${STUB}/$1.body"; }
# Een eigen TMPDIR per geval: na afloop moet die leeg zijn, want het headerbestand
# draagt het SSO-token.
draai() {
  mkdir -p "${STUB}/tmp"
  TMPDIR="${STUB}/tmp" PATH="${werkmap}/bin:$PATH" bash "${script}" "$@" > "${STUB}/out" 2> "${STUB}/err"
  echo $? > "${STUB}/rc"
}
tmp_leeg() { [ -z "$(ls -A "${STUB}/tmp")" ]; }
wacht_op() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
# Start het script, wacht tot de trage aanroep loopt en stuurt dan TERM.
onderbreek() {
  mkdir -p "${STUB}/tmp"
  TMPDIR="${STUB}/tmp" PATH="${werkmap}/bin:$PATH" bash "${script}" "$@" > "${STUB}/out" 2> "${STUB}/err" &
  local pid=$! i=0
  while [ ! -e "${STUB}/bezig" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -TERM "$pid"; wait "$pid"; echo $? > "${STUB}/rc"
}
rc() { [ "$(cat "${STUB}/rc")" = "$1" ]; }
# `! grep` op een ontbrekend log slaagt ook; eerst eisen dat er aanroepen waren.
niet_in() { [ -s "$2" ] && ! grep -q -- "$1" "$2"; }
stepup=POST__v2_step-up
sluit=DELETE__v2_step-up
uitgifte() { echo "POST__v2_projects_$1_leden_a_40b_nl_tokens"; }

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA=","lid":"a@b.nl","naam":"x"}'
antwoord "$(uitgifte p-b)" 201 '{"token":"waardeB","lid":"a@b.nl","naam":"x"}'
mkdir -p "${STUB}/zad/p-b"
printf 'ZAD_API_KEY=oud\n# tokennaam: sandbox-oud\n' > "${STUB}/zad/p-b/.env.zadctl"
chmod 644 "${STUB}/zad/p-b/.env.zadctl"
draai uitgeven "${STUB}/zad" p-a,p-b 123456
rc 0; controle "uitgeven: twee projecten slagen" $?
if [ "$(stat -c %a "${STUB}/zad/p-a/.env.zadctl")" = 600 ] && [ "$(stat -c %a "${STUB}/zad/p-b/.env.zadctl")" = 600 ]; then r=0; else r=1; fi
controle "uitgeven: mode 600, ook over een bestaand 644-bestand" "$r"
grep -qx 'ZAD_API_KEY=waardeA=' "${STUB}/zad/p-a/.env.zadctl" && grep -qx 'ZAD_PROJECT_ID=p-a' "${STUB}/zad/p-a/.env.zadctl" \
  && grep -qx 'ZAD_API_URL=https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api' "${STUB}/zad/p-a/.env.zadctl"
controle "uitgeven: projectbestand met vaste URL, project en key" $?
! grep -q 'waarde[AB]' "${STUB}/out" "${STUB}/err"
controle "uitgeven: de tokenwaarde komt niet op het scherm" $?
grep -q "vorig token 'sandbox-oud' blijft geldig" "${STUB}/err" && ! grep -q 'bestaat mogelijk' "${STUB}/err"
controle "uitgeven: een vorig token wordt gemeld, zonder intrekhint voor het nieuwe" $?
grep -q 'step-up gesloten: HTTP 204' "${STUB}/err"
controle "uitgeven: het step-up-venster wordt gesloten" $?
niet_in 123456 "${STUB}/argv.log" && grep -q 123456 "${STUB}/stdin.log"
controle "uitgeven: de 2FA-code gaat via stdin naar curl, niet via argv" $?
niet_in 'handtekening' "${STUB}/argv.log"
controle "uitgeven: het SSO-token staat niet in de argv van curl" $?
grep -q 'https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api/v2/step-up' "${STUB}/argv.log"
controle "uitgeven: praat met de vaste OM-host" $?
grep -qx 'api=https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api issuer=https://keycloak.rijksapp.nl/realms/operations-manager client=zad-cli' "${STUB}/zadctl.log"
controle "uitgeven: verversen via zadctl met de vaste hosts en client" $?
grep -q '"dagen":1' "${STUB}/stdin.log"
controle "uitgeven: standaard 1 dag" $?
if [ "$(find "${STUB}/zad/p-a" -type f | wc -l)" -eq 1 ]; then r=0; else r=1; fi
controle "uitgeven: geen tijdelijk bestand achtergelaten" "$r"
grep -qx 'ZAD_PROJECT_ID=p-b' "${STUB}/zad/p-b/.env.zadctl" && grep -qx 'ZAD_API_KEY=waardeB' "${STUB}/zad/p-b/.env.zadctl"
controle "uitgeven: het tweede project krijgt zijn eigen project en key" $?
tmp_leeg
controle "uitgeven: TMPDIR is leeg na afloop" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 'geen json'
antwoord "$(uitgifte p-b)" 201 '{"token":"waardeB"}'
draai uitgeven "${STUB}/zad" p-a,p-b 123456
rc 1 && grep -qx 'FOUT: mislukt voor p-a' "${STUB}/err"
controle "201 zonder JSON: rood, met samenvatting" $?
grep -q 'bestaat mogelijk; trek het in' "${STUB}/err"
controle "201 zonder JSON: noemt het token om in te trekken" $?
if [ ! -e "${STUB}/zad/p-a/.env.zadctl" ] && [ -f "${STUB}/zad/p-b/.env.zadctl" ]; then r=0; else r=1; fi
controle "201 zonder JSON: het volgende project gaat door" "$r"
tmp_leeg
controle "201 zonder JSON: TMPDIR is leeg na afloop" $?

for waarde in '"a\nZAD_API_URL=https://elders"' '"waardeX "' '{"x":1}' '""' 'null'; do
  geval
  antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
  antwoord "$(uitgifte p-a)" 201 "{\"token\":${waarde}}"
  draai uitgeven "${STUB}/zad" p-a 123456
  rc 1 && [ ! -e "${STUB}/zad/p-a/.env.zadctl" ] && grep -q 'zonder geldig token-veld' "${STUB}/err" \
    && ! grep -q 'waardeX\|elders' "${STUB}/out" "${STUB}/err"
  controle "token ${waarde}: geweigerd, niets geschreven, niet getoond" $?
done

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
mkdir -p "${STUB}/zad/p-a/.env.zadctl"
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'kon .* niet schrijven' "${STUB}/err" && grep -q 'bestaat mogelijk' "${STUB}/err" \
  && ! grep -q waardeA "${STUB}/out" "${STUB}/err"
controle "schrijven faalt: rood, met het token om in te trekken, zonder de waarde" $?

geval
antwoord "$stepup" 403 '{"title":"Step-up vereist","detail":"code onjuist"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'step-up geweigerd' "${STUB}/err" && grep -q 'Step-up vereist — code onjuist' "${STUB}/err" \
  && ! grep -q 'bestaat mogelijk' "${STUB}/err"
controle "step-up 403: rood, met de foutvelden" $?
niet_in '-X DELETE' "${STUB}/argv.log"
controle "step-up 403: geen poging tot sluiten" $?

geval
antwoord "$stepup" 422 '{"detail":"code verlopen"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q '2FA-code geweigerd of verlopen' "${STUB}/err" && niet_in '-X DELETE' "${STUB}/argv.log"
controle "step-up 422: code geweigerd, geen poging tot sluiten" $?

geval
antwoord "$sluit" 204 ''
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q -- '-X DELETE' "${STUB}/argv.log" && grep -q 'step-up gesloten' "${STUB}/err"
controle "step-up zonder antwoord: toch sluiten" $?

geval
antwoord "$stepup" 503 '{}'; antwoord "$sluit" 204 ''
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q -- '-X DELETE' "${STUB}/argv.log" && grep -q 'step-up gesloten' "${STUB}/err"
controle "step-up 503: toch sluiten" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 502 ''
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'bestaat mogelijk' "${STUB}/err"
controle "uitgifte 502: noemt het token om in te trekken" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''; touch "${STUB}/${stepup}.traag"
onderbreek uitgeven "${STUB}/zad" p-a 123456
rc 143 && grep -q -- '-X DELETE' "${STUB}/argv.log" && grep -q 'step-up gesloten' "${STUB}/err" && tmp_leeg
controle "TERM tijdens de step-up: venster gesloten, exitcode 143" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'; touch "${STUB}/$(uitgifte p-a).traag"
onderbreek uitgeven "${STUB}/zad" p-a 123456
rc 143 && grep -q 'bestaat mogelijk; trek het in met: bash .* intrekken' "${STUB}/err" \
  && grep -q 'step-up gesloten' "${STUB}/err" && [ ! -e "${STUB}/zad/p-a/.env.zadctl" ]
controle "TERM tijdens de uitgifte: noemt het token om in te trekken" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
touch "${STUB}/${stepup}.traag" "${STUB}/${sluit}.traag"
mkdir -p "${STUB}/tmp"
TMPDIR="${STUB}/tmp" PATH="${werkmap}/bin:$PATH" bash "${script}" uitgeven "${STUB}/zad" p-a 123456 \
  > "${STUB}/out" 2> "${STUB}/err" &
pid=$!
wacht_op "${STUB}/bezig-${stepup}"; kill -TERM "$pid"
wacht_op "${STUB}/bezig-${sluit}"; kill -TERM "$pid"
wait "$pid"; echo $? > "${STUB}/rc"
rc 143 && grep -q 'step-up gesloten' "${STUB}/err" && tmp_leeg
controle "tweede TERM tijdens het opruimen: toch gesloten en opgeruimd" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 200 '{"token":"waardeA"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 0 && [ -f "${STUB}/zad/p-a/.env.zadctl" ]
controle "uitgifte met 200 in plaats van 201: geschreven" $?

geval
antwoord "$stepup" 401 '{"detail":"Authentication required"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'SSO-token geweigerd; opnieuw inloggen' "${STUB}/err"
controle "step-up 401: hint om opnieuw in te loggen" $?

geval
antwoord GET__v2_projects_p-a_leden 401 '{}'
draai leden "${STUB}/zad" p-a
rc 1 && grep -q 'opnieuw inloggen' "${STUB}/err"
controle "leden 401: hint om opnieuw in te loggen" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
draai intrekken "${STUB}/zad" p-a sandbox-1 123456
rc 1 && grep -q 'mogelijk nog geldig; controleer met leden' "${STUB}/err"
controle "intrekken zonder antwoord: het token is mogelijk nog geldig" $?

geval
basis_raar="${STUB}/z ad;x"
mkdir -p "${basis_raar}/login" "${basis_raar}/p-a"
cp "${STUB}/zad/login/.env.zadctl" "${basis_raar}/login/"
printf '# tokennaam: sandbox-oud\n' > "${basis_raar}/p-a/.env.zadctl"
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
draai uitgeven "${basis_raar}" p-a 123456
rc 0 && grep -qF -- "intrekken $(printf %q "${basis_raar}") p-a sandbox-oud" "${STUB}/err"
controle "intrekhint: een basis met spatie en ; is gequote" $?

geval
touch "${STUB}/zadctl.faalt"
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'SSO-sessie verversen mislukt' "${STUB}/err" && [ ! -e "${STUB}/argv.log" ]
controle "verversen faalt: rood voor elke API-aanroep" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'bestaat mogelijk; trek het in met: bash .* intrekken' "${STUB}/err"
controle "uitgifte zonder antwoord: noemt het token om in te trekken" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
draai uitgeven "${STUB}/zad" p-a 123456 7
rc 0 && grep -q '"dagen":7' "${STUB}/stdin.log"
controle "uitgeven: dagen gaat mee in de aanvraag" $?

geval
antwoord "$stepup" 200 '{}'
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'WAARSCHUWING: step-up niet gesloten (HTTP 000)' "${STUB}/err" && [ -f "${STUB}/zad/p-a/.env.zadctl" ]
controle "sluiten faalt: waarschuwing en exitcode 1, het token is wel geschreven" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 403 '{"detail":"geen lid"}'
draai uitgeven "${STUB}/zad" p-a,p-b 123456
[ "$(grep -c 'geen lid' "${STUB}/err")" -eq 1 ] && grep -q 'geen leesbare foutbody' "${STUB}/err" \
  && grep -qx 'FOUT: mislukt voor p-a p-b' "${STUB}/err"
controle "verbindingsfout na een 403: geen oude body" $?

geval
antwoord GET__v2_projects_p-a_leden 200 \
  '{"leden":[{"naam":"a@b.nl","soort":"persoon","rollen":["admin"],"rol_labels":["Admin"],"tokens":[{"naam":"t","vervalt":"2026-11-20","verlopen":false,"hash":"geheim"}]}]}'
draai leden "${STUB}/zad" p-a
rc 0 && [ "$(jq -r '.[0].rollen[0]' "${STUB}/out")" = admin ] && niet_in step-up "${STUB}/argv.log" \
  && [ "$(jq -r '.[0].tokens[0].verlopen' "${STUB}/out")" = false ]
controle "leden: JSON op stdout, zonder step-up" $?
! grep -q geheim "${STUB}/out"
controle "leden: alleen de gekozen velden, geen onbekende" $?

geval
antwoord GET__v2_projects_p-a_leden 200 '{"leden":[{"naam":"svc","soort":"service-account","rollen":["ops"],"tokens":null}]}'
draai leden "${STUB}/zad" p-a
rc 0 && [ "$(jq -r '.[0].tokens | length' "${STUB}/out")" = 0 ]
controle "leden: een lid zonder tokens breekt de lijst niet" $?

geval
antwoord GET__v2_projects_p-a_leden 200 'geen json "geheimstuk"'
draai leden "${STUB}/zad" p-a
rc 1 && grep -q 'onverwacht antwoord op de ledenlijst' "${STUB}/err" && ! grep -q geheimstuk "${STUB}/err"
controle "leden: onleesbaar antwoord is rood, zonder de body te citeren" $?

geval
antwoord GET__v2_projects_p-a_leden 403 '{"detail":"Geen toegang tot dit project"}'
draai leden "${STUB}/zad" p-a
rc 1 && grep -q 'Geen toegang tot dit project' "${STUB}/err"
controle "leden: een 403 is rood, met de foutvelden" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord DELETE__v2_projects_p-a_leden_a_40b_nl_tokens_sandbox-1 200 '{"status":"ingetrokken"}'
draai intrekken "${STUB}/zad" p-a sandbox-1 123456
rc 0 && grep -q -- '--path-as-is' "${STUB}/argv.log" && grep -q 'step-up gesloten' "${STUB}/err"
controle "intrekken: slaagt met --path-as-is en sluit de step-up" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord DELETE__v2_projects_p-a_leden_a_40b_nl_tokens_sandbox-1 404 '{"detail":"onbekend token"}'
draai intrekken "${STUB}/zad" p-a sandbox-1 123456
rc 1 && grep -qx 'FOUT: mislukt voor p-a' "${STUB}/err" && grep -q 'onbekend token' "${STUB}/err"
controle "intrekken: een 404 is rood" $?

for args in 'uitgeven ZAD  123456' 'uitgeven ZAD p-a 12345' 'uitgeven ZAD a;b 123456' \
            'intrekken ZAD p-a .. 123456' 'intrekken ZAD p-a ../x 123456' 'intrekken ZAD p-a,p-b t 123456' \
            'uitgeven ZAD p-a 123456 0' 'uitgeven ZAD p-a,p-a 123456' 'uitgeven ZAD p-a' \
            'intrekken ZAD p-a t' 'leden ZAD p-a,p-b' 'uitgeven ZAD p-a 123456789' 'uitgeven ZAD p-a 123456 7x'; do
  geval
  read -r -a a <<<"${args//ZAD/${STUB}/zad}"
  [ "${args}" = 'uitgeven ZAD  123456' ] && a=(uitgeven "${STUB}/zad" "" 123456)
  draai "${a[@]}"
  rc 1 && grep -q '^FOUT:' "${STUB}/err" && [ ! -e "${STUB}/argv.log" ]
  controle "ongeldige invoer '${args}': rood voor elke aanroep" $?
done

geval
printf 'ZAD_API_URL=https://elders.example/api\n' >> "${STUB}/zad/login/.env.zadctl"
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
ZAD_OM_API_URL=https://elders.example/api ZAD_API_URL=https://elders.example/api \
  ZAD_SSO_ISSUER=https://elders.example/realms/x ZAD_KEYCLOAK_CLIENT_ID=elders \
  HTTPS_PROXY=http://elders.example:3128 https_proxy=http://elders.example:3128 \
  ALL_PROXY=http://elders.example:3128 all_proxy=http://elders.example:3128 \
  CURL_CA_BUNDLE=/elders.pem SSL_CERT_FILE=/elders.pem SSL_CERT_DIR=/elders \
  SSLKEYLOGFILE=/tmp/elders.keys CURL_HOME=/elders \
  draai uitgeven "${STUB}/zad" p-a 123456
rc 0 && niet_in 'elders' "${STUB}/argv.log" \
  && grep -qx 'api=https://operations-manager.rig.prd1.gn2.quattro.rijksapps.nl/api issuer=https://keycloak.rijksapp.nl/realms/operations-manager client=zad-cli' "${STUB}/zadctl.log"
controle "andere URL in .env.zadctl of de omgeving: genegeerd" $?

geval
printf 'ZAD_SSO_TOKEN=verouderd.token.x\nZAD_SSO_TOKEN=%s\n' "${SSO}" > "${STUB}/zad/login/.env.zadctl"
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 0
controle "twee SSO-regels: de laatste telt" $?

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
mkdir -p "${STUB}/zad/p-a"
printf '# tokennaam: x; rm -rf ~\n' > "${STUB}/zad/p-a/.env.zadctl"
draai uitgeven "${STUB}/zad" p-a 123456
rc 0 && grep -q 'noemt een ongeldige tokennaam' "${STUB}/err" && ! grep -q 'rm -rf' "${STUB}/err"
controle "ongeldige vorige tokennaam: niet in een kopieerbaar commando" $?

geval
draai onzin
rc 2 && grep -q 'bash zad-token.sh leden' "${STUB}/err"
controle "onbekende actie: gebruikstekst, exitcode 2" $?

geval
draai uitgeven "${STUB}/zad" p-a
rc 1 && grep -qx 'FOUT: 2FA-code ontbreekt: zet de code achter het commando' "${STUB}/err"
controle "uitgeven zonder code: noemt de ontbrekende code" $?

geval
printf 'ZAD_SSO_TOKEN=kop.%s.handtekening\n' "$(printf '{"sub":"x"}' | base64 | tr -d '\n=' | tr '+/' '-_')" \
  > "${STUB}/zad/login/.env.zadctl"
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'geen email-claim' "${STUB}/err" && [ ! -e "${STUB}/argv.log" ]
controle "SSO-token zonder email: rood voor elke API-aanroep" $?

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
