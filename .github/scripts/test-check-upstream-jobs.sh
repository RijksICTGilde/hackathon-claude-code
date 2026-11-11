#!/usr/bin/env bash
# Fixtures voor de compare-stappen van check-upstream.yml.
#
# De stappen worden uit de workflow gehaald en gedraaid tegen een kopie van
# claude-sandbox, met `gh` en `curl` vervangen door stubs. Zo is te toetsen dat
# een bump werkelijk alle plekken verzet en dat elke degeneratie zichtbaar
# faalt, zonder op een wekelijkse cron te wachten.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
wortel="$(cd "${hier}/../.." && pwd)"
workflow="${wortel}/.github/workflows/check-upstream.yml"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

command -v yq >/dev/null || {
  echo "yq ontbreekt; de stappen kunnen niet uit de workflow gehaald worden." >&2
  exit 1
}

geslaagd=0
gefaald=0

# De huidige pins uit de Dockerfile lezen in plaats van ze hier te herhalen:
# anders breekt elke bump die deze jobs zelf voorstellen de fixtures.
lees_pin() { # variabelenaam
  grep -oE "$1=[v]?[0-9]+\.[0-9]+\.[0-9]+" "${wortel}/claude-sandbox/Dockerfile" \
    | head -1 | cut -d= -f2
}

rtk_nu="$(lees_pin RTK_VERSION)"
delta_nu="$(lees_pin DELTA_VERSION)"
node_nu="$(lees_pin NODE_VERSION)"
node_major="${node_nu#v}"; node_major="${node_major%%.*}"
npm_nu="$(lees_pin NPM_VERSION)"
npm_major="${npm_nu%%.*}"
go_nu="$(lees_pin GO_VERSION)"
# Een pseudo-versie past niet in het X.Y.Z-patroon van lees_pin.
functl_nu="$(grep -oE 'FUNCTL_VERSION=v0\.0\.0-[0-9]{14}-[0-9a-f]{12}' "${wortel}/claude-sandbox/Dockerfile" \
  | head -1 | cut -d= -f2)"

for waarde in "${rtk_nu}" "${delta_nu}" "${node_nu}" "${npm_nu}" "${go_nu}" "${functl_nu}"; do
  if [ -z "${waarde}" ]; then
    echo "FOUT: kon niet alle pins uit de Dockerfile lezen"
    exit 1
  fi
done

for job in vendored-scripts rtk-version delta-version node-version npm-version go-version functl-version apt-security-refresh; do
  yq ".jobs.\"${job}\".steps[] | select(has(\"run\")) | .run" "${workflow}" > "${werkmap}/${job}.sh"
  # Precies één run-blok: `yq` plakt er anders meerdere achter elkaar en dan
  # draait de fixture een script dat geen enkele stap zo uitvoert.
  # apt-security-refresh heeft meerdere run-stappen; daarvan wordt alleen de
  # beslisstap los getoetst.
  verwacht_blokken=1
  [ "${job}" = apt-security-refresh ] && verwacht_blokken=3
  [ "${job}" = node-version ] && verwacht_blokken=2

  if [ ! -s "${werkmap}/${job}.sh" ] \
     || [ "$(yq ".jobs.\"${job}\".steps | map(select(has(\"run\"))) | length" "${workflow}")" -ne "${verwacht_blokken}" ]; then
    echo "FOUT: verwacht precies ${verwacht_blokken} run-blok(ken) in ${job}"
    exit 1
  fi
done

# De beslisstap apart, want de job heeft er meer dan één.
yq '.jobs."apt-security-refresh".steps[] | select(.id == "compare") | .run' "${workflow}" \
  > "${werkmap}/epoch.sh"
if [ ! -s "${werkmap}/epoch.sh" ]; then
  echo "FOUT: geen compare-stap gevonden in apt-security-refresh"
  exit 1
fi

# node-version: versievergelijking en library-vergelijking los toetsen.
yq '.jobs."node-version".steps[] | select(.id == "compare") | .run' "${workflow}" \
  > "${werkmap}/node-version.sh"
yq '.jobs."node-version".steps[] | select(.id == "libs") | .run' "${workflow}" \
  > "${werkmap}/node-libs.sh"
if [ ! -s "${werkmap}/node-version.sh" ] || [ ! -s "${werkmap}/node-libs.sh" ]; then
  echo "FOUT: geen compare- of libs-stap gevonden in node-version"
  exit 1
fi

nieuwe_map() { # -> map met een kopie van claude-sandbox en een stub-PATH
  local d; d="$(mktemp -d "${werkmap}/geval-XXXXXX")"
  mkdir -p "${d}/ws/.github/scripts" "${d}/ws/claude-sandbox/vendor/install-scripts" "${d}/bin"
  cp "${wortel}/.github/scripts/vervang-pin.sh" \
     "${wortel}/.github/scripts/apt-upgrade-beschikbaar.sh" "${d}/ws/.github/scripts/"
  cp "${wortel}/claude-sandbox/Dockerfile" "${wortel}/claude-sandbox/README.md" "${d}/ws/claude-sandbox/"
  printf '#!/bin/sh\necho origineel\n' > "${d}/ws/claude-sandbox/vendor/install-scripts/rtk.sh"
  echo "${d}"
}

stub() { # map naam inhoud
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/bin/$2"
  chmod +x "$1/bin/$2"
}

dubbele_pin() { # map ankerregel extra-regel
  awk -v anker="$2" -v extra="$3" '{ print; if (index($0, anker) == 1) print extra }' \
    "$1/ws/claude-sandbox/Dockerfile" > "$1/dockerfile.tmp"
  mv "$1/dockerfile.tmp" "$1/ws/claude-sandbox/Dockerfile"
}

draai() { # map job -> uitvoer op stdout, exitcode in $?
  ( cd "$1/ws/claude-sandbox" \
      && PATH="$1/bin:$PATH" GITHUB_WORKSPACE="$1/ws" GITHUB_OUTPUT="$1/uitvoer" \
         bash "${werkmap}/$2.sh" ) 2>&1
}

toets() { # naam verwachte_exitcode patroon uitvoer exitcode
  local naam="$1" verwacht="$2" patroon="$3" uit="$4" rc="$5"

  if [ "${rc}" -ne "${verwacht}" ]; then
    echo "FOUT ${naam}: exitcode ${rc}, verwacht ${verwacht}"
    sed 's/^/    /' <<<"${uit}" | head -4
    gefaald=$((gefaald + 1))
    return
  fi

  if [ -n "${patroon}" ] && ! grep -q "${patroon}" <<<"${uit}"; then
    echo "FOUT ${naam}: melding mist '${patroon}'"
    sed 's/^/    /' <<<"${uit}" | head -4
    gefaald=$((gefaald + 1))
    return
  fi

  echo "ok   ${naam}"
  geslaagd=$((geslaagd + 1))
}

geopend() { # naam map -> de PR-stap zou draaien
  grep -qx 'changed=true' "$2/uitvoer"
  controle "$1" $?
}

vervangingen() { # naam uitvoer aantal
  # Elke geslaagde aanroep van vervang-pin.sh meldt "<bestand>: oud -> nieuw (N×)".
  [ "$(grep -c ' -> .*×)$' <<<"$2")" -eq "$3" ]
  controle "$1" $?
}

controle() { # naam voorwaarde-exitcode
  if [ "$2" -eq 0 ]; then
    echo "ok   $1"
    geslaagd=$((geslaagd + 1))
  else
    echo "FOUT $1"
    gefaald=$((gefaald + 1))
  fi
}

script_stub='while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { shift; printf "#!/bin/sh\necho nieuw\n" > "$1"; }; shift; done'
# Een .deb begint met het ar-magic; de job toetst daarop voor hij een SHA
# berekent. Per architectuur andere inhoud, zodat de twee SHAs verschillen.
deb_stub='while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { shift; printf "!<arch>\ndebian-binary %s\n" "$1" > "$1"; }; shift; done'
node_stub='for arg in "$@"; do case "$arg" in
  *index.json) echo "[{\"version\":\"v99.0.0\",\"lts\":\"Xenon\"}]"; exit 0;;
  *SHASUMS256.txt) printf "%s  node-v99.0.0-linux-x64.tar.xz\n%s  node-v99.0.0-linux-arm64.tar.xz\n" \
      "$(printf "a%.0s" $(seq 64))" "$(printf "b%.0s" $(seq 64))"; exit 0;;
esac; done'
npm_stub="printf '{\"versions\":{\"${npm_nu}\":{},\"${npm_major}.999.0\":{},\"999.0.0\":{}}}\\n'"

# ── vendored scripts (claude, sdkman) ──
# Deze job draait in een matrix; de stap leest NAAM/URL/FILE uit de omgeving.
vendored() { # map -> uitvoer
  ( cd "$1/ws/claude-sandbox" \
      && PATH="$1/bin:$PATH" NAAM=claude \
         URL=https://voorbeeld.test/install.sh \
         FILE=vendor/install-scripts/claude.sh \
         GITHUB_OUTPUT="$1/uitvoer" bash "${werkmap}/vendored-scripts.sh" ) 2>&1
}

d="$(nieuwe_map)"; printf '#!/bin/sh\necho oud\n' > "$d/ws/claude-sandbox/vendor/install-scripts/claude.sh"
stub "$d" curl 'exit 0'
uit="$(vendored "$d")"; rc=$?
toets "vendored: lege download geweigerd" 1 "leeg of begint niet met een shebang" "$uit" "$rc"

d="$(nieuwe_map)"; printf '#!/bin/sh\necho oud\n' > "$d/ws/claude-sandbox/vendor/install-scripts/claude.sh"
stub "$d" curl 'while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { shift; printf "<html>404</html>\n" > "$1"; }; shift; done'
uit="$(vendored "$d")"; rc=$?
toets "vendored: download zonder shebang geweigerd" 1 "shebang" "$uit" "$rc"

d="$(nieuwe_map)"; printf '#!/bin/sh\necho oud\n' > "$d/ws/claude-sandbox/vendor/install-scripts/claude.sh"
stub "$d" curl "$script_stub"
uit="$(vendored "$d")"; rc=$?
toets "vendored: geldige download wordt opgepakt" 0 "" "$uit" "$rc"
geopend "vendored: wijziging zet changed=true" "$d"
grep -q 'echo nieuw' "$d/ws/claude-sandbox/vendor/install-scripts/claude.sh"
controle "vendored: het bestand is werkelijk vervangen" $?

# ── rtk ──
d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: bump verzet Dockerfile en README" 0 "README.md: ${rtk_nu} -> v0.99.0" "$uit" "$rc"
grep -q 'echo nieuw' "$d/ws/claude-sandbox/vendor/install-scripts/rtk.sh"; controle "rtk: vendored script vervangen" $?
geopend "rtk: bump zet changed=true" "$d"
vervangingen "rtk: drie vervangingen" "$uit" 3

d="$(nieuwe_map)"; stub "$d" gh 'echo "v1.0.0; rm -rf /"'; stub "$d" curl 'true'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: vijandige tag geweigerd" 1 "onverwachte rtk-tag" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl 'exit 0'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: lege download geweigerd" 1 "is leeg" "$uit" "$rc"
grep -q origineel "$d/ws/claude-sandbox/vendor/install-scripts/rtk.sh"; controle "rtk: vendored script ongemoeid na lege download" $?

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'
stub "$d" curl 'while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { shift; printf "<html>404</html>\n" > "$1"; }; shift; done'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: download zonder shebang geweigerd" 1 "shebang" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
sed -i "s|rtk-ai/rtk/${rtk_nu}/install.sh|rtk-ai/rtk/vOUD/install.sh|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: herkomst-URL achtergebleven wordt rood" 1 "komt 0× voor" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
sed -i "s|\`rtk\` ${rtk_nu}|\`rtk\` vOUD|" "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: README-vermelding achtergebleven wordt rood" 1 "komt 0× voor" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh "echo ${rtk_nu}"; stub "$d" curl 'true'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: gelijke versie opent niets" 0 "" "$uit" "$rc"
grep -q 'changed=false' "$d/uitvoer"; controle "rtk: changed=false bij gelijke versie" $?

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
dubbele_pin "$d" 'RUN case "$INSTALL_RTK" in' '      oud) RTK_VERSION=v0.0.1 sh /tmp/rtk-install.sh ;; \\'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: tweede pin wordt rood" 1 "precies één RTK_VERSION-pin" "$uit" "$rc"

# ── delta ──
d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'; stub "$d" curl "$deb_stub"
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: bump verzet versie en beide SHAs" 0 "DELTA_VERSION=${delta_nu} -> DELTA_VERSION=0.99.9" "$uit" "$rc"
geopend "delta: bump zet changed=true" "$d"
vervangingen "delta: drie vervangingen" "$uit" 3

d="$(nieuwe_map)"; stub "$d" gh 'echo "0.99.9 && curl kwaad"'; stub "$d" curl 'true'
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: vijandige tag geweigerd" 1 "onverwachte delta-tag" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'; stub "$d" curl "$deb_stub"
sed -i 's|      amd64) SHA=|      amd64)   SHA=|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: hertabelleerd case-blok blijft werken" 0 "" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'; stub "$d" curl "$deb_stub"
sed -i '0,/      arm64) SHA=[a-f0-9]*/s//      arm64) SHA=/' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: ontbrekende arm64-pin wordt rood" 1 "precies één arm64-SHA-pin" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'; stub "$d" curl "$deb_stub"
dubbele_pin "$d" 'RUN DELTA_VERSION=' 'RUN DELTA_VERSION=0.0.1 \\'
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: tweede pin wordt rood" 1 "precies één DELTA_VERSION-pin" "$uit" "$rc"

