#!/bin/bash
# Helpers for `slot claude voice` — v2.11 (ElevenLabs Conversational AI + bridge).
# Sourced by scripts/slot-claude-voice. Depends on scripts/lib/common.sh (remote_ssh etc).
#
# v2.11 architecture summary:
#   - Bridge: Python 3 HTTP server on :8080 on the slot, systemd-managed.
#   - Claude hooks: append PreToolUse/PostToolUse/Stop/Notification events to ~/.flowslot/bridge.db
#   - voice-outbound MCP: gives Claude a `call_user` tool that dials via ElevenLabs
#   - ElevenLabs CAI: the user configures an agent in their dashboard with 4 tools
#     that webhook to the bridge's Tailscale Funnel URL.

# Bridge binds locally on this port; Tailscale Funnel :443 forwards here.
# 9090 chosen to avoid clashes with common app ports (8080, 3000, 5000).
readonly FLOWSLOT_BRIDGE_LOCAL_PORT=9090
readonly FLOWSLOT_BRIDGE_SERVICE='flowslot-bridge.service'

# ============================================================================
# Tailscale Funnel (reused from v2.10 fixes)
# ============================================================================

tailscale_funnel_enable() {
  local host="$1"
  local local_port="${2:-$FLOWSLOT_BRIDGE_LOCAL_PORT}"
  local output
  # shellcheck disable=SC2029
  output="$(ssh "$host" bash -s "$local_port" 2>&1 << 'REMOTE_FUNNEL_ON'
    set -e
    port="$1"
    sudo tailscale funnel reset 2>/dev/null || true
    sudo tailscale serve reset 2>/dev/null || true
    timeout 20 sudo tailscale funnel --bg "$port"
REMOTE_FUNNEL_ON
  )" || true

  if echo "$output" | grep -q "Funnel is not enabled"; then
    log_error "Tailscale Funnel is not yet enabled for this EC2 node."
    echo ""
    echo "Tailscale provided a one-click enable URL specific to this node:"
    echo ""
    echo "$output" | grep -oE 'https://login\.tailscale\.com/[^ ]*'
    echo ""
    echo "Open it in a browser where you're signed into your Tailscale admin,"
    echo "click 'Enable', then retry 'slot claude voice enable'."
    return 1
  fi

  if echo "$output" | grep -qi "error"; then
    log_error "Tailscale Funnel enable failed:"
    echo "$output"
    return 1
  fi
  return 0
}

tailscale_funnel_disable() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_FUNNEL_OFF' 2>/dev/null || true
    sudo tailscale funnel reset 2>/dev/null || true
    sudo tailscale serve reset 2>/dev/null || true
REMOTE_FUNNEL_OFF
}

get_tailscale_fqdn() {
  local host="$1"
  ssh "$host" 'tailscale status --json 2>/dev/null' \
    | jq -r '.Self.DNSName | rtrimstr(".")' 2>/dev/null
}

# ============================================================================
# Credential preflight
# ============================================================================

# Validates ElevenLabs + Twilio config. Prompts for anything missing and writes
# back to the project .slotconfig. Exits non-zero if user aborts.
ensure_elevenlabs_configured() {
  local cfg
  cfg="$(find_config 2>/dev/null)" || {
    log_error "Cannot locate .slotconfig; run 'slot self init' first."
    return 1
  }

  # Ensure each required var exists; prompt if missing.
  _prompt_and_save_var FLOWSLOT_ELEVENLABS_API_KEY "$cfg" secret \
    "ElevenLabs API key (from elevenlabs.io → Profile → API keys):" || return 1
  _prompt_and_save_var FLOWSLOT_ELEVENLABS_AGENT_ID "$cfg" plain \
    "ElevenLabs Conversational AI agent ID (create one in your dashboard):" || return 1
  _prompt_and_save_var FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID "$cfg" plain \
    "ElevenLabs phone number ID (from elevenlabs.io → Agents → Phone numbers):" || return 1
  _prompt_and_save_var FLOWSLOT_TWILIO_TO "$cfg" plain \
    "Your phone number in E.164 (e.g. +46701234567) — the one that rings:" || return 1

  # HMAC secret is auto-generated if not already set.
  if ! _var_set FLOWSLOT_BRIDGE_HMAC_SECRET "$cfg"; then
    local secret
    secret="$(openssl rand -hex 32)"
    _save_var FLOWSLOT_BRIDGE_HMAC_SECRET "$secret" "$cfg"
    export FLOWSLOT_BRIDGE_HMAC_SECRET="$secret"
    log_info "Generated FLOWSLOT_BRIDGE_HMAC_SECRET and saved to $cfg"
  fi
}

