#!/bin/bash
# Close desktop windows created by slot desktop up (macOS only)
# Usage: slot desktop down

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

show_help() {
  cat << EOF
Usage: slot desktop down

Close browser/editor windows tracked in .slotdesktop.state.

Notes:
  - Only windows tracked by 'slot desktop up' are targeted
  - Personal browser/editor windows are left untouched
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

require_cmd osascript

if [ "$(uname -s)" != "Darwin" ]; then
  die "slot desktop commands are supported only on macOS."
fi

if [ -z "${SLOT_SOURCE_DIR:-}" ]; then
  die "Missing SLOT_SOURCE_DIR. Run via 'slot desktop down' from an initialized project."
fi

DESKTOP_CONFIG_FILE="$SLOT_SOURCE_DIR/.slotdesktop"
if [ -f "$DESKTOP_CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$DESKTOP_CONFIG_FILE"
fi

DESKTOP_BROWSER="${DESKTOP_BROWSER:-Google Chrome}"
DESKTOP_EDITOR="${DESKTOP_EDITOR:-Cursor}"
DESKTOP_STATE_FILE="${DESKTOP_STATE_FILE:-$SLOT_SOURCE_DIR/.slotdesktop.state}"

close_cursor_windows() {
  local slot_name="$1"
  local closed

  closed="$(osascript << APPLESCRIPT 2>/dev/null || true
tell application "$DESKTOP_EDITOR"
  if not running then return "0"
  set closedCount to 0
  repeat with i from (count of windows) to 1 by -1
    try
      set windowName to name of window i
      if windowName contains "$slot_name" then
        close window i
        set closedCount to closedCount + 1
      end if
    end try
  end repeat
  return closedCount as text
end tell
APPLESCRIPT
)"

  if [[ "$closed" =~ ^[0-9]+$ ]]; then
    echo "$closed"
  else
    echo "0"
  fi
}

close_browser_windows() {
  local host_port="$1"
  local port="$2"
  local closed

  closed="$(osascript << APPLESCRIPT 2>/dev/null || true
tell application "$DESKTOP_BROWSER"
  if not running then return "0"
  set closedCount to 0
  repeat with i from (count of windows) to 1 by -1
    try
      set tabURL to URL of active tab of window i
      set shouldClose to false
      if tabURL contains "$host_port" then
        set shouldClose to true
      else if "$port" is not "" then
        if tabURL contains ("localhost:" & "$port") then set shouldClose to true
        if tabURL contains ("flowslot.dev:" & "$port") then set shouldClose to true
        if tabURL contains ("flowslot.cc:" & "$port") then set shouldClose to true
      end if

      if shouldClose then
        close window i
        set closedCount to closedCount + 1
      end if
    end try
  end repeat
  return closedCount as text
end tell
APPLESCRIPT
)"

  if [[ "$closed" =~ ^[0-9]+$ ]]; then
    echo "$closed"
  else
    echo "0"
  fi
}

if [ ! -f "$DESKTOP_STATE_FILE" ]; then
  log_info "No desktop state file found at $DESKTOP_STATE_FILE. Nothing to close."
  exit 0
fi

declare -a SUMMARY_LINES=()
total_editor_closed=0
total_browser_closed=0
slots_processed=0

while IFS='|' read -r slot_name slot_space slot_dir slot_url; do
  [ -z "${slot_name:-}" ] && continue
  [[ "$slot_name" =~ ^# ]] && continue
  [ -z "${slot_url:-}" ] && continue

  host_port="${slot_url#http://}"
  host_port="${host_port%%/*}"
  port="${host_port##*:}"
  if [ "$port" = "$host_port" ]; then
    port=""
  fi

  editor_closed="$(close_cursor_windows "$slot_name")"
  browser_closed="$(close_browser_windows "$host_port" "$port")"

  total_editor_closed=$((total_editor_closed + editor_closed))
  total_browser_closed=$((total_browser_closed + browser_closed))
  slots_processed=$((slots_processed + 1))

  SUMMARY_LINES+=("${slot_name}|${slot_space}|${editor_closed}|${browser_closed}")
done < "$DESKTOP_STATE_FILE"

rm -f "$DESKTOP_STATE_FILE"

success "Desktop windows closed."
echo ""
printf "%-15s %-8s %-12s %-12s\n" "SLOT" "SPACE" "EDITOR" "BROWSER"
echo "-------------------------------------------------------"
for row in "${SUMMARY_LINES[@]}"; do
  IFS='|' read -r slot_name slot_space editor_closed browser_closed <<< "$row"
  printf "%-15s %-8s %-12s %-12s\n" "$slot_name" "${slot_space:-?}" "$editor_closed" "$browser_closed"
done

echo ""
echo "Slots processed: $slots_processed"
echo "Editor windows closed: $total_editor_closed"
echo "Browser windows closed: $total_browser_closed"
