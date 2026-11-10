#!/usr/bin/env bash
# Faalt als een regel onder `vulnerabilities` in de suppressielijst niets meer
# raakt in een Trivy-rapport dat zonder suppressies is gemaakt.
#
# Een verweesde regel valt anders nergens op: de scan blijft groen, ook na
# expired_at, en de regel blijft staan, met elke melding erover in de
# documentatie. Per regel past `trivy convert` alleen die ene regel toe op het
# rapport, zodat de matching van paden en purls die van Trivy zelf is.
# expired_at gaat daarbij weg: deze controle vraagt of een regel nog iets raakt,
# niet of hij nog geldt. Dat laatste bewaakt de gate.
set -euo pipefail

rapport="${1:?gebruik: $0 <trivy-json-rapport> [suppressielijst]}"
lijst="${2:-.trivyignore.yaml}"

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
jq -e '.SchemaVersion == 2' "${rapport}" >/dev/null 2>&1 || {
  echo "${rapport} is geen Trivy-JSON-rapport (SchemaVersion 2)." >&2
  exit 1
}

werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

tel() { # ignorefile
  trivy convert --quiet --format json --ignorefile "$1" "${rapport}" \
    | jq '[.Results[]?.Vulnerabilities[]?] | length'
}

: > "${werkmap}/leeg.yaml"
totaal="$(tel "${werkmap}/leeg.yaml")"

aantal="$(yq '.vulnerabilities // [] | length' "${lijst}")"
verweesd=0
for ((i = 0; i < aantal; i++)); do
  yq "{\"vulnerabilities\": [.vulnerabilities[${i}] | del(.expired_at)]}" "${lijst}" \
    > "${werkmap}/regel.yaml"
  # Eerst toewijzen: in de test zelf zou een falende trivy convert stil als
  # "niet verweesd" tellen.
  over="$(tel "${werkmap}/regel.yaml")"
  if [ "${over}" -ge "${totaal}" ]; then
    id="$(yq ".vulnerabilities[${i}].id" "${lijst}")"
    binding="$(yq -o=json -I=0 ".vulnerabilities[${i}] | [.paths[]?, .purls[]?]" "${lijst}")"
    echo "Verweesde suppressie in ${lijst}: ${id} op ${binding} komt niet meer voor in de scan." >&2
    verweesd=$((verweesd + 1))
  fi
done

if [ "${verweesd}" -gt 0 ]; then
  echo "Haal die regel(s) weg, met elke melding die met <!-- trivyignore: <id> --> naar de CVE verwijst." >&2
  exit 1
fi

echo "Alle ${aantal} vulnerabilities-regel(s) in ${lijst} raken nog een bevinding."