# ── node ──
d="$(nieuwe_map)"; stub "$d" curl "$node_stub"
uit="$(draai "$d" node-version)"; rc=$?
toets "node: bump verzet versie en beide SHAs" 0 "NODE_VERSION=${node_nu} -> NODE_VERSION=v99.0.0" "$uit" "$rc"
geopend "node: bump zet changed=true" "$d"
vervangingen "node: drie pins plus README bij een major-bump" "$uit" 4
grep -qF "Node.js 99 LTS" "$d/ws/claude-sandbox/README.md" \
  && ! grep -qF "Node.js ${node_major} LTS" "$d/ws/claude-sandbox/README.md"
controle "node: major-bump werkt de README tools-tabel bij" $?

d="$(nieuwe_map)"; stub "$d" curl "${node_stub//v99.0.0/v${node_major}.99.0}"
uit="$(draai "$d" node-version)"; rc=$?
toets "node: bump binnen dezelfde major" 0 "NODE_VERSION=${node_nu} -> NODE_VERSION=v${node_major}.99.0" "$uit" "$rc"
vervangingen "node: README ongemoeid binnen dezelfde major" "$uit" 3

d="$(nieuwe_map)"; stub "$d" curl "$node_stub"
sed -i "s|Node.js ${node_major} LTS|Node.js ${node_major}|" "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" node-version)"; rc=$?
toets "node: README zonder major-vermelding wordt rood" 1 "precies één 'Node.js ${node_major} LTS'" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl "$node_stub"
sed -i 's|      amd64) NODE_ARCH=x64;   SHA=|      amd64) NODE_ARCH=x64; SHA=|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" node-version)"; rc=$?
toets "node: hertabelleerd case-blok blijft werken" 0 "" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl 'printf "[]\n"'
uit="$(draai "$d" node-version)"; rc=$?
toets "node: lege upstream-lijst wordt rood" 1 "kon laatste Node.js LTS-versie niet" "$uit" "$rc"

d="$(nieuwe_map)"
stub "$d" curl 'for arg in "$@"; do case "$arg" in
  *index.json) echo "[{\"version\":\"v99.0.0\",\"lts\":\"Xenon\"}]"; exit 0;;
  *SHASUMS256.txt) printf "geen-sha  node-v99.0.0-linux-x64.tar.xz\ngeen-sha  node-v99.0.0-linux-arm64.tar.xz\n"; exit 0;;
esac; done'
uit="$(draai "$d" node-version)"; rc=$?
toets "node: checksum die geen sha256 is wordt rood" 1 "geen sha256" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl "$node_stub"
dubbele_pin "$d" 'RUN NODE_VERSION=' 'RUN NODE_VERSION=v0.0.1 \\'
uit="$(draai "$d" node-version)"; rc=$?
toets "node: tweede pin wordt rood" 1 "precies één NODE_VERSION-pin" "$uit" "$rc"

d="$(nieuwe_map)"
stub "$d" curl 'for arg in "$@"; do case "$arg" in
  *index.json) echo "[{\"version\":\"v99.0.0 && curl kwaad\",\"lts\":\"Xenon\"}]"; exit 0;;
esac; done'
uit="$(draai "$d" node-version)"; rc=$?
toets "node: vijandige versie geweigerd" 1 "onverwachte Node.js-versie" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl "$node_stub"
sed -i '0,/      arm64) NODE_ARCH=arm64; SHA=[a-f0-9]*/s//      arm64) NODE_ARCH=arm64; SHA=/' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" node-version)"; rc=$?
toets "node: ontbrekende arm64-pin wordt rood" 1 "NODE_ARCH=arm64" "$uit" "$rc"

# ── node: gedeelde libraries ──
# De tarballs bevatten een nep-binary waarvan de inhoud de NEEDED-lijst is;
# readelf is gestubd en leest die terug. Zo is de stap zonder echte ELF te toetsen.
libs_geval() { # map oude-needed nieuwe-needed (regels gescheiden door \n)
  local d="$1" v a inhoud
  for v in "${node_nu}" v99.0.0; do
    inhoud="$2"; [ "$v" = v99.0.0 ] && inhoud="$3"
    for a in x64 arm64; do
      mkdir -p "$d/bouw/node-$v-linux-$a/bin" "$d/tar"
      printf '%b' "$inhoud" > "$d/bouw/node-$v-linux-$a/bin/node"
      tar -cJf "$d/tar/node-$v-linux-$a.tar.xz" -C "$d/bouw" "node-$v-linux-$a"
    done
  done
  stub "$d" curl "uit=; url=
while [ \$# -gt 0 ]; do case \"\$1\" in -o) shift; uit=\"\$1\";; http*) url=\"\$1\";; esac; shift; done
cp \"$d/tar/\${url##*/}\" \"\$uit\""
  stub "$d" readelf 'while read -r s; do echo " 0x0000000000000001 (NEEDED)             Shared library: [$s]"; done < "$2"'
}

sha_van() { sha256sum "$1/tar/$2" | awk '{print $1}'; }

libs_draai() { # map [afwijkende nieuwe x64-sha]
  local d="$1"
  mkdir -p "$d/tmp"
  ( cd "$d/ws/claude-sandbox" \
      && PATH="$d/bin:$PATH" GITHUB_OUTPUT="$d/uitvoer" TMPDIR="$d/tmp" \
         CURRENT="${node_nu}" LATEST=v99.0.0 \
         CURRENT_X64="$(sha_van "$d" "node-${node_nu}-linux-x64.tar.xz")" \
         CURRENT_ARM64="$(sha_van "$d" "node-${node_nu}-linux-arm64.tar.xz")" \
         LATEST_X64="${2:-$(sha_van "$d" node-v99.0.0-linux-x64.tar.xz)}" \
         LATEST_ARM64="$(sha_van "$d" node-v99.0.0-linux-arm64.tar.xz)" \
         bash "${werkmap}/node-libs.sh" ) 2>&1
}

d="$(nieuwe_map)"; libs_geval "$d" 'libc.so.6\nlibm.so.6\n' 'libc.so.6\nlibm.so.6\nlibatomic.so.1\n'
uit="$(libs_draai "$d")"; rc=$?
toets "node-libs: nieuwe library wordt gemeld" 0 "libatomic.so.1" "$uit" "$rc"
grep -qxF 'nieuwe_libs=`libatomic.so.1` (x64), `libatomic.so.1` (arm64)' "$d/uitvoer"
controle "node-libs: melding noemt beide architecturen" $?

d="$(nieuwe_map)"; libs_geval "$d" 'libc.so.6\nlibm.so.6\n' 'libc.so.6\nlibm.so.6\n'
uit="$(libs_draai "$d")"; rc=$?
toets "node-libs: gelijke libraries" 0 "nieuwe libraries: geen" "$uit" "$rc"
grep -qx 'nieuwe_libs=' "$d/uitvoer"
controle "node-libs: gelijke libraries geven een lege melding" $?

d="$(nieuwe_map)"; libs_geval "$d" 'libc.so.6\nlibm.so.6\n' 'libc.so.6\nlibm.so.6\n'
uit="$(libs_draai "$d" "$(printf "a%.0s" $(seq 64))")"; rc=$?
toets "node-libs: afwijkende checksum wordt rood" 1 "did NOT match" "$uit" "$rc"

d="$(nieuwe_map)"; libs_geval "$d" 'libm.so.6\n' 'libc.so.6\nlibm.so.6\n'
uit="$(libs_draai "$d")"; rc=$?
toets "node-libs: lijst zonder libc wordt rood" 1 "geen libc.so.6" "$uit" "$rc"

d="$(nieuwe_map)"; libs_geval "$d" 'libc.so.6\n' 'libc.so.6\nlib$(id).so\n'
uit="$(libs_draai "$d")"; rc=$?
toets "node-libs: vijandige soname geweigerd" 1 "onverwachte soname" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'
stub "$d" curl 'while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { shift; printf "<html>proxy</html>\n" > "$1"; }; shift; done'
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: download die geen .deb is wordt rood" 1 "geen .deb-archief" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
sed -i "s|rtk/${rtk_nu}/install.sh)|rtk/v0.0.1/install.sh)|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: herkomst-URL op een andere tag wordt rood" 1 "komt 0× voor" "$uit" "$rc"

# ── npm ──
d="$(nieuwe_map)"; stub "$d" curl "$npm_stub"
uit="$(draai "$d" npm-version)"; rc=$?
toets "npm: bump binnen dezelfde major" 0 "NPM_VERSION=${npm_nu} -> NPM_VERSION=${npm_major}.999.0" "$uit" "$rc"
geopend "npm: bump zet changed=true" "$d"
vervangingen "npm: één vervanging" "$uit" 1

d="$(nieuwe_map)"; stub "$d" curl 'printf "{\"versions\":{}}\n"'
uit="$(draai "$d" npm-version)"; rc=$?
toets "npm: geen versie binnen major wordt rood" 1 "kon laatste npm-versie" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl "$npm_stub"
dubbele_pin "$d" 'RUN NPM_VERSION=' 'RUN NPM_VERSION=0.0.1 \\'
uit="$(draai "$d" npm-version)"; rc=$?
toets "npm: tweede pin wordt rood" 1 "precies één NPM_VERSION-pin" "$uit" "$rc"

# ── Go ──
sha_a="$(printf 'a%.0s' $(seq 64))"
sha_b="$(printf 'b%.0s' $(seq 64))"
go_feed_url='https://go.dev/dl/?mode=json'
go_minor="${go_nu%.*}"
go_patch_bump="${go_minor}.$(( ${go_nu##*.} + 1 ))"

# Een feed zoals go.dev hem levert: een release candidate vooraan, die de job
# moet overslaan, en per versie ook bestanden die geen Linux-archief zijn. Een
# optionele stabiele versie zonder bestanden staat vóór de hoofdversie, zodat
# een geval kan toetsen dat de job sorteert in plaats van de eerste te nemen.
# De stub antwoordt alleen op de echte feed-URL.
go_feed() { # map versie sha-amd64 sha-arm64 [stabiele-versie-ervoor]
  jq -n --arg v "$2" --arg a "$3" --arg b "$4" --arg voor "${5:-}" '[
    {version: "go999.0rc1", stable: false, files: []},
    if $voor != "" then {version: $voor, stable: true, files: []} else empty end,
    {version: $v, stable: true, files: [
      {filename: ($v + ".src.tar.gz"), kind: "source", sha256: ("c" * 64)},
      {filename: ($v + ".linux-amd64.tar.gz"), kind: "archive", sha256: $a},
      {filename: ($v + ".linux-arm64.tar.gz"), kind: "archive", sha256: $b}
    ]},
    {version: "go1.0.0", stable: true, files: []}
  ]' > "$1/feed.json"
  stub "$1" curl "printf '%s\n' \"\$@\" >> '$1/curl-argumenten.txt'
for arg in \"\$@\"; do [ \"\$arg\" = '${go_feed_url}' ] && { cat '$1/feed.json'; exit 0; }; done
exit 22"
}

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: bump verzet versie en beide SHAs" 0 "GO_VERSION=${go_nu} -> GO_VERSION=99.0.0" "$uit" "$rc"
geopend "go: bump zet changed=true" "$d"
vervangingen "go: minor-sprong geeft vier vervangingen" "$uit" 4
grep -q "amd64) GO_SHA=${sha_a} ;;" "$d/ws/claude-sandbox/Dockerfile" \
  && grep -q "arm64) GO_SHA=${sha_b} ;;" "$d/ws/claude-sandbox/Dockerfile"
controle "go: elke architectuur krijgt zijn eigen SHA" $?
grep -qF "Go 99.0 bij \`INSTALL_FUNDAMENT=true\`" "$d/ws/claude-sandbox/README.md" \
  && ! grep -qF "Go ${go_minor} bij" "$d/ws/claude-sandbox/README.md"
controle "go: minor-sprong verzet de README-vermelding" $?
grep -qx "current=${go_nu}" "$d/uitvoer" && grep -qx 'latest=99.0.0' "$d/uitvoer" \
  && grep -qx "amd64=${sha_a}" "$d/uitvoer" && grep -qx "arm64=${sha_b}" "$d/uitvoer"
controle "go: outputs voor de PR-body" $?
grep -qxF "${go_feed_url}" "$d/curl-argumenten.txt"
controle "go: feed opgehaald van ${go_feed_url}" $?

d="$(nieuwe_map)"; go_feed "$d" "go${go_patch_bump}" "$sha_a" "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: patch-bump verzet versie en beide SHAs" 0 "GO_VERSION=${go_nu} -> GO_VERSION=${go_patch_bump}" "$uit" "$rc"
vervangingen "go: patch-bump geeft drie vervangingen" "$uit" 3
cmp -s "${wortel}/claude-sandbox/README.md" "$d/ws/claude-sandbox/README.md"
controle "go: patch-bump laat de README ongemoeid" $?

# De volgorde van de feed is geen contract; 99.10.0 is hoger dan 99.9.0, ook
# als 99.9.0 eerst staat en als tekst hoger sorteert.
d="$(nieuwe_map)"; go_feed "$d" go99.10.0 "$sha_a" "$sha_b" go99.9.0
uit="$(draai "$d" go-version)"; rc=$?
toets "go: hoogste versie numeriek gekozen" 0 "GO_VERSION=${go_nu} -> GO_VERSION=99.10.0" "$uit" "$rc"
grep -qx 'latest=99.10.0' "$d/uitvoer"; controle "go: latest=99.10.0 ondanks de feedvolgorde" $?

d="$(nieuwe_map)"; go_feed "$d" go1.0.0 "$sha_a" "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: feed-versie lager dan de pin wordt rood" 1 "lager dan de pin ${go_nu}" "$uit" "$rc"
cmp -s "${wortel}/claude-sandbox/Dockerfile" "$d/ws/claude-sandbox/Dockerfile"
controle "go: lagere feed-versie laat de Dockerfile ongemoeid" $?

d="$(nieuwe_map)"; go_feed "$d" "go${go_nu}" "$sha_a" "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: gelijke versie opent niets" 0 "" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "go: changed=false bij gelijke versie" $?

