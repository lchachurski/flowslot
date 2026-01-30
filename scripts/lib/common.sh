#!/bin/bash
# Common functions and constants for flowslot scripts

# Exit on error, undefined vars, pipe failures
set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [ "${DEBUG:-0}" = "1" ] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2 || true; }
die()       { log_error "$*"; exit 1; }

# Check if command exists
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Required command not found: $1. Please install it first."
  fi
}

# Confirm action with user
confirm() {
  local prompt="${1:-Continue?}"
  local response
  read -r -p "$(echo -e "${YELLOW}$prompt${NC} [y/N] ")" response
  [[ "$response" =~ ^[Yy]$ ]]
}

# Success message
success() {
  echo -e "${GREEN}✓${NC} $*"
}

# Get script directory (works when sourced)
get_script_dir() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    dirname "$(readlink -f "${BASH_SOURCE[0]}")"
  else
    dirname "$(readlink -f "$0")"
  fi
}

# Find .slotconfig by walking up from current directory
find_config() {
  local dir="${PWD}"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.slotconfig" ]; then
      echo "$dir/.slotconfig"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Load config if found
load_config() {
  local config_file
  if config_file=$(find_config 2>/dev/null); then
    # shellcheck source=/dev/null
    source "$config_file"
  else
    return 1
  fi
}

# Validate slot name
validate_slot_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
    die "Slot name must be lowercase alphanumeric with hyphens only"
  fi
}

# Detect slot name from current directory
# Returns slot name if inside a slot directory, otherwise returns 1
detect_slot_name() {
  # Check if SLOT_SLOTS_DIR is set
  [ -z "${SLOT_SLOTS_DIR:-}" ] && return 1
  
  # Get absolute path of current directory
  local current_dir
  current_dir="$(pwd -P)"
  
  local slots_dir
  slots_dir="$(cd "$SLOT_SLOTS_DIR" 2>/dev/null && pwd -P)" || return 1
  
  # Check if we're inside slots directory
  if [[ "$current_dir" == "$slots_dir"/* ]]; then
    # Extract first path component after slots_dir
    local relative="${current_dir#$slots_dir/}"
    echo "${relative%%/*}"
    return 0
  fi
  return 1
}

# SSH wrapper that handles host key changes gracefully
# Use this instead of raw ssh for all remote commands
remote_ssh() {
  ssh -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=~/.ssh/known_hosts \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "$@"
}

# Interactive SSH (for exec commands that need TTY)
remote_ssh_tty() {
  ssh -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=~/.ssh/known_hosts \
      -o ConnectTimeout=10 \
      -t "$@"
}

# Constants
readonly PORT_BASE_START=7000
readonly PORT_RANGE=100

# =============================================================================
# Port-based directory naming helpers
# Directory format: /srv/project/slotname-7000/ (port base embedded in name)
# =============================================================================

# Extract slot name from directory name (e.g., "pagespeed-7100" -> "pagespeed")
get_slot_name_from_dir() {
  local dir_name="$1"
  # Remove -NNNN suffix if present
  if [[ "$dir_name" =~ -[0-9]{4}$ ]]; then
    echo "${dir_name%-[0-9][0-9][0-9][0-9]}"
  else
    # Old format without port suffix
    echo "$dir_name"
  fi
}

# Extract port base from directory name (e.g., "pagespeed-7100" -> "7100")
# Returns empty string if no port suffix found (old format)
get_port_base_from_dir() {
  local dir_name="$1"
  if [[ "$dir_name" =~ -([0-9]{4})$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# Find remote directory for a slot name
# Format: slotname-NNNN (e.g., auth-7000)
# Returns full path or empty string if not found
find_slot_dir() {
  local base="$1"
  local name="$2"
  local host="$3"
  
  local dir
  dir=$(ssh "$host" "ls -d '$base/${name}'-[0-9][0-9][0-9][0-9] 2>/dev/null | head -1" || true)
  if [ -n "$dir" ]; then
    echo "$dir"
    return 0
  fi
  
  # Not found
  return 1
}

# Find next available port base (with recycling)
# Scans existing directories to find gaps in port allocation
find_available_port_base() {
  local base="$1"
  local host="$2"
  
  ssh "$host" bash -s "$base" << 'REMOTE_EOF'
    BASE_DIR="$1"
    # Get all port bases in use from directory names
    used_ports=""
    
    # List directories matching the pattern
    for dir in $(ls -d "$BASE_DIR"/*-[0-9][0-9][0-9][0-9]/ 2>/dev/null || true); do
      if [ -d "$dir" ]; then
        port=$(basename "$dir" | grep -oE '[0-9]{4}$')
        if [ -n "$port" ]; then
          used_ports="$used_ports $port"
        fi
      fi
    done
    
    # Find first available port starting from 7000
    port=7000
    while true; do
      # Check if port is in used_ports
      if ! echo "$used_ports" | grep -qw "$port"; then
        echo "$port"
        exit 0
      fi
      port=$((port + 100))
      # Safety: don't go beyond reasonable range
      if [ "$port" -gt 9900 ]; then
        echo "7000"  # Fallback
        exit 0
      fi
    done
REMOTE_EOF
}