_var_set() {
  local name="$1"
  local cfg="$2"
  if [ -n "${!name:-}" ]; then return 0; fi
  grep -q "^${name}=\"[^\"]\+\"" "$cfg" 2>/dev/null
}

_save_var() {
  local name="$1"
  local value="$2"
  local cfg="$3"
  local tmp
  tmp="$(mktemp)"
  if grep -q "^${name}=" "$cfg" 2>/dev/null; then
    awk -v n="$name" -v v="$value" \
      'BEGIN{FS=OFS="="} $1==n { print n "=\"" v "\""; next } { print }' \
      "$cfg" > "$tmp"
  else
    cp "$cfg" "$tmp"
    printf '%s="%s"\n' "$name" "$value" >> "$tmp"
  fi
  mv "$tmp" "$cfg"
  export "${name}=${value}"
}

_prompt_and_save_var() {
  local name="$1"
  local cfg="$2"
  local mode="$3"  # "secret" or "plain"
  local msg="$4"

  if _var_set "$name" "$cfg"; then
    if [ -z "${!name:-}" ]; then
      local val
      val="$(grep "^${name}=" "$cfg" | head -1 | sed -E 's/^[^=]+="?([^"]*)"?/\1/')"
      export "${name}=${val}"
    fi
    return 0
  fi

  echo ""
  log_info "$name is not set in $cfg"
  echo "$msg"
  local val
  if [ "$mode" = "secret" ]; then
    read -r -s -p "  $name (hidden): " val
    echo ""
  else
    read -r -p "  $name: " val
  fi
  [ -z "$val" ] && { log_error "No value entered; aborting."; return 1; }
  _save_var "$name" "$val" "$cfg"
}

# ============================================================================
# Bridge install / teardown
# ============================================================================

ensure_bridge_deps_installed() {
  local host="$1"
  local missing=()
  ssh "$host" 'command -v python3 >/dev/null 2>&1' 2>/dev/null || missing+=(python3 python3-minimal)
  ssh "$host" 'command -v sqlite3 >/dev/null 2>&1' 2>/dev/null || missing+=(sqlite3)
  ssh "$host" 'command -v jq      >/dev/null 2>&1' 2>/dev/null || missing+=(jq)
  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  fi
  log_info "Installing bridge deps on slot: ${missing[*]}"
  # shellcheck disable=SC2029
  ssh "$host" "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${missing[*]} >/dev/null"
}

# Back-compat alias — old callers.
ensure_python3_installed() { ensure_bridge_deps_installed "$@"; }

install_bridge() {
  local host="$1"
  local flowslot_root="$2"

  log_info "Installing bridge server + hooks on slot..."
  ssh "$host" 'mkdir -p "$HOME/.flowslot/bridge/hooks"'
  rsync -az \
    "$flowslot_root/infra/bridge/server.py" \
    "$flowslot_root/infra/bridge/schema.sql" \
    "$host:.flowslot/bridge/"
  rsync -az "$flowslot_root/infra/bridge/hooks/" "$host:.flowslot/bridge/hooks/"

  # Initialize SQLite DB if missing; idempotent schema upgrade if present.
  ssh "$host" bash << 'REMOTE_DB_INIT'
    set -e
    db="$HOME/.flowslot/bridge.db"
    sqlite3 "$db" < "$HOME/.flowslot/bridge/schema.sql" 2>/dev/null || true
    chmod +x "$HOME/.flowslot/bridge/hooks/"*.sh "$HOME/.flowslot/bridge/hooks/"*.py 2>/dev/null || true
    chmod +x "$HOME/.flowslot/bridge/server.py" 2>/dev/null || true
REMOTE_DB_INIT
}

deploy_bridge_systemd() {
  local host="$1"
  local flowslot_root="$2"

  local tmpl="$flowslot_root/infra/flowslot-bridge.service.tmpl"
  [ -f "$tmpl" ] || { log_error "Missing $tmpl"; return 1; }

  rsync -az "$tmpl" "$host:.flowslot/${FLOWSLOT_BRIDGE_SERVICE}.staged"
  # shellcheck disable=SC2029
  ssh "$host" bash -s "$FLOWSLOT_BRIDGE_SERVICE" << 'REMOTE_SVC'
    set -e
    unit="$1"
    staged="$HOME/.flowslot/${unit}.staged"
    target="/etc/systemd/system/${unit}"
    sudo install -m 0644 "$staged" "$target"
    rm -f "$staged"
    sudo systemctl daemon-reload
    sudo systemctl enable "$unit"
    # Always restart to pick up any env-file changes on re-enable.
    sudo systemctl restart "$unit"
REMOTE_SVC
}

bridge_service_stop() {
  local host="$1"
  ssh "$host" "sudo systemctl disable --now $FLOWSLOT_BRIDGE_SERVICE 2>/dev/null || true"
}

bridge_service_is_active() {
  local host="$1"
  ssh "$host" "systemctl is-active --quiet $FLOWSLOT_BRIDGE_SERVICE" 2>/dev/null
}

# Write ~/.flowslot/bridge.env on the slot from local env vars. Consumed by
# both the bridge systemd unit and the voice-outbound MCP wrapper.
write_bridge_env() {
  local host="$1"
  local active_slot="$2"
  local tmp
  tmp="$(mktemp)"
  {
    echo "# Written by slot claude voice enable. Do not edit by hand."
    printf 'FLOWSLOT_ACTIVE_SLOT=%q\n'              "$active_slot"
    printf 'FLOWSLOT_BRIDGE_PORT=%q\n'              "$FLOWSLOT_BRIDGE_LOCAL_PORT"
    printf 'FLOWSLOT_BRIDGE_DB=%s\n'                "/home/ubuntu/.flowslot/bridge.db"
    printf 'FLOWSLOT_BRIDGE_HMAC_SECRET=%q\n'       "${FLOWSLOT_BRIDGE_HMAC_SECRET:-}"
    printf 'FLOWSLOT_ELEVENLABS_API_KEY=%q\n'       "${FLOWSLOT_ELEVENLABS_API_KEY:-}"
    printf 'FLOWSLOT_ELEVENLABS_AGENT_ID=%q\n'      "${FLOWSLOT_ELEVENLABS_AGENT_ID:-}"
    printf 'FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID=%q\n' "${FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID:-}"
    printf 'FLOWSLOT_TWILIO_TO=%q\n'                "${FLOWSLOT_TWILIO_TO:-}"
  } > "$tmp"
  ssh "$host" 'umask 077; mkdir -p "$HOME/.flowslot"; cat > "$HOME/.flowslot/bridge.env"' < "$tmp"
  rm -f "$tmp"
}

# ============================================================================
# Claude Code hooks — register the 4 bridge hooks in ~/.claude/settings.json
# ============================================================================

install_claude_hooks() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_HOOKS'
    set -e
    settings="$HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || echo '{}' > "$settings"

    H="$HOME/.flowslot/bridge/hooks"
    tmp="$(mktemp)"
    jq --arg pretool "$H/pretool.sh" \
       --arg posttool "$H/posttool.sh" \
       --arg stop "$H/stop.sh" \
       --arg notif "$H/notification.sh" '
      .hooks = (.hooks // {})
      | .hooks.PreToolUse    = [{ matcher: ".*", hooks: [{ type: "command", command: $pretool }] }]
      | .hooks.PostToolUse   = [{ matcher: ".*", hooks: [{ type: "command", command: $posttool }] }]
      | .hooks.Stop          = [{ matcher: ".*", hooks: [{ type: "command", command: $stop }] }]
      | .hooks.Notification  = [{ matcher: ".*", hooks: [{ type: "command", command: $notif }] }]
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
REMOTE_HOOKS
}

uninstall_claude_hooks() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_HOOKS_DEL' 2>/dev/null || true
    set -e
    settings="$HOME/.claude/settings.json"
    [ -f "$settings" ] || exit 0
    tmp="$(mktemp)"
    jq 'if .hooks then del(.hooks.PreToolUse, .hooks.PostToolUse, .hooks.Stop, .hooks.Notification) else . end' \
       "$settings" > "$tmp" && mv "$tmp" "$settings"
REMOTE_HOOKS_DEL
}

# ============================================================================
# voice-outbound MCP — Claude's `call_user` tool
# ============================================================================

install_voice_outbound_mcp() {
  local host="$1"
  local flowslot_root="$2"

  ssh "$host" 'mkdir -p "$HOME/.flowslot/voice-outbound-mcp" "$HOME/.flowslot/bin"'
  rsync -az \
    "$flowslot_root/infra/voice-outbound-mcp/server.py" \
    "$flowslot_root/infra/voice-outbound-mcp/wrapper.sh" \
    "$host:.flowslot/voice-outbound-mcp/"
  ssh "$host" bash << 'REMOTE_MCP_REG'
    set -e
    export PATH="$HOME/.local/bin:$PATH"
    chmod +x "$HOME/.flowslot/voice-outbound-mcp/server.py"
    chmod +x "$HOME/.flowslot/voice-outbound-mcp/wrapper.sh"
    ln -sf "$HOME/.flowslot/voice-outbound-mcp/wrapper.sh" "$HOME/.flowslot/bin/voice-outbound-mcp"

    claude mcp remove --scope user voice-outbound 2>/dev/null || true
    claude mcp add --scope user --transport stdio voice-outbound "$HOME/.flowslot/bin/voice-outbound-mcp"
REMOTE_MCP_REG
}

uninstall_voice_outbound_mcp() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_MCP_DEL' 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH"
    claude mcp remove --scope user voice-outbound 2>/dev/null || true
    rm -f "$HOME/.flowslot/bin/voice-outbound-mcp"
REMOTE_MCP_DEL
}

