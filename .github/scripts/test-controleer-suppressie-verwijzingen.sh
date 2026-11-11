#!/usr/bin/env bash
# Fixtures voor controleer-suppressie-verwijzingen.sh.
set -uo pipefail
# Zoals op de runners: in een UTF-8-locale is een bestand met een niet-UTF-8-
# byte voor grep binair.
export LC_ALL=C.UTF-8

hier="$(cd "$(dirname "$0")" && pwd)"
controle="${hier}/controleer-suppressie-verwijzingen.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

geslaagd=0
gefaald=0

# Dezelfde CVE op twee binaries: een marker hoort bij één van die regels.
printf 'misconfigurations:\n  - id: DS-0026\n    paths: ["a"]\n    expired_at: 2027-08-26\n    statement: reden\nvulnerabilities:\n  - id: CVE-2026-111943\n    paths: ["usr/local/bin/helm"]\n    expired_at: 2026-11-30\n    statement: reden\n  - id: CVE-2026-78661\n    paths: ["usr/local/bin/kubectl"]\n    expired_at: 2026-12-31\n    statement: reden\n  - id: CVE-2026-78661\n    purls: ["pkg:golang/golang.org/x/net"]\n    expired_at: 2026-12-31\n    statement: reden\n' \
  > "${werkmap}/lijst.yaml"
printf 'vulnerabilities:\n  - id: CVE-2026-78661\n    paths: ["usr/local/bin/kubectl"]\n    expired_at: 2026-12-31\n    statement: reden\n' \
  > "${werkmap}/zonder-helm.yaml"
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

melding='Open: CVE-2026-111943. <!-- trivyignore: CVE-2026-111943 usr/local/bin/helm -->'
m='<!-- trivyignore:'

printf 'README.md\tGeen markers.\n' | repo geen-markers
printf 'docs/k8s.md\t%s\n' "${melding}" | repo bekend
printf 'docs/a.md\t%s DS-0026 a -->\n' "${m}" | repo andere-sectie
printf 'docs/a.md\t%s CVE-2026-78661 pkg:golang/golang.org/x/net -->\n' "${m}" | repo purl-binding
printf 'docs/k8s.md\tTekst.\n' | repo ongetrackt
printf '%s CVE-0000-1 x -->\n' "${m}" > "${werkmap}/ongetrackt/docs/los.md"
printf 'notities.txt\t%s CVE-0000-1 x -->\n' "${m}" | repo geen-markdown
printf 'docs/k8s.md\tregel een\\n\\n%s\n' "${melding}" | repo regelnummer
printf 'docs/met spatie/k 8s.md\t%s\n' "${melding}" | repo spaties-in-pad
printf 'docs/k8s.md\t%s\r\n' "${melding}" | repo crlf

toets "geen markers"                  0 geen-markers lijst.yaml
toets "marker met bekende regel"      0 bekend       lijst.yaml
toets "regel uit een andere sectie"   0 andere-sectie lijst.yaml
toets "purl als binding"              0 purl-binding lijst.yaml
toets "ongetrackt bestand telt niet"  0 ongetrackt   lijst.yaml
toets "alleen markdown"               0 geen-markdown lijst.yaml
toets "spaties in het pad"            0 spaties-in-pad lijst.yaml
toets "CRLF-regeleinde"               0 crlf         lijst.yaml

# De regel is weg, de melding niet: precies het geval waarvoor dit bestaat.
toets "regel weg, melding blijft"     1 bekend       leeg.yaml   "docs/k8s.md:1: verwijst naar 'CVE-2026-111943 usr/local/bin/helm'"
toets "regelnummer in de melding"     1 regelnummer  leeg.yaml   'docs/k8s.md:3:'
# Dezelfde CVE blijft op een andere binary staan; de melding over helm moet
# toch weg.
printf 'docs/k8s.md\t%s CVE-2026-78661 usr/local/bin/helm -->\n' "${m}" | repo zelfde-id-ander-pad
toets "zelfde id, andere binary"      1 zelfde-id-ander-pad zonder-helm.yaml 'CVE-2026-78661 usr/local/bin/helm'

printf 'docs/k8s.md\t%s CVE-0000-1 x -->\n' "${m}" | repo onbekend
printf 'docs/k8s.md\t%s %s CVE-0000-1 x -->\n' "${melding}" "${m}" | repo twee-op-een-regel
toets "onbekende regel"               1 onbekend     lijst.yaml  'CVE-0000-1'
toets "tweede marker op de regel"     1 twee-op-een-regel lijst.yaml 'CVE-0000-1'

