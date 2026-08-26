#!/usr/bin/env bash
# Fixtures voor valideer-trivyignore.sh. Elke regel die de validatie afdwingt
# hoort hier een geval te hebben dat rood wordt zodra die regel verdwijnt.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
validator="${hier}/valideer-trivyignore.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

geslaagd=0
gefaald=0

regel() {
  printf 'misconfigurations:\n  - id: DS-0002\n%b    expired_at: 2027-08-26\n    statement: reden\n' "$1"
}

toets() { # naam verwachte_exitcode fixturenaam [mag-ontbreken]
  local naam="$1" verwacht="$2" bestand="${werkmap}/${3}" ontbreken="${4:-nee}"
  local rc=0

  # De validator geeft ook exit 1 op een bestand dat niet bestaat; zonder deze
  # controle degenereert een tikfout in een fixturenaam stil tot dat geval.
  if [ "${ontbreken}" = "nee" ] && [ ! -f "${bestand}" ]; then
    echo "FOUT ${naam}: fixture ${3} bestaat niet"
    gefaald=$((gefaald + 1))
    return
  fi

  "${validator}" "${bestand}" >/dev/null 2>&1 || rc=$?

  if [ "${rc}" -eq "${verwacht}" ]; then
    echo "ok   ${naam}"
    geslaagd=$((geslaagd + 1))
  else
    echo "FOUT ${naam}: exitcode ${rc}, verwacht ${verwacht}"
    gefaald=$((gefaald + 1))
  fi
}

# Geldige vormen.
regel '    paths: ["claude-sandbox/Dockerfile"]\n'   > "${werkmap}/pad.yaml"
regel '    paths: ["claude-sandbox/**"]\n'           > "${werkmap}/glob.yaml"
regel '    purls: ["pkg:npm/tar"]\n'                 > "${werkmap}/purl.yaml"
printf 'licenses:\n  - id: MIT\n    paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\n' \
  > "${werkmap}/licenses.yaml"
printf 'vulnerabilities:\n  - id: CVE-1\n    paths: ["a"]\n    expired_at: "2027-08-26"\n    statement: reden\n' \
  > "${werkmap}/gequote-datum.yaml"
# Zijn alle uitzonderingen vervallen, dan blijft er een kop of niets over;
# Trivy accepteert dat en deze controle hoort dat ook te doen.
printf '# alleen een kop\n' > "${werkmap}/alleen-kop.yaml"
printf 'vulnerabilities:\n' > "${werkmap}/lege-sectie.yaml"
: > "${werkmap}/leeg.yaml"

toets "pad-binding"                0 pad.yaml
toets "glob binnen een map"        0 glob.yaml
toets "purl-binding"               0 purl.yaml
toets "licenses-sectie"            0 licenses.yaml
toets "gequote datum"              0 gequote-datum.yaml
toets "alleen een kop"             0 alleen-kop.yaml
toets "lege sectie"                0 lege-sectie.yaml
toets "leeg bestand"               0 leeg.yaml

# Vormen die stil meer zouden onderdrukken dan bedoeld.
regel '    paths: ["**"]\n'                          > "${werkmap}/ster.yaml"
regel '    paths: ["*"]\n'                           > "${werkmap}/enkele-ster.yaml"
regel '    paths: ["*/**"]\n'                        > "${werkmap}/ster-slash.yaml"
regel '    paths: ["/**"]\n'                         > "${werkmap}/slash-ster.yaml"
regel '    paths: ["?*/**"]\n'                       > "${werkmap}/vraagteken.yaml"
regel '    paths: [""]\n'                            > "${werkmap}/leeg-pad.yaml"
regel '    paths:\n      -\n'                        > "${werkmap}/null-pad.yaml"
regel '    path: ["a"]\n'                            > "${werkmap}/path-typo.yaml"
printf 'misconfigurations:\n  - paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\n' \
  > "${werkmap}/geen-id.yaml"
printf 'misconfigurations:\n  - id: DS-0002\n    paths: ["a"]\n    expires_at: 2020-01-01\n    statement: reden\n' \
  > "${werkmap}/expiry-typo.yaml"
