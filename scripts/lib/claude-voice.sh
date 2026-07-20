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

# v2.17+: install the GitHub CLI on the slot host. Claude inside voice-created
# slots needs `gh` to interact with PRs/issues — falling back to raw
# api.github.com curls works but trains the agent (and the user) to think the
# slot is half-broken. Adds the official cli.github.com apt source on first
# install, skips otherwise.
ensure_gh_installed() {
  local host="$1"
  if ssh "$host" 'command -v gh >/dev/null 2>&1' 2>/dev/null; then
    return 0
  fi
  log_info "Installing GitHub CLI (gh) on slot..."
  ssh "$host" bash <<'REMOTE_GH_INSTALL'
    set -e
    # Official install steps from https://github.com/cli/cli/blob/trunk/docs/install_linux.md
    type -p curl >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null
    sudo mkdir -p -m 755 /etc/apt/keyrings
    out="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
    if [ ! -s "$out" ]; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee "$out" >/dev/null
      sudo chmod go+r "$out"
    fi
    list="/etc/apt/sources.list.d/github-cli.list"
    if [ ! -s "$list" ]; then
      arch="$(dpkg --print-architecture)"
      echo "deb [arch=$arch signed-by=$out] https://cli.github.com/packages stable main" \
        | sudo tee "$list" >/dev/null
    fi
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh >/dev/null
REMOTE_GH_INSTALL
}

# v2.17+: sync the Mac's already-authenticated `gh` session to the slot host,
# then run `gh auth setup-git` there so any later `git push` over https can use
# the same credentials. The Mac is assumed to be already `gh auth login`'d —
# we read its hosts.yml directly. No new secret to manage; reuses the user's
# existing GitHub PAT.
sync_gh_auth_to_host() {
  local host="$1"
  local local_hosts="$HOME/.config/gh/hosts.yml"
  if [ ! -f "$local_hosts" ]; then
    log_error "No gh config at $local_hosts on this Mac."
    log_error "Run \`gh auth login\` first, then re-run \`slot claude voice enable\`."
    return 1
  fi
  log_info "Syncing local gh auth (~/.config/gh/hosts.yml) to slot host..."
  ssh "$host" 'mkdir -p "$HOME/.config/gh" && chmod 700 "$HOME/.config/gh"'
  # Use scp + explicit mode so the file lands with 600 on the slot.
  scp -q "$local_hosts" "$host:.config/gh/hosts.yml"
  ssh "$host" 'chmod 600 "$HOME/.config/gh/hosts.yml"'
  # Wire git push https → gh credential helper so future `git push` from
  # voice-created slots Just Works without prompting for a password.
  ssh "$host" 'gh auth setup-git 2>/dev/null || true'
}

