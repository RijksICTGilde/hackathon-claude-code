#!/usr/bin/env bash
# Dwingt de vorm van de Trivy-suppressielijst af.
#
# Trivy negeert een onbekende sleutel zonder melding, en dat faalt open: `path`
# in plaats van `paths` laat de uitzondering projectbreed gelden, een regel
# zonder herkend `id` onderdrukt alles op dat pad, en elke schrijfwijze naast
# `expired_at` haalt de houdbaarheid eruit. Een schrijffout mag dus niet stil
# meer verbergen dan bedoeld.
set -euo pipefail

bestand="${1:-.trivyignore.yaml}"

command -v yq >/dev/null || {
  echo "yq ontbreekt; ${bestand} kan niet gecontroleerd worden." >&2
  exit 1
}

[ -f "${bestand}" ] || {
  echo "${bestand} ontbreekt." >&2
  exit 1
}

# Trivy leest alleen het eerste YAML-document; alles achter een `---` is
# onzichtbare inhoud. `yq -e` zou hier bovendien groen melden zodra één van de
# documenten deugt.
documenten="$(yq ea '[.] | length' "${bestand}" 2>/dev/null || echo 0)"
if [ "${documenten}" != "1" ]; then
  echo "Ongeldige ${bestand}: precies één YAML-document verwacht, gevonden: ${documenten}." >&2
  exit 1
fi

# Elke regel bindt aan een pad of aan een purl, draagt een reden en verloopt.
# `**` als eerste teken maakt de uitzondering weer projectbreed — correct
# gespeld, dus onzichtbaar voor een sleutelcontrole — en een leeg of niet-tekst
# element levert stil een regel op die alles onderdrukt of niets doet.
if ! yq -e '
  (keys - ["licenses", "misconfigurations", "secrets", "vulnerabilities"] | length == 0)
  and
  ([.[] | .[]] | all_c(
    (keys - ["expired_at", "id", "paths", "purls", "statement"] | length == 0)
    and (.id | tag == "!!str" and length > 0)
    and (.statement | tag == "!!str" and length > 0)
    and (has("paths") or has("purls"))
    and ([.paths, .purls] | all_c(
      . == null or (tag == "!!seq" and length > 0 and all_c(
        tag == "!!str" and length > 0 and (test("^\*\*") | not)
      ))
    ))
    and (.expired_at | to_string | test("^\d{4}-\d{2}-\d{2}$"))
  ))
' "${bestand}" >/dev/null; then
  echo "Ongeldige ${bestand}: elke regel heeft een tekstueel id, een statement, minstens één pad of purl en expired_at (JJJJ-MM-DD) nodig; geen andere sleutels, geen leeg pad en geen pad dat met ** begint." >&2
  exit 1
fi

# De regex hierboven ziet de vorm, niet de kalender: 2027-13-45 komt er anders
# doorheen en laat Trivy pas bij de scan struikelen.
while read -r datum; do
  date -d "${datum}" >/dev/null 2>&1 || {
    echo "Ongeldige ${bestand}: '${datum}' is geen bestaande datum." >&2
    exit 1
  }
done < <(yq '[.[] | .[] | .expired_at | to_string] | .[]' "${bestand}")
