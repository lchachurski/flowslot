#!/bin/bash
# Build desktop layout for running slots (macOS only)
# Usage: slot desktop up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

show_help() {
  cat << EOF
Usage: slot desktop up

Launch browser + editor windows for each running slot and place each pair
on sequential macOS Spaces.

Defaults (override in .slotconfig or .slotdesktop):
  DESKTOP_START_SPACE=1
  DESKTOP_LAYOUT=left-right
  DESKTOP_BROWSER="Google Chrome"
  DESKTOP_EDITOR="Cursor"
  DESKTOP_TOP_OFFSET=<auto> (fallback: 28)
  DESKTOP_SWITCH_DELAY=0.6
  DESKTOP_WINDOW_TIMEOUT=10

Notes:
  - Requires macOS Accessibility permissions for your terminal app
  - Requires Mission Control shortcuts: Ctrl+1 ... Ctrl+9
  - Only Space shortcuts 1-9 are supported
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

require_cmd osascript
require_cmd open
require_cmd ssh

if [ "$(uname -s)" != "Darwin" ]; then
  die "slot desktop commands are supported only on macOS."
fi

if [ -z "${SLOT_PROJECT_NAME:-}" ] || [ -z "${SLOT_SOURCE_DIR:-}" ] || [ -z "${SLOT_SLOTS_DIR:-}" ] || [ -z "${SLOT_REMOTE_HOST:-}" ] || [ -z "${SLOT_REMOTE_BASE:-}" ]; then
  die "Missing required SLOT_* variables. Run via 'slot desktop up' from an initialized project."
fi

DESKTOP_CONFIG_FILE="$SLOT_SOURCE_DIR/.slotdesktop"
if [ -f "$DESKTOP_CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$DESKTOP_CONFIG_FILE"
fi

DESKTOP_START_SPACE="${DESKTOP_START_SPACE:-1}"
DESKTOP_LAYOUT="${DESKTOP_LAYOUT:-left-right}"
DESKTOP_BROWSER="${DESKTOP_BROWSER:-Google Chrome}"
DESKTOP_EDITOR="${DESKTOP_EDITOR:-Cursor}"
DESKTOP_SWITCH_DELAY="${DESKTOP_SWITCH_DELAY:-0.6}"
DESKTOP_WINDOW_TIMEOUT="${DESKTOP_WINDOW_TIMEOUT:-10}"
DESKTOP_STATE_FILE="${DESKTOP_STATE_FILE:-$SLOT_SOURCE_DIR/.slotdesktop.state}"

detect_menu_bar_height() {
  local height
  height="$(osascript << 'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "SystemUIServer"
    if exists menu bar 1 then
      set menuSize to size of menu bar 1
      return item 2 of menuSize as text
    end if
  end tell
end tell
return ""
APPLESCRIPT
)"

  if [[ "$height" =~ ^[0-9]+$ ]] && [ "$height" -gt 0 ]; then
    echo "$height"
    return 0
  fi

  return 1
}

if [ -z "${DESKTOP_TOP_OFFSET:-}" ]; then
  if DESKTOP_TOP_OFFSET="$(detect_menu_bar_height)"; then
    log_info "Detected menu bar height: ${DESKTOP_TOP_OFFSET}px"
  else
    DESKTOP_TOP_OFFSET=28
  fi
fi

if [[ ! "$DESKTOP_START_SPACE" =~ ^[0-9]+$ ]] || [ "$DESKTOP_START_SPACE" -lt 1 ]; then
  die "DESKTOP_START_SPACE must be a positive integer (got: $DESKTOP_START_SPACE)."
fi
if [[ ! "$DESKTOP_TOP_OFFSET" =~ ^[0-9]+$ ]]; then
  die "DESKTOP_TOP_OFFSET must be a non-negative integer (got: $DESKTOP_TOP_OFFSET)."
fi
if [[ ! "$DESKTOP_WINDOW_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$DESKTOP_WINDOW_TIMEOUT" -lt 1 ]; then
  die "DESKTOP_WINDOW_TIMEOUT must be a positive integer (got: $DESKTOP_WINDOW_TIMEOUT)."
fi
if [ "$DESKTOP_LAYOUT" != "left-right" ]; then
  die "Unsupported DESKTOP_LAYOUT '$DESKTOP_LAYOUT'. Supported: left-right"
fi

space_key_code() {
  case "$1" in
    1) echo 18 ;;
    2) echo 19 ;;
    3) echo 20 ;;
    4) echo 21 ;;
    5) echo 23 ;;
    6) echo 22 ;;
    7) echo 26 ;;
    8) echo 28 ;;
    9) echo 25 ;;
    *) return 1 ;;
  esac
}