d="$(nieuwe_map)"; go_feed "$d" 'go99.0.0; rm -rf /' "$sha_a" "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: vijandige versie geweigerd" 1 "onverwachte Go-versie" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0 "$sha_a" "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: versie zonder patch-nummer geweigerd" 1 "onverwachte Go-versie" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl 'printf "[]\n"'
uit="$(draai "$d" go-version)"; rc=$?
toets "go: lege feed wordt rood" 1 "kon laatste stabiele Go-versie niet" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl 'printf "<html>proxy</html>\n"'
uit="$(draai "$d" go-version)"; rc=$?
toets "go: feed die geen JSON is wordt rood" 1 "geen leesbare JSON-lijst" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl 'exit 22'
uit="$(draai "$d" go-version)"; rc=$?
toets "go: mislukte download van de feed wordt rood" 1 "kon de Go-feed van go.dev niet ophalen" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 geen-sha "$sha_b"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: checksum die geen sha256 is wordt rood" 1 "geen sha256" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
jq '(.[1].files) |= map(select(.filename | endswith("arm64.tar.gz") | not))' "$d/feed.json" > "$d/feed.tmp"
mv "$d/feed.tmp" "$d/feed.json"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: ontbrekend arm64-archief in de feed wordt rood" 1 "geen sha256" "$uit" "$rc"

for arch in amd64 arm64; do
  d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
  sed -i "s|      ${arch}) GO_SHA=|      ${arch})   GO_SHA=|" "$d/ws/claude-sandbox/Dockerfile"
  uit="$(draai "$d" go-version)"; rc=$?
  toets "go: hertabelleerde ${arch}-regel blijft werken" 0 "" "$uit" "$rc"
  vervangingen "go: hertabelleerde ${arch}-regel geeft vier vervangingen" "$uit" 4
done

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
sed -i 's|      arm64) GO_SHA=[a-f0-9]*|      arm64) GO_SHA=|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: ontbrekende arm64-pin wordt rood" 1 "precies één arm64-SHA-pin voor Go" "$uit" "$rc"

# Ook zonder nieuwe release: anders valt een verdwenen pin pas op bij de
# eerstvolgende bump.
d="$(nieuwe_map)"; go_feed "$d" "go${go_nu}" "$sha_a" "$sha_b"
sed -i 's|      amd64) GO_SHA=[a-f0-9]*|      amd64) GO_SHA=|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: ontbrekende amd64-pin wordt ook zonder bump rood" 1 "precies één amd64-SHA-pin voor Go" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
dubbele_pin "$d" '              arm64) GO_SHA=' "              arm64) GO_SHA=${sha_b} ;; \\\\"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: tweede arm64-pin wordt rood" 1 "precies één arm64-SHA-pin voor Go" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
dubbele_pin "$d" '      true) GO_VERSION=' '            GO_VERSION=1.0.0 && \\'
uit="$(draai "$d" go-version)"; rc=$?
toets "go: tweede pin wordt rood" 1 "precies één GO_VERSION-pin" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
sed -i "s|GO_VERSION=${go_nu}|GO_VERSION=latest|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: ontbrekende versiepin wordt rood" 1 "kon huidige GO_VERSION niet" "$uit" "$rc"

d="$(nieuwe_map)"; go_feed "$d" go99.0.0 "$sha_a" "$sha_b"
sed -i "s|Go ${go_minor} bij|Go 0.0 bij|" "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" go-version)"; rc=$?
toets "go: README-vermelding achtergebleven wordt rood" 1 "komt 0× voor" "$uit" "$rc"

# ── functl ──
functl_commit="abcdef1234567890abcdef1234567890abcdef12"
functl_versie="v0.0.0-20991231235959-abcdef123456"
functl_h1="h1:$(printf 'A%.0s' $(seq 40))+/9="
fundament=github.com/fundament-oss/fundament
dagen_geleden() { date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ; }

# De stubs schrijven hun argumenten weg, zodat een geval kan toetsen dat de
# proxy naar de commit en de checksum-database naar de versie gevraagd is.
# stand.txt is het antwoord op de vergelijking met master: aantal commits
# voor, en de commitdatum van de release-commit.
functl_geval() { # map commit versie h1 go-regel
  printf 'Rolling build of functl from the latest push to master.\n\n- Version: `x-master-1`\n- Commit: %s\n\nSee functl/README.md.\n' \
    "$2" > "$1/body.txt"
  printf '3 %s\n' "$(dagen_geleden 1)" > "$1/stand.txt"
  printf '{"Version":"%s","Time":"2099-12-31T23:59:59Z"}\n' "$3" > "$1/info.json"
  printf '70856769\n%s %s %s\n%s %s/go.mod h1:0ik80wQK/R9m20shc5M8R4KbA/dhI6RcLIKNqjDVHjA=\n\ngo.sum database tree\n' \
    "${fundament}" "$3" "$4" "${fundament}" "$3" > "$1/lookup.txt"
  printf 'module %s\n\ngo %s\n\nrequire example.com/x v1.0.0\n' "${fundament}" "$5" > "$1/mod.txt"
  stub "$1" gh "printf '%s\n' \"\$@\" >> '$1/gh-argumenten.txt'
case \"\$2\" in
  repos/fundament-oss/fundament/releases/tags/functl-latest) cat '$1/body.txt';;
  repos/fundament-oss/fundament/compare/*...master) cat '$1/stand.txt';;
  *) exit 1;;
esac"
  stub "$1" curl "printf '%s\n' \"\$@\" >> '$1/curl-argumenten.txt'
for arg in \"\$@\"; do case \"\$arg\" in
  https://proxy.golang.org/*.info) cat '$1/info.json'; exit;;
  https://sum.golang.org/lookup/*) cat '$1/lookup.txt'; exit;;
  https://proxy.golang.org/*.mod) cat '$1/mod.txt'; exit;;
esac; done"
}

# De commit achter de huidige pin, aangevuld tot 40 tekens: alleen de eerste 12
# staan in de pseudo-versie.
functl_gelijk_commit="${functl_nu##*-}$(printf '0%.0s' $(seq 28))"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: bump verzet versie en h1" 0 "FUNCTL_VERSION=${functl_nu} -> FUNCTL_VERSION=${functl_versie}" "$uit" "$rc"
geopend "functl: bump zet changed=true" "$d"
vervangingen "functl: twee vervangingen" "$uit" 2
grep -qF "FUNCTL_H1=${functl_h1} " "$d/ws/claude-sandbox/Dockerfile"
controle "functl: de nieuwe h1 staat heel in de Dockerfile" $?
grep -qx 'go_te_laag=false' "$d/uitvoer"; controle "functl: lagere go-regel geeft geen waarschuwing" $?
grep -qx "commit=${functl_commit}" "$d/uitvoer" && grep -qx "old_commit=${functl_nu##*-}" "$d/uitvoer" \
  && grep -qxF "h1=${functl_h1}" "$d/uitvoer" && grep -qx 'go_mod=1.20' "$d/uitvoer" \
  && grep -qx "go_pin=${go_nu}" "$d/uitvoer"
controle "functl: outputs voor de PR-body" $?
grep -qx "https://proxy.golang.org/${fundament}/@v/${functl_commit}.info" "$d/curl-argumenten.txt" \
  && grep -qx "https://sum.golang.org/lookup/${fundament}@${functl_versie}" "$d/curl-argumenten.txt" \
  && grep -qx "https://proxy.golang.org/${fundament}/@v/${functl_versie}.mod" "$d/curl-argumenten.txt"
controle "functl: proxy en checksum-database op commit en versie bevraagd" $?
grep -qx "repos/fundament-oss/fundament/compare/${functl_commit}...master" "$d/gh-argumenten.txt"
controle "functl: release-commit met master vergeleken" $?

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
sed -i 's/$/\r/' "$d/body.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: release-body met CRLF blijft werken" 0 "" "$uit" "$rc"
geopend "functl: release-body met CRLF zet changed=true" "$d"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_gelijk_commit" "${functl_nu}" "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: gelijke versie opent niets" 0 "" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "functl: changed=false bij gelijke versie" $?

# Een rolling release die upstream niet meer ververst: alleen rood als de
# release-commit oud is én master verder is.
d="$(nieuwe_map)"; functl_geval "$d" "$functl_gelijk_commit" "${functl_nu}" "$functl_h1" 1.20
printf '0 %s\n' "$(dagen_geleden 40)" > "$d/stand.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: oude release zonder nieuwere master-commits blijft groen" 0 "" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_gelijk_commit" "${functl_nu}" "$functl_h1" 1.20
printf '3 %s\n' "$(dagen_geleden 31)" > "$d/stand.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: oude release met nieuwere master-commits wordt rood" 1 "ververst de rolling release niet meer" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_gelijk_commit" "${functl_nu}" "$functl_h1" 1.20
printf '3 %s\n' "$(dagen_geleden 30)" > "$d/stand.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: release van precies 30 dagen met nieuwere master-commits blijft groen" 0 "" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
printf 'null null\n' > "$d/stand.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: onleesbare vergelijking met master wordt rood" 1 "onverwachte vergelijking" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
stub "$d" gh 'case "$2" in */compare/*) exit 1;; *) cat "'"$d"'/body.txt";; esac'
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: mislukte vergelijking met master wordt rood" 1 "niet met master vergelijken" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
stub "$d" gh 'echo "HTTP 404: Not Found" >&2; exit 1'
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: mislukte release-aanvraag wordt als zodanig gemeld" 1 "kon de release functl-latest niet ophalen" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" 'abcdef123456; rm -rf /' "$functl_versie" "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: vijandige commit geweigerd" 1 "onverwachte commit" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" abcdef123456 "$functl_versie" "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: verkorte commit geweigerd" 1 "onverwachte commit" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
printf 'Rolling build of functl.\n' > "$d/body.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: release zonder commit wordt rood" 1 "precies één '- Commit:'-regel" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
printf -- '- Commit: %s\n' "$functl_commit" >> "$d/body.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: release met twee commits wordt rood" 1 "precies één '- Commit:'-regel" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
: > "$d/info.json"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: lege proxy-info wordt rood" 1 "kon de pseudo-versie" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
printf '<html>proxy</html>\n' > "$d/info.json"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: proxy-info die geen JSON is wordt rood" 1 "geen leesbare JSON" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
rm "$d/info.json"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: mislukte proxy-aanvraag wordt rood" 1 "kon de module-info van commit" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" v1.2.3 "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: getagde versie i.p.v. pseudo-versie geweigerd" 1 "onverwachte pseudo-versie" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" v0.1.1-0.20991231235959-abcdef123456 "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: pseudo-versie na een tag geweigerd" 1 "onverwachte pseudo-versie" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "${functl_versie}; rm -rf /" "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: vijandige pseudo-versie geweigerd" 1 "onverwachte pseudo-versie" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" v0.0.0-20991231235959-000000000000 "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: pseudo-versie van een andere commit geweigerd" 1 "hoort niet bij commit" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" v0.0.0-20000101000000-abcdef123456 "$functl_h1" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: pseudo-versie ouder dan de pin geweigerd" 1 "is ouder dan de pin" "$uit" "$rc"
cmp -s "${wortel}/claude-sandbox/Dockerfile" "$d/ws/claude-sandbox/Dockerfile"
controle "functl: oudere pseudo-versie laat de Dockerfile ongemoeid" $?

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" 'h1:kort=' 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: ongeldige h1 geweigerd" 1 "geen geldige h1-hash" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "${functl_h1}; rm" 1.20
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: h1 met aanhangsel geweigerd" 1 "geen geldige h1-hash" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
: > "$d/lookup.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: lege checksum-lookup wordt rood" 1 "geen geldige h1-hash" "$uit" "$rc"

# Alleen de regel van de gevraagde versie telt; een h1 van een andere versie
# mag niet als die van deze versie gepind worden.
d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
printf '1\n%s v0.0.0-20000101000000-abcdef123456 %s\n' "${fundament}" "$functl_h1" > "$d/lookup.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: h1 van een andere versie geweigerd" 1 "geen geldige h1-hash" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 99.0
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: hogere go-regel bumpt wel" 0 "::warning::go.mod van ${fundament}@${functl_versie} vraagt go 99.0" "$uit" "$rc"
geopend "functl: hogere go-regel zet changed=true" "$d"
grep -qx 'go_te_laag=true' "$d/uitvoer"; controle "functl: hogere go-regel zet go_te_laag=true" $?

# De waarschuwingszin in de PR-body draait hier niet mee; vul de format()-
# expressie in met de outputs van dit geval, zodat ook de volgorde van de
# argumenten getoetst is.
functl_body="$(yq '.jobs."functl-version".steps[] | select(has("uses")) | .with.body' "${workflow}")"
formule="$(grep -oE "format\('[^']*', steps\.compare\.outputs\.[a-z_]+, steps\.compare\.outputs\.[a-z_]+\)" <<<"${functl_body}")"
sjabloon="$(sed -E "s/^format\('([^']*)'.*/\1/" <<<"${formule}")"
arg0="$(sed -n "s/^$(sed -E 's/.*outputs\.([a-z_]+), .*/\1/' <<<"${formule}")=//p" "$d/uitvoer")"
arg1="$(sed -n "s/^$(sed -E 's/.*outputs\.([a-z_]+)\)$/\1/' <<<"${formule}")=//p" "$d/uitvoer")"
zin="${sjabloon//\{0\}/${arg0}}"; zin="${zin//\{1\}/${arg1}}"
grep -qF "de go.mod vraagt Go 99.0, de Dockerfile pint Go ${go_nu}." <<<"${zin}" \
  && grep -qF "merge eerst een Go-bump naar minstens 99.0." <<<"${zin}" \
  && grep -qF "steps.compare.outputs.go_te_laag == 'true' && ${formule}" <<<"${functl_body}"
