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

uitslag() { # naam verwachte_exitcode werkelijke_exitcode uitvoer [verwachte tekst]
  if [ "$3" -ne "$2" ]; then
    echo "FOUT $1: exitcode $3, verwacht $2"
    gefaald=$((gefaald + 1))
  elif [ -n "${5:-}" ] && ! grep -qF -- "$5" <<<"$4"; then
    echo "FOUT $1: '$5' ontbreekt in de melding"
    gefaald=$((gefaald + 1))
  else
    echo "ok   $1"
    geslaagd=$((geslaagd + 1))
  fi
}

toets() { # naam verwachte_exitcode lijst "rapport [rapport...]" [verwachte tekst in stderr]
  local naam="$1" verwacht="$2" lijst="${werkmap}/$3" tekst="${5:-}"
  local rc=0 uitvoer rapport rapporten=()
  for rapport in $4; do rapporten+=("${werkmap}/${rapport}"); done

  uitvoer="$("${controle}" "${lijst}" "${rapporten[@]}" 2>&1 >/dev/null)" || rc=$?
  uitslag "${naam}" "${verwacht}" "${rc}" "${uitvoer}" "${tekst}"
}

# Een helm-binary met een stdlib-CVE en de npm-bundel met een undici-CVE, zoals
# Trivy ze in de variants-image rapporteert. Trivy laat een purl-regel bij een
# bevinding zonder PkgIdentifier op elke bevinding met die id matchen; daarom
# dragen de fixtures een PURL.
cat > "${werkmap}/rapport.json" <<'EOF'
{"SchemaVersion": 2, "ArtifactName": "claude-sandbox:variants-scan", "ArtifactType": "container_image", "Results": [
  {"Target": "usr/local/bin/helm", "Class": "lang-pkgs", "Type": "gobinary", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-111943", "PkgName": "stdlib", "PkgIdentifier": {"PURL": "pkg:golang/stdlib@v1.27.2"}, "InstalledVersion": "v1.27.2", "FixedVersion": "1.27.3", "Severity": "HIGH"}]},
  {"Target": "Node.js", "Class": "lang-pkgs", "Type": "node-pkg", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-87018", "PkgName": "undici", "PkgIdentifier": {"PURL": "pkg:npm/undici@6.0.0"}, "PkgPath": "usr/local/lib/node_modules/npm/node_modules/undici/package.json", "InstalledVersion": "6.0.0", "FixedVersion": "6.29.1", "Severity": "HIGH"}]}
]}
EOF
# Een bevinding die alleen de repo-scan ziet, in een bestand dat nooit in de
# image komt.
cat > "${werkmap}/repo.json" <<'EOF'
{"SchemaVersion": 2, "ArtifactName": ".", "ArtifactType": "repository", "Results": [
  {"Target": "claude-sandbox/podman/sample/pom.xml", "Class": "lang-pkgs", "Type": "pom", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-1", "PkgName": "org.example:lib", "PkgIdentifier": {"PURL": "pkg:maven/org.example/lib@1.0.0"}, "InstalledVersion": "1.0.0", "FixedVersion": "1.0.1", "Severity": "MEDIUM"}]}
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
pom='    paths: ["claude-sandbox/podman/sample/pom.xml"]\n'

{ echo 'vulnerabilities:'; vuln CVE-2026-111943 "${helm}"; vuln CVE-2026-87018 "${npm}"; } \
  > "${werkmap}/beide.yaml"
{ echo 'vulnerabilities:'; vuln CVE-2026-87018 '    purls: ["pkg:npm/undici"]\n'; } \
  > "${werkmap}/purl.yaml"
{ echo 'vulnerabilities:'; printf '  - id: CVE-2026-111943\n%b    expired_at: 2020-01-01\n    statement: reden\n' "${helm}"; } \
  > "${werkmap}/verlopen.yaml"
{ echo 'misconfigurations:'; vuln DS-0026 '    paths: ["claude-sandbox/Dockerfile"]\n'; } \
  > "${werkmap}/alleen-misconfig.yaml"
printf '# alleen een kop\n' > "${werkmap}/alleen-kop.yaml"
printf 'vulnerabilities:\n' > "${werkmap}/lege-sectie.yaml"
{ echo 'vulnerabilities:'; vuln CVE-2026-111943 "${helm}"; vuln CVE-2026-1 "${pom}"; } \
  > "${werkmap}/image-en-repo.yaml"

toets "beide regels raken"            0 beide.yaml            rapport.json
toets "purl-binding raakt"            0 purl.yaml             rapport.json
toets "verlopen regel die nog raakt"  0 verlopen.yaml         rapport.json
toets "misconfigs vallen erbuiten"    0 alleen-misconfig.yaml rapport.json
toets "alleen een kop"                0 alleen-kop.yaml       rapport.json
toets "lege sectie"                   0 lege-sectie.yaml      rapport.json
toets "geen regels, schoon rapport"   0 lege-sectie.yaml      schoon.json
toets "regel raakt in het tweede rapport" 0 image-en-repo.yaml "rapport.json repo.json"

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

toets "regel op een ander pad"        1 ander-pad.yaml     rapport.json 'CVE-2026-111943 op ["usr/local/bin/kubectl"]'
toets "release lost de CVE op"        1 opgelost.yaml      schoon.json  'CVE-2026-111943 op ["usr/local/bin/helm"]'
toets "beide verweesd gemeld"         1 opgelost.yaml      schoon.json  'CVE-2026-87018 op'
toets "zelfde id, één pad verweesd"   1 zelfde-id.yaml     rapport.json 'usr/local/bin/kubectl'
toets "purl die niets raakt"          1 purl-mis.yaml      rapport.json 'pkg:npm/tar'
toets "repo-regel zonder repo-rapport" 1 image-en-repo.yaml rapport.json 'claude-sandbox/podman/sample/pom.xml'

# Een verkeerd rapport of ontbrekende invoer faalt met een eigen melding, en
# niet als "alles verweesd" of "niets verweesd".
toets "rapport zonder SchemaVersion"  1 beide.yaml        geen-schema.json  'geen Trivy-JSON-rapport'
toets "tabel in plaats van JSON"      1 beide.yaml        tabel.txt         'geen Trivy-JSON-rapport'
toets "rapport ontbreekt"             1 beide.yaml        bestaat-niet.json 'geen Trivy-JSON-rapport'
toets "tweede rapport ongeldig"       1 beide.yaml        "rapport.json tabel.txt" 'geen Trivy-JSON-rapport'
toets "lijst ontbreekt"               1 bestaat-niet.yaml rapport.json      'ontbreekt'
rc=0; uitvoer="$("${controle}" "${werkmap}/beide.yaml" 2>&1)" || rc=$?
uitslag "geen rapport opgegeven" 1 "${rc}" "${uitvoer}" 'gebruik:'
{ vuln CVE-2026-111943 "${helm}" | sed '1s/^/vulnerabilities:\n/'; echo '---'; echo 'vulnerabilities: []'; } \
  > "${werkmap}/twee-documenten.yaml"
toets "lijst met twee documenten"     1 twee-documenten.yaml rapport.json 'geen aantal regels'

# Een trivy convert die faalt, of die slaagt zonder telling af te leveren, mag
# een regel niet stil als "raakt nog" of als verweesd laten tellen: eerst bij
# de telling zonder suppressies, daarna bij die per regel. De nep-trivy herkent
# die laatste aan de naam van het tijdelijke ignorefile van het script.
echt="$(command -v trivy)"
mkdir -p "${werkmap}/kapot" "${werkmap}/kapot-per-regel" "${werkmap}/stil"
printf '#!/bin/sh\nexit 1\n' > "${werkmap}/kapot/trivy"
printf '#!/bin/sh\ncase "$*" in *regel.yaml*) exit 1 ;; esac\nexec "%s" "$@"\n' "${echt}" \
  > "${werkmap}/kapot-per-regel/trivy"
# Slaagt zonder iets te schrijven, zoals bij uitvoer die via TRIVY_OUTPUT of
# een trivy.yaml elders belandt.
printf '#!/bin/sh\nexit 0\n' > "${werkmap}/stil/trivy"
# Pas per regel stil: een uitvoerbestand van de vorige telling mag dan niet
# als deze telling gelden.
mkdir -p "${werkmap}/stil-per-regel" "${werkmap}/leeg-bestand"
printf '#!/bin/sh\ncase "$*" in *regel.yaml*) exit 0 ;; esac\nexec "%s" "$@"\n' "${echt}" \
  > "${werkmap}/stil-per-regel/trivy"
# Schrijft een leeg uitvoerbestand; jq geeft daarop niets en exitcode 0.
printf '#!/bin/sh\nvorige=\nfor a in "$@"; do [ "$vorige" = --output ] && : > "$a"; vorige=$a; done\nexit 0\n' \
  > "${werkmap}/leeg-bestand/trivy"
chmod +x "${werkmap}/kapot/trivy" "${werkmap}/kapot-per-regel/trivy" "${werkmap}/stil/trivy" \
  "${werkmap}/stil-per-regel/trivy" "${werkmap}/leeg-bestand/trivy"
for nep in kapot kapot-per-regel stil stil-per-regel leeg-bestand; do
  rc=0
  uitvoer="$(PATH="${werkmap}/${nep}:${PATH}" "${controle}" "${werkmap}/beide.yaml" "${werkmap}/rapport.json" 2>&1)" \
    || rc=$?
  if [ "${rc}" -ne 0 ] && ! grep -qF 'Verweesde suppressie' <<<"${uitvoer}"; then
    echo "ok   falende trivy convert (${nep})"
    geslaagd=$((geslaagd + 1))
  else
    echo "FOUT falende trivy convert (${nep}): exitcode ${rc}"
    gefaald=$((gefaald + 1))
  fi
done

# TRIVY_OUTPUT mag de telling niet wegsturen.
rc=0
uitvoer="$(TRIVY_OUTPUT="${werkmap}/elders.json" "${controle}" "${werkmap}/opgelost.yaml" "${werkmap}/schoon.json" 2>&1 >/dev/null)" \
  || rc=$?
uitslag "TRIVY_OUTPUT in de omgeving" 1 "${rc}" "${uitvoer}" 'Verweesde suppressie'

echo
echo "${geslaagd} geslaagd, ${gefaald} gefaald"
[ "${gefaald}" -eq 0 ]
