#!/usr/bin/env bash
# Fixtures voor controleer-suppressie-verwijzingen.sh.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
controle="${hier}/controleer-suppressie-verwijzingen.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

geslaagd=0
gefaald=0

printf 'misconfigurations:\n  - id: DS-0026\n    paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\nvulnerabilities:\n  - id: CVE-2026-111943\n    paths: ["usr/local/bin/helm"]\n    expired_at: 2026-11-30\n    statement: reden\n' \
  > "${werkmap}/lijst.yaml"
printf 'vulnerabilities:\n' > "${werkmap}/leeg.yaml"

repo() { # naam; leest "pad<TAB>inhoud"-regels van stdin, getrackt
  local map="${werkmap}/$1" pad inhoud
  git init -q "${map}"
  while IFS=$'\t' read -r pad inhoud; do
    mkdir -p "$(dirname "${map}/${pad}")"
    printf '%b\n' "${inhoud}" > "${map}/${pad}"
  done
  git -C "${map}" add -A
}

toets() { # naam verwachte_exitcode repo lijst [verwachte tekst in stderr]
  local naam="$1" verwacht="$2" map="${werkmap}/$3" lijst="${werkmap}/$4" tekst="${5:-}"
  local rc=0 uitvoer

  uitvoer="$("${controle}" "${lijst}" "${map}" 2>&1 >/dev/null)" || rc=$?

  if [ "${rc}" -ne "${verwacht}" ]; then
    echo "FOUT ${naam}: exitcode ${rc}, verwacht ${verwacht}"
    gefaald=$((gefaald + 1))
  elif [ -n "${tekst}" ] && ! grep -qF -- "${tekst}" <<<"${uitvoer}"; then
    echo "FOUT ${naam}: '${tekst}' ontbreekt in de melding"
    gefaald=$((gefaald + 1))
  else
    echo "ok   ${naam}"
    geslaagd=$((geslaagd + 1))
  fi
}

melding='Open: CVE-2026-111943. <!-- trivyignore: CVE-2026-111943 -->'

printf 'README.md\tGeen markers.\n' | repo geen-markers
printf 'docs/k8s.md\t%s\n' "${melding}" | repo bekend
printf 'docs/a.md\t<!-- trivyignore: DS-0026 -->\n' | repo andere-sectie
printf 'docs/k8s.md\tTekst.\n' | repo ongetrackt
printf '<!-- trivyignore: CVE-0000-1 -->\n' > "${werkmap}/ongetrackt/docs/los.md"
printf 'notities.txt\t<!-- trivyignore: CVE-0000-1 -->\n' | repo geen-markdown
printf 'docs/k8s.md\tregel een\\n\\n%s\n' "${melding}" | repo regelnummer

toets "geen markers"                  0 geen-markers lijst.yaml
toets "marker met bekende id"         0 bekend       lijst.yaml
toets "id uit een andere sectie"      0 andere-sectie lijst.yaml
toets "ongetrackt bestand telt niet"  0 ongetrackt   lijst.yaml
toets "alleen markdown"               0 geen-markdown lijst.yaml

# De regel is weg, de melding niet: precies het geval waarvoor dit bestaat.
toets "regel weg, melding blijft"     1 bekend       leeg.yaml   'docs/k8s.md:1: verwijst naar CVE-2026-111943'
toets "regelnummer in de melding"     1 regelnummer  leeg.yaml   'docs/k8s.md:3:'

printf 'docs/k8s.md\t<!-- trivyignore: CVE-0000-1 -->\n' | repo onbekend
printf 'docs/k8s.md\t%s <!-- trivyignore: CVE-0000-1 -->\n' "${melding}" | repo twee-op-een-regel
toets "onbekende id"                  1 onbekend     lijst.yaml  'CVE-0000-1'
toets "tweede marker op de regel"     1 twee-op-een-regel lijst.yaml 'CVE-0000-1'

# Een marker die net anders gespeld is, valt anders stil buiten de controle.
printf 'docs/a.md\t<!--trivyignore: CVE-2026-111943 -->\n'  | repo zonder-spatie
printf 'docs/a.md\t<!-- trivyignore:CVE-2026-111943 -->\n'  | repo zonder-spatie-na-dubbelepunt
printf 'docs/a.md\t<!-- trivyignore: CVE-2026-111943-->\n'  | repo sluiting-vast
printf 'docs/a.md\t<!--  trivyignore: CVE-2026-111943 -->\n' | repo dubbele-spatie
printf 'docs/a.md\t<!-- trivyignore: -->\n'                 | repo zonder-id
toets "zonder spatie na <!--"         1 zonder-spatie lijst.yaml 'docs/a.md:1: marker niet in de vorm'
toets "zonder spatie na dubbelepunt"  1 zonder-spatie-na-dubbelepunt lijst.yaml 'marker niet in de vorm'
toets "--> tegen de id aan"           1 sluiting-vast lijst.yaml 'marker niet in de vorm'
toets "dubbele spatie"                1 dubbele-spatie lijst.yaml 'marker niet in de vorm'
toets "marker zonder id"              1 zonder-id    lijst.yaml  'marker niet in de vorm'

# Een getrackt bestand dat niet te lezen is, mag niet als "geen markers" tellen.
printf 'docs/k8s.md\t%s\n' "${melding}" | repo onleesbaar
rm "${werkmap}/onleesbaar/docs/k8s.md"
toets "onleesbaar getrackt bestand"   1 onleesbaar   lijst.yaml  'docs/k8s.md kan niet gelezen worden'

mkdir -p "${werkmap}/geen-git"
toets "map zonder git"                1 geen-git     lijst.yaml  'geen git-werkmap'
toets "lijst ontbreekt"               1 bekend       bestaat-niet.yaml 'ontbreekt'

echo
echo "${geslaagd} geslaagd, ${gefaald} gefaald"
[ "${gefaald}" -eq 0 ]
