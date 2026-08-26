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

for job in rtk-version delta-version node-version npm-version; do
  yq ".jobs.\"${job}\".steps[] | select(has(\"run\")) | .run" "${workflow}" > "${werkmap}/${job}.sh"
  if [ ! -s "${werkmap}/${job}.sh" ]; then
    echo "FOUT: geen run-blok gevonden voor ${job}"
    exit 1
  fi
done

nieuwe_map() { # -> map met een kopie van claude-sandbox en een stub-PATH
  local d; d="$(mktemp -d "${werkmap}/geval-XXXXXX")"
  mkdir -p "${d}/ws/.github/scripts" "${d}/ws/claude-sandbox/vendor/install-scripts" "${d}/bin"
  cp "${wortel}/.github/scripts/vervang-pin.sh" "${d}/ws/.github/scripts/"
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
npm_stub='printf "{\"versions\":{\"11.19.0\":{},\"11.20.0\":{},\"12.0.0\":{}}}\n"'

# ── rtk ──
d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: bump verzet Dockerfile en README" 0 "README.md: v0.45.0 -> v0.99.0" "$uit" "$rc"
grep -q 'echo nieuw' "$d/ws/claude-sandbox/vendor/install-scripts/rtk.sh"; controle "rtk: vendored script vervangen" $?

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
sed -i 's|rtk-ai/rtk/v0.45.0/install.sh|rtk-ai/rtk/vOUD/install.sh|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: herkomst-URL achtergebleven wordt rood" 1 "komt 0× voor" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
sed -i 's|`rtk` v0.45.0|`rtk` vOUD|' "$d/ws/claude-sandbox/README.md"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: README-vermelding achtergebleven wordt rood" 1 "komt 0× voor" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.45.0'; stub "$d" curl 'true'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: gelijke versie opent niets" 0 "" "$uit" "$rc"
grep -q 'changed=false' "$d/uitvoer"; controle "rtk: changed=false bij gelijke versie" $?

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
dubbele_pin "$d" 'RUN case "$INSTALL_RTK" in' '      oud) RTK_VERSION=v0.44.0 sh /tmp/rtk-install.sh ;; \\'
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: tweede pin wordt rood" 1 "precies één RTK_VERSION-pin" "$uit" "$rc"

# ── delta ──
d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'; stub "$d" curl "$deb_stub"
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: bump verzet versie en beide SHAs" 0 "DELTA_VERSION=0.19.2 -> DELTA_VERSION=0.99.9" "$uit" "$rc"

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
dubbele_pin "$d" 'RUN DELTA_VERSION=0.19.2' 'RUN DELTA_VERSION=0.18.2 \'
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: tweede pin wordt rood" 1 "precies één DELTA_VERSION-pin" "$uit" "$rc"

# ── node ──
d="$(nieuwe_map)"; stub "$d" curl "$node_stub"
uit="$(draai "$d" node-version)"; rc=$?
toets "node: bump verzet versie en beide SHAs" 0 "NODE_VERSION=v24.19.0 -> NODE_VERSION=v99.0.0" "$uit" "$rc"

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
dubbele_pin "$d" 'RUN NODE_VERSION=v24.19.0' 'RUN NODE_VERSION=v22.11.0 \'
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

d="$(nieuwe_map)"; stub "$d" gh 'echo 0.99.9'
stub "$d" curl 'while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { shift; printf "<html>proxy</html>\n" > "$1"; }; shift; done'
uit="$(draai "$d" delta-version)"; rc=$?
toets "delta: download die geen .deb is wordt rood" 1 "geen .deb-archief" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" gh 'echo v0.99.0'; stub "$d" curl "$script_stub"
sed -i 's|# afkomstig van https://raw.githubusercontent.com/rtk-ai/rtk/v0.45.0/install.sh|# afkomstig van https://raw.githubusercontent.com/rtk-ai/rtk/v0.44.0/install.sh|' "$d/ws/claude-sandbox/Dockerfile"
uit="$(draai "$d" rtk-version)"; rc=$?
toets "rtk: herkomst-URL op een andere tag wordt rood" 1 "komt 0× voor" "$uit" "$rc"

# ── npm ──
d="$(nieuwe_map)"; stub "$d" curl "$npm_stub"
uit="$(draai "$d" npm-version)"; rc=$?
toets "npm: bump binnen dezelfde major" 0 "NPM_VERSION=11.19.0 -> NPM_VERSION=11.20.0" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl 'printf "{\"versions\":{}}\n"'
uit="$(draai "$d" npm-version)"; rc=$?
toets "npm: geen versie binnen major wordt rood" 1 "kon laatste npm-versie" "$uit" "$rc"

d="$(nieuwe_map)"; stub "$d" curl "$npm_stub"
dubbele_pin "$d" 'RUN NPM_VERSION=11.19.0' 'RUN NPM_VERSION=10.9.4 \'
uit="$(draai "$d" npm-version)"; rc=$?
toets "npm: tweede pin wordt rood" 1 "precies één NPM_VERSION-pin" "$uit" "$rc"

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