controle "functl: de PR-body meldt een te hoge go-regel met go.mod en pin op hun plek" $?

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" "${go_nu}"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: go-regel gelijk aan de pin" 0 "" "$uit" "$rc"
grep -qx 'go_te_laag=false' "$d/uitvoer"; controle "functl: go-regel gelijk aan de pin geeft geen waarschuwing" $?

# Numeriek vergelijken: als tekst is 1.27.9 hoger dan 1.27.10.
d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.27.9
sed -i "s|GO_VERSION=${go_nu}|GO_VERSION=1.27.10|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: pin 1.27.10 tegen go-regel 1.27.9" 0 "" "$uit" "$rc"
grep -qx 'go_te_laag=false' "$d/uitvoer" && grep -qx 'go_pin=1.27.10' "$d/uitvoer"
controle "functl: pin 1.27.10 tegen go-regel 1.27.9 geeft geen waarschuwing" $?

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
: > "$d/mod.txt"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: lege go.mod wordt rood" 1 "onverwachte go-regel" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" '1.20; rm -rf /'
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: vijandige go-regel geweigerd" 1 "onverwachte go-regel" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.2.3.4
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: go-regel met vier delen geweigerd" 1 "onverwachte go-regel" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
sed -i '/^            FUNCTL_H1=/d' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: ontbrekende h1-pin wordt rood" 1 "precies één FUNCTL_H1-pin" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
sed -i 's|FUNCTL_H1=h1:[^ ]*|FUNCTL_H1=onbekend|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: onleesbare h1-pin wordt rood" 1 "kon huidige FUNCTL_H1 niet" "$uit" "$rc"

# Ook zonder nieuwe commit: anders valt een kapotte pin pas op bij de
# eerstvolgende bump.
d="$(nieuwe_map)"; functl_geval "$d" "$functl_gelijk_commit" "${functl_nu}" "$functl_h1" 1.20
sed -i 's|FUNCTL_H1=h1:[^ ]*|FUNCTL_H1=onbekend|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: onleesbare h1-pin wordt ook zonder bump rood" 1 "kon huidige FUNCTL_H1 niet" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
dubbele_pin "$d" '            FUNCTL_VERSION=' '            FUNCTL_VERSION=v0.0.0-20000101000000-000000000000 && \\'
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: tweede versiepin wordt rood" 1 "precies één FUNCTL_VERSION-pin" "$uit" "$rc"

d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
sed -i "s|FUNCTL_VERSION=${functl_nu}|FUNCTL_VERSION=latest|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: onleesbare versiepin wordt rood" 1 "kon huidige FUNCTL_VERSION niet" "$uit" "$rc"

# Zonder Go-pin is de vergelijking met de go-regel geen meting.
d="$(nieuwe_map)"; functl_geval "$d" "$functl_commit" "$functl_versie" "$functl_h1" 1.20
sed -i "s|GO_VERSION=${go_nu}|GO_VERSION=latest|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" functl-version)"; rc=$?
toets "functl: onleesbare Go-pin wordt rood" 1 "kon huidige GO_VERSION niet" "$uit" "$rc"


# ── apt-security-refresh: de beslissing om wel of niet te verversen ──
# De scanrapporten en de apt-suite zijn hier gestubd; wat getoetst wordt is de
# beslislogica eromheen.
epoch_map() { # -> map met rapporten, stubs en een kopie van claude-sandbox
  local d; d="$(nieuwe_map)"
  mkdir -p "$d/tmp"
  echo "$d"
}

epoch_rapport() { # map arch cve-json installed-json
  jq -n --argjson v "$3" --argjson p "$4" --arg a "$2" '{
    Metadata: {OS: {Family: "debian"}, ImageConfig: {architecture: $a}},
    Results: [{Class: "os-pkgs", Vulnerabilities: $v, Packages: $p}]
  }' > "$1/tmp/trivy-$2.json"
}

# De job-env uit de workflow lezen in plaats van hem hier te herhalen: een
# nieuwe of gewijzigde variabele zou anders in de fixtures een andere waarde
# hebben dan in CI, en dat verschil valt pas op als het misgaat.
mapfile -t job_env < <(yq -r \
  '.jobs.apt-security-refresh.env | to_entries | .[] | .key + "=" + (.value | tostring)' \
  "${workflow}")
if [ "${#job_env[@]}" -eq 0 ]; then
  echo "De job apt-security-refresh heeft geen env; de fixtures zouden op standaardwaarden draaien." >&2
  exit 1
fi

epoch_draai() { # map [gh-uitvoer]
  ( cd "$1/ws/claude-sandbox" \
      && PATH="$1/bin:$PATH" GITHUB_WORKSPACE="$1/ws" GITHUB_OUTPUT="$1/uitvoer" \
         TMPDIR="$1/tmp" env "${job_env[@]}" bash "${werkmap}/epoch.sh" ) 2>&1
}

