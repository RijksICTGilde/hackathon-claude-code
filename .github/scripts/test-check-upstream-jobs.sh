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
npm_nu="$(lees_pin NPM_VERSION)"
npm_major="${npm_nu%%.*}"

for waarde in "${rtk_nu}" "${delta_nu}" "${node_nu}" "${npm_nu}"; do
  if [ -z "${waarde}" ]; then
    echo "FOUT: kon niet alle pins uit de Dockerfile lezen"
    exit 1
  fi
done

for job in vendored-scripts rtk-version delta-version node-version npm-version apt-security-refresh; do
  yq ".jobs.\"${job}\".steps[] | select(has(\"run\")) | .run" "${workflow}" > "${werkmap}/${job}.sh"
  # Precies één run-blok: `yq` plakt er anders meerdere achter elkaar en dan
  # draait de fixture een script dat geen enkele stap zo uitvoert.
  # apt-security-refresh heeft meerdere run-stappen; daarvan wordt alleen de
  # beslisstap los getoetst.
  verwacht_blokken=1
  [ "${job}" = apt-security-refresh ] && verwacht_blokken=3

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
vervangingen "node: drie vervangingen" "$uit" 3

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
if [ "\$1" = update ]; then exit 0; fi
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

d="$(epoch_map)"; epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: fix beschikbaar levert een verversing" 0 "kandidaat 2.41-5+deb13u1 dekt" "$uit" "$rc"
geopend "epoch: fix beschikbaar zet changed=true" "$d"
grep -q 'reason=.*nu op te halen' "$d/uitvoer"
controle "epoch: de aanleiding noemt de beschikbare fix" $?

d="$(epoch_map)"; epoch_geval "$d" "$cve_te_nieuw" "$pakketten" "$policy_met_update"
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

d="$(epoch_map)"; epoch_geval "$d" '[]' "$pakketten" "$policy_arm" "" "" "$arm_cve" "$arm_pakketten"
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
grep -qF '$(SITE)' "$d/docker-argumenten.txt"
controle "epoch: de format-string bereikt apt onuitgevoerd" $?

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

# De uitsluitingslijst moet spiegelen wat de Dockerfile buiten apt om installeert.
d="$(epoch_map)"
sed -i 's|^    dpkg -i /tmp/git-delta.deb|    dpkg -i /tmp/iets-anders.deb \&\& dpkg -i /tmp/git-delta.deb|' \
  "$d/ws/claude-sandbox/Dockerfile"
epoch_geval "$d" "$cve_bevinding" "$pakketten" "$policy_met_update"
uit="$(epoch_draai "$d")"; rc=$?
toets "epoch: een tweede dpkg-installatie zonder uitsluiting wordt rood" 1 "buiten apt om, BUITEN_APT_LAAG noemt er" "$uit" "$rc"

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
  'git-delta:\n  Installed: 0.19.2\n  Candidate: 0.18.2-4+b1\nutil-linux:\n  Installed: 2.41-5\n  Candidate: 2.41-5\n'
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

echo "---- ${geslaagd} geslaagd, ${gefaald} gefaald ----"
[ "${gefaald}" -eq 0 ]
