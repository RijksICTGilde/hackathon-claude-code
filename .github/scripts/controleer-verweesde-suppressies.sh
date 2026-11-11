#!/usr/bin/env bash
# Faalt als een regel onder `vulnerabilities` in de suppressielijst in geen van
# de Trivy-rapporten nog iets raakt. De rapporten zijn zonder suppressies
# gemaakt, samen over alles wat de scans zien die de lijst lezen.
#
# Een verweesde regel valt anders nergens op: de scan blijft groen, ook na
# expired_at, en de regel blijft staan, met elke melding erover in de
# documentatie. Per regel past `trivy convert` alleen die ene regel toe op elk
# rapport, zodat de matching van paden en purls die van Trivy zelf is.
# expired_at gaat daarbij weg: deze controle vraagt of een regel nog iets raakt,
# niet of hij nog geldt. Dat laatste bewaakt de gate.
set -euo pipefail
# Zonder dit stopt een falend commando binnen "$(...)" de substitutie niet.
shopt -s inherit_errexit

gebruik="gebruik: $0 <suppressielijst> <trivy-json-rapport> [rapport...]"
lijst="${1:?${gebruik}}"
shift
[ "$#" -gt 0 ] || { echo "${gebruik}" >&2; exit 1; }
rapporten=("$@")

for tool in trivy yq jq; do
  command -v "${tool}" >/dev/null || {
    echo "${tool} ontbreekt; verweesde suppressies kunnen niet gecontroleerd worden." >&2
    exit 1
  }
done

[ -f "${lijst}" ] || {
  echo "${lijst} ontbreekt." >&2
  exit 1
}

# Een ander bestand dan een Trivy-JSON-rapport telt nul bevindingen en zou zo
# elke regel verweesd noemen; dat is een andere fout dan die hier gemeld wordt.
for rapport in "${rapporten[@]}"; do
  jq -e '.SchemaVersion == 2' "${rapport}" >/dev/null 2>&1 || {
    echo "${rapport} is geen Trivy-JSON-rapport (SchemaVersion 2)." >&2
    exit 1
  }
done

werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

# --output expliciet: een TRIVY_OUTPUT of trivy.yaml stuurt de uitvoer anders
# naar een bestand, en een lege telling mag niet als "raakt nog" doorgaan.
tel() { # ignorefile rapport
  local uit="${werkmap}/telling.json" aantal
  rm -f "${uit}"
  trivy convert --quiet --format json --ignorefile "$1" --output "${uit}" "$2"
  aantal="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "${uit}")"
  [[ "${aantal}" =~ ^[0-9]+$ ]] || {
    echo "trivy convert gaf geen telling voor $2." >&2
    return 1
  }
  echo "${aantal}"
}

: > "${werkmap}/leeg.yaml"
totalen=()
for rapport in "${rapporten[@]}"; do
  totaal="$(tel "${werkmap}/leeg.yaml" "${rapport}")"
  totalen+=("${totaal}")
done

aantal="$(yq '.vulnerabilities // [] | length' "${lijst}")"
[[ "${aantal}" =~ ^[0-9]+$ ]] || {
  echo "${lijst} gaf geen aantal regels; meer dan één YAML-document?" >&2
  exit 1
}
verweesd=0
for ((i = 0; i < aantal; i++)); do
  yq "{\"vulnerabilities\": [.vulnerabilities[${i}] | del(.expired_at)]}" "${lijst}" \
    > "${werkmap}/regel.yaml"
  raakt=nee
  for j in "${!rapporten[@]}"; do
    # Eerst toewijzen: in de test zelf zou een falende telling stil als
    # "niet verweesd" tellen.
    over="$(tel "${werkmap}/regel.yaml" "${rapporten[j]}")"
    if [ "${over}" -lt "${totalen[j]}" ]; then
      raakt=ja
      break
    fi
  done
  if [ "${raakt}" = nee ]; then
    id="$(yq ".vulnerabilities[${i}].id" "${lijst}")"
    binding="$(yq -o=json -I=0 ".vulnerabilities[${i}] | [.paths[]?, .purls[]?]" "${lijst}")"
    echo "Verweesde suppressie in ${lijst}: ${id} op ${binding} komt in geen scan meer voor." >&2
    verweesd=$((verweesd + 1))
  fi
done

if [ "${verweesd}" -gt 0 ]; then
  echo "Haal die regel(s) weg, met elke melding die met <!-- trivyignore: <id> <pad> --> naar de regel verwijst." >&2
  exit 1
fi

echo "Alle ${aantal} vulnerabilities-regel(s) in ${lijst} raken nog een bevinding."