# De job schrijft naar vaste /tmp-paden; die worden per geval leeggemaakt.
epoch_geval() { # map cve-json installed-json policy [open-pr] [epoch] [cve-arm64] [installed-arm64]
  rm -f /tmp/trivy-amd64.json /tmp/trivy-arm64.json /tmp/os-all.json \
        /tmp/rest-all.json /tmp/geinstalleerd.json /tmp/policy.txt
  epoch_rapport "$1" amd64 "$2" "$3"
  epoch_rapport "$1" arm64 "${7:-$2}" "${8:-$3}"
  cp "$1/tmp/trivy-amd64.json" /tmp/trivy-amd64.json
  cp "$1/tmp/trivy-arm64.json" /tmp/trivy-arm64.json
  printf '%b' "$4" > "$1/policy.txt"
  # De bronnen die de container zegt gebruikt te hebben. Standaard de drie van
  # een echte trixie-image; een geval kan er een uitlaten.
  printf '%b' "${EPOCH_INDEX:-https://deb.debian.org/debian trixie\nhttps://deb.debian.org/debian trixie-updates\nhttps://deb.debian.org/debian-security trixie-security\n}" \
    > "$1/bronnen.txt"
  # Net als de echte aanroep: eerst de gebruikte bronnen, dan alleen de blokken
  # van de gevraagde pakketten, zodat de fixtures merken welke lijst er
  # werkelijk is voorgelegd.
  # De stub voert de opdracht van de container echt uit in plaats van de
  # pakketlijst uit de argumenten te raden. Alleen zo tellen de format-string,
  # de pipeline en de `_`-placeholder mee: valt die placeholder weg, dan schuift
  # het eerste pakket naar \$0 en verdwijnt het uit de vraag.
  cat > "$1/bin/apt-get" <<APTGET
#!/usr/bin/env bash
if [ "\$1" = update ]; then
  # Net als apt: voortgang op stdout. Belandt die in het bestand dat geparsed
  # wordt, dan is de omleiding in de workflow weggevallen.
  echo "Get:1 https://deb.debian.org/debian trixie InRelease"
  exit 0
fi
if [ "\$1" = indextargets ]; then
  # Net als apt: de opgegeven velden invullen. Is de format-string leeg — omdat
  # de shell hem als commando heeft uitgevoerd — dan komt er per bron een lege
  # regel uit, precies zoals apt dat doet.
  format=""
  while [ \$# -gt 0 ]; do [ "\$1" = --format ] && { format="\$2"; shift; }; shift; done
  while read -r site release; do
    uit="\$format"
    uit="\${uit//\\\$(SITE)/\$site}"
    uit="\${uit//\\\$(RELEASE)/\$release}"
    printf '%s\\n' "\$uit"
  done < '$1/bronnen.txt'
  exit 0
fi
exit 0
APTGET
  cat > "$1/bin/apt-cache" <<APTCACHE
#!/usr/bin/env bash
[ "\$1" = policy ] || exit 0
shift
for naam in "\$@"; do
  awk -v p="\$naam" '\$0 == p ":" {toon=1; print; next} /^[^ ]/ {toon=0} toon' '$1/policy.txt'
done
APTCACHE
  chmod +x "$1/bin/apt-get" "$1/bin/apt-cache"
  stub "$1" docker "
    printf '%s\n' \"\$@\" >> '$1/docker-argumenten.txt'
    while [ \$# -gt 0 ]; do
      case \"\$1\" in
        sh) shift; [ \"\$1\" = -c ] && shift; break ;;
        *) shift ;;
      esac
    done
    opdracht=\"\$1\"; shift
    sh -c \"\$opdracht\" \"\$@\""
  # De stub schrijft zijn argumenten weg, zodat een geval kan toetsen dát er
  # met de juiste branch gezocht is en niet alleen wát er terugkwam.
  stub "$1" gh "printf '%s\n' \"\$@\" >> '$1/gh-argumenten.txt'; ${EPOCH_GH:-printf '%s' '${5:-}'}"

  # De periodieke tak slaat pas aan bij een oude epoch; zonder dit blijven die
  # gevallen in de CVE-tak steken en meten ze de poort niet.
  if [ -n "${6:-}" ]; then
    sed -i "s|^ARG APT_UPGRADE_EPOCH=.*|ARG APT_UPGRADE_EPOCH=$6|" "$1/ws/claude-sandbox/Dockerfile"
  fi
}

# De herkomstregel hoort erbij: apt drukt onder elke kandidaat af waar die
# vandaan komt, en de stap gebruikt dat om een terugval op de pakketstatus van
# de image te herkennen.
herkomst='     500 https://deb.debian.org/debian trixie/main amd64 Packages\n'
# Gevallen die niets met de leeftijd van de epoch te maken hebben, krijgen een
# verse datum mee: anders hangt hun uitkomst af van de datum die toevallig in
# de Dockerfile staat, en kantelen ze zodra die over de drempel komt.
vandaag="$(date -u +%F)"
# Gevallen die verwachten dat de job een PR opent, krijgen een epoch van
# gisteren. Niet vandaag: dan weigert de job een tweede bump op dezelfde dag.
# Niet ouder dan de drempel: dan kan de periodieke verversing de PR openen en
# ziet de test niet meer of de CVE-controle zelf werkt.
gisteren="$(date -u -d yesterday +%F)"
policy_met_update="util-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5+deb13u1\n${herkomst}bind9-dnsutils:\n  Installed: 1:9.20.26-1~deb13u1\n  Candidate: 1:9.20.26-1~deb13u1\n${herkomst}"
policy_zonder_update="util-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5\n${herkomst}bind9-dnsutils:\n  Installed: 1:9.20.26-1~deb13u1\n  Candidate: 1:9.20.26-1~deb13u1\n${herkomst}"
# Wat apt teruggeeft als er geen enkele index is: kandidaten uit de status van
# de image zelf, met priority 100 en zonder archief.
policy_zonder_index='util-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5\n        100 /var/lib/dpkg/status\nbind9-dnsutils:\n  Installed: 1:9.20.26-1~deb13u1\n  Candidate: 1:9.20.26-1~deb13u1\n        100 /var/lib/dpkg/status\n'
cve_bevinding='[{"VulnerabilityID":"CVE-1","Severity":"HIGH","PkgName":"util-linux","InstalledVersion":"2.41-5","FixedVersion":"2.41-5+deb13u1"}]'
cve_te_nieuw='[{"VulnerabilityID":"CVE-1","Severity":"HIGH","PkgName":"util-linux","InstalledVersion":"2.41-5","FixedVersion":"9.9-1"}]'
# De vorm die Trivy werkelijk schrijft: `Version` mist de epoch en de revisie,
# de volledige versie staat in `ID`.
pakketten='[{"ID":"util-linux@2.41-5","Name":"util-linux","Version":"2.41","Release":"5","Arch":"amd64"},{"ID":"bind9-dnsutils@1:9.20.26-1~deb13u1","Name":"bind9-dnsutils","Version":"9.20.26","Release":"1~deb13u1","Epoch":1,"Arch":"amd64"}]'

d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update" "" "$gisteren"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: fix beschikbaar levert een verversing" 0 "kandidaat 2.41-5+deb13u1 dekt" "$uit" "$rc"
geopend "epoch: fix beschikbaar zet changed=true" "$d"
grep -q 'reason=.*nu op te halen' "$d/uitvoer"
controle "epoch: de aanleiding noemt de beschikbare fix" $?

d="$(epoch_map)"; epoch_geval "$d" "$cve_te_nieuw" "$pakketten" "$policy_met_update" "" "$vandaag"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: fix nog niet in de suite opent niets" 0 "geen enkele fix staat in de suite" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "epoch: fix nog niet in de suite zet changed=false" $?

d="$(epoch_map)"; epoch_geval "$d" '[]' "$pakketten" "$policy_zonder_update" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: niets te upgraden slaat de periodieke verversing over" 0 "geen pakket heeft een hogere kandidaat" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "epoch: niets te upgraden opent niets" $?

d="$(epoch_map)"; epoch_geval "$d" '[]' "$pakketten" "$policy_met_update" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: periodieke verversing met iets te halen" 0 "hogere kandidaat" "$uit" "$rc"
grep -q 'reason=periodieke verversing' "$d/uitvoer"
controle "epoch: de aanleiding noemt de periodieke verversing" $?
geopend "epoch: periodieke verversing zet changed=true" "$d"

d="$(epoch_map)"; epoch_geval "$d" '[]' "$pakketten" "$policy_met_update" "1234" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: openstaand voorstel wordt met rust gelaten" 0 "staat al een voorstel open" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "epoch: openstaand voorstel wordt niet herschreven" $?

d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" ""
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: lege policy-uitvoer wordt rood" 1 "geïnstalleerde pakketten" "$uit" "$rc"

# Een vastzittende CVE mag de periodieke verversing niet bevriezen.
d="$(epoch_map)"; epoch_geval "$d" "$cve_te_nieuw" "$pakketten" "$policy_met_update" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: vastzittende CVE blokkeert de periodieke verversing niet" 0 "hogere kandidaat" "$uit" "$rc"
geopend "epoch: vastzittende CVE laat de periodieke verversing door" "$d"

# Een bevinding die alleen op arm64 staat, moet net zo goed aan de suite
# gevraagd worden; anders leest "niet gevraagd" als "niet in de suite".
arm_cve='[{"VulnerabilityID":"CVE-ARM","Severity":"HIGH","PkgName":"libnuma1","InstalledVersion":"2.0.18-1","FixedVersion":"2.0.18-2"}]'
arm_pakketten='[{"ID":"util-linux@2.41-5","Name":"util-linux","Version":"2.41","Release":"5","Arch":"arm64"}]'
policy_arm="util-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5\n${herkomst}bind9-dnsutils:\n  Installed: 1:9.20.26-1~deb13u1\n  Candidate: 1:9.20.26-1~deb13u1\n${herkomst}libnuma1:\n  Installed: 2.0.18-1\n  Candidate: 2.0.18-2\n${herkomst}"

d="$(epoch_map)"; epoch_geval "$d" '[]' "$pakketten" "$policy_arm" "" "$gisteren" "$arm_cve" "$arm_pakketten"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: arm64-only bevinding wordt aan de suite gevraagd" 0 "libnuma1: kandidaat 2.0.18-2 dekt" "$uit" "$rc"
geopend "epoch: arm64-only bevinding opent een voorstel" "$d"

# Een openstaand voorstel geldt ook voor de CVE-tak.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update" "1234"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: openstaand voorstel houdt ook de CVE-tak tegen" 0 "staat al een voorstel open" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "epoch: CVE-tak herschrijft het voorstel niet" $?

# De format-string voor apt moet de container letterlijk bereiken. Staat hij
# tussen dubbele quotes in de `sh -c`-body, dan voert `sh` hem uit als
# command-substitution, krijgt apt een lege format en levert elke regel niets
# op — waarna de controle op de security-index altijd faalt.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
epoch_draai "$d" >/dev/null
grep -qF '\$(SITE)' "$d/docker-argumenten.txt"
controle "epoch: de format-string bereikt apt onuitgevoerd" $?

# Een pakket waar een fixbare bevinding op zit maar dat apt niet noemt: dan is
# de vraag of die fix bestaat niet gesteld, en dat mag geen "nee" worden.
d="$(epoch_map)"; epoch_geval "$d" \
  '[{"VulnerabilityID":"CVE-Z","Severity":"HIGH","PkgName":"zoekgeraakt","InstalledVersion":"1","FixedVersion":"2"}]' \
  "$pakketten" "$policy_met_update" "" "$vandaag"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: bevinding op een pakket dat apt niet noemt wordt rood" 1 "voor de rest is de vraag niet gesteld" "$uit" "$rc"

# Zonder index geeft apt gewoon kandidaten terug — die van de image zelf. Dat
# leest als "niets te halen" terwijl er niets geraadpleegd is.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_zonder_index"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: kandidaten uit de pakketstatus wordt rood" 1 "geen enkele kandidaat komt uit een archief" "$uit" "$rc"

# Loopt de basis-image ver uit de pas met de gepubliceerde image, dan is een
# groot deel van de namen onbekend en wordt er meer geraden dan gemeten.
d="$(epoch_map)"; epoch_geval "$d" '[]' \
  '[{"ID":"a@1","Name":"a","Arch":"amd64"},{"ID":"b@1","Name":"b","Arch":"amd64"},{"ID":"c@1","Name":"c","Arch":"amd64"},{"ID":"d@1","Name":"d","Arch":"amd64"},{"ID":"e@1","Name":"e","Arch":"amd64"},{"ID":"f@1","Name":"f","Arch":"amd64"},{"ID":"g@1","Name":"g","Arch":"amd64"},{"ID":"h@1","Name":"h","Arch":"amd64"},{"ID":"i@1","Name":"i","Arch":"amd64"},{"ID":"j@1","Name":"j","Arch":"amd64"}]' \
  "a:\n  Installed: 1\n  Candidate: 1\n${herkomst}" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: te lage dekking wordt rood" 1 "te veel om de uitkomst een meting te noemen" "$uit" "$rc"

# Een tweede pakket dat buiten apt om binnenkomt, valt automatisch buiten de
# weging: de lijst wordt uit de Dockerfile afgeleid, dus er kan geen drift
# ontstaan tussen wat er staat en wat er gewogen wordt.
d="$(epoch_map)"
sed -i 's|^    dpkg -i /tmp/git-delta.deb|    dpkg -i /tmp/iets-anders.deb \&\& dpkg -i /tmp/git-delta.deb|' \
  "$d/ws/claude-sandbox/Dockerfile"
epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: een tweede dpkg-pakket valt vanzelf buiten de weging" 0 '"git-delta","iets-anders"' "$uit" "$rc"

# Een dpkg-regel waar geen pakketnaam uit te halen is, mag niet stil als "niets
# uit te sluiten" gelden.
d="$(epoch_map)"
sed -i 's|^    dpkg -i /tmp/git-delta.deb|    dpkg -i $SOMEVAR|' "$d/ws/claude-sandbox/Dockerfile"
epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: onherkenbare dpkg-vorm wordt rood" 1 "de vorm is niet herkend" "$uit" "$rc"

# Koppen zonder versietabel: de namen worden herkend, het formaat niet. Dat is
# geen "niets te halen" maar een meting die niet gedaan is.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" \
  'util-linux:\nbind9-dnsutils:\n'
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: policy zonder Candidate-regels wordt rood" 1 "geen enkele Candidate-regel" "$uit" "$rc"

# Nul dekking is een kapotte meting; een enkel ontbrekend pakket is een antwoord.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" \
  'iets-anders:\n  Installed: 1\n  Candidate: 2\n'
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: policy over andere pakketten wordt rood" 1 "geen enkel van de" "$uit" "$rc"

# Zonder security-bron zou een fix uit die suite onzichtbaar blijven, terwijl
# `apt-get update` netjes met 0 eindigt.
d="$(epoch_map)"
EPOCH_INDEX='https://deb.debian.org/debian trixie\n' \
  epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: ontbrekende security-index wordt rood" 1 "geen security-index" "$uit" "$rc"

# Een `gh` die faalt mag niet als "geen voorstel open" tellen.
d="$(epoch_map)"
EPOCH_GH='exit 1' epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: falende gh wordt rood" 1 "kon niet nagaan" "$uit" "$rc"

# En hij moet op de eigen branch zoeken: zonder --head zou elk willekeurig open
# voorstel de verversing voorgoed stilleggen.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
epoch_draai "$d" >/dev/null
grep -qx 'deps/apt-security-refresh' "$d/gh-argumenten.txt"
controle "epoch: het voorstel wordt op de eigen branch gezocht" $?

# Loopt arm64 achter op amd64, dan moet de periodieke tak dat zien: de
# geïnstalleerde versies van beide architecturen wegen mee.
d="$(epoch_map)"
epoch_geval "$d" '[]' \
  '[{"ID":"util-linux@2.41-5+deb13u1","Name":"util-linux","Version":"2.41","Arch":"amd64"}]' \
  "util-linux:\n  Installed: 2.41-5+deb13u1\n  Candidate: 2.41-5+deb13u1\n${herkomst}" \
  "" 2020-01-01 '[]' \
  '[{"ID":"util-linux@2.41-5","Name":"util-linux","Version":"2.41","Arch":"arm64"}]'
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: een achterlopende arm64 lokt een verversing uit" 0 "is hoger dan het geïnstalleerde 2.41-5" "$uit" "$rc"

# Een pakket dat buiten apt om gepind wordt, kan een epoch-bump niet bewegen.
# Naast git-delta staat er een gewoon apt-pakket in, anders zou de meting al op
# "geen geïnstalleerde pakketten" stranden en meet dit geval de uitsluiting niet.
d="$(epoch_map)"
epoch_geval "$d" \
  '[{"VulnerabilityID":"CVE-D","Severity":"HIGH","PkgName":"git-delta","InstalledVersion":"0.19.2","FixedVersion":"0.18.2-4+b1"}]' \
  '[{"ID":"git-delta@0.19.2","Name":"git-delta","Version":"0.19.2","Arch":"amd64"},{"ID":"util-linux@2.41-5","Name":"util-linux","Version":"2.41","Arch":"amd64"}]' \
  "git-delta:\n  Installed: 0.19.2\n  Candidate: 0.18.2-4+b1\n${herkomst}util-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5\n${herkomst}" \
  "" "$vandaag"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: bevinding buiten de apt-laag opent geen voorstel" 0 "Buiten de weging gelaten" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"
controle "epoch: een gepind pakket zet changed niet op true" $?

# Een pakket zonder ID is niet te vergelijken en moet dat zeggen.
d="$(epoch_map)"; epoch_geval "$d" '[]' '[{"Name":"util-linux","Version":"2.41"}]' "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: pakket zonder ID wordt rood" 1 "zonder ID" "$uit" "$rc"

# Een onverwachte pakketnaam mag niet naar de container.
d="$(epoch_map)"; epoch_geval "$d" '[]' '[{"ID":"raar naam@1","Name":"raar naam","Arch":"amd64"}]' "$policy_met_update" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: onverwachte pakketnaam wordt rood" 1 "onverwachte pakketnaam" "$uit" "$rc"

# Een naam die alleen toegestane tekens gebruikt maar met een streepje begint,
# zou als optie bij apt-cache policy terechtkomen.
d="$(epoch_map)"; epoch_geval "$d" '[]' '[{"ID":"-force@1","Name":"-force","Arch":"amd64"}]' \
  "$policy_met_update" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: pakketnaam die met een streepje begint wordt rood" 1 "onverwachte pakketnaam" "$uit" "$rc"

# Een naam met een newline erin is door jq en mapfile al in tweeën geknipt; een
# regelgewijze toets zou beide helften doorlaten en het echte pakket zou nooit
# gevraagd worden.
d="$(epoch_map)"; epoch_geval "$d" '[]' '[{"ID":"foo\nbar@1","Name":"foo\nbar","Arch":"amd64"}]' "$policy_met_update" "" 2020-01-01
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: pakketnaam met een newline wordt rood" 1 "onverwachte pakketnaam" "$uit" "$rc"

# Een falende container is geen antwoord.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
stub "$d" docker 'echo "Error: pull access denied" >&2; exit 125'
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: falende policy-container wordt rood" 1 "exitcode 125" "$uit" "$rc"

# Een vraag die niet beantwoord kán worden mag niet als "nee" tellen.
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
printf '#!/usr/bin/env bash\nexit 2\n' > "$d/ws/.github/scripts/apt-upgrade-beschikbaar.sh"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: onbeantwoordbare beschikbaarheidsvraag wordt rood" 1 "kon niet beantwoord worden" "$uit" "$rc"

# Een gedeeltelijk mislukte apt-get update leest anders als "niets te halen".
d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
stub "$d" docker "cat '$d/policy.txt'; echo 'W: Some index files failed to download.' >&2"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: mislukte index-download wordt rood" 1 "niet alle indexen" "$uit" "$rc"

d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" '[]' "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: geen geïnstalleerde pakketten wordt rood" 1 "niet te stellen" "$uit" "$rc"

rm -f /tmp/trivy-amd64.json /tmp/trivy-arm64.json /tmp/os-all.json \
      /tmp/rest-all.json /tmp/geinstalleerd.json /tmp/policy.txt

# ── kubectl en helm ──
kubectl_nu="$(lees_pin KUBECTL_VERSION)"
helm_nu="$(lees_pin HELM_VERSION)"
if [ -z "${kubectl_nu}" ] || [ -z "${helm_nu}" ]; then
  echo "FOUT: kon KUBECTL_VERSION of HELM_VERSION niet uit de Dockerfile lezen"
  exit 1
fi
for job in kubectl-version helm-version; do
  yq ".jobs.\"${job}\".steps[] | select(has(\"run\")) | .run" "${workflow}" > "${werkmap}/${job}.sh"
  if [ ! -s "${werkmap}/${job}.sh" ] \
     || [ "$(yq ".jobs.\"${job}\".steps | map(select(has(\"run\"))) | length" "${workflow}")" -ne 1 ]; then
    echo "FOUT: verwacht precies 1 run-blok in ${job}"
    exit 1
  fi
done

sha_a="$(printf 'a%.0s' $(seq 64))"
sha_b="$(printf 'b%.0s' $(seq 64))"
kubectl_minor="${kubectl_nu%.*}"
kubectl_patch="${kubectl_minor}.$(( ${kubectl_nu##*.} + 1 ))"
helm_major="${helm_nu%%.*}"
helm_patch="${helm_nu%.*}.$(( ${helm_nu##*.} + 1 ))"
# major.minor zonder v, zoals de README en docs/kubernetes.md hem noemen.
helm_mm="${helm_nu#v}"; helm_mm="${helm_mm%.*}"
helm_volgende="v$(( ${helm_major#v} + 1 )).0.0"
# Een minor die n stappen voor de gepinde ligt, voor de supportgrens.
kubectl_plus() { # n -> vX.Y.2
  echo "${kubectl_minor%%.*}.$(( 10#${kubectl_minor#*.} + $1 )).2"
}

# De huidige SHA-pins: bij gelijke versie toetst de job ze tegen upstream, dus
# de stubs leveren voor de gepinde versie deze waarden.
lees_sha() { # arch naam
  grep -oP "$1\)\s*$2=\K[a-f0-9]{64}" "${wortel}/claude-sandbox/Dockerfile"
}
kubectl_sha_amd64="$(lees_sha amd64 KUBECTL_SHA)"
kubectl_sha_arm64="$(lees_sha arm64 KUBECTL_SHA)"
helm_sha_amd64="$(lees_sha amd64 HELM_SHA)"
helm_sha_arm64="$(lees_sha arm64 HELM_SHA)"
for waarde in "${kubectl_sha_amd64}" "${kubectl_sha_arm64}" "${helm_sha_amd64}" "${helm_sha_arm64}"; do
  if [ "${#waarde}" -ne 64 ]; then
    echo "FOUT: kon de SHA-pins van kubectl en helm niet uit de Dockerfile lezen"
    exit 1
  fi
done

# Een kopie met ook docs/kubernetes.md: de helm-job bumpt de vermelding daarin.
k8s_map() {
  local d; d="$(nieuwe_map)"
  mkdir -p "$d/ws/claude-sandbox/docs"
  cp "${wortel}/claude-sandbox/docs/kubernetes.md" "$d/ws/claude-sandbox/docs/"
  echo "$d"
}

# Zet een pin in de kopie op een vaste waarde, voor gevallen die een bepaalde
# verhouding tot de pin nodig hebben.
zet_pin() { # map naam waarde
  sed -i -E "s/$2=v[0-9]+\.[0-9]+\.[0-9]+/$2=$3/" "$1/ws/claude-sandbox/Dockerfile"
}

# Alleen regels met deze naam mogen veranderd zijn, en precies zoveel.
alleen_gewijzigd() { # naam map patroon aantal
  local nieuw anders
  nieuw="$(diff "${wortel}/claude-sandbox/Dockerfile" "$2/ws/claude-sandbox/Dockerfile" | grep -c '^>')"
  anders="$(diff "${wortel}/claude-sandbox/Dockerfile" "$2/ws/claude-sandbox/Dockerfile" | grep '^>' | grep -vc "$3")"
  [ "${nieuw}" -eq "$4" ] && [ "${anders}" -eq 0 ]
  controle "$1" $?
}

# De zin die de PR-body bij een melding toont, ingevuld met de outputs van een
# geval: de format()-expressie draait hier niet mee, zo is ook de volgorde van
# de argumenten getoetst.
pr_melding() { # job uitvoerbestand
  local body formule sjabloon naam0 naam1 arg0 arg1 zin
  body="$(yq ".jobs.\"$1\".steps[] | select(.with.body != null) | .with.body" "${workflow}")"
  formule="$(grep -oE "format\('[^']*', steps\.compare\.outputs\.[a-z_]+, steps\.compare\.outputs\.[a-z_]+\)" <<<"${body}")"
  sjabloon="$(sed -E "s/^format\('([^']*)'.*/\1/" <<<"${formule}")"
  naam0="$(sed -E 's/.*outputs\.([a-z_]+), .*/\1/' <<<"${formule}")"
  naam1="$(sed -E 's/.*outputs\.([a-z_]+)\)$/\1/' <<<"${formule}")"
  arg0="$(sed -n "s/^${naam0}=//p" "$2")"
  arg1="$(sed -n "s/^${naam1}=//p" "$2")"
  zin="${sjabloon//\{0\}/${arg0}}"; zin="${zin//\{1\}/${arg1}}"
  printf '%s\n' "${zin}"
}

