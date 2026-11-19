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
EOF
# Nep-curl antwoordt per methode en pad uit $STUB/<sleutel>.status en .body, en logt
# argv en stdin. Zonder .status: verbindingsfout, zoals curl dan zelf 000 schrijft.
# Alleen de vaste OM-host en een Bearer uit een headerbestand worden bediend.
cat > "${werkmap}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" meth=GET url="" stdin=0 bearer=0
printf '%s\n' "$*" >> "$STUB/argv.log"
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
draai() {
  PATH="${werkmap}/bin:$PATH" bash "${script}" "$@" > "${STUB}/out" 2> "${STUB}/err"
  echo $? > "${STUB}/rc"
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
grep -q "vorig token 'sandbox-oud' blijft geldig" "${STUB}/err"
controle "uitgeven: een vorig token wordt gemeld" $?
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

for waarde in '"a\nZAD_API_URL=https://elders"' '{"x":1}' '""' 'null'; do
  geval
  antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
  antwoord "$(uitgifte p-a)" 201 "{\"token\":${waarde}}"
  draai uitgeven "${STUB}/zad" p-a 123456
  rc 1 && [ ! -e "${STUB}/zad/p-a/.env.zadctl" ] && grep -q 'zonder geldig token-veld' "${STUB}/err"
  controle "token ${waarde}: geweigerd, niets geschreven" $?
done

geval
antwoord "$stepup" 200 '{}'; antwoord "$sluit" 204 ''
antwoord "$(uitgifte p-a)" 201 '{"token":"waardeA"}'
mkdir -p "${STUB}/zad/p-a/.env.zadctl"
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q 'kon .* niet schrijven' "${STUB}/err" && grep -q 'bestaat mogelijk' "${STUB}/err"
controle "schrijven faalt: rood, met het token om in te trekken" $?

geval
antwoord "$stepup" 403 '{"title":"Step-up vereist","detail":"code onjuist"}'
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q '2FA-code geweigerd' "${STUB}/err" && grep -q 'Step-up vereist — code onjuist' "${STUB}/err"
controle "step-up 403: rood, met de foutvelden" $?
niet_in '-X DELETE' "${STUB}/argv.log"
controle "step-up 403: geen poging tot sluiten" $?

geval
antwoord "$sluit" 204 ''
draai uitgeven "${STUB}/zad" p-a 123456
rc 1 && grep -q -- '-X DELETE' "${STUB}/argv.log" && grep -q 'step-up gesloten' "${STUB}/err"
controle "step-up zonder antwoord: toch sluiten" $?

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
grep -q 'WAARSCHUWING: step-up niet gesloten (HTTP 000)' "${STUB}/err"
controle "sluiten faalt: waarschuwing in plaats van 'gesloten'" $?

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
rc 0 && [ "$(jq -r '.[0].rollen[0]' "${STUB}/out")" = admin ] && niet_in step-up "${STUB}/argv.log"
controle "leden: JSON op stdout, zonder step-up" $?
! grep -q geheim "${STUB}/out"
controle "leden: alleen de gekozen velden, geen onbekende" $?

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
            'uitgeven ZAD p-a 123456 0' 'uitgeven ZAD p-a,p-a 123456'; do
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
  draai uitgeven "${STUB}/zad" p-a 123456
rc 0 && niet_in 'elders' "${STUB}/argv.log" && niet_in 'elders' "${STUB}/zadctl.log"
controle "andere URL in .env.zadctl of de omgeving: genegeerd" $?

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
