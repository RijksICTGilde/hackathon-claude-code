#!/usr/bin/env bash
# Hertest van spec-blokkade #2 (`write to uid_map failed: Operation not
# permitted`): werkt de multi-uid newuidmap-range-write in de huidige
# sandbox-stand? Die stand is sinds de oorspronkelijke meting veranderd —
# tailored seccomp-profiel, AppArmor-userns-profiel en `systempaths=unconfined`
# kwamen er later bij, en géén van de destijds uitgesloten oorzaken (NoNewPrivs,
# nosuid, ontbrekende CAP_SETUID in de bounding set) is nog aanwezig.
#
# Waarom dit ertoe doet: in single-uid modus start elke image die naar een
# tweede uid chownt niet. Bevestigd met `postgres:18`, dat afbreekt op
# `chown: changing ownership of '/var/lib/postgresql/18/docker': Invalid
# argument` — waardoor Quarkus Dev Services met PostgreSQL nested niet draait.
# Slaagt deze test, dan kan de subuid-strip uit de Dockerfile (single-uid
# modus) vervallen en werken die images wél.
#
# Draai dit op de HOST (het gebruikt `docker exec -u root`; in de sandbox zelf
# is geen root beschikbaar). Op een macOS Podman-machine: RUNTIME=podman.
#
# De wijziging is EPHEMEER: /etc/subuid leeft in de container-laag en is weg na
# een `up --force-recreate` — dat is meteen de rollback.
set -euo pipefail

RUNTIME="${RUNTIME:-docker}"

# GEEN vaste default voor de containernaam. Er draaien vaak meerdere sandboxen
# naast elkaar (de hoofd-sandbox `claude-sandbox` op volume `claude-home`, en
# dev-clones met een eigen container_name + eigen claude-home volume via hun
# compose.override.yml). Een verkeerde gok wist de podman-storage van de
# verkeerde container. Daarom: autodetectie, en bij twijfel stoppen.
if [[ -z "${CONTAINER:-}" ]]; then
    mapfile -t gevonden < <("$RUNTIME" ps --filter "name=claude-sandbox" --format '{{.Names}}' | sort)
    case "${#gevonden[@]}" in
        0) echo "FOUT: geen draaiende container met 'claude-sandbox' in de naam gevonden. Geef expliciet mee: CONTAINER=<naam> $0" >&2; exit 1 ;;
        1) CONTAINER="${gevonden[0]}" ;;
        *) echo "FOUT: meerdere sandboxen draaien: ${gevonden[*]}" >&2
           echo "Kies expliciet welke je wil testen, bv.: CONTAINER=${gevonden[0]} $0" >&2
           exit 1 ;;
    esac
fi

# Stap 3 wist alle gepullde images en podman-volumes ín de sandbox. Projectcode
# en de Maven-repo blijven ongemoeid, maar het is niet terug te draaien, dus
# eerst bevestigen.
cat <<EOF
Deze test wijzigt de draaiende container '$CONTAINER' (runtime: $RUNTIME):
  1. voegt een subuid/subgid-range toe voor 'claude' (ephemeer)
  2. stopt een lopende 'podman system service'
  3. draait 'podman system reset -f' IN de sandbox — dit WIST alle gepullde
     images en podman-volumes van de sandbox. Onomkeerbaar. Projectcode en de
     Maven-repo (~/.m2) blijven ongemoeid.
     Reikwijdte: alleen het claude-home volume van DEZE container. Draait er een
     tweede sandbox met een eigen volume (dev-clone), dan blijft die ongemoeid.
     Controleer welk volume eronder zit met:
       $RUNTIME inspect $CONTAINER --format '{{range .Mounts}}{{.Name}} {{end}}'
  4. leest de uid_map uit
  5. start postgres:18 (wordt opnieuw gepulld)

EOF
read -r -p "Doorgaan? [j/N] " antwoord
case "$antwoord" in
    j|J|ja|Ja) ;;
    *) echo "Afgebroken."; exit 1 ;;
esac

echo "== 1. subuid/subgid-range toevoegen voor claude (als root) =="
# Range bewust op 200000 en niet op de shadow-utils-default 100000: die default
# krijgt de eerste host-gebruiker ook, en docker draait hier zonder
# userns-remap (container-uid 1000 == host-uid 1000). Bij overlap zouden nested
# processen als dezelfde host-uids draaien als de rootless-podman-storage van
# de host-gebruiker zelf.
"$RUNTIME" exec -u root "$CONTAINER" bash -c '
  grep -q "^claude:" /etc/subuid || echo "claude:200000:65536" >> /etc/subuid
  grep -q "^claude:" /etc/subgid || echo "claude:200000:65536" >> /etc/subgid
  cat /etc/subuid /etc/subgid'

echo "== 2. lopende podman-socket stoppen (draait nog met de oude mapping) =="
"$RUNTIME" exec -u claude "$CONTAINER" bash -c 'pkill -f "podman system service" || true'

echo "== 3. podman storage resetten naar de nieuwe uid-range =="
# De bestaande storage is in single-uid modus aangelegd (alles van uid 0) en
# klopt na een uid-range-wissel niet meer; `system migrate` volstaat daar niet.
"$RUNTIME" exec -u claude "$CONTAINER" bash -lc '
  export XDG_RUNTIME_DIR=/tmp/podman-run-$(id -u)
  podman system reset -f'

echo "== 4. DE TEST: mapt podman nu meerdere uids? =="
# Succes  = een regel met count 65536 (i.p.v. count 1).
# Blokkade #2 bestaat nog = "write to uid_map failed: Operation not permitted"
# of "cannot set up namespace".
"$RUNTIME" exec -u claude "$CONTAINER" bash -lc '
  export XDG_RUNTIME_DIR=/tmp/podman-run-$(id -u)
  podman unshare cat /proc/self/uid_map'

echo "== 5. postgres:18 =="
"$RUNTIME" exec -u claude "$CONTAINER" bash -lc '
  export XDG_RUNTIME_DIR=/tmp/podman-run-$(id -u)
  timeout 120 podman run --rm -e POSTGRES_PASSWORD=x postgres:18 2>&1 | tail -20'

cat <<'EOF'

== Uitslag lezen ==
Route 1 werkt   : stap 4 toont count 65536 én stap 5 bereikt
                  "database system is ready to accept connections".
Route 1 dood    : stap 4 geeft "write to uid_map failed: Operation not
                  permitted". Volgende diagnostische stap:
                  strace -f -e trace=write podman unshare true
                  — dat laat zien welke uid_map-write precies EPERM geeft; dat
                  is wat de vorige ronde niet sluitend kreeg.

Bij succes is de permanente fix: in de Dockerfile de subuid-strip omkeren naar
`usermod --add-subuids 200000-265535 --add-subgids 200000-265535 claude`, en
`ignore_chown_errors` uit storage.conf halen (Dockerfile + entrypoint.sh) — met
een echte uid-range is die niet alleen overbodig maar maskeert hij fouten.

Neveneffect om te documenteren: docker draait hier zonder userns-remap, dus
container-uid 1000 is host-uid 1000. Een nested proces dat als uid 999 draait,
schrijft op een bind-mount voortaan als host-uid 200999 — bestanden in je repo
die je zonder sudo niet meer weg krijgt. Testcontainers gebruikt zelden
bind-mounts, `quarkus:dev` en compose-mounts wel.
EOF