# De stub antwoordt alleen op de echte URL's en schrijft zijn argumenten weg.
# Een ontbrekend antwoordbestand is een mislukte download. Een checksum komt
# uit sha-<arch>-<versie>.txt als dat er is (standaard: de gepinde versie met
# de echte pins), anders uit sha-<arch>.txt.
kubectl_geval() { # map stable-<minor> stable sha-amd64 sha-arm64
  printf '%s' "$2" > "$1/stable-minor.txt"
  printf '%s' "$3" > "$1/stable.txt"
  printf '%s' "$4" > "$1/sha-amd64.txt"
  printf '%s' "$5" > "$1/sha-arm64.txt"
  printf '%s' "${kubectl_sha_amd64}" > "$1/sha-amd64-${kubectl_nu}.txt"
  printf '%s' "${kubectl_sha_arm64}" > "$1/sha-arm64-${kubectl_nu}.txt"
  stub "$1" curl "printf '%s\n' \"\$@\" >> '$1/curl-argumenten.txt'
for arg in \"\$@\"; do case \"\$arg\" in
  https://dl.k8s.io/release/stable-${kubectl_minor#v}.txt) bron='$1/stable-minor.txt';;
  https://dl.k8s.io/release/stable.txt) bron='$1/stable.txt';;
  https://dl.k8s.io/release/*/bin/linux/amd64/kubectl.sha256|https://dl.k8s.io/release/*/bin/linux/arm64/kubectl.sha256)
    v=\"\${arg#https://dl.k8s.io/release/}\"; a=\"\${v#*/bin/linux/}\"; a=\"\${a%%/*}\"; v=\"\${v%%/*}\"
    bron=\"$1/sha-\$a-\$v.txt\"; [ -e \"\$bron\" ] || bron=\"$1/sha-\$a.txt\";;
  *) continue;;
esac; [ -e \"\$bron\" ] || exit 22; cat \"\$bron\"; exit 0; done
exit 22"
}

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: patch-bump verzet versie en beide SHAs" 0 "KUBECTL_VERSION=${kubectl_nu} -> KUBECTL_VERSION=${kubectl_patch}" "$uit" "$rc"
geopend "kubectl: bump zet changed=true" "$d"
vervangingen "kubectl: drie vervangingen" "$uit" 3
grep -q "amd64) KUBECTL_SHA=${sha_a} ;;" "$d/ws/claude-sandbox/Dockerfile" \
  && grep -q "arm64) KUBECTL_SHA=${sha_b} ;;" "$d/ws/claude-sandbox/Dockerfile"
controle "kubectl: elke architectuur krijgt zijn eigen SHA" $?
alleen_gewijzigd "kubectl: alleen de drie kubectl-regels gewijzigd" "$d" KUBECTL_ 3
cmp -s "${wortel}/claude-sandbox/README.md" "$d/ws/claude-sandbox/README.md" \
  && cmp -s "${wortel}/claude-sandbox/docs/kubernetes.md" "$d/ws/claude-sandbox/docs/kubernetes.md"
controle "kubectl: patch-bump laat README en docs ongemoeid" $?
printf 'current=%s\nlatest=%s\nminor=%s\nstable=%s\nnieuwere_minor=false\nchanged=true\namd64=%s\narm64=%s\n' \
  "$kubectl_nu" "$kubectl_patch" "$kubectl_minor" "$kubectl_patch" "$sha_a" "$sha_b" | cmp -s - "$d/uitvoer"
controle "kubectl: outputs voor de PR-body exact" $?
grep -qxF "https://dl.k8s.io/release/stable-${kubectl_minor#v}.txt" "$d/curl-argumenten.txt" \
  && grep -qxF "https://dl.k8s.io/release/stable.txt" "$d/curl-argumenten.txt" \
  && grep -qxF "https://dl.k8s.io/release/${kubectl_patch}/bin/linux/amd64/kubectl.sha256" "$d/curl-argumenten.txt" \
  && grep -qxF "https://dl.k8s.io/release/${kubectl_patch}/bin/linux/arm64/kubectl.sha256" "$d/curl-argumenten.txt"
controle "kubectl: stable-<minor>, stable.txt en de checksums van de nieuwe versie opgehaald" $?
! grep -q 'nieuwere minor' <<<"$uit"
controle "kubectl: gelijke minor in stable.txt geeft geen melding" $?

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" "$kubectl_nu" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: gelijke versie opent niets" 0 "" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "kubectl: changed=false bij gelijke versie" $?
cmp -s "${wortel}/claude-sandbox/Dockerfile" "$d/ws/claude-sandbox/Dockerfile"
controle "kubectl: gelijke versie laat de Dockerfile ongemoeid" $?
grep -qxF "https://dl.k8s.io/release/${kubectl_nu}/bin/linux/amd64/kubectl.sha256" "$d/curl-argumenten.txt" \
  && grep -qxF "https://dl.k8s.io/release/${kubectl_nu}/bin/linux/arm64/kubectl.sha256" "$d/curl-argumenten.txt"
controle "kubectl: gelijke versie haalt de checksums van de gepinde versie op" $?

# Een gewijzigde upstream-checksum of een verkeerd overgenomen pin valt ook
# zonder nieuwe patch op.
for arch in amd64 arm64; do
  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" "$kubectl_nu" "$sha_a" "$sha_b"
  printf '%s' "$sha_a" > "$d/sha-${arch}-${kubectl_nu}.txt"
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: afwijkende ${arch}-SHA bij gelijke versie wordt rood" 1 "de ${arch}-SHA-pin van kubectl ${kubectl_nu} wijkt af van upstream (${sha_a})" "$uit" "$rc"
  ! grep -q '^changed=' "$d/uitvoer"
  controle "kubectl: afwijkende ${arch}-SHA zet geen changed" $?

  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" "$kubectl_nu" "$sha_a" "$sha_b"
  rm "$d/sha-${arch}-${kubectl_nu}.txt" "$d/sha-${arch}.txt"
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: mislukte ${arch}-checksum bij gelijke versie wordt rood" 1 "kon de ${arch}-checksum van kubectl ${kubectl_nu} niet ophalen" "$uit" "$rc"
done

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" "$kubectl_nu" "$sha_a" "$sha_b"
printf '%s  kubectl' "$kubectl_sha_amd64" > "$d/sha-amd64-${kubectl_nu}.txt"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: checksum met aanhangsel bij gelijke versie wordt rood" 1 "geen sha256 uit kubectl.sha256 voor amd64 ${kubectl_nu}" "$uit" "$rc"

# Een nieuwere minor wordt gemeld, nooit gebumpt; ook zonder patch.
plus2="$(kubectl_plus 2)"
d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$plus2" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: twee minors achter geeft een waarschuwing" 0 "::warning::stable.txt staat op ${plus2}, een nieuwere minor dan de gepinde ${kubectl_minor}" "$uit" "$rc"
grep -qx 'nieuwere_minor=true' "$d/uitvoer" && grep -qx "stable=${plus2}" "$d/uitvoer" \
  && grep -qx "latest=${kubectl_patch}" "$d/uitvoer"
controle "kubectl: nieuwere minor zet nieuwere_minor=true en bumpt binnen de pin" $?
zin="$(pr_melding kubectl-version "$d/uitvoer")"
grep -qF "\`stable.txt\` staat op ${plus2}, een nieuwere minor dan de gepinde ${kubectl_minor}." <<<"${zin}" \
  && grep -qF "Deze PR blijft binnen ${kubectl_minor};" <<<"${zin}" \
  && yq '.jobs."kubectl-version".steps[] | select(.with.body != null) | .with.body' "${workflow}" \
     | grep -qF "steps.compare.outputs.nieuwere_minor == 'true' && format("
controle "kubectl: de PR-body meldt de nieuwere minor met stable en pin op hun plek" $?

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" "$(kubectl_plus 1)" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: nieuwere minor zonder patch waarschuwt ook" 0 "::warning::stable.txt staat op $(kubectl_plus 1)" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "kubectl: nieuwere minor zonder patch opent niets" $?

# Buiten de drie ondersteunde minors komt er geen patch-PR meer; dan moet de
# run zelf rood worden, ook als er nog een patch klaarstaat.
for stable in "$(kubectl_plus 3)" "$(kubectl_plus 65)" v2.0.0; do
  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$stable" "$sha_a" "$sha_b"
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: stable ${stable} ligt buiten de support van de pin en wordt rood" 1 "stable.txt staat op ${stable}; de gepinde minor ${kubectl_minor} valt buiten de drie ondersteunde minors" "$uit" "$rc"
  cmp -s "${wortel}/claude-sandbox/Dockerfile" "$d/ws/claude-sandbox/Dockerfile" && ! grep -q '^changed=' "$d/uitvoer" 2>/dev/null
  controle "kubectl: stable ${stable} buiten de support bumpt niets" $?
done

# Numeriek: als tekst is v1.9 hoger dan v1.35.
d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" v1.9.0 "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: lagere minor in stable.txt" 0 "" "$uit" "$rc"
grep -qx 'nieuwere_minor=false' "$d/uitvoer" && ! grep -q '::warning::' <<<"$uit"
controle "kubectl: lagere minor in stable.txt geeft geen melding" $?

# Numeriek: als tekst is v1.35.9 hoger dan v1.35.10.
d="$(k8s_map)"; kubectl_geval "$d" "${kubectl_minor}.9" "${kubectl_minor}.9" "$sha_a" "$sha_b"
zet_pin "$d" KUBECTL_VERSION "${kubectl_minor}.10"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: lagere patch dan de pin wordt rood" 1 "lager dan de pin ${kubectl_minor}.10" "$uit" "$rc"
grep -q "KUBECTL_VERSION=${kubectl_minor}.10 " "$d/ws/claude-sandbox/Dockerfile"
controle "kubectl: lagere patch laat de pin staan" $?

