#!/usr/bin/env bash
# Emit one picker row per running coding agent that lives in a tmux pane.
#
# Each script in sources/ prints the agents it knows about:
#   pid \t agent \t status \t last_active_epoch \t cwd
# status is waiting / idle / working. Any field after agent may be empty; it is
# then read from the agent's tmux pane.
#
# This script pairs each agent with its pane (pid -> tty -> pane), drops agents
# outside tmux or idle longer than @claude_stale_minutes, and formats the rows.
#
#   Row: rank \t pane_id \t pid \t kind \t agent+status \t age \t loc \t path
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

{
  ps -Ao pid=,tty= 2>/dev/null | awk '{ print "P\t" $1 "\t" $2 }'
  # -u: without a UTF-8 locale tmux prints the tabs in -F output as underscores.
  tmux -u list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_path}\t#{window_activity}' 2>/dev/null
  for source in "$DIR"/sources/*.sh; do
    "$source" 2>/dev/null | sed $'s/^/A\t/'
  done
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v stale="$(get_tmux_option @claude_stale_minutes '1440')" '
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; loc[$2] = $5; cwd[$2] = $6; act[$2] = $7; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (!(tty in pane)) next   # not running inside tmux

    status = $4; last = ($5 != "") ? $5 : act[tty]; path = ($6 != "") ? $6 : cwd[tty]
    quiet = now - last
    # ponytail: output-recency guess; an agent that redraws while idle reads as working.
    if (status == "") status = (quiet < 5) ? "working" : "idle"
    if (stale > 0 && status != "working" && quiet > stale * 60) next

    if      (status == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
    else if (status == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
    else if (status == "working") { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
    else                          { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

    kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

    printf "%s\t%s\t%s\t%s\t%-8s %s\t%5s\t%s\t%s\n",
      rank, pane[tty], $2, kind, $3, icon, int(quiet / 60) "m", loc[tty], path
  }
' | sort -t$'\t' -k1,1n -k6,6n
# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group. -k6,6n reads the leading number of the age field.
