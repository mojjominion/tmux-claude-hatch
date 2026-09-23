#!/usr/bin/env bash
# Claude Code agents, with the exact status Claude reports through
# `claude agents --json`.
#
#   Row: pid \t agent \t status \t last_active_epoch \t cwd
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../helpers.sh
. "$DIR/../helpers.sh"

command -v claude >/dev/null 2>&1 || exit 0

# transcript_mtime <session-id>
# `claude agents --json` reports only `startedAt`, so the transcript's last write
# stands in for last activity. Found by glob so we never reproduce Claude's
# cwd -> project-slug encoding; the path is internal to Claude Code and may move,
# and an empty result leaves agents.sh to fall back to the pane's activity.
transcript_mtime() {
  local f
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$1".jsonl; do
    [ -f "$f" ] && {
      file_mtime "$f"
      return
    }
  done
}

claude agents --json 2>/dev/null |
  jq -r '.[] | select(.kind == "interactive")
    | [.pid, (if .status == "busy" then "working" else .status end), .sessionId, .cwd] | @tsv' 2>/dev/null |
  while IFS=$'\t' read -r pid status session cwd; do
    printf '%s\tclaude\t%s\t%s\t%s\n' "$pid" "$status" "$(transcript_mtime "$session")" "$cwd"
  done
