#!/bin/bash
# slot_create_remote.sh — create a slot directly on the slot host.
#
# Mirrors the REMOTE_SETUP + REMOTE_SCRIPT blocks of scripts/slot-create, but
# runs locally on the slot host (the bridge process is co-located) and clones
# from the upstream repo directly instead of mutagen-syncing from a Mac.
#
# Invoked by the bridge's POST /bridge/slot/create endpoint.
#
# Args (positional):
#   $1 = slot name (validated upstream)
#   $2 = project name
#   $3 = repo url   (https://...; credentials inherited from global git config)
#   $4 = port base  (integer, e.g. 7300)
#   $5 = remote base (e.g. /srv/thunder)
#   $6 = compose files (space-separated, e.g. "docker-compose.yml docker-compose.dev.yml")
#   $7 = branch     (defaults to slot name)
#
# Exit codes:
#   0  ok; prints REMOTE_PATH=<path> on the last line for the bridge to capture
#   2  slot dir already exists (caller should already check; safety net)
#   3  clone failed
#   4  compose up failed
#
# Stdout/stderr are forwarded to the bridge's reply; keep messages short and
# parseable.

set -euo pipefail

SLOT="$1"
PROJECT="$2"
REPO_URL="$3"
PORT_BASE="$4"
REMOTE_BASE="$5"
COMPOSE_FILES="$6"
BRANCH="${7:-$SLOT}"

REMOTE_PATH="$REMOTE_BASE/${SLOT}-${PORT_BASE}"
PORT_BASE_START=7000
PORT_RANGE=100
SLOT_NUM=$(( (PORT_BASE - PORT_BASE_START) / PORT_RANGE ))

# 1) Ensure base dir exists (sudo path matches scripts/slot-create:132-135)
if [ ! -d "$REMOTE_BASE" ]; then
  sudo mkdir -p "$REMOTE_BASE"
  sudo chown "$USER:$USER" "$REMOTE_BASE"
fi

# 2) Refuse to clobber. Caller (bridge) should have 409'd already; this is a
# concurrency safety net.
if [ -d "$REMOTE_PATH" ]; then
  echo "ERROR: $REMOTE_PATH already exists" >&2
  exit 2
fi

# 3) Clone the repo at the requested branch. Credentials come from the global
# `credential.helper=store` set by ensure_slot_git_credentials on first
# `slot create` for the project. If the branch doesn't exist upstream, clone
# the default branch and create the branch locally so push will create it.
echo "Cloning $REPO_URL at $BRANCH into $REMOTE_PATH..."
if git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REMOTE_PATH" 2>/dev/null; then
  :
elif git clone --quiet "$REPO_URL" "$REMOTE_PATH"; then
  git -C "$REMOTE_PATH" checkout -B "$BRANCH" --quiet
else
  echo "ERROR: git clone failed" >&2
  exit 3
fi

# 4) Copy .env* files. Priority: HQ dir (canonical, synced from the Mac during
# `voice enable`) → sibling slot (legacy fallback). Project-level env (DB
# strings, API keys) is gitignored, so it wouldn't come down from `git clone`.
HQ="$REMOTE_BASE/.flowslot-hq"
ENV_SRC=""
if [ -d "$HQ" ]; then
  ENV_SRC="$HQ"
  echo "Copying .env* from HQ ($HQ)..."
else
  ENV_SRC="$(find "$REMOTE_BASE" -maxdepth 1 -type d -name "*-[0-9][0-9][0-9][0-9]" \
              -not -path "$REMOTE_PATH" | head -1 || true)"
  if [ -n "$ENV_SRC" ]; then
    echo "WARNING: no HQ at $HQ; falling back to sibling slot $ENV_SRC" >&2
  fi
fi
if [ -n "$ENV_SRC" ]; then
  ( cd "$ENV_SRC" && find . -maxdepth 4 -name ".env*" -type f \
      ! -path "*/node_modules/*" ! -path "*/.git/*" ) \
    | while read -r rel_path; do
        src="$ENV_SRC/${rel_path#./}"
        dst="$REMOTE_PATH/${rel_path#./}"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
      done
fi

# 5) Start containers — mirrors scripts/slot-create:206-241 verbatim. Exporting
# the same env vars; compose project name is namespaced per slot.
echo "Starting containers in $REMOTE_PATH..."
cd "$REMOTE_PATH"

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -1 || echo "")

export SLOT="$SLOT_NUM"
export SLOT_NAME="$SLOT"
export SLOT_PORT_BASE="$PORT_BASE"
export SLOT_PROJECT_NAME="$PROJECT"
export SLOT_REMOTE_IP="${TAILSCALE_IP:-localhost}"
export COMPOSE_PROJECT_NAME="${PROJECT}-${SLOT}"

# Per-project port definitions, if present (mirrors slot-create:218-221).
if [ -f flowslot-ports.sh ]; then
  # shellcheck disable=SC1091
  source flowslot-ports.sh
fi

COMPOSE_CMD="docker compose"
for f in $COMPOSE_FILES; do
  if [ -f "$f" ]; then
    COMPOSE_CMD="$COMPOSE_CMD -f $f"
  fi
done
# Add flowslot override if present and not already included
if [ -f docker-compose.flowslot.yml ] && ! echo "$COMPOSE_CMD" | grep -q docker-compose.flowslot.yml; then
  COMPOSE_CMD="$COMPOSE_CMD -f docker-compose.flowslot.yml"
fi

if ! eval "$COMPOSE_CMD up -d"; then
  echo "ERROR: compose up failed; rolling back partial clone" >&2
  # Walk back: try to compose down anything that may have started, then
  # remove the dir so the next create call isn't blocked by 409.
  eval "$COMPOSE_CMD down -v --remove-orphans" 2>/dev/null || true
  cd /
  sudo rm -rf "$REMOTE_PATH"
  exit 4
fi

echo "OK"
echo "REMOTE_PATH=$REMOTE_PATH"