# Een marker die net anders gespeld is, valt anders stil buiten de controle.
printf 'docs/a.md\t<!--trivyignore: CVE-2026-111943 usr/local/bin/helm -->\n'  | repo zonder-spatie
printf 'docs/a.md\t<!-- trivyignore:CVE-2026-111943 usr/local/bin/helm -->\n'  | repo zonder-spatie-na-dubbelepunt
printf 'docs/a.md\t<!-- trivyignore: CVE-2026-111943 usr/local/bin/helm-->\n'  | repo sluiting-vast
printf 'docs/a.md\t<!--  trivyignore: CVE-2026-111943 usr/local/bin/helm -->\n' | repo dubbele-spatie
printf 'docs/a.md\t<!-- trivyignore: -->\n'                                     | repo zonder-id
printf 'docs/a.md\t<!-- trivyignore: CVE-2026-111943 -->\n'                     | repo zonder-binding
printf 'docs/a.md\t<!-- TrivyIgnore: CVE-2026-111943 usr/local/bin/helm -->\n'  | repo hoofdletters
printf 'docs/a.md\t<!-- trivy-ignore: CVE-2026-111943 usr/local/bin/helm -->\n' | repo koppelteken
printf 'docs/a.md\t<!-- trivy_ignore: CVE-2026-111943 usr/local/bin/helm -->\n' | repo underscore
toets "zonder spatie na <!--"         1 zonder-spatie lijst.yaml 'docs/a.md:1: marker niet in de vorm'
toets "zonder spatie na dubbelepunt"  1 zonder-spatie-na-dubbelepunt lijst.yaml 'marker niet in de vorm'
toets "--> tegen de binding aan"      1 sluiting-vast lijst.yaml 'marker niet in de vorm'
toets "dubbele spatie"                1 dubbele-spatie lijst.yaml 'marker niet in de vorm'
toets "marker zonder id"              1 zonder-id    lijst.yaml  'marker niet in de vorm'
toets "marker zonder binding"         1 zonder-binding lijst.yaml 'marker niet in de vorm'
toets "hoofdletters"                  1 hoofdletters lijst.yaml  'marker niet in de vorm'
toets "trivy-ignore"                  1 koppelteken  lijst.yaml  'marker niet in de vorm'
toets "trivy_ignore"                  1 underscore   lijst.yaml  'marker niet in de vorm'

# Hoofdletters in de extensie en niet-UTF-8-bytes houden een marker niet
# buiten de controle.
printf 'docs/K8S.MD\t%s CVE-0000-1 x -->\n' "${m}" | repo hoofdletter-extensie
toets "extensie .MD"                  1 hoofdletter-extensie lijst.yaml 'docs/K8S.MD:1:'
printf 'docs/k8s.md\t\xe9t\xe9 %s CVE-0000-1 x -->\n' "${m}" | repo latin1
toets "niet-UTF-8-byte op de regel"   1 latin1       lijst.yaml  'CVE-0000-1'
printf 'docs/k8s.md\t\xe9t\xe9 %s\n' "${melding}" | repo latin1-bekend
toets "niet-UTF-8, bekende regel"     0 latin1-bekend lijst.yaml

# Een getrackt bestand dat niet te lezen is, mag niet als "geen markers" tellen.
printf 'docs/k8s.md\t%s\n' "${melding}" | repo onleesbaar
rm "${werkmap}/onleesbaar/docs/k8s.md"
toets "onleesbaar getrackt bestand"   1 onleesbaar   lijst.yaml  'docs/k8s.md kan niet gelezen worden'

# Een kapotte index laat ls-files falen; dat is geen "nul bestanden".
printf 'docs/k8s.md\t%s CVE-0000-1 x -->\n' "${m}" | repo kapotte-index
printf 'kapot' > "${werkmap}/kapotte-index/.git/index"
toets "kapotte git-index"             1 kapotte-index lijst.yaml 'git ls-files faalt'

mkdir -p "${werkmap}/geen-git"
toets "map zonder git"                1 geen-git     lijst.yaml  'geen git-werkmap'
toets "lijst ontbreekt"               1 bekend       bestaat-niet.yaml 'ontbreekt'

echo
echo "${geslaagd} geslaagd, ${gefaald} gefaald"
[ "${gefaald}" -eq 0 ]
