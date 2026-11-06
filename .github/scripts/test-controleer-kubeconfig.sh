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
  elif [ "${verwacht}" -eq 0 ] && [ -s "${werkmap}/fout" ]; then
    extra="schreef naar stderr: $(head -1 "${werkmap}/fout")"
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

# Zonder kubectl in PATH: de controle mag dan niet stil goedkeuren.
leeg="${werkmap}/leeg-pad"
mkdir -p "${leeg}"
printf '%s' "${recept}" > "${werkmap}/config"
rc=0
PATH="${leeg}" /bin/bash "${controle}" "${werkmap}/config" >/dev/null 2>"${werkmap}/fout" || rc=$?
extra=""
grep -q 'INSTALL_K8S=true' "${werkmap}/fout" || extra="melding noemt INSTALL_K8S=true niet"
resultaat "kubectl ontbreekt" 1 "${rc}" "${extra}"

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

echo "geslaagd: ${geslaagd}, gefaald: ${gefaald}"
[ "${gefaald}" -eq 0 ]
