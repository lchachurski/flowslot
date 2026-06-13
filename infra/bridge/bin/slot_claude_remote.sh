#!/bin/bash
# slot_claude_remote.sh — launch a detached `claude` tmux session on the host.
#
# Mirrors the inner `tmux new-session` invocation in scripts/slot-claude:227-229
# but always passes --dangerously-skip-permissions and an explicit --model so
# voice-driven sessions never block on a permission prompt mid-call.
#
# Idempotent: if the tmux session already exists, exit 0 with a "running"
# marker; otherwise launch a new detached session.
#
# Args (positional):
#   $1 = slot name
#   $2 = remote path (absolute, e.g. /srv/thunder/sandbox-7800)
#   $3 = project name
#   $4 = model (alias 'opus'/'sonnet' or full id, e.g. 'claude-opus-4-8')
#
# Exit codes:
#   0 started or already running (check stdout)
#   2 remote path missing
#   3 claude binary not on PATH (after PATH augmentation)

set -euo pipefail

SLOT="$1"
REMOTE_PATH="$2"
PROJECT="$3"
MODEL="$4"

SESSION="claude-${SLOT}"

if [ ! -d "$REMOTE_PATH" ]; then
  echo "ERROR: $REMOTE_PATH does not exist" >&2
  exit 2
fi

# Claude installs to ~/.local/bin by default; mirror slot-claude:228.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude not on PATH (looked in \$HOME/.local/bin)" >&2
  exit 3
fi

# Idempotent: detect a live session and short-circuit.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "OK"
  echo "STATUS=already_running"
  echo "SESSION=$SESSION"
  exit 0
fi

# Hook context — slot-claude exports FLOWSLOT_SLOT_NAME / FLOWSLOT_PROJECT_NAME
# into the tmux session so Claude Code's hook subprocess inherits them and
# tags every row in bridge.db with the slot of origin (see _record.py).
export FLOWSLOT_SLOT_NAME="$SLOT"
export FLOWSLOT_PROJECT_NAME="$PROJECT"

# Build the inner command. --dangerously-skip-permissions is non-negotiable
# for voice — the user can't approve prompts over the phone. --model is
# always set (bridge fills it in from request body / host detection / opus).
INNER="claude --dangerously-skip-permissions --model '$MODEL'"

# Detached so the bridge's subprocess returns immediately; user attaches
# later via `slot claude attach` or `tmux attach -t claude-<slot>`.
tmux new-session -d -s "$SESSION" -c "$REMOTE_PATH" "$INNER"

echo "OK"
echo "STATUS=started"
echo "SESSION=$SESSION"
echo "MODEL=$MODEL"