# Set up /srv/<project>/.flowslot-hq/ on the remote — the canonical source
# for `.env*` files used by `slot_create_remote.sh`. Avoids the bridge having
# to copy env from a sibling slot, which mixes per-slot drift back into new
# slots and breaks when there's no sibling.
#
# HQ is hidden (leading dot) so it doesn't match the bridge's slot-discovery
# glob `/srv/*/*-NNNN`.
ensure_hq_dir() {
  local host="$1"
  [ -n "${SLOT_REMOTE_BASE:-}" ] || { log_warn "SLOT_REMOTE_BASE not set; skipping HQ setup"; return 1; }
  [ -n "${SLOT_SOURCE_DIR:-}" ]  || { log_warn "SLOT_SOURCE_DIR not set; skipping HQ setup";  return 1; }

  local hq="$SLOT_REMOTE_BASE/.flowslot-hq"
  log_info "Setting up HQ dir at $host:$hq..."

  # Create the dir (may need sudo if /srv/<project> doesn't exist yet).
  # shellcheck disable=SC2029
  ssh "$host" bash -s "$SLOT_REMOTE_BASE" "$hq" <<'REMOTE_HQ'
    set -e
    base="$1"; hq="$2"
    if [ ! -d "$base" ]; then
      sudo mkdir -p "$base"
      sudo chown "$USER:$USER" "$base"
    fi
    mkdir -p "$hq"
REMOTE_HQ

  # rsync just the .env* files from the local source repo. Limit depth (4) and
  # skip noisy paths to match what slot-create copies on the Mac side.
  if [ -d "$SLOT_SOURCE_DIR" ]; then
    local tmp_filelist
    tmp_filelist="$(mktemp)"
    ( cd "$SLOT_SOURCE_DIR" && find . -maxdepth 4 -name ".env*" -type f \
        ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/dist/*" \
        ! -path "*/.next/*" | sed 's|^\./||' ) > "$tmp_filelist"
    if [ -s "$tmp_filelist" ]; then
      log_info "  Syncing $(wc -l < "$tmp_filelist" | tr -d ' ') .env* files into HQ..."
      rsync -az --files-from="$tmp_filelist" \
        "$SLOT_SOURCE_DIR/" "$host:$hq/" 2>&1 | tail -5
    else
      log_warn "  No .env* files found in $SLOT_SOURCE_DIR — HQ will be empty"
    fi
    rm -f "$tmp_filelist"
  fi
}


install_bridge() {
  local host="$1"
  local flowslot_root="$2"

  log_info "Installing bridge server + hooks + bin/ helpers on slot..."
  ssh "$host" 'mkdir -p "$HOME/.flowslot/bridge/hooks" "$HOME/.flowslot/bridge/bin"'
  rsync -az \
    "$flowslot_root/infra/bridge/server.py" \
    "$flowslot_root/infra/bridge/schema.sql" \
    "$flowslot_root/infra/bridge/events-tail.sh" \
    "$host:.flowslot/bridge/"
  rsync -az "$flowslot_root/infra/bridge/hooks/" "$host:.flowslot/bridge/hooks/"
  # v2.16+: slot-lifecycle helpers (create/destroy/start-claude) invoked by
  # the bridge's POST /bridge/slot/* endpoints. Co-located with server.py so
  # the bridge can `subprocess.run` them without an absolute PATH dance.
  rsync -az "$flowslot_root/infra/bridge/bin/" "$host:.flowslot/bridge/bin/"

  # Initialize SQLite DB if missing; idempotent schema upgrade if present.
  ssh "$host" bash << 'REMOTE_DB_INIT'
    set -e
    db="$HOME/.flowslot/bridge.db"
    sqlite3 "$db" < "$HOME/.flowslot/bridge/schema.sql" 2>/dev/null || true
    chmod +x "$HOME/.flowslot/bridge/hooks/"*.sh "$HOME/.flowslot/bridge/hooks/"*.py 2>/dev/null || true
    chmod +x "$HOME/.flowslot/bridge/server.py" 2>/dev/null || true
    chmod +x "$HOME/.flowslot/bridge/events-tail.sh" 2>/dev/null || true
    chmod +x "$HOME/.flowslot/bridge/bin/"*.sh 2>/dev/null || true
REMOTE_DB_INIT
}

# Lazily deploy events-tail.sh for `voice watch` callers whose bridge was
# installed before this helper existed. Idempotent.
ensure_events_tail_installed() {
  local host="$1"
  local flowslot_root="$2"
  if ssh "$host" 'test -x "$HOME/.flowslot/bridge/events-tail.sh"' 2>/dev/null; then
    return 0
  fi
  ssh "$host" 'mkdir -p "$HOME/.flowslot/bridge"' 2>/dev/null
  rsync -az "$flowslot_root/infra/bridge/events-tail.sh" "$host:.flowslot/bridge/events-tail.sh"
  ssh "$host" 'chmod +x "$HOME/.flowslot/bridge/events-tail.sh"' 2>/dev/null
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
#
# v2.15+: FLOWSLOT_ACTIVE_SLOT is no longer written — slot is per-request
# now. Before overwriting, we capture the OLD FLOWSLOT_ACTIVE_SLOT value (if
# any) and run a one-time backfill: UPDATE events SET slot = <old> WHERE slot
# IS NULL. Preserves historical rows for single-slot hosts upgrading to v2.15.
write_bridge_env() {
  local host="$1"
  local tmp
  tmp="$(mktemp)"
  {
    echo "# Written by slot claude voice enable. Do not edit by hand."
    printf 'FLOWSLOT_BRIDGE_PORT=%q\n'              "$FLOWSLOT_BRIDGE_LOCAL_PORT"
    printf 'FLOWSLOT_BRIDGE_DB=%s\n'                "/home/ubuntu/.flowslot/bridge.db"
    printf 'FLOWSLOT_BRIDGE_HMAC_SECRET=%q\n'       "${FLOWSLOT_BRIDGE_HMAC_SECRET:-}"
    printf 'FLOWSLOT_ELEVENLABS_API_KEY=%q\n'       "${FLOWSLOT_ELEVENLABS_API_KEY:-}"
    printf 'FLOWSLOT_ELEVENLABS_AGENT_ID=%q\n'      "${FLOWSLOT_ELEVENLABS_AGENT_ID:-}"
    printf 'FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID=%q\n' "${FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID:-}"
    printf 'FLOWSLOT_TWILIO_TO=%q\n'                "${FLOWSLOT_TWILIO_TO:-}"
    # v2.16+: bridge's slot-lifecycle endpoints need the same compose-file list
    # the local CLI uses. Ships in bridge.env so the bridge knows which files
    # the consuming project actually wants (avoids picking up prod.yml etc.).
    printf 'FLOWSLOT_COMPOSE_FILES=%q\n'            "${SLOT_COMPOSE_FILES:-}"
    printf 'FLOWSLOT_PROJECT_NAME=%q\n'             "${SLOT_PROJECT_NAME:-}"
    printf 'FLOWSLOT_REPO_URL=%q\n'                 "${SLOT_REPO_URL:-}"
  } > "$tmp"
  # One-shot v2.15 migration: backfill the new events.slot column from the
  # legacy FLOWSLOT_ACTIVE_SLOT value, then overwrite bridge.env without it.
  # `set -a; source bridge.env; set +a` makes FLOWSLOT_ACTIVE_SLOT available
  # in the parent shell; Python's sqlite3 handles quoting safely.
  ssh "$host" 'bash -s' <<'REMOTE_MIGRATE'
    set -e
    ENV_FILE="$HOME/.flowslot/bridge.env"
    DB="$HOME/.flowslot/bridge.db"
    if [ -f "$ENV_FILE" ] && [ -f "$DB" ]; then
      OLD_SLOT="$(set -a; . "$ENV_FILE" 2>/dev/null; printf %s "${FLOWSLOT_ACTIVE_SLOT:-}")"
      if [ -n "$OLD_SLOT" ]; then
        python3 - "$DB" "$OLD_SLOT" <<'PYMIG'
import sys, sqlite3
db, slot = sys.argv[1], sys.argv[2]
with sqlite3.connect(db, timeout=5) as c:
    cols = {r[1] for r in c.execute("PRAGMA table_info(events)")}
    if "slot" not in cols:
        c.execute("ALTER TABLE events ADD COLUMN slot TEXT")
    if "project" not in cols:
        c.execute("ALTER TABLE events ADD COLUMN project TEXT")
    n = c.execute("UPDATE events SET slot=? WHERE slot IS NULL", (slot,)).rowcount
    c.commit()
    print(f"[bridge migrate] backfilled {n} legacy events to slot={slot!r}")
PYMIG
      fi
    fi
REMOTE_MIGRATE
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
       --arg notif "$H/notification.sh" \
       --arg userprompt "$H/userprompt.sh" '
      .hooks = (.hooks // {})
      | .hooks.PreToolUse       = [{ matcher: ".*", hooks: [{ type: "command", command: $pretool }] }]
      | .hooks.PostToolUse      = [{ matcher: ".*", hooks: [{ type: "command", command: $posttool }] }]
      | .hooks.Stop             = [{ matcher: ".*", hooks: [{ type: "command", command: $stop }] }]
      | .hooks.Notification     = [{ matcher: ".*", hooks: [{ type: "command", command: $notif }] }]
      | .hooks.UserPromptSubmit = [{ matcher: ".*", hooks: [{ type: "command", command: $userprompt }] }]
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
    jq 'if .hooks then del(.hooks.PreToolUse, .hooks.PostToolUse, .hooks.Stop, .hooks.Notification, .hooks.UserPromptSubmit) else . end' \
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


# ============================================================================
# Agent push — PATCH the live ElevenLabs CAI agent's tools + system prompt
# directly via the API, so the user doesn't have to copy-paste each time.
# Same pattern used to fix the X-Flowslot-Token rotation issue in v2.13.
# ============================================================================

push_agent_to_elevenlabs() {
  local flowslot_root="$1"
  local funnel_url="$2"
  local hmac_secret="$3"
  local api_key="$4"
  local agent_id="$5"
  local allowed_caller="${6:-}"

  local tools_file="$flowslot_root/templates/agent-tools.json"
  local prompt_file="$flowslot_root/templates/agent-system-prompt.md"
  [ -f "$tools_file" ]  || { log_error "Missing $tools_file"; return 1; }
  [ -f "$prompt_file" ] || { log_error "Missing $prompt_file"; return 1; }

  python3 - "$tools_file" "$prompt_file" "$funnel_url" "$hmac_secret" "$api_key" "$agent_id" "$allowed_caller" <<'PY'
import json, sys, urllib.request, urllib.error

tools_file, prompt_file, funnel_url, hmac_secret, api_key, agent_id, allowed_caller = sys.argv[1:8]
ELEVEN = "https://api.elevenlabs.io/v1/convai/agents"

# 1. Load + substitute the flowslot template.
raw = open(tools_file).read()
raw = raw.replace("{{BASE_URL}}", funnel_url).replace("{{FLOWSLOT_BRIDGE_HMAC_SECRET}}", hmac_secret)
src = json.loads(raw)
prompt_text = open(prompt_file).read()
# Caller-ID gate substitution — never embed the real number in the template;
# it comes from .slotconfig (gitignored). If unset, leave the placeholder
# unresolved so the gate fails closed for every caller.
prompt_text = prompt_text.replace("{{FLOWSLOT_ALLOWED_CALLER}}", allowed_caller or "__unset__")


def to_eleven(t):
    """Convert a flowslot-template tool dict to ElevenLabs CAI webhook tool shape."""
    api = {
        "url":             t["url"],
        "method":          t.get("method", "GET"),
        "request_headers": t.get("headers", {}),
    }
    # Query params: build JSON-schema-style shape from our condensed form.
    q = t.get("query") or {}
    if q:
        props, required = {}, []
        for name, spec in q.items():
            entry = {k: v for k, v in spec.items() if k != "required"}
            props[name] = entry
            if spec.get("required"):
                required.append(name)
        api["query_params_schema"] = {"properties": props, "required": required}
    # Body schema: pass through if present.
    if t.get("body_schema"):
        api["request_body_schema"] = t["body_schema"]
    return {
        "name":        t["name"],
        "description": t["description"],
        "type":        "webhook",
        "api_schema":  api,
    }


tools_eleven = [to_eleven(t) for t in src["tools"]]

# 2. Fetch current agent — keep voice/LLM settings untouched.
def req(method, body=None):
    r = urllib.request.Request(
        f"{ELEVEN}/{agent_id}",
        method=method,
        headers={"xi-api-key": api_key, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"[agent-push] HTTP {e.code} on {method}: {e.read().decode()[:500]}", file=sys.stderr)
        raise

current = req("GET")
agent_block = current["conversation_config"]["agent"]
prompt_block = agent_block.get("prompt") or {}

# 3. Build PATCH body: replace prompt.tools + prompt.prompt only.
# ElevenLabs rejects both `tools` (inline) and `tool_ids` (workspace refs)
# in the same prompt block, so we explicitly null tool_ids when sending
# inline tools. Strip our copied tool_ids before the merge.
prompt_block = {k: v for k, v in prompt_block.items()
                if k not in ("tools", "tool_ids")}
patch = {
    "conversation_config": {
        "agent": {
            "prompt": {
                **prompt_block,
                "prompt":   prompt_text,
                "tools":    tools_eleven,
                "tool_ids": [],
            }
        }
    }
}

req("PATCH", patch)

# 3b. Second PATCH: enable the `end_call` system tool so the caller-ID gate
# at the top of the system prompt can actually hang up on unauthorized
# callers. Kept in a SEPARATE PATCH because when sent in the same PATCH as
# `tools: [...]`, the API silently drops enabled built_in_tools entries.
# Sending only built_in_tools works reliably. Minimal shape (name +
# description) — API auto-fills type/params server-side.
req("PATCH", {
    "conversation_config": {
        "agent": {
            "prompt": {
                "built_in_tools": {
                    "end_call": {
                        "name":        "end_call",
                        "description": "End the current phone call. Use when the caller is unauthorized (failed the access gate at the top of the system prompt), or when the caller says goodbye / hangs up / task is complete.",
                    }
                }
            }
        }
    }
})

# 4. Verify round-trip. The live tools list includes any enabled built_in
# system tools (end_call from step 3b), so filter those out before comparing
# the webhook tool names we actually pushed.
after = req("GET")
after_tools = after["conversation_config"]["agent"]["prompt"]["tools"]
after_built_in = after["conversation_config"]["agent"]["prompt"].get("built_in_tools") or {}
enabled_built_in = [n for n, v in after_built_in.items() if v]
webhook_after  = [t for t in after_tools if t.get("type") != "system"]
names_expected = [t["name"] for t in tools_eleven]
names_after    = [t["name"] for t in webhook_after]
print(f"[agent-push] expected {len(names_expected)} webhook tools: {names_expected}")
print(f"[agent-push] now live  {len(names_after)} webhook tools: {names_after}")
print(f"[agent-push] built-in system tools enabled: {enabled_built_in}")

# Spot-check: every tool carries the right token.
mismatches = []
for t in after_tools:
    tok = (t.get("api_schema") or {}).get("request_headers", {}).get("X-Flowslot-Token")
    if tok and tok != hmac_secret:
        mismatches.append(f"{t.get('name')}: token mismatch")
if mismatches:
    print("[agent-push] WARNING:", "; ".join(mismatches), file=sys.stderr)
    sys.exit(2)

if set(names_after) != set(names_expected):
    print("[agent-push] WARNING: tool name set diverged after PATCH", file=sys.stderr)
    sys.exit(3)

print(f"[agent-push] success: agent {agent_id} now serves {len(names_after)} webhook tools + {len(enabled_built_in)} built-in, system prompt updated.")
PY
}
