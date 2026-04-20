#!/bin/bash
# flowslot-notify — invoked by Claude Code hooks on a slot to call the user.
#
# Deployed to ~/.flowslot/bin/flowslot-notify by `slot claude` (see scripts/lib/claude.sh).
# Config is sourced from ~/.flowslot/notify.conf (0600, written by deploy_notify_hook).
#
# Usage:
#   flowslot-notify <event>    event ∈ { stop, notification }
#
# Config (sourced from ~/.flowslot/notify.conf):
#   FLOWSLOT_TWILIO_ACCOUNT_SID   Your Twilio Account SID (starts with "AC...").
#   FLOWSLOT_TWILIO_AUTH_TOKEN    Your Twilio Auth Token (from Twilio console).
#   FLOWSLOT_TWILIO_FROM          Your Twilio phone number in E.164 (e.g. +15551234567).
#   FLOWSLOT_TWILIO_TO            Your personal phone number in E.164 (the one that rings).
#   FLOWSLOT_TWILIO_VOICE         Optional TwiML voice (default: "alice"). E.g. "Polly.Matthew-Neural".
#
# Per-invocation env (set by `slot claude` when launching Claude):
#   FLOWSLOT_SLOT_NAME, FLOWSLOT_PROJECT_NAME — used in the spoken message.
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

sid="${FLOWSLOT_TWILIO_ACCOUNT_SID:-}"
token="${FLOWSLOT_TWILIO_AUTH_TOKEN:-}"
from="${FLOWSLOT_TWILIO_FROM:-}"
to="${FLOWSLOT_TWILIO_TO:-}"
voice="${FLOWSLOT_TWILIO_VOICE:-alice}"

for name in sid token from to; do
  if [ -z "${!name}" ]; then
    log_line "notify.conf missing FLOWSLOT_TWILIO_${name^^}; skipping $event"
    exit 0
  fi
done

slot="${FLOWSLOT_SLOT_NAME:-$(basename "$PWD" | sed -E 's/-[0-9]{4}$//')}"
project="${FLOWSLOT_PROJECT_NAME:-$(basename "$(dirname "$PWD")")}"

case "$event" in
  stop)         msg="Claude finished a task on slot ${slot} in project ${project}." ;;
  notification) msg="Claude needs your input on slot ${slot} in project ${project}." ;;
  *)            msg="Claude event ${event} on slot ${slot} in project ${project}." ;;
esac

# XML-escape the spoken text for TwiML.
xml_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}
msg_xml="$(xml_escape "$msg")"
twiml="<Response><Say voice=\"${voice}\">${msg_xml}</Say></Response>"

api="https://api.twilio.com/2010-04-01/Accounts/${sid}/Calls.json"

log_line "notify $event → twilio ${from} → ${to}"
body_file="$(mktemp)"
http_code="$(curl -sS --max-time 20 \
  -u "${sid}:${token}" \
  --data-urlencode "From=${from}" \
  --data-urlencode "To=${to}" \
  --data-urlencode "Twiml=${twiml}" \
  -o "$body_file" -w '%{http_code}' \
  "$api" 2>>"$log" || echo 000)"
log_line "  http=$http_code"

# Twilio returns 201 on success; anything else is an error — surface it to the log.
if [ "$http_code" != "201" ]; then
  if command -v jq >/dev/null 2>&1; then
    err_msg="$(jq -r '.message // .detail // "unknown"' "$body_file" 2>/dev/null)"
  else
    err_msg="$(head -c 400 "$body_file" 2>/dev/null)"
  fi
  log_line "  ERROR from Twilio: ${err_msg}"
fi
rm -f "$body_file"

# Never surface errors to Claude — hooks must not block or pollute output.
exit 0
