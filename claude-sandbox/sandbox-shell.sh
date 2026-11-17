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
if ! bron="$(docker inspect "$container" \
  --format "{{range .Mounts}}{{if eq .Destination \"$doel\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)"; then
  echo "Container $container niet gevonden; start hem met 'docker compose up --detach' in claude-sandbox/." >&2
  exit 1
fi

werkmap="$doel"
if [ -n "$bron" ] && [ -d "$bron" ]; then
  # pwd -P aan beide kanten, zodat symlinks (zoals /tmp -> /private/tmp op
  # macOS) de vergelijking niet laten mislukken.
  bron="$(cd "$bron" && pwd -P)"
  hier="$(pwd -P)"
  if [ "$hier" = "$bron" ]; then
    werkmap="$doel"
  elif [ "${hier#"$bron"/}" != "$hier" ]; then
    werkmap="$doel/${hier#"$bron"/}"
  else
    echo "Let op: $hier valt buiten $bron; shell start in $doel." >&2
  fi
fi

if [ "$#" -eq 0 ]; then
  set -- bash
fi

exec docker exec -ti -u claude -w "$werkmap" "$container" "$@"
