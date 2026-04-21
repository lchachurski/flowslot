#!/bin/bash
# Helpers for `slot claude voice`. Sourced by scripts/slot-claude-voice.
# Depends on scripts/lib/common.sh being sourced first (remote_ssh etc).

# Pinned SHA of the lchachurski/call-me fork to install on the slot.
# Bump this when you want to pick up upstream changes. Override via
# FLOWSLOT_VOICE_PINNED_SHA in the environment.
readonly FLOWSLOT_CALL_ME_REPO='https://github.com/lchachurski/call-me.git'
readonly FLOWSLOT_CALL_ME_DEFAULT_SHA='fe43756ba484773da32266a7592d413f4a733557'
readonly FLOWSLOT_VOICE_LOCAL_PORT=8080

_voice_pinned_sha() {
  echo "${FLOWSLOT_VOICE_PINNED_SHA:-$FLOWSLOT_CALL_ME_DEFAULT_SHA}"
}

# Install bun on the slot if missing. Bun is call-me's runtime.
# Idempotent; safe to call every invocation.
ensure_bun_installed() {
  local host="$1"
  if ssh "$host" 'test -x "$HOME/.bun/bin/bun"' 2>/dev/null; then
    return 0
  fi
  log_info "Installing bun on slot (one-time)..."
  ssh "$host" bash << 'REMOTE_BUN'
    set -e
    if ! command -v unzip >/dev/null 2>&1; then
      sudo apt-get update -qq
      sudo apt-get install -y unzip curl >/dev/null
    fi
    curl -fsSL https://bun.sh/install | bash
REMOTE_BUN
}

# Clone the call-me fork at the pinned SHA, run bun install.
# Safe to call every invocation (idempotent fetch + checkout).
ensure_call_me_cloned() {
  local host="$1"
  local sha
  sha="$(_voice_pinned_sha)"

  log_info "Syncing call-me fork to ${sha:0:10} on slot..."
  ssh "$host" bash -s "$FLOWSLOT_CALL_ME_REPO" "$sha" << 'REMOTE_CLONE'
    set -e
    repo_url="$1"
    pin_sha="$2"
    dir="$HOME/.flowslot/call-me"
    export PATH="$HOME/.bun/bin:$PATH"

    if [ ! -d "$dir/.git" ]; then
      mkdir -p "$(dirname "$dir")"
      git clone --quiet "$repo_url" "$dir"
    fi

    cd "$dir"
    git fetch --quiet origin
    if [ "$(git rev-parse HEAD)" != "$pin_sha" ]; then
      git checkout --quiet --detach "$pin_sha"
    fi

    # package.json lives in the server/ subdir in this project layout.
    cd "$dir/server"
    # bun install is idempotent; only reinstalls if lockfile/packages changed.
    bun install --production >/dev/null 2>&1 || bun install >/dev/null
REMOTE_CLONE
}

# Write ~/.flowslot/call-me.env on the slot from local env vars.
# Values are piped via stdin — safer than ssh positional args.
write_call_me_env() {
  local host="$1"
  local public_url="$2"
  local tmp
  tmp="$(mktemp)"

  {
    echo "# Written by slot claude voice enable. Do not edit by hand."
    printf 'CALLME_PUBLIC_URL=%q\n'            "$public_url"
    printf 'CALLME_PORT=%q\n'                  "$FLOWSLOT_VOICE_LOCAL_PORT"
    printf 'CALLME_PHONE_ACCOUNT_SID=%q\n'     "${FLOWSLOT_TWILIO_ACCOUNT_SID:-}"
    printf 'CALLME_PHONE_AUTH_TOKEN=%q\n'      "${FLOWSLOT_TWILIO_AUTH_TOKEN:-}"
    printf 'CALLME_PHONE_NUMBER=%q\n'          "${FLOWSLOT_TWILIO_FROM:-}"
    printf 'CALLME_USER_PHONE_NUMBER=%q\n'     "${FLOWSLOT_TWILIO_TO:-}"
    printf 'CALLME_OPENAI_API_KEY=%q\n'        "${FLOWSLOT_OPENAI_API_KEY:-}"
    # Phone provider defaults to twilio when the SID starts with AC.
    echo "CALLME_PHONE_PROVIDER=twilio"
  } > "$tmp"

  ssh "$host" 'umask 077; mkdir -p "$HOME/.flowslot"; cat > "$HOME/.flowslot/call-me.env"' < "$tmp"
  rm -f "$tmp"
}

# Enable Tailscale Funnel for the local call-me port.
# Tailscale >= 1.64 uses a simplified CLI: `tailscale funnel --bg <port>`
# (previously required a separate `tailscale serve` call). See
# https://tailscale.com/kb/1242/tailscale-serve.
#
# If Funnel is not yet enabled on the tailnet for this node, Tailscale
# returns a node-specific enable URL in the error message; we surface that
# URL verbatim to the user so they can one-click it.
tailscale_funnel_enable() {
  local host="$1"
  local local_port="${2:-$FLOWSLOT_VOICE_LOCAL_PORT}"
  local output
  # shellcheck disable=SC2029
  output="$(ssh "$host" bash -s "$local_port" 2>&1 << 'REMOTE_FUNNEL_ON'
    set -e
    port="$1"
    sudo tailscale funnel reset 2>/dev/null || true
    sudo tailscale serve reset 2>/dev/null || true
    # --bg detaches; runs in ~3s or errors out immediately with a URL.
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

  # If we got here, either success (exit 0) or some other error.
  if echo "$output" | grep -qi "error"; then
    log_error "Tailscale Funnel enable failed:"
    echo "$output"
    return 1
  fi
  return 0
}