# ============================================================================
# v2.10 cleanup — remove call-me artifacts from a slot that was on v2.10
# ============================================================================

cleanup_v210_artifacts() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_CLEAN' 2>/dev/null || true
    set +e
    export PATH="$HOME/.local/bin:$PATH"
    # Kill any lingering call-me/bun process launched from earlier Claude sessions.
    # The process runs as `bun run src/index.ts` from the call-me/server cwd, so
    # match on parent-dir instead of command string: walk /proc and kill matches.
    for pid in $(pgrep -x bun 2>/dev/null); do
      cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
      case "$cwd" in *.flowslot/call-me*) kill "$pid" 2>/dev/null ;; esac
    done
    claude mcp remove --scope user call-me 2>/dev/null
    rm -f  "$HOME/.flowslot/bin/call-me-mcp"
    rm -f  "$HOME/.flowslot/call-me.env"
    rm -f  "$HOME/.flowslot/notify.conf"
    rm -rf "$HOME/.flowslot/call-me"
    exit 0
REMOTE_CLEAN
}

# ============================================================================
# Agent config output — emitted by `slot claude voice agent-config`
# ============================================================================

print_agent_config() {
  local flowslot_root="$1"
  local funnel_url="$2"
  local hmac_secret="$3"

  local prompt_file="$flowslot_root/templates/agent-system-prompt.md"
  local tools_file="$flowslot_root/templates/agent-tools.json"

  [ -f "$prompt_file" ] || { log_error "Missing $prompt_file"; return 1; }
  [ -f "$tools_file" ]  || { log_error "Missing $tools_file"; return 1; }

  cat << EOF

==============================================================================
 ElevenLabs Agent Configuration — paste the pieces below into your CAI agent
==============================================================================

 Agent webhook base URL:
   ${funnel_url}

 HMAC-SHA256 secret (header 'X-Flowslot-Signature' on every tool webhook):
   ${hmac_secret}

 Recommended LLM for the agent: Claude (Anthropic) — so the voice brain is
 Claude, talking *about* the running Claude Code session.

 ------------------------------------------------------------------------------
 1) SYSTEM PROMPT  (paste into agent → Prompt)
 ------------------------------------------------------------------------------

EOF

  cat "$prompt_file"

  cat << EOF

 ------------------------------------------------------------------------------
 2) TOOLS  (add as server-side tools / webhooks, one per tool)
 ------------------------------------------------------------------------------
 The JSON below lists all 4 tools. ElevenLabs' dashboard accepts them one at
 a time; copy each tool block. Every tool uses the base URL above, and every
 request needs the HMAC signature header (the dashboard has a signing helper —
 select HMAC-SHA256 over "path + body" with the secret above).

EOF

  sed "s|{{BASE_URL}}|${funnel_url}|g" "$tools_file"

  cat << EOF

 ------------------------------------------------------------------------------
 3) VOICE  (agent → Voice)
 ------------------------------------------------------------------------------
 Any ElevenLabs voice will work. For coding contexts, 'eleven_turbo_v2_5' or
 'eleven_flash_v2_5' with a professional voice (e.g. 'Brian', 'Adam') is
 fast and low-latency.

 ==============================================================================
 Save the agent. Then: call the agent's phone number from your phone.
 Say 'how's it going?' to test get_claude_state;
 Say 'read me the last thing Claude said' to test get_claude_last_output.
 ==============================================================================

EOF
}