d="$(k8s_map)"; kubectl_geval "$d" "${kubectl_minor}.10" "${kubectl_minor}.10" "$sha_a" "$sha_b"
rm -f "$d"/sha-*-"${kubectl_minor}".10.txt
zet_pin "$d" KUBECTL_VERSION "${kubectl_minor}.9"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: patch 10 na pin 9 is een bump" 0 "KUBECTL_VERSION=${kubectl_minor}.9 -> KUBECTL_VERSION=${kubectl_minor}.10" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" v1.999.0 v1.999.0 "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: stable-<minor> met een andere minor wordt rood" 1 "buiten de gepinde minor ${kubectl_minor}" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "${kubectl_patch}; rm -rf /" "$kubectl_patch" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: vijandige versie geweigerd" 1 "onverwachte kubectl-versie '${kubectl_patch}; rm -rf /' in stable-" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$(printf '%s\n%s' "$kubectl_patch" "$kubectl_patch")" "$kubectl_patch" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: versie over twee regels geweigerd" 1 "onverwachte kubectl-versie" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "${kubectl_minor#v}.11" "$kubectl_patch" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: versie zonder v geweigerd" 1 "onverwachte kubectl-versie" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "" "$kubectl_patch" "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: lege stable-<minor> wordt rood" 1 "onverwachte kubectl-versie '' in stable-" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"; rm "$d/stable-minor.txt"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: mislukte download van stable-<minor> wordt rood" 1 "kon stable-${kubectl_minor#v}.txt niet ophalen" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"; rm "$d/stable.txt"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: mislukte download van stable.txt wordt rood" 1 "kon stable.txt niet ophalen" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" 'v1.999.0 && curl kwaad' "$sha_a" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: vijandige stable.txt geweigerd" 1 "onverwachte kubectl-versie 'v1.999.0 && curl kwaad' in stable.txt" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" geen-sha "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: amd64-checksum die geen sha256 is wordt rood" 1 "'geen-sha' is geen sha256 uit kubectl.sha256 voor amd64" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "${sha_b}  kubectl"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: arm64-checksum met aanhangsel wordt rood" 1 "geen sha256 uit kubectl.sha256 voor arm64" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "x${sha_a}" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: amd64-checksum met voorvoegsel wordt rood" 1 "geen sha256 uit kubectl.sha256 voor amd64" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "" "$sha_b"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: lege checksum wordt rood" 1 "'' is geen sha256" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"; rm "$d/sha-arm64.txt"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: mislukte checksum-download wordt rood" 1 "kon de arm64-checksum van kubectl ${kubectl_patch} niet ophalen" "$uit" "$rc"
cmp -s "${wortel}/claude-sandbox/Dockerfile" "$d/ws/claude-sandbox/Dockerfile"
controle "kubectl: mislukte checksum-download laat de Dockerfile ongemoeid" $?

for arch in amd64 arm64; do
  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
  sed -i "s|      ${arch}) KUBECTL_SHA=|      ${arch})   KUBECTL_SHA=|" "$d/ws/claude-sandbox/Dockerfile"
  grep -q "${arch})   KUBECTL_SHA=" "$d/ws/claude-sandbox/Dockerfile"
  controle "kubectl: fixture hertabelleert de ${arch}-regel" $?
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: hertabelleerde ${arch}-regel blijft werken" 0 "" "$uit" "$rc"
  vervangingen "kubectl: hertabelleerde ${arch}-regel geeft drie vervangingen" "$uit" 3

  # 65 hextekens: zonder grens op de telling zou de bump er één laten staan.
  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
  sed -i "s|${arch}) KUBECTL_SHA=\([a-f0-9]*\)|${arch}) KUBECTL_SHA=\1a|" "$d/ws/claude-sandbox/Dockerfile"
  grep -qE "${arch}\) KUBECTL_SHA=[a-f0-9]{65} " "$d/ws/claude-sandbox/Dockerfile"
  controle "kubectl: fixture verlengt de ${arch}-pin" $?
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: ${arch}-pin van 65 tekens wordt rood" 1 "precies één ${arch}-SHA-pin voor kubectl" "$uit" "$rc"

  # Ook zonder nieuwe patch: anders valt een verdwenen pin pas op bij de
  # eerstvolgende bump.
  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_nu" "$kubectl_nu" "$sha_a" "$sha_b"
  sed -i "s|      ${arch}) KUBECTL_SHA=[a-f0-9]*|      ${arch}) KUBECTL_SHA=|" "$d/ws/claude-sandbox/Dockerfile"
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: ontbrekende ${arch}-pin wordt ook zonder bump rood" 1 "precies één ${arch}-SHA-pin voor kubectl" "$uit" "$rc"

  d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
  dubbele_pin "$d" "              ${arch}) KUBECTL_SHA=" "              ${arch}) KUBECTL_SHA=${sha_b} ;; \\\\"
  uit="$(draai "$d" kubectl-version)"; rc=$?
  toets "kubectl: tweede ${arch}-pin wordt rood" 1 "precies één ${arch}-SHA-pin voor kubectl" "$uit" "$rc"
done

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
dubbele_pin "$d" '            KUBECTL_VERSION=' '            KUBECTL_VERSION=v1.0.0 && \\'
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: tweede versiepin wordt rood" 1 "precies één KUBECTL_VERSION-pin" "$uit" "$rc"

d="$(k8s_map)"; kubectl_geval "$d" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
sed -i "s|KUBECTL_VERSION=${kubectl_nu}|KUBECTL_VERSION=latest|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" kubectl-version)"; rc=$?
toets "kubectl: onleesbare versiepin wordt rood" 1 "kon huidige KUBECTL_VERSION niet" "$uit" "$rc"

# Releases zoals de API ze levert: nieuwste eerst, v3 en v4 door elkaar, met
# een pre-release en een concept ertussen.
helm_release() { # tag [draft] [prerelease]
  jq -nc --arg t "$1" --argjson d "${2:-false}" --argjson p "${3:-false}" \
    '{tag_name: $t, draft: $d, prerelease: $p, name: ("Helm " + $t)}'
}
helm_geval() { # map sha-amd64 sha-arm64 release-json...
  local d="$1" a="$2" b="$3"; shift 3
  # Eén pagina; `gh api --paginate` zet pagina's als losse lijsten achter elkaar.
  printf '%s\n' "$@" | jq -s . > "$d/releases.json"
  # De checksum-bestanden noemen de tarball; die naam hangt aan de versie die
  # de job kiest, dus de stub vult hem in vanuit de URL. Zoals bij kubectl:
  # sum-<arch>-<versie>.txt gaat voor, standaard de echte pins van de pin.
  printf '%s' "$a" > "$d/sum-amd64.txt"
  printf '%s' "$b" > "$d/sum-arm64.txt"
  printf '%s' "${helm_sha_amd64}" > "$d/sum-amd64-${helm_nu}.txt"
  printf '%s' "${helm_sha_arm64}" > "$d/sum-arm64-${helm_nu}.txt"
  stub "$d" gh "printf '%s\n' \"\$@\" >> '$d/gh-argumenten.txt'
[ \"\$*\" = 'api --paginate repos/helm/helm/releases?per_page=100' ] || exit 1
cat '$d/releases.json'"
  stub "$d" curl "printf '%s\n' \"\$@\" >> '$d/curl-argumenten.txt'
for arg in \"\$@\"; do case \"\$arg\" in
  https://get.helm.sh/helm-*-linux-amd64.tar.gz.sha256sum|https://get.helm.sh/helm-*-linux-arm64.tar.gz.sha256sum)
    naam=\"\${arg#https://get.helm.sh/}\"; naam=\"\${naam%.sha256sum}\"
    v=\"\${naam#helm-}\"; v=\"\${v%-linux-*}\"; a=\"\${naam#*-linux-}\"; a=\"\${a%.tar.gz}\"
    bron=\"$d/sum-\$a-\$v.txt\"; [ -e \"\$bron\" ] || bron=\"$d/sum-\$a.txt\";;
  *) continue;;
esac; [ -e \"\$bron\" ] || exit 22
printf '%s  %s\n' \"\$(cat \"\$bron\")\" \"\$naam\"; exit 0; done
exit 22"
}
helm_standaard() { # map nieuwste-v4 [extra release-json...]
  local d="$1" v="$2"; shift 2
  helm_geval "$d" "$sha_a" "$sha_b" \
    "$(helm_release "${helm_major}.999.0" false true)" \
    "$(helm_release "${helm_major}.998.0" true false)" \
    "$(helm_release v3.999.9)" \
    "$(helm_release "$v")" \
    "$(helm_release v3.22.1)" \
    "$(helm_release "${helm_nu}")" \
    "$@"
}

d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.99.0"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: minor-sprong verzet versie en beide SHAs" 0 "HELM_VERSION=${helm_nu} -> HELM_VERSION=${helm_major}.99.0" "$uit" "$rc"
geopend "helm: bump zet changed=true" "$d"
vervangingen "helm: minor-sprong geeft vijf vervangingen" "$uit" 5
grep -q "amd64) HELM_SHA=${sha_a} ;;" "$d/ws/claude-sandbox/Dockerfile" \
  && grep -q "arm64) HELM_SHA=${sha_b} ;;" "$d/ws/claude-sandbox/Dockerfile"
controle "helm: elke architectuur krijgt zijn eigen SHA" $?
alleen_gewijzigd "helm: alleen de drie helm-regels in de Dockerfile gewijzigd" "$d" HELM_ 3
grep -qF "helm ${helm_major#v}.99 (" "$d/ws/claude-sandbox/README.md" \
  && ! grep -qF "helm ${helm_mm} " "$d/ws/claude-sandbox/README.md" \
  && grep -qF "\`helm\` (${helm_major#v}.99)" "$d/ws/claude-sandbox/docs/kubernetes.md" \
  && ! grep -qF "\`helm\` (${helm_mm})" "$d/ws/claude-sandbox/docs/kubernetes.md"
controle "helm: minor-sprong verzet de vermelding in README en docs/kubernetes.md" $?
printf 'current=%s\nlatest=%s\nmajor=%s\nhoogste=%s\nnieuwe_major=false\nchanged=true\namd64=%s\narm64=%s\n' \
  "$helm_nu" "${helm_major}.99.0" "$helm_major" "${helm_major}.99.0" "$sha_a" "$sha_b" | cmp -s - "$d/uitvoer"
controle "helm: outputs voor de PR-body exact" $?
grep -qxF "https://get.helm.sh/helm-${helm_major}.99.0-linux-amd64.tar.gz.sha256sum" "$d/curl-argumenten.txt" \
  && grep -qxF "https://get.helm.sh/helm-${helm_major}.99.0-linux-arm64.tar.gz.sha256sum" "$d/curl-argumenten.txt"
controle "helm: checksums van de nieuwe versie opgehaald" $?

d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: patch-bump" 0 "HELM_VERSION=${helm_nu} -> HELM_VERSION=${helm_patch}" "$uit" "$rc"
vervangingen "helm: patch-bump geeft drie vervangingen" "$uit" 3
cmp -s "${wortel}/claude-sandbox/README.md" "$d/ws/claude-sandbox/README.md" \
  && cmp -s "${wortel}/claude-sandbox/docs/kubernetes.md" "$d/ws/claude-sandbox/docs/kubernetes.md"
controle "helm: patch-bump laat README en docs ongemoeid" $?

d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: gelijke versie opent niets" 0 "" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer" && ! grep -q '::warning::' <<<"$uit"
controle "helm: changed=false en geen melding bij gelijke versie" $?

# De volgorde van de API is geen contract: v4.10 is hoger dan v4.9, ook als
# v4.9 eerst staat en als tekst hoger sorteert.
d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.9.0" "$(helm_release "${helm_major}.10.0")"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: hoogste versie numeriek gekozen" 0 "HELM_VERSION=${helm_nu} -> HELM_VERSION=${helm_major}.10.0" "$uit" "$rc"

d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}" "$(helm_release "${helm_volgende}")"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: nieuwe major geeft een waarschuwing" 0 "::warning::helm ${helm_volgende} is uit, een nieuwere major dan de gepinde ${helm_major}" "$uit" "$rc"
grep -qx 'nieuwe_major=true' "$d/uitvoer" && grep -qx "hoogste=${helm_volgende}" "$d/uitvoer" \
  && grep -qx "latest=${helm_patch}" "$d/uitvoer"
controle "helm: nieuwe major zet nieuwe_major=true en bumpt binnen de pin" $?
zin="$(pr_melding helm-version "$d/uitvoer")"
grep -qF "helm ${helm_volgende} is uit, een nieuwere major dan de gepinde ${helm_major}." <<<"${zin}" \
  && grep -qF "Deze PR blijft binnen ${helm_major};" <<<"${zin}" \
  && yq '.jobs."helm-version".steps[] | select(.with.body != null) | .with.body' "${workflow}" \
     | grep -qF "steps.compare.outputs.nieuwe_major == 'true' && format("
controle "helm: de PR-body meldt de nieuwe major met release en pin op hun plek" $?

d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}" "$(helm_release "${helm_volgende}")"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: nieuwe major zonder bump waarschuwt ook" 0 "::warning::helm ${helm_volgende} is uit" "$uit" "$rc"
grep -qx 'changed=false' "$d/uitvoer"; controle "helm: nieuwe major zonder bump opent niets" $?

d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}" "$(helm_release "${helm_volgende}-rc.1" false true)" "$(helm_release "${helm_volgende}" true false)"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: pre-release of concept van een nieuwe major" 0 "" "$uit" "$rc"
grep -qx 'nieuwe_major=false' "$d/uitvoer" && ! grep -q '::warning::' <<<"$uit"
controle "helm: pre-release of concept van een nieuwe major geeft geen melding" $?

# Een lijst zonder de pin is onvolledig of teruggezet; "niets nieuwers" zegt
# dan niets. Numeriek: als tekst is v4.9.0 hoger dan v4.10.0.
d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b" "$(helm_release "${helm_major}.9.0")"
zet_pin "$d" HELM_VERSION "${helm_major}.10.0"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: lijst met alleen een lagere versie dan de pin wordt rood" 1 "de gepinde helm ${helm_major}.10.0 staat niet tussen de stabiele releases" "$uit" "$rc"
grep -q "HELM_VERSION=${helm_major}.10.0 " "$d/ws/claude-sandbox/Dockerfile"
controle "helm: lagere versie laat de pin staan" $?

d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b" "$(helm_release "${helm_patch}")" "$(helm_release "${helm_nu}" false true)"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: pin die alleen als pre-release in de lijst staat wordt rood" 1 "de gepinde helm ${helm_nu} staat niet tussen" "$uit" "$rc"

# Meerdere pagina's: de nieuwste v4 en de pin staan pas op de tweede.
d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b" "$(helm_release v3.999.9)"
jq -c . "$d/releases.json" > "$d/pagina1.json"
jq -nc --argjson a "$(helm_release "${helm_major}.99.0")" --argjson b "$(helm_release "${helm_nu}")" '[$a, $b]' \
  | cat "$d/pagina1.json" - > "$d/releases.json"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: release op de tweede pagina wordt gevonden" 0 "HELM_VERSION=${helm_nu} -> HELM_VERSION=${helm_major}.99.0" "$uit" "$rc"
