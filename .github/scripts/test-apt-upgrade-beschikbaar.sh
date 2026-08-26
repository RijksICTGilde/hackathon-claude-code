#!/usr/bin/env bash
# Fixtures voor apt-upgrade-beschikbaar.sh.
#
# De beslissing "levert een verversing nu iets op?" hangt aan een
# versievergelijking tussen wat Trivy meldt en wat de suite aanbiedt. Die
# vergelijking is hier zonder container te toetsen; de container levert in de
# workflow alleen de `apt-cache policy`-uitvoer aan.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
beoordeel="${hier}/apt-upgrade-beschikbaar.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

geslaagd=0
gefaald=0

policy() { # naam inhoud
  printf '%b' "$2" > "${werkmap}/$1"
}

bevindingen() { # naam json
  printf '%s' "$2" > "${werkmap}/$1"
}

toets() { # naam verwachte_exitcode modus bevindingen policy [patroon]
  local naam="$1" verwacht="$2" modus="$3" bev="$4" pol="$5" patroon="${6:-}"
  local uit rc=0
  uit="$("${beoordeel}" "${modus}" "${werkmap}/${bev}" "${werkmap}/${pol}" 2>&1)" || rc=$?

  if [ "${rc}" -ne "${verwacht}" ]; then
    echo "FOUT ${naam}: exitcode ${rc}, verwacht ${verwacht}"
    sed 's/^/    /' <<<"${uit}" | head -4
    gefaald=$((gefaald + 1))
    return
  fi

  if [ -n "${patroon}" ] && ! grep -q "${patroon}" <<<"${uit}"; then
    echo "FOUT ${naam}: melding mist '${patroon}'"
    sed 's/^/    /' <<<"${uit}" | head -4
    gefaald=$((gefaald + 1))
    return
  fi

  echo "ok   ${naam}"
  geslaagd=$((geslaagd + 1))
}

policy gewoon 'util-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5+deb13u1\n  Version table:\n     2.41-5+deb13u1 500\nzlib1g:\n  Installed: 1:1.3.dfsg+really1.3.1-1\n  Candidate: 1:1.3.dfsg+really1.3.1-1\n'
policy zonder_kandidaat 'util-linux:\n  Installed: 2.41-5\n  Candidate: (none)\n'
policy leeg ''

bevindingen fix_beschikbaar '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":"2.41-5+deb13u1"}]'
bevindingen fix_te_nieuw    '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":"2.42-1"}]'
bevindingen fix_lijst       '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":"2.42-1,2.41-5+deb13u1"}]'
bevindingen fix_lijst_spatie '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":"2.42-1, 2.41-5+deb13u1"}]'
bevindingen fix_onbekend    '[{"id":"CVE-1","pkg":"bestaat-niet","inst":"1","fix":"2"}]'
bevindingen fix_zonder_fix  '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5"}]'
bevindingen twee_pakketten  '[{"id":"CVE-1","pkg":"zlib1g","inst":"1:1.3.dfsg+really1.3.1-1","fix":"1:1.4"},{"id":"CVE-2","pkg":"util-linux","inst":"2.41-5","fix":"2.41-5+deb13u1"}]'
bevindingen fix_onleesbaar  '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":"2.0:a:b"}]'
bevindingen fix_geen_versie '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":"unfixed"}]'
bevindingen fix_leeg        '[{"id":"CVE-1","pkg":"util-linux","inst":"2.41-5","fix":""}]'
bevindingen geen            '[]'
bevindingen kapot           '{"geen":"lijst"}'
bevindingen upgrade_kan     '[{"pkg":"util-linux","inst":"2.41-5"}]'
bevindingen upgrade_kan_niet '[{"pkg":"zlib1g","inst":"1:1.3.dfsg+really1.3.1-1"}]'

toets "cve: fix staat in de suite"              0 cve fix_beschikbaar gewoon "dekt 2.41-5+deb13u1"
toets "cve: fix nog niet uitgeleverd"           1 cve fix_te_nieuw    gewoon "nog niet"
toets "cve: een van meerdere fixversies telt"   0 cve fix_lijst       gewoon "dekt"
toets "cve: fixlijst met spatie na de komma"   0 cve fix_lijst_spatie gewoon "dekt"
toets "cve: pakket niet in de suite"            1 cve fix_onbekend    gewoon "geen kandidaat"
toets "cve: bevinding zonder fixversie"         1 cve fix_zonder_fix  gewoon "nog niet"
toets "cve: een van twee pakketten is genoeg"   0 cve twee_pakketten  gewoon "1 pakket"
toets "cve: geen bevindingen"                   1 cve geen            gewoon "Geen bevindingen"
toets "cve: onbruikbare invoer"                 2 cve kapot           gewoon "geen bruikbare JSON"
toets "cve: fixversie die geen versie is"        2 cve fix_geen_versie gewoon "geen leesbare Debian-versie"
toets "cve: leeg fixveld schuift geen kolom op" 1 cve fix_leeg        gewoon "dekt - nog niet (CVE-1)"
toets "cve: onvergelijkbare versie"            2 cve fix_onleesbaar   gewoon "niet te vergelijken"
toets "cve: lege policy-uitvoer"                1 cve fix_beschikbaar leeg   "geen kandidaat"
toets "cve: kandidaat is (none)"                1 cve fix_beschikbaar zonder_kandidaat "geen kandidaat"
toets "upgrade: hogere kandidaat"               0 upgrade upgrade_kan     gewoon "is hoger dan het geïnstalleerde 2.41-5"
toets "upgrade: kandidaat gelijk aan installed" 1 upgrade upgrade_kan_niet gewoon "is niet hoger dan het geïnstalleerde"
toets "onbekende modus"                         2 cvee fix_beschikbaar gewoon "onbekende modus"

rc=0
"${beoordeel}" cve "${werkmap}/bestaat-niet.json" "${werkmap}/gewoon" >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 2 ]; then
  echo "ok   ontbrekend bevindingenbestand"
  geslaagd=$((geslaagd + 1))
else
  echo "FOUT ontbrekend bevindingenbestand: exitcode ${rc}, verwacht 2"
  gefaald=$((gefaald + 1))
fi

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
