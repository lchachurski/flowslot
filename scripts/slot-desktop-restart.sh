#!/bin/bash
# Restart desktop layout (down + up)
# Usage: slot desktop restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

show_help() {
  cat << EOF
Usage: slot desktop restart

Close managed desktop windows, then relaunch layout for running slots.
Equivalent to:
  slot desktop down
  slot desktop up
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

log_info "Resetting desktop layout..."
"$SCRIPT_DIR/slot-desktop-down.sh"
"$SCRIPT_DIR/slot-desktop-up.sh"