switch_to_space() {
  local space="$1"
  local key_code
  key_code="$(space_key_code "$space")" || return 1

  osascript \
    -e 'tell application "System Events"' \
    -e "key code $key_code using control down" \
    -e 'end tell' >/dev/null 2>&1
}

get_screen_bounds() {
  local bounds
  bounds="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | tr -d ' ')"

  if [[ "$bounds" =~ ^-?[0-9]+,-?[0-9]+,-?[0-9]+,-?[0-9]+$ ]]; then
    IFS=',' read -r SCREEN_LEFT SCREEN_TOP SCREEN_RIGHT SCREEN_BOTTOM <<< "$bounds"
  else
    log_warn "Could not read screen bounds from Finder. Falling back to 1728x1117."
    SCREEN_LEFT=0
    SCREEN_TOP=0
    SCREEN_RIGHT=1728
    SCREEN_BOTTOM=1117
  fi

  if [ "$SCREEN_RIGHT" -le "$SCREEN_LEFT" ] || [ "$SCREEN_BOTTOM" -le "$SCREEN_TOP" ]; then
    die "Invalid screen bounds detected: $SCREEN_LEFT,$SCREEN_TOP,$SCREEN_RIGHT,$SCREEN_BOTTOM"
  fi

  WORK_LEFT="$SCREEN_LEFT"
  WORK_TOP=$((SCREEN_TOP + DESKTOP_TOP_OFFSET))
  WORK_RIGHT="$SCREEN_RIGHT"
  WORK_BOTTOM="$SCREEN_BOTTOM"

  if [ "$WORK_TOP" -ge "$WORK_BOTTOM" ]; then
    WORK_TOP="$SCREEN_TOP"
  fi

  WORK_WIDTH=$((WORK_RIGHT - WORK_LEFT))
  MID_X=$((WORK_LEFT + (WORK_WIDTH / 2)))
}

cursor_window_exists() {
  local slot_name="$1"
  local exists

  exists="$(osascript << APPLESCRIPT 2>/dev/null || true
tell application "$DESKTOP_EDITOR"
  if not running then return "0"
  repeat with w in windows
    try
      if (name of w) contains "$slot_name" then return "1"
    end try
  end repeat
  return "0"
end tell
APPLESCRIPT
)"

  [ "$exists" = "1" ]
}

browser_window_exists() {
  local host_port="$1"
  local exists

  exists="$(osascript << APPLESCRIPT 2>/dev/null || true
tell application "$DESKTOP_BROWSER"
  if not running then return "0"
  repeat with w in windows
    try
      set tabURL to URL of active tab of w
      if tabURL contains "$host_port" then return "1"
    end try
  end repeat
  return "0"
end tell
APPLESCRIPT
)"

  [ "$exists" = "1" ]
}

wait_for_cursor_window() {
  local slot_name="$1"
  local deadline=$((SECONDS + DESKTOP_WINDOW_TIMEOUT))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if cursor_window_exists "$slot_name"; then
      return 0
    fi
    sleep 0.4
  done

  return 1
}

wait_for_browser_window() {
  local host_port="$1"
  local deadline=$((SECONDS + DESKTOP_WINDOW_TIMEOUT))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if browser_window_exists "$host_port"; then
      return 0
    fi
    sleep 0.4
  done

  return 1
}

set_browser_bounds() {
  local host_port="$1"
  local applied

  applied="$(osascript << APPLESCRIPT 2>/dev/null || true
tell application "$DESKTOP_BROWSER"
  if not running then return "0"
  set movedCount to 0
  repeat with w in windows
    try
      set tabURL to URL of active tab of w
      if tabURL contains "$host_port" then
        set bounds of w to {$WORK_LEFT, $WORK_TOP, $MID_X, $WORK_BOTTOM}
        set movedCount to movedCount + 1
      end if
    end try
  end repeat
  return movedCount as text
end tell
APPLESCRIPT
)"

  [[ "$applied" =~ ^[0-9]+$ ]] && [ "$applied" -gt 0 ]
}

set_editor_bounds() {
  local slot_name="$1"
  local applied

  applied="$(osascript << APPLESCRIPT 2>/dev/null || true
tell application "$DESKTOP_EDITOR"
  if not running then return "0"
  set movedCount to 0
  repeat with w in windows
    try
      if (name of w) contains "$slot_name" then
        set bounds of w to {$MID_X, $WORK_TOP, $WORK_RIGHT, $WORK_BOTTOM}
        set movedCount to movedCount + 1
      end if
    end try
  end repeat
  return movedCount as text
end tell
APPLESCRIPT
)"

  [[ "$applied" =~ ^[0-9]+$ ]] && [ "$applied" -gt 0 ]
}

