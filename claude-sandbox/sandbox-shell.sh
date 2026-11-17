#!/usr/bin/env bash
# Opent een shell als claude in de sandbox, in de map die overeenkomt met de
# huidige hostmap. Ligt die buiten de projects-mount, dan start de shell in
# /home/claude/projects. Argumenten worden als commando uitgevoerd in plaats
# van bash, bijvoorbeeld: sandbox-shell.sh claude --dangerously-skip-permissions
#
# Bash 3.2-compatibel, zodat het ook met de standaard-bash van macOS draait.
set -euo pipefail

container="${CLAUDE_SANDBOX_CONTAINER:-claude-sandbox}"
doel=/home/claude/projects

# Het hostpad komt uit de draaiende container zelf, niet uit .env: zo klopt
# het ook als de container met een andere PROJECTS_DIR of override gestart is.
if ! bron="$(docker inspect --type container "$container" \
  --format "{{range .Mounts}}{{if eq .Destination \"$doel\"}}{{.Source}}{{end}}{{end}}")"; then
  echo "Kan container $container niet inspecteren (zie melding hierboven); start hem met 'docker compose up --detach' in claude-sandbox/." >&2
  exit 1
fi

werkmap="$doel"
hier="$(pwd -P)"
if [ -n "$bron" ] && [ -d "$bron" ]; then
  # pwd -P aan beide kanten, zodat symlinks (zoals /tmp -> /private/tmp op
  # macOS) de vergelijking niet laten mislukken.
  bron="$(cd "$bron" && pwd -P)"
  case "$hier/" in
    "$bron"/*) werkmap="$doel${hier#"$bron"}" ;;
    *) echo "Let op: $hier valt buiten $bron; shell start in $doel." >&2 ;;
  esac
else
  # Bijvoorbeeld een remote Docker-context of een runtime die het pad vertaalt.
  echo "Let op: projects-mount van $container niet gevonden op deze host${bron:+ ($bron)}; shell start in $doel." >&2
fi

if [ "$#" -eq 0 ]; then
  set -- bash
fi

# -t alleen met een terminal, zodat een commando ook in een pipe of script werkt.
if [ -t 0 ] && [ -t 1 ]; then tty=-ti; else tty=-i; fi

exec docker exec "$tty" -u claude -w "$werkmap" "$container" "$@"
