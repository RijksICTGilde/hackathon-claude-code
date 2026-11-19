#!/bin/bash
set -euo pipefail

# Weigert een kubeconfig die meer meegeeft dan één token. De sandbox hoort een
# eigen kubeconfig te krijgen met alleen een kortlevend token voor een eigen
# ServiceAccount (docs/kubernetes.md). Een eigen ~/.kube/config bevat vaak
# beheerdersgegevens of een exec-plugin die langlevende sessies van de host
# aanspreekt; die horen niet in de sandbox, ook niet read-only.
#
# Gebruik: controleer-kubeconfig.sh <kubeconfig>

bestand="${1:?gebruik: controleer-kubeconfig.sh <kubeconfig>}"
advies="Mount de aparte kubeconfig uit claude-sandbox/docs/kubernetes.md, niet je eigen ~/.kube/config."

if ! command -v kubectl >/dev/null 2>&1; then
    echo "FOUT: kubectl ontbreekt; bouw de image met INSTALL_FUNDAMENT=true." >&2
    exit 1
fi
# Docker en podman maken een bronpad dat bij de start ontbreekt aan als lege map.
if [[ -d "$bestand" ]]; then
    echo "FOUT: kubeconfig $bestand is een map, geen bestand. Het bestand in SANDBOX_KUBECONFIG ontbrak bij een eerdere start; verwijder op de host de lege map op dat pad, schrijf de kubeconfig, en start opnieuw met docker compose down en up." >&2
    exit 1
fi
if [[ ! -r "$bestand" ]]; then
    echo "FOUT: kubeconfig $bestand is niet leesbaar." >&2
    exit 1
fi

# kubectl leest de YAML- en de JSON-vorm. Zonder --raw vervangt hij de waarden
# van sleutels en tokens door een placeholder; de namen, waar de controle op
# toetst, blijven staan.
if ! json=$(kubectl config view --kubeconfig "$bestand" -o json 2>&1); then
    echo "FOUT: kubeconfig $bestand is niet te lezen: $json" >&2
    exit 1
fi

# Leeg betekent goedgekeurd; anders één regel per reden.
redenen=$(jq -r '
  def aantal(v): (v // []) | length;
  [
    (if aantal(.users) != 1 then "\(aantal(.users)) gebruikers in plaats van 1" else empty end),
    (if aantal(.clusters) != 1 then "\(aantal(.clusters)) clusters in plaats van 1" else empty end),
    (if aantal(.contexts) != 1 then "\(aantal(.contexts)) contexts in plaats van 1" else empty end),
    ((.users // [])[] | .user // {} | keys[] | select(. != "token") | "gegevens anders dan een token: \(.)"),
    ((.users // [])[] | select((.user.token // "") == "") | "gebruiker \(.name) heeft geen token")
  ] | unique | .[]
' <<<"$json")

if [[ -n "$redenen" ]]; then
    {
        echo "FOUT: kubeconfig $bestand geeft de sandbox meer dan één token:"
        while IFS= read -r reden; do echo "  - $reden"; done <<<"$redenen"
        # De kubeconfig van Fundament roept functl aan; daarvoor is deze mount
        # niet bedoeld.
        if jq -e 'any(.users[]?; .user.exec.command? == "functl")' <<<"$json" >/dev/null; then
            echo "Dit is een kubeconfig van Fundament: log daarvoor in de sandbox in met functl, zonder deze mount (claude-sandbox/docs/fundament.md)."
        else
            echo "$advies"
        fi
    } >&2
    exit 1
fi

# Vanaf hier geen oordeel meer over de kubeconfig zelf, maar over de vraag of de
# firewall de API-server erin doorlaat. Een waarschuwing en geen fout: een
# cluster op het netwerk van de sandbox heeft ALLOWED_K8S_API niet nodig, en een
# mismatch is daar dus geen misconfiguratie.
server=$(jq -r '.clusters[0].cluster.server // ""' <<<"$json")
[ -n "$server" ] || exit 0

schema="${server%%://*}"
adres="${server#*://}"
adres="${adres%%/*}"
case "$adres" in
    # De firewall zet alle IPv6 dicht, dus hier helpt geen enkele allowlist.
    *\[*|*:*:*)
        echo "WAARSCHUWING: de kubeconfig wijst naar een IPv6-adres ($server). De sandbox blokkeert IPv6 volledig; kubectl zal 'no route to host' geven." >&2
        exit 0 ;;
    *:*) api_host="${adres%:*}"; api_poort="${adres##*:}" ;;
    *)   api_host="$adres"
         if [ "$schema" = http ]; then api_poort=80; else api_poort=443; fi ;;
esac
[[ "$api_poort" =~ ^[0-9]{1,5}$ ]] || exit 0
api_poort=$((10#$api_poort))

# Poort 443 valt onder OPEN_HTTPS en ALLOWED_DOMAINS, niet onder ALLOWED_K8S_API.
# Daar hier over waarschuwen zou naar de verkeerde variabele wijzen.
if [ "$api_poort" = 443 ]; then
    exit 0
fi

ip_naar_getal() { # a.b.c.d -> geheel getal
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

# Het subnet van de sandbox krijgt een ongeclausuleerde ACCEPT in de firewall.
# Een cluster daarbinnen — k3d met --network op het sandbox-netwerk — is dus al
# bereikbaar, op elke poort, zonder ALLOWED_K8S_API.
in_eigen_subnet() {
    local ip="$1" cidr net bits getal netgetal masker
    command -v ip >/dev/null 2>&1 || return 1
    getal=$(ip_naar_getal "$ip")
    while read -r cidr; do
        [ -n "$cidr" ] || continue
        [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] || continue
        net="${cidr%/*}"
        bits="${cidr#*/}"
        if [ "$bits" -eq 0 ]; then masker=0; else masker=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF )); fi
        netgetal=$(ip_naar_getal "$net")
        if [ $(( getal & masker )) -eq $(( netgetal & masker )) ]; then
            return 0
        fi
    done < <(ip -o route show scope link 2>/dev/null | awk '{print $1}')
    return 1
}

if [[ "$api_host" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    api_ips="$api_host"
else
    api_ips=$(dig +short +timeout=5 +tries=1 A "$api_host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
fi
while read -r api_ip; do
    [ -n "$api_ip" ] || continue
    if in_eigen_subnet "$api_ip"; then
        exit 0
    fi
done <<<"$api_ips"

toegestaan="${ALLOWED_K8S_API:-}"
# Poort apart vergelijken: `:06443` en `:6443` zijn voor de firewall dezelfde
# poort, en een waarschuwing over dat verschil zou naar niets wijzen.
if [[ "$toegestaan" == *:* && "${toegestaan##*:}" =~ ^[0-9]{1,5}$ ]]; then
    toegestaan="${toegestaan%:*}:$((10#${toegestaan##*:}))"
fi
if [ -z "$toegestaan" ]; then
    echo "WAARSCHUWING: de kubeconfig wijst naar ${api_host}:${api_poort}, buiten het netwerk van de sandbox, en ALLOWED_K8S_API is niet gezet. De firewall weigert dat adres; kubectl zal 'no route to host' geven. Zet ALLOWED_K8S_API=${api_host}:${api_poort} in .env en recreate de container (claude-sandbox/docs/kubernetes.md)." >&2
elif [ "$toegestaan" != "${api_host}:${api_poort}" ]; then
    echo "WAARSCHUWING: de kubeconfig wijst naar ${api_host}:${api_poort}, maar ALLOWED_K8S_API staat op ${toegestaan}. De firewall weigert het adres uit de kubeconfig; kubectl zal 'no route to host' geven." >&2
fi
