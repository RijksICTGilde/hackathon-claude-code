#!/usr/bin/env bash
# Fixtures voor claude-sandbox/controleer-kubeconfig.sh. Vereist kubectl en jq.
set -uo pipefail

hier="$(cd "$(dirname "$0")" && pwd)"
controle="${hier}/../../claude-sandbox/controleer-kubeconfig.sh"
werkmap="$(mktemp -d)"
trap 'rm -rf "${werkmap}"' EXIT

for nodig in kubectl jq; do
  if ! command -v "${nodig}" >/dev/null 2>&1; then
    echo "FOUT: ${nodig} ontbreekt; deze fixtures draaien de echte kubectl" >&2
    exit 1
  fi
done

geslaagd=0
gefaald=0

resultaat() { # naam verwachte_exitcode werkelijke_exitcode [extra_fout]
  if [ "$3" -eq "$2" ] && [ -z "${4:-}" ]; then
    echo "ok   $1"
    geslaagd=$((geslaagd + 1))
  else
    echo "FOUT $1: exitcode $3, verwacht $2${4:+; $4}"
    gefaald=$((gefaald + 1))
  fi
}

toets() { # naam verwachte_exitcode inhoud
  local naam="$1" verwacht="$2" bestand="${werkmap}/config" rc=0 extra=""
  printf '%s' "$3" > "${bestand}"
  "${controle}" "${bestand}" > "${werkmap}/uit" 2> "${werkmap}/fout" || rc=$?
  if [ -s "${werkmap}/uit" ]; then
    extra="schreef naar stdout"
  # Een WAARSCHUWING hoort bij exitcode 0: de kubeconfig is goedgekeurd, maar de
  # API-server erin is mogelijk niet bereikbaar. Al het andere op stderr is fout.
  elif [ "${verwacht}" -eq 0 ] && grep -qv '^WAARSCHUWING:' "${werkmap}/fout"; then
    extra="schreef naar stderr: $(grep -v '^WAARSCHUWING:' "${werkmap}/fout" | head -1)"
  elif [ "${verwacht}" -ne 0 ] && ! grep -q 'docs/kubernetes.md' "${werkmap}/fout" \
       && ! grep -q '^FOUT: kubeconfig .* is niet te lezen' "${werkmap}/fout"; then
    extra="geen verwijzing naar docs/kubernetes.md"
  fi
  resultaat "${naam}" "${verwacht}" "${rc}" "${extra}"
}

# Een kubeconfig zoals het recept in docs/kubernetes.md hem schrijft.
kop='apiVersion: v1
kind: Config
clusters:
- name: sandbox
  cluster:
    server: https://k3d-sandbox-server-0:6443
    certificate-authority-data: Y2E=
contexts:
- name: sandbox
  context:
    cluster: sandbox
    user: sandbox
    namespace: team-a
current-context: sandbox
'
recept="${kop}users:
- name: sandbox
  user:
    token: abc.def.ghi
"
met_gebruiker() { # extra regels onder user:
  printf '%susers:\n- name: sandbox\n  user:\n%s\n' "${kop}" "$1"
}

toets "recept: alleen een token"            0 "${recept}"
toets "JSON-vorm met alleen een token"      0 '{"apiVersion":"v1","kind":"Config","clusters":[{"name":"c","cluster":{"server":"https://c:6443"}}],"users":[{"name":"u","user":{"token":"t"}}],"contexts":[{"name":"x","context":{"cluster":"c","user":"u"}}],"current-context":"x"}'
toets "clientcertificaat"                   1 "$(met_gebruiker '    client-certificate-data: Y2VydA==
    client-key-data: a2V5')"
toets "token plus clientsleutel"            1 "$(met_gebruiker '    token: t
    client-key-data: a2V5')"
toets "clientcertificaat als bestandspad"   1 "$(met_gebruiker '    client-certificate: /etc/cert.pem
    client-key: /etc/key.pem')"
toets "exec-plugin"                         1 "$(met_gebruiker '    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: gke-gcloud-auth-plugin')"
toets "auth-provider"                       1 "$(met_gebruiker '    auth-provider:
      name: oidc')"
