#!/usr/bin/env bash
# Beantwoordt de vraag of een verversing van de apt-laag nu iets oplevert.
#
# Trivy's `ignore-unfixed` filtert op "upstream kent een FixedVersion", niet op
# "die versie staat in de suite die de image gebruikt". Die twee lopen uiteen
# zodra een fix eerst in unstable landt: er gaat dan een verversings-PR open die
# niets verhelpt, de bevinding komt de week erna terug, en dat kost elke keer
# drie volledige bouwrondes.
#
#   apt-upgrade-beschikbaar.sh cve     <bevindingen.json> <policy-uitvoer>
#   apt-upgrade-beschikbaar.sh upgrade <pakketten.json>   <policy-uitvoer>
#
# `cve` leest objecten met `pkg` en `fix` en slaagt zodra een fix installeerbaar
# is; `upgrade` leest objecten met `pkg` en `inst` en slaagt zodra een pakket
# een hogere kandidaat heeft. Exitcode 1 betekent: niets te halen, geen PR.
set -euo pipefail

modus="${1:?modus ontbreekt (cve of upgrade)}"
bevindingen="${2:?bevindingenbestand ontbreekt}"
policy="${3:?policy-uitvoer ontbreekt}"

for bestand in "${bevindingen}" "${policy}"; do
  [ -f "${bestand}" ] || {
    echo "FOUT: ${bestand} bestaat niet." >&2
    exit 2
  }
done

case "${modus}" in
  cve)     sleutel='.pkg + " " + (.fix // "-") + " " + (.id // "?")' ;;
  upgrade) sleutel='.pkg + " " + (.inst // "-") + " " + "-"' ;;
  *)
    echo "FOUT: onbekende modus '${modus}' (verwacht: cve of upgrade)." >&2
    exit 2 ;;
esac

lijst="${bevindingen}.lijst"
jq -r "[.[] | select(.pkg != null) | ${sleutel}] | unique | .[]" "${bevindingen}" > "${lijst}" || {
  echo "FOUT: ${bevindingen} is geen bruikbare JSON-lijst." >&2
  exit 2
}

if [ ! -s "${lijst}" ]; then
  echo "Geen bevindingen om te wegen."
  rm -f "${lijst}"
  exit 1
fi

# `apt-cache policy` schrijft per pakket een kop en een Candidate-regel. Een
# pakket dat de suite niet kent, krijgt "(none)" — dat is geen versie.
kandidaat() {
  awk -v pkg="$1" '
    $0 == pkg ":" { in_pkg = 1; next }
    /^[^ ]/       { in_pkg = 0 }
    in_pkg && $1 == "Candidate:" { print $2; exit }
  ' "${policy}"
}

haalbaar=0

while read -r pkg doel id; do
  [ -n "${pkg}" ] || continue
  kand="$(kandidaat "${pkg}")"

  if [ -z "${kand}" ] || [ "${kand}" = "(none)" ]; then
    echo "  ${pkg}: geen kandidaat in de suite"
    continue
  fi

  # Trivy noemt soms meerdere gefixte versies; een haalbare is genoeg.
  gehaald=nee

  for versie in ${doel//,/ }; do
    [ -n "${versie}" ] && [ "${versie}" != "-" ] || continue

    if [ "${modus}" = cve ]; then
      dpkg --compare-versions "${kand}" ge "${versie}" && gehaald=ja
    else
      dpkg --compare-versions "${kand}" gt "${versie}" && gehaald=ja
    fi
  done

  if [ "${gehaald}" = ja ]; then
    echo "  ${pkg}: kandidaat ${kand} dekt ${doel} (${id})"
    haalbaar=$((haalbaar + 1))
  else
    echo "  ${pkg}: kandidaat ${kand} dekt ${doel} nog niet (${id})"
  fi
done < "${lijst}"

rm -f "${lijst}"

if [ "${haalbaar}" -eq 0 ]; then
  echo "Niets installeerbaars gevonden."
  exit 1
fi

echo "${haalbaar} pakket(ten) met iets te halen."
