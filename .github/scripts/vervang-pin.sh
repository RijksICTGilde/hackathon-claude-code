#!/usr/bin/env bash
# Vervangt een pin in een bestand en controleert dat het ook echt gebeurd is.
#
# `sed -i` meldt exit 0 bij nul substituties. Een auto-PR die daarop vertrouwt
# opent een voorstel dat zegt drie plekken te hebben bijgewerkt terwijl er één
# is bijgewerkt — en de plek die stil achterbleef is meestal de herkomst- of
# checksum-verwijzing, precies wat de bump controleerbaar maakt.
#
#   vervang-pin.sh <bestand> <oude-waarde> <nieuwe-waarde> [verwacht-aantal]
set -euo pipefail

bestand="${1:?bestand ontbreekt}"
oud="${2:?oude waarde ontbreekt}"
nieuw="${3:?nieuwe waarde ontbreekt}"
verwacht="${4:-1}"

[ -f "${bestand}" ] || {
  echo "FOUT: ${bestand} bestaat niet." >&2
  exit 1
}

# Beide waarden belanden in een sed-expressie. `&` en `\1` in de vervanging en
# metatekens in het patroon zouden het bestand stil corrumperen, dus alleen
# tekens toelaten die in een versie, checksum of URL voorkomen.
for waarde in "${oud}" "${nieuw}"; do
  case "${waarde}" in
    *[!A-Za-z0-9._/:=-]*)
      echo "FOUT: '${waarde}' bevat een teken dat hier niet is toegestaan." >&2
      exit 1 ;;
  esac
done

if [ "${oud}" = "${nieuw}" ]; then
  echo "FOUT: oude en nieuwe waarde zijn gelijk ('${oud}'); er valt niets te vervangen." >&2
  exit 1
fi

gevonden="$(grep -cF -- "${oud}" "${bestand}" || true)"
if [ "${gevonden}" != "${verwacht}" ]; then
  echo "FOUT: '${oud}' komt ${gevonden}× voor in ${bestand}, verwacht ${verwacht}×." >&2
  exit 1
fi

sed -i "s|${oud}|${nieuw}|g" "${bestand}"

if grep -qF -- "${oud}" "${bestand}"; then
  echo "FOUT: '${oud}' staat nog in ${bestand} na de vervanging." >&2
  exit 1
fi

na="$(grep -cF -- "${nieuw}" "${bestand}" || true)"
if [ "${na}" != "${verwacht}" ]; then
  echo "FOUT: '${nieuw}' komt ${na}× voor in ${bestand} na de vervanging, verwacht ${verwacht}×." >&2
  exit 1
fi

echo "${bestand}: ${oud} -> ${nieuw} (${verwacht}×)"
