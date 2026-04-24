#!/bin/bash
# Poll ~/.flowslot/bridge.db for new hook events and print them one per line.
# Used by `slot claude voice watch` to stream Claude Code hook activity live.
#
# Output columns:
#   HH:MM:SS  <type>  <tool>  <first 80 chars of args/message>
#
# Exits on SIGINT/SIGTERM. Quiet when no new events.

set -euo pipefail

DB="${FLOWSLOT_BRIDGE_DB:-$HOME/.flowslot/bridge.db}"

if [ ! -f "$DB" ]; then
  echo "error: bridge DB not found at $DB. Is voice enabled on this slot?" >&2
  exit 1
fi

# Start from the newest existing row so we only show NEW events going forward.
last="$(sqlite3 "$DB" "SELECT COALESCE(MAX(id), 0) FROM events;" 2>/dev/null || echo 0)"

trap 'exit 0' INT TERM

printf '%-8s  %-14s  %-12s  %s\n' "time" "type" "tool" "detail (first 80 chars)"
printf '%.0s-' {1..100}; printf '\n'

while true; do
  rows="$(sqlite3 -separator '|' "$DB" "
    SELECT id, strftime('%H:%M:%S', ts, 'unixepoch', 'localtime'),
           type, COALESCE(tool, ''),
           substr(COALESCE(args, message, ''), 1, 80)
      FROM events
      WHERE id > $last
      ORDER BY id;
  " 2>/dev/null || true)"
  if [ -n "$rows" ]; then
    while IFS='|' read -r id ts ev tool detail; do
      [ -z "$id" ] && continue
      # Strip JSON-ish clutter from detail
      detail="${detail//\\n/ }"
      printf '%-8s  %-14s  %-12s  %s\n' "$ts" "$ev" "$tool" "$detail"
      last="$id"
    done <<< "$rows"
  fi
  sleep 1
done
