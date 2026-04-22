#!/usr/bin/env python3
"""voice-outbound — stdio MCP server giving Claude a `call_user` tool.

Claude invokes `call_user(message, reason)` → we POST ElevenLabs'
outbound-call API with the configured agent + user's phone number.
Once the call connects, control is with the ElevenLabs Conversational AI
agent (which itself has access to the flowslot bridge's get_claude_state
/ get_claude_last_output / inject_message / watch_for_stop tools).

Requires env vars (sourced from ~/.flowslot/bridge.env by the wrapper):
  FLOWSLOT_ELEVENLABS_API_KEY
  FLOWSLOT_ELEVENLABS_AGENT_ID
  FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID
  FLOWSLOT_TWILIO_TO           — user's phone (E.164)

Protocol: JSON-RPC over stdio, MCP spec.
Implements only what Claude Code's MCP client needs:
  - initialize
  - tools/list
  - tools/call
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request

ELEVENLABS_API = "https://api.elevenlabs.io"
PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "flowslot-voice-outbound", "version": "2.11.0"}


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def env_required(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise RuntimeError(f"missing env var: {name}")
    return v


def call_elevenlabs_outbound(message: str, reason: str) -> dict:
    """POST ElevenLabs /v1/convai/twilio/outbound-call."""
    api_key = env_required("FLOWSLOT_ELEVENLABS_API_KEY")
    agent_id = env_required("FLOWSLOT_ELEVENLABS_AGENT_ID")
    phone_number_id = env_required("FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID")
    to_number = env_required("FLOWSLOT_TWILIO_TO")

    body = {
        "agent_id": agent_id,
        "agent_phone_number_id": phone_number_id,
        "to_number": to_number,
        "conversation_initiation_client_data": {
            "dynamic_variables": {
                "initial_message": message,
                "reason": reason,
            }
        },
    }
    req = urllib.request.Request(
        f"{ELEVENLABS_API}/v1/convai/twilio/outbound-call",
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
        },
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            return {"ok": True, "status": resp.status, "body": json.loads(resp.read().decode())}
    except urllib.error.HTTPError as e:
        return {"ok": False, "status": e.code, "error": e.read().decode()[:500]}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


# --- MCP JSON-RPC handling ---

def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(message: dict):
    method = message.get("method")
    id_ = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        return reply(id_, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        })

    if method == "notifications/initialized":
        # No response expected.
        return

    if method == "tools/list":
        return reply(id_, {
            "tools": [{
                "name": "call_user",
                "description": (
                    "Place a phone call to the user via ElevenLabs Conversational AI. "
                    "Once connected, an ElevenLabs agent greets the user with your message "
                    "and handles the subsequent voice conversation (barge-in, turn-taking). "
                    "The agent has tools to read your current state, read your last output "
                    "verbatim, inject messages back into your REPL, and wait for your next "
                    "Stop event. Use this to report completed work, ask for input, or raise "
                    "a blocker you need human help with."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "message": {
                            "type": "string",
                            "description": "First sentence the agent speaks after the user picks up. Keep it natural, conversational, and short."
                        },
                        "reason": {
                            "type": "string",
                            "enum": ["done", "question", "blocker"],
                            "description": "Category for the call: 'done' (task complete), 'question' (need user input), or 'blocker' (stuck and need help)."
                        }
                    },
                    "required": ["message", "reason"]
                }
            }]
        })

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name != "call_user":
            return reply(id_, error={"code": -32601, "message": f"unknown tool: {name}"})
        message_text = (args.get("message") or "").strip()
        reason = (args.get("reason") or "done").strip()
        if not message_text:
            return reply(id_, error={"code": -32602, "message": "missing 'message'"})

        result = call_elevenlabs_outbound(message_text, reason)
        if result.get("ok"):
            conv_id = (result.get("body") or {}).get("conversation_id", "")
            text = (
                f"Call placed via ElevenLabs. The agent will speak your message and then "
                f"handle the conversation on my behalf. Conversation ID: {conv_id or 'unknown'}. "
                f"You will hear back from the user via the bridge tools if they speak or "
                f"inject a message."
            )
        else:
            text = (
                f"Failed to place call. ElevenLabs returned: "
                f"{result.get('status', 'n/a')} — {result.get('error', 'no detail')}"
            )
        return reply(id_, {"content": [{"type": "text", "text": text}], "isError": not result.get("ok")})

    return reply(id_, error={"code": -32601, "message": f"unknown method: {method}"})


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except Exception as e:
            log(f"[voice-outbound] parse error: {e}")
            continue
        try:
            handle(msg)
        except Exception as e:
            log(f"[voice-outbound] handler error: {e}")
            if msg.get("id") is not None:
                reply(msg["id"], error={"code": -32603, "message": str(e)})


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
