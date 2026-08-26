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
# een hogere kandidaat heeft.
#
# Exitcodes: 0 = er valt iets te halen, 1 = niets te halen (een antwoord, geen
# PR), 2 = de vraag is niet beantwoord. Die derde mag nergens als "nee" gelden;
# een aanroeper die 2 met 1 op één hoop gooit, slaat security-updates over.
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

# Scheiden op US (0x1f), niet op tab: Trivy geeft meerdere fixversies soms als
# "a, b", dus een spatie kapt de lijst af, en tab is voor `read` whitespace —
# twee opeenvolgende tabs klappen samen en schuiven het CVE-ID de versiekolom
# in. `//` valt alleen terug bij null, dus een leeg veld wordt hier apart
# afgevangen; anders komt het als lege kolom door.
leeg='(. // "") | if . == "" then "-" else . end'
case "${modus}" in
  cve)     sleutel="[(.pkg | ${leeg}), (.fix | ${leeg}), (.id | ${leeg})] | join(\"\\u001f\")" ;;
  upgrade) sleutel="[(.pkg | ${leeg}), (.inst | ${leeg}), \"-\"] | join(\"\\u001f\")" ;;
  *)
    echo "FOUT: onbekende modus '${modus}' (verwacht: cve of upgrade)." >&2
    exit 2 ;;
esac

lijst="$(mktemp)"
trap 'rm -f "${lijst}"' EXIT
jq -r "[.[] | select(.pkg != null) | ${sleutel}] | unique | .[]" "${bevindingen}" > "${lijst}" || {
  echo "FOUT: ${bevindingen} is geen bruikbare JSON-lijst." >&2
  exit 2
}

if [ ! -s "${lijst}" ]; then
  echo "Geen bevindingen om te wegen."
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
haalbare_pakketten="$(mktemp)"
trap 'rm -f "${lijst}" "${haalbare_pakketten}"' EXIT

while IFS=$'\037' read -r pkg doel id; do
  [ -n "${pkg}" ] || continue
  kand="$(kandidaat "${pkg}")"

  if [ -z "${kand}" ] || [ "${kand}" = "(none)" ]; then
    echo "  ${pkg}: geen kandidaat in de suite"
    continue
  fi

  # In `cve`-modus kan `doel` meerdere gefixte versies bevatten en is één
  # haalbare genoeg; in `upgrade`-modus staat er altijd precies één versie.
  gehaald=nee

  # Ongequote expansie splitst op spaties, maar zou ook globben; versiesyntax
  # kent geen metatekens, dus dat is vandaag onschadelijk en morgen een val.
  read -r -a doelversies <<<"${doel//,/ }"

  leesbaar=0

  for versie in "${doelversies[@]}"; do
    [ -n "${versie}" ] && [ "${versie}" != "-" ] || continue

    # dpkg geeft alleen 2 bij een versie die het echt niet kan ontleden. Bij
    # iets dat niet met een cijfer begint waarschuwt het naar stderr en
    # vergelijkt alsnog — resultaat 1, wat hier "nee" zou betekenen. Zo'n
    # element overslaan, niet de hele regel laten vallen: Trivy geeft vaak een
    # lijst, en één onleesbaar element mag een versie die er wél in staat niet
    # ongeldig maken.
    case "${versie}" in
      [0-9]*) leesbaar=$((leesbaar + 1)) ;;
      *)
        echo "  ${pkg}: '${versie}' is geen leesbare Debian-versie en telt niet mee"
        continue ;;
    esac

    vergelijking=ge
    [ "${modus}" = cve ] || vergelijking=gt
    rc=0
    dpkg --compare-versions "${kand}" "${vergelijking}" "${versie}" || rc=$?

    case "${rc}" in
      0) gehaald=ja ;;
      1) ;;
      *)
        echo "FOUT: '${kand}' en '${versie}' zijn niet te vergelijken." >&2
        exit 2 ;;
    esac
  done

  # Stond er wel een doelversie maar was er geen enkele leesbaar, dan is de
  # vraag voor dit pakket niet beantwoord; dat mag geen "nee" worden.
  if [ "${leesbaar}" -eq 0 ] && [ "${doel}" != "-" ] && [ -n "${doel}" ]; then
    echo "FOUT: geen enkele leesbare versie in '${doel}' voor ${pkg}; de vergelijking is niet gedaan." >&2
    exit 2
  fi

  herkomst=""
  [ "${id}" = "-" ] || herkomst=" (${id})"

  # Eén formulering voor beide modi leest in de logs als onzin
  # ("kandidaat 2.41-5 dekt 2.41-5 nog niet").
  if [ "${gehaald}" = ja ]; then
    if [ "${modus}" = cve ]; then
      echo "  ${pkg}: kandidaat ${kand} dekt ${doel}${herkomst}"
    else
      echo "  ${pkg}: kandidaat ${kand} is hoger dan het geïnstalleerde ${doel}"
    fi

    haalbaar=$((haalbaar + 1))
    echo "${pkg}" >> "${haalbare_pakketten}"
  elif [ "${modus}" = cve ]; then
    echo "  ${pkg}: kandidaat ${kand} dekt ${doel} nog niet${herkomst}"
  else
    echo "  ${pkg}: kandidaat ${kand} is niet hoger dan het geïnstalleerde ${doel}"
  fi
done < "${lijst}"

if [ "${haalbaar}" -eq 0 ]; then
  echo "Niets installeerbaars gevonden."
  exit 1
fi

echo "$(sort -u "${haalbare_pakketten}" | wc -l) pakket(ten) met iets te halen."
