#!/bin/bash
# slot_destroy_remote.sh — tear down a slot directly on the slot host.
#
# Mirrors the remote-side teardown of scripts/slot-destroy:88-120 (kill tmux,
# compose down -v, sudo rm -rf the slot dir). The bridge's POST
# /bridge/slot/destroy endpoint invokes this only after a `confirm: true`
# call from the agent / a human-authored API client.
#
# Args (positional):
#   $1 = slot name
#   $2 = project name
#   $3 = port base (used to derive REMOTE_PATH)
#   $4 = remote base (/srv/<project>)
#   $5 = compose files (space-separated)
#
# Exit codes:
#   0 ok
#   2 slot dir not found

set -euo pipefail

SLOT="$1"
PROJECT="$2"
PORT_BASE="$3"
REMOTE_BASE="$4"
COMPOSE_FILES="$5"

REMOTE_PATH="$REMOTE_BASE/${SLOT}-${PORT_BASE}"

if [ ! -d "$REMOTE_PATH" ]; then
  echo "ERROR: $REMOTE_PATH does not exist" >&2
  exit 2
fi

# 1) Kill the Claude tmux session so its stop hook fires cleanly into bridge.db
# before we yank the working tree out from under it.
tmux kill-session -t "claude-${SLOT}" 2>/dev/null || true

# 2) Compose down -v --remove-orphans. Mirrors scripts/slot-destroy:93-112.
# Use the same compose-file iteration so we tear down everything we created.
echo "Stopping containers in $REMOTE_PATH..."
(
  cd "$REMOTE_PATH" 2>/dev/null || exit 0
  export COMPOSE_PROJECT_NAME="${PROJECT}-${SLOT}"
  COMPOSE_CMD="docker compose"
  for f in $COMPOSE_FILES; do
    if [ -f "$f" ]; then
      COMPOSE_CMD="$COMPOSE_CMD -f $f"
    fi
  done
  if [ -f docker-compose.flowslot.yml ] && ! echo "$COMPOSE_CMD" | grep -q docker-compose.flowslot.yml; then
    COMPOSE_CMD="$COMPOSE_CMD -f docker-compose.flowslot.yml"
  fi
  eval "$COMPOSE_CMD down -v --remove-orphans" 2>/dev/null \
    || docker compose down -v --remove-orphans 2>/dev/null || true
) || true

# 3) Remove the slot directory. Docker-owned bind mounts may need sudo
# (matches scripts/slot-destroy:120).
echo "Removing $REMOTE_PATH..."
sudo rm -rf "$REMOTE_PATH"

echo "OK"
