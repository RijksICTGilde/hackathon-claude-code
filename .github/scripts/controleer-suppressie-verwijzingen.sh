#!/usr/bin/env bash
# Faalt als documentatie naar een suppressie verwijst die niet in de
# suppressielijst staat.
#
# Een melding aan gebruikers over een open kwetsbaarheid draagt een HTML-comment
# `<!-- trivyignore: <id> <pad-of-purl> -->`, gebonden aan één regel: dezelfde
# CVE kan op meer binaries staan, en de melding hoort weg te gaan met de regel
# waar ze over gaat. Verdwijnt die regel omdat een release de kwetsbaarheid
# oplost, dan maakt deze controle de melding zichtbaar die anders blijft staan.
# Alles wat op een marker lijkt maar die vorm niet heeft, faalt ook: dat zou
# stil buiten de controle vallen.
set -euo pipefail
shopt -s inherit_errexit

lijst="${1:-.trivyignore.yaml}"
map="${2:-.}"

command -v yq >/dev/null || {
  echo "yq ontbreekt; ${lijst} kan niet gelezen worden." >&2
  exit 1
}

[ -f "${lijst}" ] || {
  echo "${lijst} ontbreekt." >&2
  exit 1
}

git -C "${map}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "${map} is geen git-werkmap." >&2
  exit 1
}

werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

# Alleen getrackte bestanden: een worktree of build-uitvoer in de map hoort
# niet mee te tellen. Eerst naar een bestand, zodat een falende ls-files niet
# stil tot nul bestanden wordt.
git -C "${map}" ls-files -z -- ':(icase)*.md' > "${werkmap}/bestanden" || {
  echo "git ls-files faalt in ${map}; de documentatie kan niet doorzocht worden." >&2
  exit 1
}

# Elk paar "<id> <binding>" uit de lijst, over alle secties.
# shellcheck disable=SC2016 # $id is een yq-variabele
yq '[. // {} | .[] // [] | .[] | .id as $id | ((.paths // []) + (.purls // [])) | .[] | $id + " " + .] | .[]' \
  "${lijst}" > "${werkmap}/paren"

los='<!--[[:space:]]*trivy[-_ ]?ignore'
strikt='<!-- trivyignore: [A-Za-z0-9._-]+ [^[:space:]]+ -->'
fouten=0
while IFS= read -r -d '' bestand; do
  # -a: een bestand met een niet-UTF-8-byte is voor grep anders binair, en
  # geeft dan geen regels terug. grep geeft 1 bij geen treffer; alleen een
  # leesfout (2) mag hier niet stil tot "geen markers" worden.
  rc=0
  treffers="$(grep -naiE "${los}" "${map}/${bestand}")" || rc=$?
  if [ "${rc}" -eq 1 ]; then
    continue
  elif [ "${rc}" -ne 0 ]; then
    echo "${bestand} kan niet gelezen worden." >&2
    exit 1
  fi
  while IFS=: read -r nummer tekst; do
    plek="${bestand}:${nummer}"
    aantal_los="$(grep -oaiE "${los}" <<<"${tekst}" | wc -l)"
    mapfile -t markers < <(grep -oaE "${strikt}" <<<"${tekst}" || true)
    if [ "${#markers[@]}" -ne "${aantal_los}" ]; then
      echo "${plek}: marker niet in de vorm <!-- trivyignore: <id> <pad-of-purl> -->." >&2
      fouten=$((fouten + 1))
    fi
    for marker in "${markers[@]}"; do
      paar="${marker#<!-- trivyignore: }"
      paar="${paar% -->}"
      if ! grep -qxF -- "${paar}" "${werkmap}/paren"; then
        echo "${plek}: verwijst naar '${paar}', maar die regel staat niet in ${lijst}; haal de melding weg." >&2
        fouten=$((fouten + 1))
      fi
    done
  done <<<"${treffers}"
done < "${werkmap}/bestanden"

[ "${fouten}" -eq 0 ] || exit 1
echo "Elke trivyignore-marker in de documentatie verwijst naar een regel in ${lijst}."