toets "gebruikersnaam en wachtwoord"        1 "$(met_gebruiker '    username: admin
    password: geheim')"
toets "tokenFile"                           1 "$(met_gebruiker '    tokenFile: /var/run/token')"
toets "impersonatie naast token"            1 "$(met_gebruiker '    token: t
    as: system:admin')"
toets "leeg token"                          1 "$(met_gebruiker '    token: ""')"
toets "gebruiker zonder gegevens"           1 "$(met_gebruiker '    {}')"
toets "geen gebruikers"                     1 "${kop}"
toets "tweede gebruiker met beheerrechten"  1 "${recept}- name: admin
  user:
    client-key-data: a2V5
"
twee_contexts="${recept/contexts:
- name: sandbox/contexts:
- name: ander
  context:
    cluster: sandbox
    user: sandbox
- name: sandbox}"
toets "tweede context"                      1 "${twee_contexts}"
twee_clusters="${recept/clusters:
- name: sandbox/clusters:
- name: ander
  cluster:
    server: https://ander:6443
- name: sandbox}"
toets "tweede cluster"                      1 "${twee_clusters}"
toets "geen geldige YAML"                   1 'clusters: [niet: gesloten'

# Een bestand dat niet bestaat.
rc=0
"${controle}" "${werkmap}/bestaat-niet" >/dev/null 2>"${werkmap}/fout" || rc=$?
extra=""
grep -q 'is niet leesbaar' "${werkmap}/fout" || extra="melding noemt niet dat het bestand onleesbaar is"
resultaat "bestand bestaat niet" 1 "${rc}" "${extra}"

# Een map op het pad: Docker of podman maakte een ontbrekend bronpad aan.
mkdir -p "${werkmap}/map-config"
rc=0
"${controle}" "${werkmap}/map-config" >/dev/null 2>"${werkmap}/fout" || rc=$?
extra=""
grep -q 'is een map' "${werkmap}/fout" || extra="melding noemt niet dat het pad een map is"
resultaat "kubeconfig is een map" 1 "${rc}" "${extra}"

# Zonder kubectl in PATH: de controle mag dan niet stil goedkeuren.
leeg="${werkmap}/leeg-pad"
mkdir -p "${leeg}"
printf '%s' "${recept}" > "${werkmap}/config"
rc=0
PATH="${leeg}" /bin/bash "${controle}" "${werkmap}/config" >/dev/null 2>"${werkmap}/fout" || rc=$?
extra=""
grep -q 'INSTALL_FUNDAMENT=true' "${werkmap}/fout" || extra="melding noemt INSTALL_FUNDAMENT=true niet"
resultaat "kubectl ontbreekt" 1 "${rc}" "${extra}"

# Een kubeconfig van Fundament roept functl aan: geweigerd, met een verwijzing
# naar de route in de sandbox in plaats van naar het recept.
printf '%s' "$(met_gebruiker '    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: functl
      args: [cluster, token, 0b5e1c2a-0000-4000-8000-000000000000]')" > "${werkmap}/config"
rc=0
"${controle}" "${werkmap}/config" >/dev/null 2>"${werkmap}/fout" || rc=$?
extra=""
grep -q 'docs/fundament.md' "${werkmap}/fout" || extra="geen verwijzing naar docs/fundament.md"
! grep -q 'docs/kubernetes.md' "${werkmap}/fout" || extra="${extra:+${extra}, }verwijst ook naar het recept"
grep -q 'gegevens anders dan een token: exec' "${werkmap}/fout" || extra="${extra:+${extra}, }exec niet genoemd"
resultaat "kubeconfig van Fundament" 1 "${rc}" "${extra}"

# Een andere exec-plugin krijgt het gewone advies.
printf '%s' "$(met_gebruiker '    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: gke-gcloud-auth-plugin')" > "${werkmap}/config"
rc=0
"${controle}" "${werkmap}/config" >/dev/null 2>"${werkmap}/fout" || rc=$?
extra=""
! grep -q 'docs/fundament.md' "${werkmap}/fout" || extra="verwijst naar docs/fundament.md"
resultaat "andere exec-plugin zonder Fundament-advies" 1 "${rc}" "${extra}"