# Disable Tailscale Funnel on the slot. Idempotent.
tailscale_funnel_disable() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_FUNNEL_OFF' 2>/dev/null || true
    sudo tailscale funnel reset 2>/dev/null || true
    sudo tailscale serve reset 2>/dev/null || true
REMOTE_FUNNEL_OFF
}

# Read the public Funnel URL the slot currently serves for :443.
# Returns empty string if Funnel isn't configured.
get_tailscale_funnel_url() {
  local host="$1"
  ssh "$host" 'tailscale funnel status --json 2>/dev/null' \
    | jq -r '
        .. | objects | select(has("443")) | .["443"]
          | if type == "string" then . else empty end
      ' 2>/dev/null | head -1
}

# Alternative Funnel URL computation that doesn't depend on the status subcommand
# output shape (which shifts between Tailscale versions). Uses the node's own
# Tailscale fqdn.
get_tailscale_fqdn() {
  local host="$1"
  ssh "$host" 'tailscale status --json 2>/dev/null' \
    | jq -r '.Self.DNSName | rtrimstr(".")' 2>/dev/null
}

# Register the call-me MCP server via `claude mcp add` (user scope) so it's
# available to every Claude session on this slot. The MCP entry points at a
# bash wrapper that sources the env file and execs bun — this keeps Twilio /
# OpenAI creds out of Claude Code's own config storage.
register_mcp_in_settings() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_MCP_ADD'
    set -e
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

    # Wrapper that sources the env file then execs bun.
    wrapper="$HOME/.flowslot/bin/call-me-mcp"
    mkdir -p "$(dirname "$wrapper")"
    cat > "$wrapper" << 'WRAPPER'
#!/bin/bash
set -euo pipefail
set -a
# shellcheck disable=SC1091
. "$HOME/.flowslot/call-me.env"
set +a
export PATH="$HOME/.bun/bin:$PATH"
cd "$HOME/.flowslot/call-me/server"
exec bun run src/index.ts
WRAPPER
    chmod +x "$wrapper"

    # Remove any stale registration, then add. Use user scope so every
    # Claude invocation on this slot sees the tool.
    claude mcp remove --scope user call-me 2>/dev/null || true
    claude mcp add --scope user --transport stdio call-me "$wrapper"
REMOTE_MCP_ADD
}

# Remove the call-me MCP registration. Idempotent.
unregister_mcp_in_settings() {
  local host="$1"
  ssh "$host" bash << 'REMOTE_MCP_DEL' 2>/dev/null || true
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
    claude mcp remove --scope user call-me 2>/dev/null || true
    rm -f "$HOME/.flowslot/bin/call-me-mcp"
REMOTE_MCP_DEL
}

# Prompt user for an OpenAI API key if not already in the environment, and
# write it into the flowslot config.local so it persists across invocations.
# Writes via the standard SLOT_PROJECT_ROOT discovery — caller must have
# already sourced .slotconfig so find_config works.
ensure_openai_key_configured() {
  if [ -n "${FLOWSLOT_OPENAI_API_KEY:-}" ]; then
    return 0
  fi

  local project_config
  project_config="$(find_config 2>/dev/null)" || {
    log_error "Cannot locate .slotconfig; run 'slot self init' first."
    return 1
  }

  echo ""
  log_info "FLOWSLOT_OPENAI_API_KEY is not set in $project_config."
  echo "call-me needs an OpenAI API key for speech-to-text (Whisper) and text-to-speech."
  echo "Get one at https://platform.openai.com/api-keys — top up ~\$5 of credit."
  echo ""
  read -r -s -p "OpenAI API key (hidden): " key
  echo ""
  [ -z "$key" ] && { log_error "No key entered; aborting."; return 1; }

  if grep -q '^FLOWSLOT_OPENAI_API_KEY=' "$project_config" 2>/dev/null; then
    # Portable in-place edit for the existing line.
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" '
      /^FLOWSLOT_OPENAI_API_KEY=/ { print "FLOWSLOT_OPENAI_API_KEY=\"" k "\""; next }
      { print }
    ' "$project_config" > "$tmp" && mv "$tmp" "$project_config"
  else
    printf '\nFLOWSLOT_OPENAI_API_KEY=%q\n' "$key" >> "$project_config"
  fi
  export FLOWSLOT_OPENAI_API_KEY="$key"
}

# Validate required Twilio config is present. Returns 0 on success.
ensure_twilio_configured() {
  local missing=()
  [ -n "${FLOWSLOT_TWILIO_ACCOUNT_SID:-}" ] || missing+=(FLOWSLOT_TWILIO_ACCOUNT_SID)
  [ -n "${FLOWSLOT_TWILIO_AUTH_TOKEN:-}" ] || missing+=(FLOWSLOT_TWILIO_AUTH_TOKEN)
  [ -n "${FLOWSLOT_TWILIO_FROM:-}" ]       || missing+=(FLOWSLOT_TWILIO_FROM)
  [ -n "${FLOWSLOT_TWILIO_TO:-}" ]         || missing+=(FLOWSLOT_TWILIO_TO)

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Twilio is not configured. Missing in .slotconfig:"
    printf '  %s\n' "${missing[@]}"
    log_error "Re-run 'slot self init' or edit .slotconfig manually."
    return 1
  fi
  return 0
}
