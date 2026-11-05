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
# Geeft de kandidaat, maar alleen als die uit een archief komt. Zonder index
# vult apt de kandidaat met de versie die al geïnstalleerd is, herkenbaar aan
# een versietabel die alleen naar /var/lib/dpkg/status verwijst. Die versie
# beantwoordt de vraag niet: hij zegt wat er ís, niet wat er te halen valt.
# De herkomst per pakket toetsen en niet over het hele bestand: één pakket met
# een archiefregel zou anders alle andere afdekken.
kandidaat() {
  awk -v pkg="$1" '
    $0 == pkg ":" { in_pkg = 1; next }
    /^[^ ]/       { if (kand != "") exit; in_pkg = 0 }
    in_pkg && $1 == "Candidate:" { kand = $2; next }
    # Een herkomstregel is "<prioriteit> <bron>"; de status van de image zelf
    # is het pad /var/lib/dpkg/status, elk archief heeft een schema ervoor.
    in_pkg && kand != "" && $1 ~ /^[0-9]+$/ && $2 !~ /^\// { uit_archief = 1 }
    # Onderscheid bewaren: geen kandidaat is een antwoord ("de suite kent dit
    # pakket niet"), een kandidaat zonder archief is een niet-gestelde vraag.
    END {
      if (kand == "") exit
      # "(none)" heeft geen versietabel en dus geen herkomst; dat is een
      # antwoord van apt, geen ontbrekende meting.
      print (uit_archief || kand == "(none)" ? kand : "@status")
    }
  ' "${policy}"
}

haalbaar=0
ongemeten=0
haalbare_pakketten="$(mktemp)"
trap 'rm -f "${lijst}" "${haalbare_pakketten}"' EXIT

while IFS=$'\037' read -r pkg doel id; do
  [ -n "${pkg}" ] || continue
  kand="$(kandidaat "${pkg}")"

  if [ "${kand}" = "@status" ]; then
    echo "  ${pkg}: de kandidaat komt uit de pakketstatus van de image, niet uit een suite" >&2
    ongemeten=$((ongemeten + 1))
    continue
  fi

  if [ -z "${kand}" ] || [ "${kand}" = "(none)" ]; then
    echo "  ${pkg}: geen kandidaat in de suite"
    continue
  fi

  # In `cve`-modus kan `doel` meerdere gefixte versies bevatten en is één
  # haalbare genoeg; in `upgrade`-modus staat er altijd precies één versie.
  gehaald=nee

  # `read -a` splitst op spaties zonder pathname-expansie; een fixversie met
  # een glob-teken erin blijft daardoor de tekst die Trivy gaf.
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

# Een pakket waarvoor de vraag niet gesteld is, mag niet als "nee" meetellen:
# dan zou een ontbrekende index als "niets te halen" lezen.
if [ "${ongemeten}" -gt 0 ]; then
  echo "FOUT: voor ${ongemeten} pakket(ten) kwam de kandidaat niet uit een suite; de vergelijking is daar niet gedaan." >&2
  exit 2
fi

if [ "${haalbaar}" -eq 0 ]; then
  echo "Niets installeerbaars gevonden."
  exit 1
fi

echo "$(sort -u "${haalbare_pakketten}" | wc -l) pakket(ten) met iets te halen."
