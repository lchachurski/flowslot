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

# v2.17.1: pre-accept Claude Code's workspace-trust dialog for this folder.
# Without this, the very first `claude` launch on a new slot dir asks
# "Yes, I trust this folder?" and blocks at that prompt —
# `--dangerously-skip-permissions` only covers per-tool prompts, not the
# workspace gate. Voice-driven slots can't answer it. We write
# `projects[<path>].hasTrustDialogAccepted = true` directly to
# ~/.claude.json under flock so concurrent claude processes don't clobber
# each other's writes to the same file.
python3 - "$REMOTE_PATH" <<'PYTRUST'
import fcntl, json, os, sys, tempfile
path = sys.argv[1]
cfg  = os.path.expanduser("~/.claude.json")
# fcntl.flock needs an existing file; create empty one if missing.
if not os.path.exists(cfg):
    with open(cfg, "w") as f:
        f.write("{}")
with open(cfg, "r+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        try:
            data = json.load(f)
        except Exception:
            data = {}
        projects = data.setdefault("projects", {})
        proj = projects.setdefault(path, {})
        if proj.get("hasTrustDialogAccepted") is True:
            sys.exit(0)  # already trusted; no write needed
        proj["hasTrustDialogAccepted"] = True
        # Atomic-ish replace: write to temp in same dir, rename. The flock
        # we hold is on the original fd, so the rename closes our lock —
        # but by then we've already updated the file.
        tmp = tempfile.NamedTemporaryFile(
            "w", dir=os.path.dirname(cfg), delete=False)
        json.dump(data, tmp, separators=(",", ":"))
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, cfg)
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
PYTRUST

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