slot_web_url() {
  local slot_name="$1"
  local port_base="$2"
  local slot_num web_port slot_domain parsed

  slot_num=$(( (port_base - PORT_BASE_START) / PORT_RANGE ))
  web_port=$((port_base + 1))

  if [ -n "${TS_SPLIT_DOMAIN:-}" ]; then
    slot_domain="${SLOT_PROJECT_NAME}.${TS_SPLIT_DOMAIN}"
  else
    slot_domain="${SLOT_PROJECT_NAME}.flowslot.cc"
  fi

  if [ -f "$SLOT_SOURCE_DIR/flowslot-ports.sh" ]; then
    if parsed="$(
      SLOT="$slot_num" \
      SLOT_NAME="$slot_name" \
      SLOT_PORT_BASE="$port_base" \
      SLOT_PROJECT_NAME="$SLOT_PROJECT_NAME" \
      SLOT_REMOTE_IP="localhost" \
      COMPOSE_PROJECT_NAME="${SLOT_PROJECT_NAME}-${slot_name}" \
      TS_SPLIT_DOMAIN="${TS_SPLIT_DOMAIN:-}" \
      bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        if [ -n "${SLOT_PORT_WEB:-}" ]; then
          web_port="$SLOT_PORT_WEB"
        else
          web_port=$((SLOT_PORT_BASE + 1))
        fi

        if [ -n "${SLOT_DOMAIN:-}" ]; then
          slot_domain="$SLOT_DOMAIN"
        elif [ -n "${TS_SPLIT_DOMAIN:-}" ]; then
          slot_domain="${SLOT_PROJECT_NAME}.${TS_SPLIT_DOMAIN}"
        else
          slot_domain="${SLOT_PROJECT_NAME}.flowslot.cc"
        fi

        echo "${web_port}|${slot_domain}"
      ' _ "$SLOT_SOURCE_DIR/flowslot-ports.sh" 2>/dev/null
    )"; then
      web_port="${parsed%%|*}"
      slot_domain="${parsed#*|}"
    else
      log_warn "Could not parse flowslot-ports.sh for slot '$slot_name'. Using defaults."
    fi
  fi

  echo "http://web.${slot_domain}:${web_port}"
}

