#!/usr/bin/env bash
# Fixtures voor vervang-pin.sh.
#
# De tellingen vooraf en achteraf dekken elkaar af, en de controle op resten van
# het tussentoken is per constructie onbereikbaar zolang `sed -g` alles
# vervangt: die drie zijn een vangnet en zijn hier niet los rood te krijgen. De
# overige controles horen hier wel een geval te hebben dat rood wordt zodra ze
# verdwijnen.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
vervang="${hier}/vervang-pin.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

geslaagd=0
gefaald=0

toets() { # naam verwachte_exitcode bestandsinhoud oud nieuw [aantal]
  local naam="$1" verwacht="$2" inhoud="$3" oud="$4" nieuw="$5" aantal="${6:-1}"
  local doel="${werkmap}/doel.txt" rc=0
  printf '%b' "${inhoud}" > "${doel}"
  "${vervang}" "${doel}" "${oud}" "${nieuw}" "${aantal}" >/dev/null 2>&1 || rc=$?

  if [ "${rc}" -eq "${verwacht}" ]; then
    echo "ok   ${naam}"
    geslaagd=$((geslaagd + 1))
  else
    echo "FOUT ${naam}: exitcode ${rc}, verwacht ${verwacht}"
    gefaald=$((gefaald + 1))
  fi
}

toets "enkele treffer"            0 'VERSION=v1.0.0\n'                 v1.0.0 v1.1.0
toets "twee treffers, twee verwacht" 0 'A=v1.0.0\nB=v1.0.0\n'          v1.0.0 v1.1.0 2
toets "twee treffers op één regel"  0 'A=v1.0.0 B=v1.0.0\n'             v1.0.0 v1.1.0 2
toets "nieuwe waarde bevat de oude" 0 'V=v1.0.1\n'                      v1.0.1 v1.0.10
toets "nieuwe waarde bevat de oude, twee plekken" 0 'A=v1.0.1\nB=v1.0.1\n' v1.0.1 v1.0.10 2
toets "nul treffers"              1 'VERSION=v9.9.9\n'                 v1.0.0 v1.1.0
toets "meer treffers dan verwacht" 1 'A=v1.0.0\nB=v1.0.0\n'            v1.0.0 v1.1.0 1
toets "minder treffers dan verwacht" 1 'A=v1.0.0\n'                    v1.0.0 v1.1.0 2
toets "oud en nieuw gelijk"       1 'VERSION=v1.0.0\n'                 v1.0.0 v1.0.0
toets "ampersand in nieuwe waarde" 1 'VERSION=v1.0.0\n'                v1.0.0 'v1&1.0'
toets "sed-metateken in oude waarde" 1 'VERSION=v1.0.0\n'              'v1.0.*' v1.1.0
toets "spatie in waarde"          1 'VERSION=v1.0.0\n'                 'v1.0.0 ' v1.1.0
# Een punt is een wildcard in een sed-patroon; zonder escape raakt v1.0.0 ook
# v1x0y0 en telt de controle achteraf twee vervangingen.
toets "punt matcht geen willekeurig teken" 1 'A=v1.0.0\nB=v1x0y0\n'      v1.0.0 v1.1.0 2
toets "alleen de letterlijke waarde"       0 'A=v1.0.0\nB=v1x0y0\n'      v1.0.0 v1.1.0 1
toets "nul verwachte vervangingen"        1 'A=v1.0.0\n'                v9.9.9 v9.9.8 0
toets "niet-numeriek aantal"              1 'A=v1.0.0\n'                v1.0.0 v1.1.0 abc
# De nieuwe waarde staat al elders; dat mag een correcte vervanging niet
# als mislukt laten eindigen.
toets "nieuwe waarde bestond al elders"   0 'A=v1.0.0\nB=v1.1.0\n'      v1.0.0 v1.1.0 1

# Een afgekeurde invoer mag het bestand niet half verminkt achterlaten.
doel="${werkmap}/onaangeroerd.txt"
printf 'V=v1.0.0\n' > "${doel}"
"${vervang}" "${doel}" v1.0.0 'v1&1.0' >/dev/null 2>&1
if [ "$(cat "${doel}")" = 'V=v1.0.0' ]; then
  echo "ok   afgekeurde invoer laat het bestand ongemoeid"
  geslaagd=$((geslaagd + 1))
else
  echo "FOUT afgekeurde invoer laat het bestand ongemoeid: $(cat "${doel}")"
  gefaald=$((gefaald + 1))
fi

# Bestaat het bestand niet, dan is er niets vervangen en niets te melden.
rc=0
"${vervang}" "${werkmap}/bestaat-niet.txt" v1.0.0 v1.1.0 >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 1 ]; then
  echo "ok   bestand ontbreekt"
  geslaagd=$((geslaagd + 1))
else
  echo "FOUT bestand ontbreekt: exitcode ${rc}, verwacht 1"
  gefaald=$((gefaald + 1))
fi

# Een geslaagde vervanging laat het bestand ook echt gewijzigd achter.
doel="${werkmap}/echt.txt"
printf 'SHA=aaa\nSHA2=bbb\n' > "${doel}"
"${vervang}" "${doel}" aaa ccc >/dev/null 2>&1
if grep -q 'SHA=ccc' "${doel}" && grep -q 'SHA2=bbb' "${doel}"; then
  echo "ok   alleen de bedoelde waarde is vervangen"
  geslaagd=$((geslaagd + 1))
else
  echo "FOUT alleen de bedoelde waarde is vervangen"
  gefaald=$((gefaald + 1))
fi

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