grep -qxF -- '--paginate' "$d/gh-argumenten.txt"
controle "helm: de releases worden met --paginate opgehaald" $?

# Zie kubectl: de pins van de gepinde versie worden ook zonder bump getoetst.
d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}"
draai "$d" helm-version >/dev/null
grep -qxF "https://get.helm.sh/helm-${helm_nu}-linux-amd64.tar.gz.sha256sum" "$d/curl-argumenten.txt" \
  && grep -qxF "https://get.helm.sh/helm-${helm_nu}-linux-arm64.tar.gz.sha256sum" "$d/curl-argumenten.txt"
controle "helm: gelijke versie haalt de checksums van de gepinde versie op" $?
for arch in amd64 arm64; do
  d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}"
  printf '%s' "$sha_b" > "$d/sum-${arch}-${helm_nu}.txt"
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: afwijkende ${arch}-SHA bij gelijke versie wordt rood" 1 "de ${arch}-SHA-pin van helm ${helm_nu} wijkt af van upstream (${sha_b})" "$uit" "$rc"

  d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}"
  rm "$d/sum-${arch}-${helm_nu}.txt" "$d/sum-${arch}.txt"
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: mislukte ${arch}-checksum bij gelijke versie wordt rood" 1 "kon de checksum van helm-${helm_nu}-linux-${arch}.tar.gz niet ophalen" "$uit" "$rc"
done

# Ongeldige tags vallen weg in plaats van in curl of sed te belanden; de
# geldige release ernaast wordt gewoon gekozen.
d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}" \
  "$(helm_release "${helm_major}.99.0; rm -rf /")" \
  "$(helm_release "$(printf 'x\n%s.99.1' "${helm_major}")")" \
  "$(helm_release "${helm_major}.99.2"$'\n')" \
  "$(helm_release "${helm_major#v}.99.3")" \
  "$(jq -nc '{tag_name: null, draft: false, prerelease: false}')"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: vijandige en misvormde tags vallen weg" 0 "HELM_VERSION=${helm_nu} -> HELM_VERSION=${helm_patch}" "$uit" "$rc"
grep -qx "latest=${helm_patch}" "$d/uitvoer"; controle "helm: alleen de geldige tag gekozen" $?

d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b" "$(helm_release "${helm_major}.99.0; rm -rf /")" "$(helm_release v3.99.0)"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: geen geldige release binnen de major wordt rood" 1 "geen stabiele helm-release binnen major ${helm_major}" "$uit" "$rc"

d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: lege releaselijst wordt rood" 1 "geen stabiele helm-release binnen major" "$uit" "$rc"

for kapot in '<html>proxy</html>' '{"message":"Not Found"}' 'null'; do
  d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"; printf '%s\n' "$kapot" > "$d/releases.json"
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: releases '${kapot}' wordt rood" 1 "geen leesbare JSON-lijst" "$uit" "$rc"
done

d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
stub "$d" gh 'echo "HTTP 403: rate limit" >&2; exit 1'
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: mislukte API-aanvraag wordt rood" 1 "kon de releases van helm/helm niet ophalen" "$uit" "$rc"

d="$(k8s_map)"; helm_geval "$d" geen-sha "$sha_b" "$(helm_release "${helm_patch}")" "$(helm_release "${helm_nu}")"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: checksum die geen sha256 is wordt rood" 1 "'geen-sha' is geen sha256 uit helm-${helm_patch}-linux-amd64.tar.gz.sha256sum" "$uit" "$rc"

d="$(k8s_map)"; helm_geval "$d" "x${sha_a}" "$sha_b" "$(helm_release "${helm_patch}")" "$(helm_release "${helm_nu}")"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: checksum met voorvoegsel wordt rood" 1 "'x${sha_a}' is geen sha256" "$uit" "$rc"

d="$(k8s_map)"; helm_geval "$d" "$sha_a" "" "$(helm_release "${helm_patch}")" "$(helm_release "${helm_nu}")"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: lege checksum wordt rood" 1 "'' is geen sha256 uit helm-${helm_patch}-linux-arm64" "$uit" "$rc"

# Een checksum-bestand van een andere tarball mag niet als deze gepind worden.
d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b" "$(helm_release "${helm_patch}")" "$(helm_release "${helm_nu}")"
stub "$d" curl "printf '%s  helm-v0.0.1-linux-amd64.tar.gz\n' '${sha_a}'"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: checksum van een andere tarball wordt rood" 1 "is geen sha256 uit helm-${helm_patch}-linux-amd64" "$uit" "$rc"

d="$(k8s_map)"; helm_geval "$d" "$sha_a" "$sha_b" "$(helm_release "${helm_patch}")" "$(helm_release "${helm_nu}")"; rm "$d/sum-arm64.txt"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: mislukte checksum-download wordt rood" 1 "kon de checksum van helm-${helm_patch}-linux-arm64.tar.gz niet ophalen" "$uit" "$rc"
cmp -s "${wortel}/claude-sandbox/Dockerfile" "$d/ws/claude-sandbox/Dockerfile"
controle "helm: mislukte checksum-download laat de Dockerfile ongemoeid" $?

for arch in amd64 arm64; do
  d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
  sed -i "s|      ${arch}) HELM_SHA=|      ${arch})   HELM_SHA=|" "$d/ws/claude-sandbox/Dockerfile"
  grep -q "${arch})   HELM_SHA=" "$d/ws/claude-sandbox/Dockerfile"
  controle "helm: fixture hertabelleert de ${arch}-regel" $?
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: hertabelleerde ${arch}-regel blijft werken" 0 "" "$uit" "$rc"
  vervangingen "helm: hertabelleerde ${arch}-regel geeft drie vervangingen" "$uit" 3

  d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
  sed -i "s|${arch}) HELM_SHA=\([a-f0-9]*\)|${arch}) HELM_SHA=\1a|" "$d/ws/claude-sandbox/Dockerfile"
  grep -qE "${arch}\) HELM_SHA=[a-f0-9]{65} " "$d/ws/claude-sandbox/Dockerfile"
  controle "helm: fixture verlengt de ${arch}-pin" $?
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: ${arch}-pin van 65 tekens wordt rood" 1 "precies één ${arch}-SHA-pin voor helm" "$uit" "$rc"

  d="$(k8s_map)"; helm_standaard "$d" "${helm_nu}"
  sed -i "s|      ${arch}) HELM_SHA=[a-f0-9]*|      ${arch}) HELM_SHA=|" "$d/ws/claude-sandbox/Dockerfile"
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: ontbrekende ${arch}-pin wordt ook zonder bump rood" 1 "precies één ${arch}-SHA-pin voor helm" "$uit" "$rc"

  d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
  dubbele_pin "$d" "              ${arch}) HELM_SHA=" "              ${arch}) HELM_SHA=${sha_b} ;; \\\\"
  uit="$(draai "$d" helm-version)"; rc=$?
  toets "helm: tweede ${arch}-pin wordt rood" 1 "precies één ${arch}-SHA-pin voor helm" "$uit" "$rc"
done

d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
dubbele_pin "$d" '            HELM_VERSION=' '            HELM_VERSION=v4.0.0 && \\'
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: tweede versiepin wordt rood" 1 "precies één HELM_VERSION-pin" "$uit" "$rc"

d="$(k8s_map)"; helm_standaard "$d" "${helm_patch}"
sed -i "s|HELM_VERSION=${helm_nu}|HELM_VERSION=latest|" "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: onleesbare versiepin wordt rood" 1 "kon huidige HELM_VERSION niet" "$uit" "$rc"

d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.99.0"
sed -i "s|helm ${helm_mm} (|helm 0.0 (|" "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: README-vermelding achtergebleven wordt rood" 1 "'helm ${helm_mm} (' komt 0× voor in README.md" "$uit" "$rc"

d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.99.0"
sed -i "s|\`helm\` (${helm_mm})|\`helm\` (0.0)|" "$d/ws/claude-sandbox/docs/kubernetes.md"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: vermelding in docs/kubernetes.md achtergebleven wordt rood" 1 "'\`helm\` (${helm_mm})' komt 0× voor in docs/kubernetes.md" "$uit" "$rc"

# Alleen de helm-vermelding verschuift: hetzelfde getal elders blijft staan,
# en zonder vermelding wordt de run rood in plaats van een ander getal te raken.
d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.99.0"
printf 'Python 3.%s\n' "${helm_mm}" >> "$d/ws/claude-sandbox/README.md"
printf 'Zie ook versie %s.\n' "${helm_mm}" >> "$d/ws/claude-sandbox/docs/kubernetes.md"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: ander voorkomen van ${helm_mm} houdt de minor-sprong niet tegen" 0 "" "$uit" "$rc"
grep -qxF "Python 3.${helm_mm}" "$d/ws/claude-sandbox/README.md" \
  && grep -qF "helm ${helm_major#v}.99 (" "$d/ws/claude-sandbox/README.md" \
  && grep -qxF "Zie ook versie ${helm_mm}." "$d/ws/claude-sandbox/docs/kubernetes.md" \
  && grep -qF "\`helm\` (${helm_major#v}.99)" "$d/ws/claude-sandbox/docs/kubernetes.md"
controle "helm: alleen de helm-vermelding verschoven" $?

d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.99.0"
sed -i "s|helm ${helm_mm} (|helm (|" "$d/ws/claude-sandbox/README.md"
printf 'Python 3.%s\n' "${helm_mm}" >> "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: zonder vermelding blijft een ander getal staan" 1 "'helm ${helm_mm} (' komt 0× voor in README.md" "$uit" "$rc"
grep -qxF "Python 3.${helm_mm}" "$d/ws/claude-sandbox/README.md"
controle "helm: zonder vermelding is het andere getal ongemoeid" $?

d="$(k8s_map)"; helm_standaard "$d" "${helm_major}.99.0"
printf 'Ook helm %s (tweede vermelding).\n' "${helm_mm}" >> "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" helm-version)"; rc=$?
toets "helm: dubbele README-vermelding wordt rood" 1 "'helm ${helm_mm} (' komt 2× voor in README.md" "$uit" "$rc"

# Elke tool heeft een eigen blok in de Dockerfile. Raken de bumps aangrenzende
# regels, dan conflicteren hun auto-PR's bij de tweede merge.
dk="$(k8s_map)"; kubectl_geval "$dk" "$kubectl_patch" "$kubectl_patch" "$sha_a" "$sha_b"
draai "$dk" kubectl-version >/dev/null
dh="$(k8s_map)"; helm_standaard "$dh" "${helm_major}.99.0"
draai "$dh" helm-version >/dev/null
for bestand in Dockerfile README.md docs/kubernetes.md; do
  samen="$(diff3 -m "$dk/ws/claude-sandbox/${bestand}" "${wortel}/claude-sandbox/${bestand}" "$dh/ws/claude-sandbox/${bestand}")"
  [ $? -eq 0 ] && ! grep -q '^<<<<<<<' <<<"${samen}"
  controle "kubectl- en helm-bump mergen zonder conflict in ${bestand}" $?
done
grep -qF "KUBECTL_VERSION=${kubectl_patch}" "$dk/ws/claude-sandbox/Dockerfile" \
  && grep -qF "HELM_VERSION=${helm_major}.99.0" "$dh/ws/claude-sandbox/Dockerfile"
controle "conflictproef: beide bumps zijn echt uitgevoerd" $?

# De vaste delen van beide PR's: de poort op changed, branch, commit, titel,
# de SHA-regels, de suppressie-oproep en de waarschuwing dat een PR van
# GITHUB_TOKEN geen checks start.
for tool in kubectl helm; do
  job=".jobs.\"${tool}-version\""
  stap="${job}.steps[] | select(.with.body != null)"
  body="$(yq "${stap} | .with.body" "${workflow}")"
  r=1
  if [ "$(yq "${stap} | .if" "${workflow}")" = "steps.compare.outputs.changed == 'true'" ] \
     && [ "$(yq "${job}.steps[] | select(has(\"run\")) | .id" "${workflow}")" = "compare" ]; then r=0; fi
  controle "${tool}: de PR-stap hangt aan changed van de compare-stap" "$r"
  r=1
  if [ "$(yq "${stap} | .with.branch" "${workflow}")" = "deps/${tool}" ] \
     && [ "$(yq "${stap} | .with.title" "${workflow}")" = "chore(deps): bump ${tool} naar \${{ steps.compare.outputs.latest }}" ] \
     && [ "$(yq "${stap} | .with.commit-message" "${workflow}")" = "chore(deps): bump ${tool} naar \${{ steps.compare.outputs.latest }}" ]; then r=0; fi
  controle "${tool}: branch, titel en commit-message van de PR" "$r"
  grep -qxF -- "- **SHA amd64:** \`\${{ steps.compare.outputs.amd64 }}\`" <<<"${body}" \
    && grep -qxF -- "- **SHA arm64:** \`\${{ steps.compare.outputs.arm64 }}\`" <<<"${body}"
  controle "${tool}: de SHA-regels in de PR-body wijzen naar hun eigen architectuur" $?
  tr '\n' ' ' <<<"${body}" | grep -qF "suppressie op \`usr/local/bin/${tool}\` die deze release oplost, haal die dan weg" \
    && tr '\n' ' ' <<<"${body}" | grep -qF 'door `GITHUB_TOKEN` geopend en start daardoor geen workflow-runs'
  controle "${tool}: suppressie-oproep en GITHUB_TOKEN-zin in de PR-body" $?
  [ "$(yq "${job}.steps[0].with.persist-credentials" "${workflow}")" = "false" ]
  controle "${tool}: de checkout bewaart geen credentials" $?
done

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