# Twee op zichzelf geldige documenten: alleen de documenttelling mag hier
# roepen, want Trivy leest er maar één en de rest is onzichtbare inhoud.
{ regel '    paths: ["a"]\n'; echo '---'; regel '    paths: ["b"]\n'; } \
  > "${werkmap}/twee-documenten.yaml"
printf 'misconfigurations:\n  - &b\n    id: DS-0002\n    paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\n  - <<: *b\n    id: DS-0026\n' \
  > "${werkmap}/anker.yaml"

toets "pad begint met **"          1 ster.yaml
toets "pad is *"                   1 enkele-ster.yaml
toets "pad begint met */"          1 ster-slash.yaml
toets "pad begint met /"           1 slash-ster.yaml
toets "pad begint met ?*"          1 vraagteken.yaml
toets "leeg pad"                   1 leeg-pad.yaml
toets "leeg lijstitem in paths"    1 null-pad.yaml
toets "path in plaats van paths"   1 path-typo.yaml
toets "regel zonder id"            1 geen-id.yaml
toets "expires_at in plaats van expired_at" 1 expiry-typo.yaml
toets "tweede YAML-document"       1 twee-documenten.yaml
toets "merge-key uit een anker"    1 anker.yaml

# Vormen waar Trivy zelf op struikelt of die niets doen.
regel '    paths: "a"\n'                             > "${werkmap}/scalar-pad.yaml"
printf 'misconfigurations:\n  - id: 12345\n    paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\n' \
  > "${werkmap}/getal-id.yaml"
printf 'misconfigurations:\n  - id: DS-0002\n    paths: ["a"]\n    expired_at: 2027-13-45\n    statement: reden\n' \
  > "${werkmap}/onbestaande-datum.yaml"
printf 'misconfigurations:\n  - id: DS-0002\n    paths: ["a"]\n    expired_at: 26-11-2027\n    statement: reden\n' \
  > "${werkmap}/omgedraaide-datum.yaml"
printf 'misconfigurations:\n  - id: DS-0002\n    paths: ["a"]\n    expired_at: 2027-08-26\n' \
  > "${werkmap}/geen-statement.yaml"
printf 'misconfigurations:\n  - id: DS-0002\n    expired_at: 2027-08-26\n    statement: reden\n' \
  > "${werkmap}/geen-binding.yaml"
regel '    paths: ["a"]\n    notitie: extra\n'       > "${werkmap}/extra-sleutel.yaml"
printf 'vulnerability:\n  - id: CVE-1\n    paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\n' \
  > "${werkmap}/onbekende-hoofdsleutel.yaml"

toets "paths als losse tekst"      1 scalar-pad.yaml
toets "id als getal"               1 getal-id.yaml
toets "datum die niet bestaat"     1 onbestaande-datum.yaml
toets "datum in dd-mm-jjjj"        1 omgedraaide-datum.yaml
toets "regel zonder statement"     1 geen-statement.yaml
toets "regel zonder pad of purl"   1 geen-binding.yaml
toets "onbekende sleutel"          1 extra-sleutel.yaml
toets "onbekende hoofdsleutel"     1 onbekende-hoofdsleutel.yaml
toets "bestand ontbreekt"          1 bestaat-niet.yaml ja

# Een trivy.yaml in de scanroot beperkt de scan buiten de suppressielijst om.
cp "${werkmap}/pad.yaml" "${werkmap}/root.yaml"
(
  cd "${werkmap}" || exit 1
  printf 'scan:\n  skip-dirs:\n    - "**"\n' > trivy.yaml
  rc=0
  "${validator}" root.yaml >/dev/null 2>&1 || rc=$?
  rm -f trivy.yaml
  [ "${rc}" -eq 1 ]
) && { echo "ok   trivy.yaml in de scanroot"; geslaagd=$((geslaagd + 1)); } \
  || { echo "FOUT trivy.yaml in de scanroot: werd niet geweigerd"; gefaald=$((gefaald + 1)); }

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
