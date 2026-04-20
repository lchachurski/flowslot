#!/bin/bash
# Helpers for the `slot claude` command.
# Sourced by scripts/slot-claude. Depends on scripts/lib/common.sh being sourced
# first (for log_info / log_warn / log_error / remote_ssh).

# Remote locations, relative to the slot user's $HOME.
readonly FLOWSLOT_REMOTE_DIR='$HOME/.flowslot'
readonly FLOWSLOT_NOTIFY_BIN_REL='.flowslot/bin/flowslot-notify'
readonly FLOWSLOT_NOTIFY_CONF_REL='.flowslot/notify.conf'
readonly FLOWSLOT_INSTALL_MARKER_REL='.flowslot/claude-installed'
readonly FLOWSLOT_READY_MARKER_REL='.flowslot/claude-ready'

# Install Claude Code on the slot if not already present.
# Per-EC2 (not per-slot) — one ubuntu user shares the install across slots.
ensure_claude_installed() {
  local host="$1"
  if ssh "$host" 'test -f "$HOME/'"$FLOWSLOT_INSTALL_MARKER_REL"'" && (test -x "$HOME/.local/bin/claude" || command -v claude >/dev/null 2>&1)' 2>/dev/null; then
    return 0
  fi

  log_info "Installing Claude Code on slot (one-time, ~30s)..."
  ssh "$host" bash << 'REMOTE_INSTALL'
    set -e
    mkdir -p "$HOME/.flowslot/bin"

    # Install prerequisites (jq is needed later for settings.json merge).
    if ! command -v jq >/dev/null 2>&1; then
      sudo apt-get update -qq
      sudo apt-get install -y jq curl >/dev/null
    fi

    # Run the official installer only if claude isn't present.
    if ! test -x "$HOME/.local/bin/claude" && ! command -v claude >/dev/null 2>&1; then
      curl -fsSL https://claude.ai/install.sh | bash
    fi

    # Make sure future non-interactive ssh sessions find claude on PATH.
    if ! grep -q 'flowslot-claude-path' "$HOME/.bashrc" 2>/dev/null; then
      cat >> "$HOME/.bashrc" << 'BRC'
# flowslot-claude-path
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
BRC
    fi

    date -u +%FT%TZ > "$HOME/.flowslot/claude-installed"
REMOTE_INSTALL
}

# rsync the user's ~/.claude credentials + settings to the slot.
# Called on every `slot claude` invocation so rotated OAuth tokens propagate.
# Returns 1 if local credentials file is missing (caller decides fallback).
sync_claude_auth() {
  local host="$1"

  if [ ! -f "$HOME/.claude/credentials.json" ]; then
    log_warn "No local ~/.claude/credentials.json — skipping auth sync."
    log_warn "Run 'claude /login' locally once, then rerun; or run /login inside the slot's tmux session."
    return 1
  fi

  ssh "$host" 'mkdir -p "$HOME/.claude"' 2>/dev/null

  local to_sync=("$HOME/.claude/credentials.json")
  [ -f "$HOME/.claude/settings.json" ] && to_sync+=("$HOME/.claude/settings.json")

  # --chmod=F600 mirrors the sensitive perms of credentials.json.
  if ! rsync -az --chmod=F600 "${to_sync[@]}" "$host:.claude/" 2>/dev/null; then
    log_warn "Credential rsync failed."
    return 1
  fi
  return 0
}

# Deploy the notify script to the slot and merge hooks into ~/.claude/settings.json.
# Idempotent; safe to call on every invocation.
# $1 = ssh host, $2 = absolute path to flowslot repo on local machine.
deploy_notify_hook() {
  local host="$1"
  local flowslot_root="$2"

  # 1) Copy the notify script.
  ssh "$host" 'mkdir -p "$HOME/.flowslot/bin"'
  rsync -az --chmod=F755 "$flowslot_root/infra/flowslot-notify.sh" \
    "$host:.flowslot/bin/flowslot-notify" 2>/dev/null

  # 2) Write notify.conf with CallMeBot creds (0600).
  ssh "$host" bash -s -- \
    "${FLOWSLOT_CALLMEBOT_PHONE:-}" \
    "${FLOWSLOT_CALLMEBOT_APIKEY:-}" \
    "${FLOWSLOT_CALLMEBOT_CHANNEL:-whatsapp}" << 'REMOTE_CONF'
    set -e
    phone="$1"
    apikey="$2"
    channel="$3"
    conf="$HOME/.flowslot/notify.conf"
    umask 077
    cat > "$conf" << CONF
FLOWSLOT_CALLMEBOT_PHONE="${phone}"
FLOWSLOT_CALLMEBOT_APIKEY="${apikey}"
FLOWSLOT_CALLMEBOT_CHANNEL="${channel}"
CONF
REMOTE_CONF

  # 3) Merge hook block into ~/.claude/settings.json using jq.
  ssh "$host" bash << 'REMOTE_MERGE'
    set -e
    settings="$HOME/.claude/settings.json"
    notify="$HOME/.flowslot/bin/flowslot-notify"
    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || echo '{}' > "$settings"

    tmp="$(mktemp)"
    jq --arg notify "$notify" '
      .hooks = (.hooks // {})
      | .hooks.Stop = [{ matcher: ".*", hooks: [{ type: "command", command: ($notify + " stop") }] }]
      | .hooks.Notification = [{ matcher: ".*", hooks: [{ type: "command", command: ($notify + " notification") }] }]
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
REMOTE_MERGE
}

# Quick sanity check that Claude can authenticate headlessly.
# Returns 0 on success, 1 if auth is broken (caller should fall back to tmux /login).
# Bypasses .bashrc, which typically short-circuits for non-interactive shells.
verify_claude_auth() {
  local host="$1"
  ssh "$host" 'PATH="$HOME/.local/bin:$PATH" claude -p --max-turns 0 "ping" >/dev/null 2>&1' \
    </dev/null >/dev/null 2>&1
}

# Mark a slot host as bootstrapped so subsequent calls skip the slow install+verify path.
mark_claude_ready() {
  local host="$1"
  ssh "$host" 'date -u +%FT%TZ > "$HOME/.flowslot/claude-ready"' 2>/dev/null || true
}

# Returns 0 if the slot has already been bootstrapped successfully.
claude_is_ready() {
  local host="$1"
  ssh "$host" 'test -f "$HOME/.flowslot/claude-ready"' 2>/dev/null
}

# Readable rendering of `claude --output-format stream-json` on stdin.
# Best-effort: unknown event shapes are passed through as raw JSON.
pretty_print_stream_json() {
  if ! command -v jq >/dev/null 2>&1; then
    cat
    return
  fi
  jq -r '
    if .type == "assistant" and (.message.content // [])[0].text then
      (.message.content[] | select(.type=="text") | .text)
    elif .type == "tool_use" or (.message.content // [])[0].type == "tool_use" then
      "[tool] " + ((.message.content // [])[0].name // .name // "?")
    elif .type == "result" then
      "\n[done] " + (.result // .text // "")
    elif .type == "error" then
      "[error] " + (.error // tostring)
    else
      empty
    end
  ' 2>/dev/null
}

# Session name for tmux, scoped per-slot so multiple slots don't collide.
claude_tmux_session() {
  local slot_name="$1"
  echo "claude-${slot_name}"
}