running_slots() {
  ssh "$SLOT_REMOTE_HOST" bash << REMOTE_SCRIPT
set -euo pipefail

BASE_DIR="$SLOT_REMOTE_BASE"
PROJECT="$SLOT_PROJECT_NAME"

for slot_path in "\$BASE_DIR"/*/; do
  [ -d "\$slot_path" ] || continue

  dir_name=\$(basename "\$slot_path")

  if [ ! -f "\$slot_path/docker-compose.yml" ] && [ ! -f "\$slot_path/docker-compose.dev.yml" ]; then
    continue
  fi

  if [[ "\$dir_name" =~ -([0-9]{4})$ ]]; then
    slot_name="\${dir_name%-[0-9][0-9][0-9][0-9]}"
    port_base="\${BASH_REMATCH[1]}"
  else
    continue
  fi

  running=\$(docker ps --filter "name=\${PROJECT}-\${slot_name}" -q 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "\${running:-0}" -gt 0 ] 2>/dev/null; then
    echo "\${slot_name}|\${port_base}"
  fi
done
REMOTE_SCRIPT
}

get_screen_bounds

SLOT_DATA="$(running_slots)"
if [ -z "$SLOT_DATA" ]; then
  log_info "No running slots found. Nothing to launch."
  exit 0
fi

mapfile -t SLOT_LINES < <(printf "%s\n" "$SLOT_DATA" | sed '/^$/d' | sort -t'|' -k2,2n)
if [ "${#SLOT_LINES[@]}" -eq 0 ]; then
  log_info "No running slots found. Nothing to launch."
  exit 0
fi

LAST_SPACE=$((DESKTOP_START_SPACE + ${#SLOT_LINES[@]} - 1))
if [ "$LAST_SPACE" -gt 9 ]; then
  die "Need Space shortcuts up to Desktop $LAST_SPACE. Only Ctrl+1..Ctrl+9 are supported."
fi

log_warn "Ensure Desktops $DESKTOP_START_SPACE-$LAST_SPACE exist in Mission Control before continuing."

TMP_STATE="$(mktemp)"
trap 'rm -f "$TMP_STATE"' EXIT

if [ -f "$DESKTOP_STATE_FILE" ]; then
  cp "$DESKTOP_STATE_FILE" "$TMP_STATE"
else
  echo "# Managed by slot desktop up" > "$TMP_STATE"
  echo "# slot|space|dir|url" >> "$TMP_STATE"
fi

declare -a SUMMARY_LINES=()
launched_count=0
skipped_count=0
space="$DESKTOP_START_SPACE"

for row in "${SLOT_LINES[@]}"; do
  IFS='|' read -r slot_name port_base <<< "$row"
  [ -z "$slot_name" ] && continue
  [ -z "$port_base" ] && continue

  validate_slot_name "$slot_name"

  slot_dir="$SLOT_SLOTS_DIR/$slot_name"
  if [ ! -d "$slot_dir" ]; then
    log_warn "Slot '$slot_name' not found locally at $slot_dir. Skipping."
    skipped_count=$((skipped_count + 1))
    space=$((space + 1))
    continue
  fi

  slot_url="$(slot_web_url "$slot_name" "$port_base")"
  host_port="${slot_url#http://}"
  host_port="${host_port%%/*}"

  if cursor_window_exists "$slot_name"; then
    log_warn "Cursor window for slot '$slot_name' already open. Skipping (use 'slot desktop restart')."
    skipped_count=$((skipped_count + 1))
    space=$((space + 1))
    continue
  fi

  if browser_window_exists "$host_port"; then
    log_warn "$DESKTOP_BROWSER window for '$host_port' already open. Skipping (use 'slot desktop restart')."
    skipped_count=$((skipped_count + 1))
    space=$((space + 1))
    continue
  fi

  log_info "Space $space -> slot '$slot_name'"

  if ! switch_to_space "$space"; then
    die "Failed to switch to Desktop $space. Enable Mission Control shortcuts Ctrl+1..Ctrl+9."
  fi

  sleep "$DESKTOP_SWITCH_DELAY"

  open -a "$DESKTOP_EDITOR" "$slot_dir" >/dev/null 2>&1 || {
    log_warn "Failed to launch $DESKTOP_EDITOR for slot '$slot_name'."
    skipped_count=$((skipped_count + 1))
    space=$((space + 1))
    continue
  }

  if [ "$DESKTOP_BROWSER" = "Google Chrome" ]; then
    open -n -a "$DESKTOP_BROWSER" --args --new-window "$slot_url" >/dev/null 2>&1 || {
      log_warn "Failed to launch $DESKTOP_BROWSER for slot '$slot_name'."
      skipped_count=$((skipped_count + 1))
      space=$((space + 1))
      continue
    }
  else
    open -a "$DESKTOP_BROWSER" "$slot_url" >/dev/null 2>&1 || {
      log_warn "Failed to launch $DESKTOP_BROWSER for slot '$slot_name'."
      skipped_count=$((skipped_count + 1))
      space=$((space + 1))
      continue
    }
  fi

  if ! wait_for_cursor_window "$slot_name"; then
    log_warn "Timed out waiting for $DESKTOP_EDITOR window for slot '$slot_name'."
  fi
  if ! wait_for_browser_window "$host_port"; then
    log_warn "Timed out waiting for $DESKTOP_BROWSER window for $host_port."
  fi

  if ! set_browser_bounds "$host_port"; then
    log_warn "Could not position browser window for slot '$slot_name'."
  fi
  if ! set_editor_bounds "$slot_name"; then
    log_warn "Could not position editor window for slot '$slot_name'."
  fi

  grep -Ev "^${slot_name}\|" "$TMP_STATE" > "${TMP_STATE}.next" || true
  mv "${TMP_STATE}.next" "$TMP_STATE"
  echo "${slot_name}|${space}|${slot_dir}|${slot_url}" >> "$TMP_STATE"

  SUMMARY_LINES+=("${slot_name}|${space}|${slot_url}")
  launched_count=$((launched_count + 1))
  space=$((space + 1))
done

if [ "$launched_count" -gt 0 ]; then
  mv "$TMP_STATE" "$DESKTOP_STATE_FILE"
  trap - EXIT
  success "Desktop layout updated ($launched_count slot(s) launched)."
else
  log_warn "No new slot windows were launched."
fi

if [ "$skipped_count" -gt 0 ]; then
  log_warn "$skipped_count slot(s) were skipped."
fi

if [ "${#SUMMARY_LINES[@]}" -gt 0 ]; then
  echo ""
  printf "%-15s %-8s %s\n" "SLOT" "SPACE" "URL"
  echo "--------------------------------------------------------------"
  for line in "${SUMMARY_LINES[@]}"; do
    IFS='|' read -r slot_name slot_space slot_url <<< "$line"
    printf "%-15s %-8s %s\n" "$slot_name" "$slot_space" "$slot_url"
  done
  echo ""
  echo "State file: $DESKTOP_STATE_FILE"
fi
