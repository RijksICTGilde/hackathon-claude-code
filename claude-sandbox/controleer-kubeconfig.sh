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
    echo "FOUT: kubectl ontbreekt; bouw de image met INSTALL_K8S=true." >&2
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
        echo "$advies"
    } >&2
    exit 1
fi