# De melding noemt elke reden.
printf '%s' "$(met_gebruiker '    exec:
      command: x
    client-key-data: a2V5')" > "${werkmap}/config"
"${controle}" "${werkmap}/config" >/dev/null 2>"${werkmap}/fout"
extra=""
grep -q 'gegevens anders dan een token: exec' "${werkmap}/fout" || extra="exec niet genoemd"
grep -q 'gegevens anders dan een token: client-key-data' "${werkmap}/fout" || extra="${extra:+${extra}, }client-key-data niet genoemd"
grep -q 'gebruiker sandbox heeft geen token' "${werkmap}/fout" || extra="${extra:+${extra}, }ontbrekend token niet genoemd"
resultaat "melding noemt elke reden" 1 1 "${extra}"

# De waarschuwing over de firewall: de kubeconfig is goedgekeurd, maar het adres
# van de API-server valt mogelijk buiten wat de firewall doorlaat.
met_server() { # server-URL
  printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: sandbox\n  cluster:\n    server: %s\nusers:\n- name: sandbox\n  user:\n    token: abc\ncontexts:\n- name: sandbox\n  context:\n    cluster: sandbox\n    user: sandbox\ncurrent-context: sandbox\n' "$1"
}

# Een stub-`ip` zodat het eigen subnet van de testmachine er niet toe doet.
stub="${werkmap}/stub"
mkdir -p "${stub}"
printf '#!/bin/sh\necho "192.168.77.0/24 dev eth0 proto kernel scope link src 192.168.77.5"\n' > "${stub}/ip"
chmod +x "${stub}/ip"

firewall_toets() { # naam server ALLOWED_K8S_API ("-" = ongezet) verwacht_patroon ("" = geen waarschuwing)
  local naam="$1" server="$2" allow="$3" patroon="$4" rc=0 extra=""
  met_server "${server}" > "${werkmap}/config"
  if [ "${allow}" = "-" ]; then
    env -u ALLOWED_K8S_API PATH="${stub}:${PATH}" "${controle}" "${werkmap}/config" \
      > "${werkmap}/uit" 2> "${werkmap}/fout" || rc=$?
  else
    env ALLOWED_K8S_API="${allow}" PATH="${stub}:${PATH}" "${controle}" "${werkmap}/config" \
      > "${werkmap}/uit" 2> "${werkmap}/fout" || rc=$?
  fi
  if [ -n "${patroon}" ]; then
    grep -q "${patroon}" "${werkmap}/fout" || extra="waarschuwing ontbreekt of noemt '${patroon}' niet"
  elif [ -s "${werkmap}/fout" ]; then
    extra="onverwachte melding: $(head -1 "${werkmap}/fout")"
  fi
  resultaat "${naam}" 0 "${rc}" "${extra}"
}

firewall_toets "API-server op 6443 zonder ALLOWED_K8S_API" \
  https://172.19.0.1:6443 - 'ALLOWED_K8S_API is niet gezet'
firewall_toets "ALLOWED_K8S_API past bij de kubeconfig" \
  https://172.19.0.1:6443 172.19.0.1:6443 ''
firewall_toets "ALLOWED_K8S_API wijst naar een ander adres" \
  https://172.19.0.1:6443 10.0.0.5:6443 'staat op 10.0.0.5:6443'
firewall_toets "API-server op poort 443 valt onder ALLOWED_DOMAINS" \
  https://api.intern - ''
firewall_toets "API-server met pad telt als poort 443" \
  https://api.intern/clusters/abc - ''
firewall_toets "API-server op het eigen subnet is al bereikbaar" \
  https://192.168.77.9:6443 - ''
firewall_toets "IPv6 in server is nooit bereikbaar" \
  'https://[fd00::1]:6443' - 'blokkeert IPv6'

echo "geslaagd: ${geslaagd}, gefaald: ${gefaald}"
[ "${gefaald}" -eq 0 ]
