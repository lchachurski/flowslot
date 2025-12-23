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

# Constants
readonly PORT_BASE_START=7100
readonly PORT_RANGE=100

