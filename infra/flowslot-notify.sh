#!/bin/bash
# flowslot-notify — invoked by Claude Code hooks on a slot to call/message the user.
#
# Deployed to ~/.flowslot/bin/flowslot-notify by `slot claude` (see scripts/lib/claude.sh).
# Config is sourced from ~/.flowslot/notify.conf (0600, written by deploy_notify_hook).
#
# Usage:
#   flowslot-notify <event>    event ∈ { stop, notification }
#
# Config (sourced from ~/.flowslot/notify.conf):
#   FLOWSLOT_CALLMEBOT_PHONE       Phone number in international format (e.g. +46701234567)
#                                  For 'telegram' channel: a Telegram @username instead.
#   FLOWSLOT_CALLMEBOT_APIKEY      CallMeBot API key (obtained per-channel from CallMeBot).
#   FLOWSLOT_CALLMEBOT_CHANNEL     whatsapp | signal | telegram  (default: whatsapp)
#   FLOWSLOT_CALLMEBOT_URL_TEMPLATE  Optional override: URL with {PHONE}, {APIKEY}, {TEXT} placeholders.
#
# Per-invocation env (set by `slot claude` when launching Claude):
#   FLOWSLOT_SLOT_NAME, FLOWSLOT_PROJECT_NAME — used in the message body.
#   FLOWSLOT_SILENT=1                         — skip notification (for automated runs).
#
# All output goes to ~/.flowslot/claude-session.log; hooks must stay quiet on stdout/stderr.

set -u

event="${1:-stop}"
log="$HOME/.flowslot/claude-session.log"
mkdir -p "$(dirname "$log")"

log_line() { echo "[$(date -u +%FT%TZ)] $*" >> "$log"; }

# Shortcut: caller asked to be quiet.
if [ "${FLOWSLOT_SILENT:-0}" = "1" ]; then
  log_line "silent mode, skipping $event"
  exit 0
fi

conf="$HOME/.flowslot/notify.conf"
if [ ! -f "$conf" ]; then
  log_line "no notify.conf; skipping $event"
  exit 0
fi
# shellcheck disable=SC1090
. "$conf"

phone="${FLOWSLOT_CALLMEBOT_PHONE:-}"
apikey="${FLOWSLOT_CALLMEBOT_APIKEY:-}"
channel="${FLOWSLOT_CALLMEBOT_CHANNEL:-whatsapp}"

if [ -z "$phone" ] || [ -z "$apikey" ]; then
  log_line "notify.conf missing phone/apikey; skipping $event"
  exit 0
fi

slot="${FLOWSLOT_SLOT_NAME:-$(basename "$PWD" | sed -E 's/-[0-9]{4}$//')}"
project="${FLOWSLOT_PROJECT_NAME:-$(basename "$(dirname "$PWD")")}"

case "$event" in
  stop)         msg="Claude finished task on slot '${slot}' (${project})." ;;
  notification) msg="Claude needs your input on slot '${slot}' (${project})." ;;
  *)            msg="Claude event '${event}' on slot '${slot}' (${project})." ;;
esac

# URL-encode the message body. Prefer jq, which is installed as a dependency.
urlencode() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -sRr @uri
  else
    # Minimal fallback — only safe because msg content is controlled by this script.
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null \
      || printf '%s' "$1" | sed 's/ /%20/g'
  fi
}
text_enc="$(urlencode "$msg")"

# Choose endpoint.
if [ -n "${FLOWSLOT_CALLMEBOT_URL_TEMPLATE:-}" ]; then
  url="$FLOWSLOT_CALLMEBOT_URL_TEMPLATE"
  url="${url//\{PHONE\}/$phone}"
  url="${url//\{APIKEY\}/$apikey}"
  url="${url//\{TEXT\}/$text_enc}"
else
  case "$channel" in
    whatsapp)
      url="https://api.callmebot.com/whatsapp.php?phone=${phone}&apikey=${apikey}&text=${text_enc}"
      ;;
    signal)
      url="https://api.callmebot.com/signal/send.php?phone=${phone}&apikey=${apikey}&text=${text_enc}"
      ;;
    telegram)
      # For telegram, 'phone' is expected to be @username; apikey is ignored by CallMeBot's text.php.
      url="https://api.callmebot.com/text.php?user=${phone}&text=${text_enc}"
      ;;
    call)
      # CallMeBot voice call (Telegram-based). 'phone' must be a Telegram @username.
      url="http://api.callmebot.com/start.php?source=web&user=${phone}&text=${text_enc}"
      ;;
    *)
      log_line "unknown channel '$channel'; skipping"
      exit 0
      ;;
  esac
fi

log_line "notify $event → channel=$channel"
http_code="$(curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>>"$log" || echo 000)"
log_line "  http=$http_code"

# Never surface errors to Claude — hooks must not block or pollute output.
exit 0
