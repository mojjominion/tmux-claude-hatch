#!/usr/bin/env bash
# Emit one picker row per running coding agent that lives in a tmux pane.
#
# Two sources:
#   Claude Code   self-reports its status through `claude agents --json`, so its
#                 rows carry an exact waiting / idle / working.
#   Anything else (omp, codex, opencode, ...) is found by process name, listed in
#                 @claude_agents. Its status is read from the pane: output in the
#                 last few seconds means working, silence means idle.
#
# Identity is the agent process, joined pid -> tty -> pane, so several agents in
# one project (same cwd, same session, different windows) each get a row.
#
#   Row: rank \t pane_id \t pid \t kind \t icon \t age \t loc \t path
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

claude_rows=''
if command -v claude >/dev/null 2>&1; then
  claude_rows="$(claude agents --json 2>/dev/null |
    jq -r '.[] | select(.kind == "interactive") | [.pid, .status, .sessionId, .cwd] | @tsv' 2>/dev/null)"
fi

# Resolved out here because only `stat`, outside awk, can read an mtime.
mtimes="$([ -n "$claude_rows" ] && printf '%s\n' "$claude_rows" | cut -f3 | while IFS= read -r sid; do
  printf 'M\t%s\t%s\n' "$sid" "$(claude_transcript_mtime "$sid")"
done)"

# Tagged streams into one awk: pid->tty+name, tty->pane, session->last-activity,
# Claude's own rows. Cost is a fixed handful of subprocesses however many agents.
{
  # comm can hold spaces (a macOS app path), so it is everything after pid and tty.
  ps -Ao pid=,tty=,comm= 2>/dev/null | awk '{
    pid = $1; tty = $2; sub(/^ *[0-9]+ +[^ ]+ +/, ""); n = split($0, p, "/")
    print "P\t" pid "\t" tty "\t" p[n] }'
  # -u: without a UTF-8 locale tmux prints the tabs in -F output as underscores.
  tmux -u list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_path}\t#{window_activity}' 2>/dev/null
  printf '%s\n' "$mtimes"
  [ -n "$claude_rows" ] && printf '%s\n' "$claude_rows" | sed $'s/^/A\t/'
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v names="$(get_tmux_option @claude_agents 'omp codex opencode gemini aider amp crush goose')" '
  BEGIN { split(names, nl, " "); for (i in nl) wanted[nl[i]] = 1 }
  function tilde(p) { return index(p, home) == 1 ? "~" substr(p, length(home) + 1) : p }
  function emit(rank, tty, pid, icon, age, path) {
    claimed[tty] = 1
    kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"
    printf "%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n",
      rank, pane[tty], pid, kind, icon, age, loc[tty], tilde(path)
  }
  $1 == "P" { tty_of[$2] = $3; if ($4 in wanted) { gen_pid[++ng] = $2 } next }
  $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; loc[$2] = $5; cwd[$2] = $6; act[$2] = $7; next }
  $1 == "M" { seen_at[$2] = $3; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux

    if      ($3 == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
    else if ($3 == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
    else if ($3 == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
    else                      { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

    age = (seen_at[$4] != "") ? int((now - seen_at[$4]) / 60) "m" : "-"
    emit(rank, tty, $2, icon, age, $5)
  }
  END {
    for (i = 1; i <= ng; i++) {
      tty = tty_of[gen_pid[i]]
      if (!(tty in pane) || (tty in claimed)) continue   # outside tmux, or a child of one already listed
      # ponytail: output-recency guess; an agent that redraws while idle reads as working.
      quiet = now - act[tty]
      if (quiet < 5) { icon = "\033[31m●\033[0m working"; rank = 3 }
      else           { icon = "\033[32m●\033[0m idle   "; rank = 1 }
      emit(rank, tty, gen_pid[i], icon, int(quiet / 60) "m", cwd[tty])
    }
  }
' | sort -t$'\t' -k1,1n -k6,6n
# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group. -k6,6n reads the leading number of the age field
# ("5m" -> 5; "-" -> 0).
