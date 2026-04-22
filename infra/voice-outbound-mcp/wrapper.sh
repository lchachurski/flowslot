#!/bin/bash
# MCP launcher for voice-outbound. Claude Code launches this as an MCP stdio
# subprocess. Sources bridge.env for ElevenLabs + Twilio creds, then execs the
# Python server.
set -euo pipefail
set -a
# shellcheck disable=SC1091
. "$HOME/.flowslot/bridge.env"
set +a
exec /usr/bin/python3 "$HOME/.flowslot/voice-outbound-mcp/server.py"
