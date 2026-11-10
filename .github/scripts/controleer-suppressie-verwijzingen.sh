#!/usr/bin/env bash
# Faalt als documentatie naar een suppressie verwijst die niet in de
# suppressielijst staat.
#
# Een melding aan gebruikers over een open kwetsbaarheid draagt een HTML-comment
# `<!-- trivyignore: <id> -->`. Verdwijnt de regel uit de lijst omdat een
# release de kwetsbaarheid oplost, dan maakt deze controle de melding zichtbaar
# die anders blijft staan. Een marker in een andere vorm faalt ook: die zou
# stil buiten de controle vallen.
set -euo pipefail

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

# Alleen getrackte bestanden: een worktree of build-uitvoer in de map hoort
# niet mee te tellen.
git -C "${map}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "${map} is geen git-werkmap." >&2
  exit 1
}

mapfile -t ids < <(yq '[. // {} | .[] // [] | .[] | .id] | .[]' "${lijst}")

bekend() {
  local id
  for id in "${ids[@]}"; do
    [ "${id}" = "$1" ] && return 0
  done
  return 1
}

strikt='<!-- trivyignore: [A-Za-z0-9._-]+ -->'
fouten=0
while IFS= read -r -d '' bestand; do
  # grep geeft 1 bij geen treffer; alleen een leesfout (2) mag hier niet stil
  # tot "geen markers" worden.
  rc=0
  treffers="$(grep -nE '<!--[[:space:]]*trivyignore' "${map}/${bestand}")" || rc=$?
  if [ "${rc}" -eq 1 ]; then
    continue
  elif [ "${rc}" -ne 0 ]; then
    echo "${bestand} kan niet gelezen worden." >&2
    exit 1
  fi
  while IFS=: read -r nummer tekst; do
    plek="${bestand}:${nummer}"
    los="$(grep -oE '<!--[[:space:]]*trivyignore' <<<"${tekst}" | wc -l)"
    mapfile -t markers < <(grep -oE "${strikt}" <<<"${tekst}" || true)
    if [ "${#markers[@]}" -ne "${los}" ]; then
      echo "${plek}: marker niet in de vorm <!-- trivyignore: <id> -->." >&2
      fouten=$((fouten + 1))
    fi
    for marker in "${markers[@]}"; do
      id="${marker#<!-- trivyignore: }"
      id="${id% -->}"
      if ! bekend "${id}"; then
        echo "${plek}: verwijst naar ${id}, maar die staat niet in ${lijst}; haal de melding weg." >&2
        fouten=$((fouten + 1))
      fi
    done
  done <<<"${treffers}"
done < <(git -C "${map}" ls-files -z -- '*.md')

[ "${fouten}" -eq 0 ] || exit 1
echo "Elke trivyignore-marker in de documentatie verwijst naar een regel in ${lijst}."
