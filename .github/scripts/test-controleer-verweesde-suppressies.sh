#!/usr/bin/env bash
# Fixtures voor controleer-verweesde-suppressies.sh. Draaien tegen de echte
# trivy, want de matching van paden en purls is die van Trivy; zonder trivy
# falen ze.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
controle="${hier}/controleer-verweesde-suppressies.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

geslaagd=0
gefaald=0

command -v trivy >/dev/null || {
  echo "FOUT: trivy ontbreekt; de fixtures kunnen niet draaien."
  exit 1
}

toets() { # naam verwachte_exitcode rapport lijst [verwachte tekst in stderr]
  local naam="$1" verwacht="$2" rapport="${werkmap}/$3" lijst="${werkmap}/$4" tekst="${5:-}"
  local rc=0 uitvoer

  uitvoer="$("${controle}" "${rapport}" "${lijst}" 2>&1 >/dev/null)" || rc=$?

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

# Een helm-binary met een stdlib-CVE en de npm-bundel met een undici-CVE, zoals
# Trivy ze in de variants-image rapporteert. Zonder PkgIdentifier raakt een
# purl-regel elke bevinding met dezelfde id, ook in Trivy zelf.
cat > "${werkmap}/rapport.json" <<'EOF'
{"SchemaVersion": 2, "ArtifactName": "claude-sandbox:variants-scan", "ArtifactType": "container_image", "Results": [
  {"Target": "usr/local/bin/helm", "Class": "lang-pkgs", "Type": "gobinary", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-111943", "PkgName": "stdlib", "PkgIdentifier": {"PURL": "pkg:golang/stdlib@v1.27.2"}, "InstalledVersion": "v1.27.2", "FixedVersion": "1.27.3", "Severity": "HIGH"}]},
  {"Target": "Node.js", "Class": "lang-pkgs", "Type": "node-pkg", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-87018", "PkgName": "undici", "PkgIdentifier": {"PURL": "pkg:npm/undici@6.0.0"}, "PkgPath": "usr/local/lib/node_modules/npm/node_modules/undici/package.json", "InstalledVersion": "6.0.0", "FixedVersion": "6.29.1", "Severity": "HIGH"}]}
]}
EOF
printf '{"SchemaVersion": 2, "ArtifactName": "x", "ArtifactType": "container_image"}\n' \
  > "${werkmap}/schoon.json"
printf '{"Results": []}\n' > "${werkmap}/geen-schema.json"
printf 'usr/local/bin/helm (gobinary)\n' > "${werkmap}/tabel.txt"

vuln() { # id binding [extra regels]
  printf '  - id: %s\n%b%b    expired_at: 2027-01-28\n    statement: reden\n' "$1" "$2" "${3:-}"
}
helm='    paths: ["usr/local/bin/helm"]\n'
npm='    paths: ["usr/local/lib/node_modules/npm/**"]\n'

{ echo 'vulnerabilities:'; vuln CVE-2026-111943 "${helm}"; vuln CVE-2026-87018 "${npm}"; } \
  > "${werkmap}/beide.yaml"
{ echo 'vulnerabilities:'; vuln CVE-2026-87018 '    purls: ["pkg:npm/undici"]\n'; } \
  > "${werkmap}/purl.yaml"
# Deze controle vraagt of een regel nog iets raakt; of hij nog geldt is aan
# de gate.
{ echo 'vulnerabilities:'; printf '  - id: CVE-2026-111943\n%b    expired_at: 2020-01-01\n    statement: reden\n' "${helm}"; } \
  > "${werkmap}/verlopen.yaml"
{ echo 'misconfigurations:'; vuln DS-0026 '    paths: ["claude-sandbox/Dockerfile"]\n'; } \
  > "${werkmap}/alleen-misconfig.yaml"
printf '# alleen een kop\n' > "${werkmap}/alleen-kop.yaml"
printf 'vulnerabilities:\n' > "${werkmap}/lege-sectie.yaml"

toets "beide regels raken"            0 rapport.json beide.yaml
toets "purl-binding raakt"            0 rapport.json purl.yaml
toets "verlopen regel die nog raakt"  0 rapport.json verlopen.yaml
toets "misconfigs vallen erbuiten"    0 rapport.json alleen-misconfig.yaml
toets "alleen een kop"                0 rapport.json alleen-kop.yaml
toets "lege sectie"                   0 rapport.json lege-sectie.yaml
toets "geen regels, schoon rapport"   0 schoon.json  lege-sectie.yaml

# Verweesd: de release lost de CVE op, of de regel zit op het verkeerde pad.
{ echo 'vulnerabilities:'; vuln CVE-2026-111943 '    paths: ["usr/local/bin/kubectl"]\n'; } \
  > "${werkmap}/ander-pad.yaml"
{ echo 'vulnerabilities:'; vuln CVE-2026-87018 "${npm}"; vuln CVE-2026-111943 "${helm}"; } \
  > "${werkmap}/opgelost.yaml"
# Dezelfde CVE op twee paden: per regel controleren, niet per id.
{ echo 'vulnerabilities:'; vuln CVE-2026-111943 "${helm}"; vuln CVE-2026-111943 '    paths: ["usr/local/bin/kubectl"]\n'; } \
  > "${werkmap}/zelfde-id.yaml"
{ echo 'vulnerabilities:'; vuln CVE-2026-87018 '    purls: ["pkg:npm/tar"]\n'; } \
  > "${werkmap}/purl-mis.yaml"

toets "regel op een ander pad"        1 rapport.json ander-pad.yaml     'CVE-2026-111943 op ["usr/local/bin/kubectl"]'
toets "release lost de CVE op"        1 schoon.json  opgelost.yaml      'CVE-2026-111943 op ["usr/local/bin/helm"]'
toets "beide verweesd gemeld"         1 schoon.json  opgelost.yaml      'CVE-2026-87018 op'
toets "zelfde id, één pad verweesd"   1 rapport.json zelfde-id.yaml     'usr/local/bin/kubectl'
toets "purl die niets raakt"          1 rapport.json purl-mis.yaml      'pkg:npm/tar'

# Een verkeerd rapport of ontbrekende invoer faalt met een eigen melding, en
# niet als "alles verweesd" of "niets verweesd".
toets "rapport zonder SchemaVersion"  1 geen-schema.json beide.yaml     'geen Trivy-JSON-rapport'
toets "tabel in plaats van JSON"      1 tabel.txt    beide.yaml         'geen Trivy-JSON-rapport'
toets "rapport ontbreekt"             1 bestaat-niet.json beide.yaml    'geen Trivy-JSON-rapport'
toets "lijst ontbreekt"               1 rapport.json bestaat-niet.yaml  'ontbreekt'

# Een falende trivy convert mag een regel niet stil als "raakt nog" of als
# verweesd laten tellen: eerst bij de telling zonder suppressies, daarna pas
# bij die per regel.
echt="$(command -v trivy)"
mkdir -p "${werkmap}/kapot" "${werkmap}/kapot-per-regel"
printf '#!/bin/sh\nexit 1\n' > "${werkmap}/kapot/trivy"
printf '#!/bin/sh\ncase "$*" in *regel.yaml*) exit 1 ;; esac\nexec "%s" "$@"\n' "${echt}" \
  > "${werkmap}/kapot-per-regel/trivy"
chmod +x "${werkmap}/kapot/trivy" "${werkmap}/kapot-per-regel/trivy"
for nep in kapot kapot-per-regel; do
  rc=0
  uitvoer="$(PATH="${werkmap}/${nep}:${PATH}" "${controle}" "${werkmap}/rapport.json" "${werkmap}/beide.yaml" 2>&1)" \
    || rc=$?
  if [ "${rc}" -ne 0 ] && ! grep -qF 'Verweesde suppressie' <<<"${uitvoer}"; then
    echo "ok   falende trivy convert (${nep})"
    geslaagd=$((geslaagd + 1))
  else
    echo "FOUT falende trivy convert (${nep}): exitcode ${rc}"
    gefaald=$((gefaald + 1))
  fi
done

echo
echo "${geslaagd} geslaagd, ${gefaald} gefaald"
[ "${gefaald}" -eq 0 ]
