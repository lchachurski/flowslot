#!/usr/bin/env python3
"""flowslot voice bridge — HTTP server exposing Claude Code session state
to an ElevenLabs Conversational AI agent.

Endpoints (all require valid X-Flowslot-Signature HMAC-SHA256 header):
  GET  /bridge/state            — structured summary of what Claude is doing
  GET  /bridge/output?lines=N   — raw tmux capture (for verbatim relay)
  POST /bridge/inject           — inject user message into Claude REPL
  GET  /bridge/watch?timeout=N  — long-poll: returns when next Stop event fires

Runs under systemd. Bound to 127.0.0.1:8080; Tailscale Funnel terminates
TLS at :443 on the tailnet hostname and forwards here.

Dependencies: Python 3 stdlib only (http.server, sqlite3, hmac, subprocess).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# --- Config (via env, populated by /home/ubuntu/.flowslot/bridge.env) ---

PORT = int(os.environ.get("FLOWSLOT_BRIDGE_PORT", "8080"))
SECRET = os.environ.get("FLOWSLOT_BRIDGE_HMAC_SECRET", "").encode()
DB_PATH = os.path.expanduser(os.environ.get("FLOWSLOT_BRIDGE_DB", "~/.flowslot/bridge.db"))
ACTIVE_SLOT = os.environ.get("FLOWSLOT_ACTIVE_SLOT", "")  # e.g. "claude-test"
TMUX_SESSION = f"claude-{ACTIVE_SLOT}" if ACTIVE_SLOT else ""

if not SECRET:
    print("FATAL: FLOWSLOT_BRIDGE_HMAC_SECRET not set", file=sys.stderr)
    sys.exit(1)


def log(*args):
    print(*args, file=sys.stderr, flush=True)


# --- Signature verification ---

def verify_hmac(path: str, body: bytes, signature: str | None) -> bool:
    """Verify HMAC-SHA256 over (path + body) with shared secret."""
    if not signature:
        return False
    payload = path.encode() + body
    expected = hmac.new(SECRET, payload, hashlib.sha256).hexdigest()
    # Accept with or without "sha256=" prefix (ElevenLabs may use either)
    provided = signature.lower().removeprefix("sha256=")
    return hmac.compare_digest(expected, provided)


# --- SQLite helpers ---

def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def state_from_db() -> dict:
    """Compute a structured status snapshot from recent events.

    Logic:
    - If last event is `pre_tool` (no matching `post_tool` yet): currently executing
    - If last is `post_tool` or `stop`: idle
    - If a `notification` came after the last `stop`: waiting for user input
    """
    with db_connect() as conn:
        last = conn.execute(
            "SELECT * FROM events ORDER BY ts DESC, id DESC LIMIT 1"
        ).fetchone()
        last_stop = conn.execute(
            "SELECT ts FROM events WHERE type='stop' ORDER BY ts DESC LIMIT 1"
        ).fetchone()
        last_notification = conn.execute(
            "SELECT ts, message FROM events WHERE type='notification' ORDER BY ts DESC LIMIT 1"
        ).fetchone()
        last_pre_tool = conn.execute(
            "SELECT id, ts, tool, args FROM events WHERE type='pre_tool' "
            "ORDER BY ts DESC, id DESC LIMIT 1"
        ).fetchone()

    now = int(time.time())

    if last is None:
        return {
            "status": "idle",
            "current_tool": None,
            "tool_args_brief": None,
            "elapsed_seconds": 0,
            "waiting_for_input": False,
            "last_claude_preview": None,
            "last_event_ts": None,
        }

    status = "idle"
    current_tool = None
    tool_args_brief = None
    elapsed = 0

    # Is Claude currently in a tool call? pre_tool without a later post_tool/stop.
    if last_pre_tool is not None:
        pre_id = last_pre_tool["id"]
        with db_connect() as conn:
            post_after = conn.execute(
                "SELECT 1 FROM events WHERE id > ? AND type IN ('post_tool','stop') LIMIT 1",
                (pre_id,),
            ).fetchone()
        if post_after is None:
            status = "executing_tool"
            current_tool = last_pre_tool["tool"]
            tool_args_brief = _brief(last_pre_tool["args"])
            elapsed = now - last_pre_tool["ts"]

    # Waiting for input? last notification after last stop.
    waiting = False
    if last_notification is not None:
        stop_ts = last_stop["ts"] if last_stop else 0
        if last_notification["ts"] > stop_ts:
            waiting = True
            status = "awaiting_input"

    return {
        "status": status,
        "current_tool": current_tool,
        "tool_args_brief": tool_args_brief,
        "elapsed_seconds": elapsed,
        "waiting_for_input": waiting,
        "last_claude_preview": _last_claude_preview(),
        "last_event_ts": last["ts"],
    }


def _brief(args_json: str | None, limit: int = 140) -> str | None:
    """Summarize tool args into a human-readable snippet."""
    if not args_json:
        return None
    try:
        args = json.loads(args_json)
    except Exception:
        return args_json[:limit]
    # Heuristic: prefer common keys
    for key in ("command", "prompt", "query", "url", "path", "file_path", "description"):
        if key in args and isinstance(args[key], str):
            val = args[key]
            return (val[:limit] + "…") if len(val) > limit else val
    # Fallback: first string value
    for v in args.values():
        if isinstance(v, str):
            return (v[:limit] + "…") if len(v) > limit else v
    return json.dumps(args)[:limit]


# --- tmux helpers ---

def _tmux_has_session() -> bool:
    if not TMUX_SESSION:
        return False
    r = subprocess.run(
        ["tmux", "has-session", "-t", TMUX_SESSION],
        capture_output=True,
    )
    return r.returncode == 0


def tmux_capture(lines: int = 50) -> str:
    if not _tmux_has_session():
        return ""
    r = subprocess.run(
        ["tmux", "capture-pane", "-t", TMUX_SESSION, "-p", "-S", f"-{lines}"],
        capture_output=True, text=True,
    )
    return r.stdout


def _last_claude_preview(max_chars: int = 240) -> str | None:
    """Strip ANSI, grab the most recent non-empty line that looks like Claude text."""
    text = tmux_capture(lines=30)
    if not text:
        return None
    # Strip ANSI escapes
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
    # Keep lines that are plainly Claude's output (not REPL chrome)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    # Filter out tmux/claude REPL chrome heuristically
    lines = [
        ln for ln in lines
        if not ln.startswith(("╭", "╰", "│", "❯", "───", "━━━", "⎿"))
        and not re.match(r"^[\s*▐▜▛▓░]+$", ln)
    ]
    if not lines:
        return None
    last = lines[-1]
    return last[-max_chars:] if len(last) > max_chars else last


def tmux_inject(text: str, urgent: bool = False) -> dict:
    """Send a message into the Claude tmux REPL.

    urgent=True first sends Escape (interrupts current prompt / tool) before the message.
    """
    if not _tmux_has_session():
        return {"ok": False, "error": f"no tmux session '{TMUX_SESSION}'"}
    before_state = state_from_db()
    if urgent:
        subprocess.run(
            ["tmux", "send-keys", "-t", TMUX_SESSION, "Escape"],
            capture_output=True,
        )
        time.sleep(0.25)
    # Send text + Enter as a single send-keys call so Enter isn't swallowed.
    subprocess.run(
        ["tmux", "send-keys", "-t", TMUX_SESSION, text, "Enter"],
        capture_output=True,
    )
    return {
        "ok": True,
        "mode": "interrupted_and_sent" if urgent else "queued",
        "claude_state_at_send": before_state,
    }


# --- HTTP handlers ---

class Handler(BaseHTTPRequestHandler):
    # Suppress default stderr access logs; we log our own.
    def log_message(self, fmt, *args):
        pass

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def _signature_ok(self, body: bytes) -> bool:
        sig = self.headers.get("X-Flowslot-Signature") or self.headers.get("x-flowslot-signature")
        return verify_hmac(self.path, body, sig)

    def _reply(self, status: int, payload: dict | str):
        if isinstance(payload, str):
            data = payload.encode()
            ctype = "text/plain; charset=utf-8"
        else:
            data = json.dumps(payload, ensure_ascii=False).encode()
            ctype = "application/json; charset=utf-8"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _unauthorized(self):
        self._reply(401, {"error": "invalid signature"})

    def _bad_request(self, msg: str):
        self._reply(400, {"error": msg})

    # --- dispatch ---

    def do_GET(self):
        try:
            body = self._read_body()  # GET may have body; ElevenLabs sometimes sends one
            if not self._signature_ok(body):
                log(f"[bridge] 401 GET {self.path} (bad signature)")
                return self._unauthorized()

            parsed = urlparse(self.path)
            q = parse_qs(parsed.query)

            if parsed.path == "/bridge/state":
                return self._reply(200, state_from_db())

            if parsed.path == "/bridge/output":
                lines = int((q.get("lines") or ["50"])[0])
                lines = max(1, min(lines, 500))
                text = tmux_capture(lines=lines)
                # Strip ANSI for cleaner speech
                text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
                return self._reply(200, {"output": text, "session": TMUX_SESSION})

            if parsed.path == "/bridge/watch":
                timeout = int((q.get("timeout") or ["60"])[0])
                timeout = max(1, min(timeout, 300))
                return self._reply(200, watch_for_stop(timeout))

            if parsed.path == "/bridge/health":
                return self._reply(200, {"ok": True, "slot": ACTIVE_SLOT})

            return self._reply(404, {"error": "not found"})
        except Exception as e:
            log(f"[bridge] ERROR {self.path}: {e}")
            return self._reply(500, {"error": str(e)})

    def do_POST(self):
        try:
            body = self._read_body()
            if not self._signature_ok(body):
                log(f"[bridge] 401 POST {self.path} (bad signature)")
                return self._unauthorized()

            parsed = urlparse(self.path)

            if parsed.path == "/bridge/inject":
                try:
                    payload = json.loads(body) if body else {}
                except Exception as e:
                    return self._bad_request(f"invalid JSON: {e}")
                text = (payload.get("text") or "").strip()
                urgent = bool(payload.get("urgent", False))
                if not text:
                    return self._bad_request("missing 'text'")
                return self._reply(200, tmux_inject(text, urgent=urgent))

            return self._reply(404, {"error": "not found"})
        except Exception as e:
            log(f"[bridge] ERROR {self.path}: {e}")
            return self._reply(500, {"error": str(e)})


# --- Long-poll implementation ---

def watch_for_stop(timeout_sec: int) -> dict:
    """Block up to timeout_sec; return when a new `stop` event is observed."""
    with db_connect() as conn:
        baseline = conn.execute(
            "SELECT ts FROM events WHERE type='stop' ORDER BY ts DESC LIMIT 1"
        ).fetchone()
    baseline_ts = baseline["ts"] if baseline else 0
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT ts FROM events WHERE type='stop' AND ts > ? "
                "ORDER BY ts DESC LIMIT 1",
                (baseline_ts,),
            ).fetchone()
        if row:
            return {
                "stopped": True,
                "stop_ts": row["ts"],
                "last_claude_preview": _last_claude_preview(),
            }
        time.sleep(1)
    return {"stopped": False, "last_claude_preview": _last_claude_preview()}


# --- main ---

def main():
    log(f"[bridge] starting on 127.0.0.1:{PORT}, slot={ACTIVE_SLOT!r}, db={DB_PATH}")
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("[bridge] shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
