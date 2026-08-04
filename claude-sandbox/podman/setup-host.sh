#!/usr/bin/env bash
# Host-setup voor rootless Podman-in-Docker (issue #44).
# Laadt een AppArmor-profiel dat ALLEEN de sandbox-container userns laat
# gebruiken, zodat de host-hardening (apparmor_restrict_unprivileged_userns)
# systeembreed aan kan blijven. Het profiel is afgeleid van docker-default
# (flags=(attach_disconnected,mediate_deleted)) en mediateert dus echt; op
# niet-gehardende hosts is het onschadelijk maar we laden het altijd zodat de
# compose-override consistent naar `apparmor=claude-sandbox-podman` kan verwijzen.
#
# Draai dit op de HOST (niet in de container). Vereist sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_SRC="$SCRIPT_DIR/apparmor/claude-sandbox-podman"
PROFILE_DST="/etc/apparmor.d/claude-sandbox-podman"

echo "== Host-setup: rootless Podman-in-Docker =="

# 1. Kernel-devices: /dev/fuse (fuse-overlayfs storage) en /dev/net/tun (rootless
# netwerk-tap). Ontbreken ze, dan proberen we de module te laden.
ensure_device() {
    local dev="$1" mod="$2"
    if [[ -e "$dev" ]]; then
        echo "✓ $dev aanwezig"
    else
        echo "• $dev ontbreekt → 'sudo modprobe $mod'…"
        if sudo modprobe "$mod" 2>/dev/null && [[ -e "$dev" ]]; then
            echo "✓ $dev nu aanwezig"
        else
            echo "✗ $dev nog steeds afwezig — kernel mist '$mod'. Zie README-fallbacks." >&2
        fi
    fi
}
ensure_device /dev/fuse fuse
ensure_device /dev/net/tun tun

# 2. userns-hardening melden (informatief)
RESTRICT="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
if [[ "$RESTRICT" == "1" ]]; then
    echo "• kernel.apparmor_restrict_unprivileged_userns=1 → AppArmor-profiel is hier VEREIST."
else
    echo "• userns niet afgehard (sysctl=$RESTRICT) → profiel niet strikt nodig, wel onschadelijk."
fi

# 3. AppArmor-profiel laden
if ! command -v apparmor_parser >/dev/null 2>&1; then
    if [[ "$RESTRICT" == "1" ]]; then
        echo "✗ apparmor_parser ontbreekt terwijl de host userns afhardt." >&2
        echo "  Installeer 'apparmor-utils', of (minder veilig) zet de sysctl op 0." >&2
        exit 1
    fi
    echo "• Geen AppArmor op deze host — zet in de override apparmor=unconfined i.p.v." \
         "het profiel (zie README)."
    exit 0
fi

# Valideer wat we straks als root in de kernel laden tegen een GEPINDE HASH.
# `apparmor_parser -r` vervangt élk profielblok in het bestand op naam — een
# toegevoegd blok kan een ander host-profiel vervangen, een weggehaalde deny-regel
# opent onze eigen /proc/sys-escape. Structuur-greps vangen dat niet volledig: het
# is een flex/bison-grammatica, geen regex, en drie ronden hardening lieten elk
# een nieuwe randvorm door (keyword-loos blok, mode zonder flags=, blok op één
# regel, verwijderde deny). Een hash sluit ze allemaal in één keer: hij garandeert
# "dit is exact het gereviewde profiel".
#
# LET OP — dit blijft defense-in-depth. Ligt dit script (of het profiel) in een
# map die de sandbox kan schrijven (bv. de repo onder PROJECTS_DIR), dan kan de
# agent zowel het profiel ALS deze gepinde hash aanpassen. De sluitende maatregel
# is setup-host.sh vanuit een niet-agent-schrijfbare checkout draaien (zie de
# security-noot in docs/adr/0001-...md). De hash verhoogt wél de zichtbaarheid:
# een gewijzigde hash in de diff is een expliciet signaal; een weggehaalde
# deny-regel is dat niet.
#
# BEWUSTE PROFIELWIJZIGING? Werk PROFILE_SHA hieronder bij en commit het profiel
# én de hash in dezelfde commit, zodat de wijziging in review zichtbaar is.
PROFILE_SHA="f1eeda5a9ed27e234794d483edc7bcfb9364ae7c71c0f198901c6a4f083314a9"
actual_sha="$(sha256sum "$PROFILE_SRC" | cut -d' ' -f1)"
if [[ "$actual_sha" != "$PROFILE_SHA" ]]; then
    echo "✗ $PROFILE_SRC wijkt af van de gepinde, gereviewde versie." >&2
    echo "  Verwacht: $PROFILE_SHA" >&2
    echo "  Gevonden: $actual_sha" >&2
    echo "  Bewust gewijzigd? Werk PROFILE_SHA in dit script bij en commit beide samen." >&2
    echo "  Zo niet: het profiel is buiten review om aangepast — laad het NIET." >&2
    exit 1
fi

echo "→ profiel laden: $PROFILE_SRC → $PROFILE_DST"
sudo install -m 0644 "$PROFILE_SRC" "$PROFILE_DST"
if ! sudo apparmor_parser -r -W "$PROFILE_DST" 2>/tmp/aa-err; then
    # Oudere AppArmor kent `abi <abi/4.0>,` niet → parse-fout. Strip die regel en
    # probeer opnieuw; de userns-regel werkt ook zonder de abi-declaratie.
    if grep -q 'abi' /tmp/aa-err 2>/dev/null || grep -q '^abi ' "$PROFILE_DST"; then
        echo "• apparmor_parser faalde; abi-regel strippen en opnieuw proberen…" >&2
        sudo sed -i '/^abi /d' "$PROFILE_DST"
        sudo apparmor_parser -r -W "$PROFILE_DST"
    else
        cat /tmp/aa-err >&2
        rm -f /tmp/aa-err
        exit 1
    fi
fi
rm -f /tmp/aa-err
echo "✓ profiel 'claude-sandbox-podman' geladen."
echo
echo "Start nu de sandbox met de podman-override:"
echo "  docker compose -f compose.yml -f compose.override.podman-linux.yml up -d --force-recreate"
echo
echo "Breekt podman hierna op een AppArmor-weigering, zet het profiel dan tijdelijk"
echo "in klaagmodus en kijk wat er geweigerd wordt:"
echo "  sudo aa-complain $PROFILE_DST"
echo "  sudo dmesg | grep -i 'apparmor.*DENIED'"
echo "  sudo aa-enforce $PROFILE_DST"
echo "== klaar =="
