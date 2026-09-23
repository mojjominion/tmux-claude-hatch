#!/usr/bin/env bash
# Agents that report no status of their own (omp, codex, opencode, ...), found by
# process name from @claude_agents. Status, last activity and cwd are left empty
# for agents.sh to read from the agent's pane.
#
#   Row: pid \t agent \t \t \t
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../helpers.sh
. "$DIR/../helpers.sh"

names="$(get_tmux_option @claude_agents 'omp codex opencode gemini aider amp crush goose')"

# comm can hold spaces (a macOS app path), so it is everything after the pid.
ps -Ao pid=,comm= 2>/dev/null | awk -v names="$names" '
  BEGIN { split(names, list, " "); for (i in list) wanted[list[i]] = 1 }
  {
    pid = $1; sub(/^ *[0-9]+ +/, ""); n = split($0, part, "/")
    if (part[n] in wanted) print pid "\t" part[n] "\t\t\t"
  }'
