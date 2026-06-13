#!/usr/bin/env python3
"""flowslot voice bridge — HTTP server exposing Claude Code session state for
N slots on one host to the ElevenLabs Conversational AI agent.

Endpoints (all require X-Flowslot-Signature HMAC or X-Flowslot-Token header):
  GET  /bridge/slots                    — list slots on host with status
  GET  /bridge/state?slot=NAME          — structured "what is Claude doing"
  GET  /bridge/output?slot=NAME&lines=N — raw tmux capture for verbatim relay
  POST /bridge/inject  {slot,text,urgent} — inject user message into REPL
  GET  /bridge/watch?slot=NAME&timeout=N  — long-poll until next Stop
  GET  /bridge/system_status            — host + bridge + all-slots overview
  GET  /bridge/health                   — liveness + slot count

Per-slot endpoints return 400 if `slot` is missing/malformed and 404 if the
slot has no live `claude-<slot>` tmux session (except `/bridge/state`, which
returns DB-derived state with `tmux_alive: false` so the agent can suggest
starting a session).

Runs under systemd. Bound to 127.0.0.1:8080; Tailscale Funnel terminates TLS
at :443 on the tailnet hostname and forwards here.

Dependencies: Python 3 stdlib only.
"""
from __future__ import annotations

import concurrent.futures
import glob
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
# Legacy FLOWSLOT_ACTIVE_SLOT is intentionally not read — slot is per-request
# now. We *do* still honor it during one-shot migration; see lib/claude-voice.sh
# `write_bridge_env`, which backfills historical rows before dropping the var.

if not SECRET:
    print("FATAL: FLOWSLOT_BRIDGE_HMAC_SECRET not set", file=sys.stderr)
    sys.exit(1)

# Slot name validation mirrors `validate_slot_name` in scripts/lib/common.sh.
SLOT_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")

# Cache TTLs for the multi-slot snapshots. Voice agents are chatty;
# repeated /bridge/slots inside a 10s window costs us one tmux/docker/git pass.
SLOTS_CACHE_TTL = 10
SYSTEM_STATUS_CACHE_TTL = 10


def log(*args):
    print(*args, file=sys.stderr, flush=True)


# --- Signature verification ---

def verify_hmac(path: str, body: bytes, signature: str | None) -> bool:
    """Verify HMAC-SHA256 over (path + body) with shared secret."""
    if not signature:
        return False
    payload = path.encode() + body
    expected = hmac.new(SECRET, payload, hashlib.sha256).hexdigest()
    provided = signature.lower().removeprefix("sha256=")
    return hmac.compare_digest(expected, provided)


def verify_static_token(token: str | None) -> bool:
    """Verify a static bearer token (X-Flowslot-Token header) against the shared
    secret. ElevenLabs CAI's dashboard supports static request headers cleanly
    but doesn't offer per-request HMAC signing."""
    if not token:
        return False
    return hmac.compare_digest(SECRET.decode(), token.strip().removeprefix("Bearer ").strip())


# --- SQLite helpers ---

def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_schema(conn: sqlite3.Connection) -> None:
    """Idempotent schema migration. Run once at boot.

    SQLite has no `ADD COLUMN IF NOT EXISTS`, so we probe `table_info` and
    only ALTER what's missing. WAL mode lets N hook processes INSERT in
    parallel without blocking the bridge's reads.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(events)")}
    if "slot" not in cols:
        conn.execute("ALTER TABLE events ADD COLUMN slot TEXT")
        log("[bridge] migration: events.slot added")
    if "project" not in cols:
        conn.execute("ALTER TABLE events ADD COLUMN project TEXT")
        log("[bridge] migration: events.project added")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_events_slot_type_ts "
        "ON events(slot, type, ts DESC)"
    )
    conn.execute("PRAGMA journal_mode=WAL")
    conn.commit()


def _kv_get(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute("SELECT value FROM bridge_state WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def _kv_set(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO bridge_state(key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )
    conn.commit()


def state_from_db(slot: str) -> dict:
    """Compute a structured status snapshot from recent events for one slot.

    States (in priority order):
    - `executing_tool` — a `pre_tool` event has no matching `post_tool` or
      `stop` after it. Claude is in a tool call right now.
    - `thinking`       — a `user_prompt` event has no matching `stop` after it,
      and no tool is currently running. Claude is processing/streaming text
      between turns; nothing visible to hooks until the next pre_tool or stop.
    - `awaiting_input` — last `notification` is more recent than any stop AND
      any later user_prompt/pre_tool. Claude paused for user input.
    - `idle`           — last `stop` is more recent than the last user_prompt
      and there's no pending notification. Claude finished and is waiting.
    """
    with db_connect() as conn:
        last = conn.execute(
            "SELECT * FROM events WHERE slot = ? ORDER BY ts DESC, id DESC LIMIT 1",
            (slot,),
        ).fetchone()
        last_stop = conn.execute(
            "SELECT ts FROM events WHERE slot = ? AND type='stop' "
            "ORDER BY ts DESC LIMIT 1",
            (slot,),
        ).fetchone()
        last_notification = conn.execute(
            "SELECT ts, message FROM events WHERE slot = ? AND type='notification' "
            "ORDER BY ts DESC LIMIT 1",
            (slot,),
        ).fetchone()
        last_pre_tool = conn.execute(
            "SELECT id, ts, tool, args FROM events WHERE slot = ? AND type='pre_tool' "
            "ORDER BY ts DESC, id DESC LIMIT 1",
            (slot,),
        ).fetchone()
        last_user_prompt = conn.execute(
            "SELECT id, ts, args FROM events WHERE slot = ? AND type='user_prompt' "
            "ORDER BY ts DESC, id DESC LIMIT 1",
            (slot,),
        ).fetchone()

    now = int(time.time())
    tmux_alive = _tmux_has_session(slot)

    base = {
        "slot": slot,
        "tmux_alive": tmux_alive,
    }

    if last is None:
        return {
            **base,
            "status": "idle",
            "current_tool": None,
            "tool_args_brief": None,
            "elapsed_seconds": 0,
            "waiting_for_input": False,
            "last_claude_preview": _last_claude_preview(slot) if tmux_alive else None,
            "last_event_ts": None,
        }

    status = "idle"
    current_tool = None
    tool_args_brief = None
    elapsed = 0

    stop_ts = last_stop["ts"] if last_stop else 0
    user_prompt_ts = last_user_prompt["ts"] if last_user_prompt else 0
    pre_tool_ts = last_pre_tool["ts"] if last_pre_tool else 0

    # 1) Tool currently running? pre_tool without a later post_tool/stop.
    executing_tool = False
    if last_pre_tool is not None:
        pre_id = last_pre_tool["id"]
        with db_connect() as conn:
            post_after = conn.execute(
                "SELECT 1 FROM events WHERE slot = ? AND id > ? "
                "AND type IN ('post_tool','stop') LIMIT 1",
                (slot, pre_id),
            ).fetchone()
        if post_after is None:
            executing_tool = True
            status = "executing_tool"
            current_tool = last_pre_tool["tool"]
            tool_args_brief = _brief(last_pre_tool["args"])
            elapsed = now - last_pre_tool["ts"]

    # 2) Thinking? user_prompt newer than the last stop, no tool currently
    # running. Catches submit→first-tool and post_tool→next-tool gaps where
    # Claude is streaming silently.
    if not executing_tool and user_prompt_ts > stop_ts:
        status = "thinking"
        anchor_ts = max(user_prompt_ts, pre_tool_ts)
        elapsed = max(0, now - anchor_ts)

    # 3) Awaiting input? Notification newer than anything else.
    waiting = False
    if not executing_tool and last_notification is not None:
        last_activity_ts = max(stop_ts, pre_tool_ts, user_prompt_ts)
        if last_notification["ts"] > last_activity_ts:
            waiting = True
            status = "awaiting_input"

    return {
        **base,
        "status": status,
        "current_tool": current_tool,
        "tool_args_brief": tool_args_brief,
        "elapsed_seconds": elapsed,
        "waiting_for_input": waiting,
        "last_claude_preview": _last_claude_preview(slot) if tmux_alive else None,
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
    for key in ("command", "prompt", "query", "url", "path", "file_path", "description"):
        if key in args and isinstance(args[key], str):
            val = args[key]
            return (val[:limit] + "…") if len(val) > limit else val
    for v in args.values():
        if isinstance(v, str):
            return (v[:limit] + "…") if len(v) > limit else v
    return json.dumps(args)[:limit]


# --- shell helpers ---

def _shell(cmd: list[str], timeout: float = 3.0) -> str:
    """Run a shell command, return stdout or empty string on failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


# --- slot discovery ---

# Slot dirs live at /srv/<project>/<slot>-<port_base>. Mirrors flowslot's
# scripts/lib/common.sh:get_port_base_from_dir / find_slot_dir.
_SLOT_DIR_RE = re.compile(r"^/srv/(?P<project>[^/]+)/(?P<slot>[a-z0-9][a-z0-9-]*)-(?P<port>\d{4})$")


def _discover_slots() -> list[dict]:
    """Filesystem-discover slots on this host. Cheap (single glob)."""
    out = []
    for path in glob.glob("/srv/*/*-[0-9][0-9][0-9][0-9]"):
        if not os.path.isdir(path):
            continue
        m = _SLOT_DIR_RE.match(path)
        if not m:
            continue
        out.append({
            "name":        m.group("slot"),
            "project":     m.group("project"),
            "port_base":   int(m.group("port")),
            "remote_path": path,
        })
    # Sort by project, then slot, for stable output to the voice agent.
    out.sort(key=lambda s: (s["project"], s["name"]))
    return out


def _tmux_sessions() -> set[str]:
    """Set of slot names with a live `claude-<slot>` tmux session."""
    out = _shell(["tmux", "ls", "-F", "#{session_name}"])
    return {ln.removeprefix("claude-") for ln in out.splitlines()
            if ln.startswith("claude-")}


def _docker_ps() -> list[tuple[str, str]]:
    """Return list of (container_name, status) once."""
    raw = _shell(["bash", "-c", "docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null"])
    out = []
    for line in raw.splitlines():
        if "|" not in line:
            continue
        name, status = line.split("|", 1)
        out.append((name, status))
    return out


def _slot_git(path: str) -> tuple[str | None, bool | None]:
    """Return (branch, is_clean) for a slot's working tree."""
    branch = _shell(["git", "-C", path, "branch", "--show-current"]).strip() or None
    if branch is None:
        return (None, None)
    status = _shell(["git", "-C", path, "status", "--porcelain"])
    return (branch, status.strip() == "")


def _slot_last_event(slot: str) -> dict | None:
    with db_connect() as conn:
        row = conn.execute(
            "SELECT type, ts, tool, message FROM events WHERE slot = ? "
            "ORDER BY ts DESC, id DESC LIMIT 1",
            (slot,),
        ).fetchone()
    if not row:
        return None
    return {"type": row["type"], "ts": row["ts"],
            "tool": row["tool"], "message": row["message"]}


def _enrich_slot(seed: dict, tmux_alive: set[str], containers: list[tuple[str, str]]) -> dict:
    """Add per-slot git + DB + container summary to a discovered slot."""
    name = seed["name"]
    project = seed["project"]
    prefix = f"{project}-{name}"  # docker compose project-name pattern
    branch, clean = _slot_git(seed["remote_path"])
    matching = [(n, s) for (n, s) in containers if prefix in n]
    running = sum(1 for (_, s) in matching if s.startswith("Up"))
    return {
        **seed,
        "tmux_alive":         name in tmux_alive,
        "git_branch":         branch,
        "git_clean":          clean,
        "containers_running": running,
        "containers_total":   len(matching),
        "last_event":         _slot_last_event(name),
    }


def _list_slots_snapshot() -> dict:
    """Build the multi-slot snapshot, with 10s caching in bridge_state KV.

    Total budget: <500ms first call (parallel per-slot enrich), <10ms cached.
    """
    now = int(time.time())
    with db_connect() as conn:
        cached = _kv_get(conn, "slots_snapshot_v1")
    if cached:
        try:
            obj = json.loads(cached)
            if now - obj.get("snapshot_ts", 0) < SLOTS_CACHE_TTL:
                obj["cached"] = True
                return obj
        except Exception:
            pass

    seeds      = _discover_slots()
    tmux_alive = _tmux_sessions()
    containers = _docker_ps()

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(4, len(seeds))) as ex:
        slots = list(ex.map(lambda s: _enrich_slot(s, tmux_alive, containers), seeds))

    snapshot = {"slots": slots, "snapshot_ts": now, "cached": False}
    try:
        with db_connect() as conn:
            _kv_set(conn, "slots_snapshot_v1", json.dumps(snapshot))
    except Exception:
        pass
    return snapshot


# --- system monitoring ---

def system_status_snapshot() -> dict:
    """Host + bridge + all-slots overview. Cached 10s.

    Per-slot section is a list of lightweight summaries (no last-event detail)
    so the voice agent can ask one tool for the big picture.
    """
    now = int(time.time())
    with db_connect() as conn:
        cached = _kv_get(conn, "system_status_v1")
    if cached:
        try:
            obj = json.loads(cached)
            if now - obj.get("snapshot_ts", 0) < SYSTEM_STATUS_CACHE_TTL:
                obj["cached"] = True
                return obj
        except Exception:
            pass

    out: dict = {"host": {}, "bridge": {}, "slots": [], "snapshot_ts": now, "cached": False}

    # ---- host ----
    try:
        with open("/proc/uptime") as f:
            out["host"]["uptime_seconds"] = int(float(f.read().split()[0]))
    except Exception:
        pass
    try:
        with open("/proc/loadavg") as f:
            la = f.read().split()
            out["host"]["load_1m"] = float(la[0])
            out["host"]["load_5m"] = float(la[1])
            out["host"]["load_15m"] = float(la[2])
    except Exception:
        pass
    try:
        with open("/proc/meminfo") as f:
            mem = {ln.split(":")[0].strip(): ln.split(":")[1].strip()
                   for ln in f if ":" in ln}
            total_kb = int(mem.get("MemTotal", "0 kB").split()[0])
            avail_kb = int(mem.get("MemAvailable", "0 kB").split()[0])
            if total_kb:
                out["host"]["memory_total_mb"] = total_kb // 1024
                out["host"]["memory_used_pct"] = round(
                    100 * (total_kb - avail_kb) / total_kb, 1)
    except Exception:
        pass
    df = _shell(["df", "-P", "/"])
    for line in df.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[5] == "/":
            try:
                out["host"]["disk_root_used_pct"] = int(parts[4].rstrip("%"))
            except Exception:
                pass
            break

    # ---- bridge ----
    try:
        with db_connect() as conn:
            t = int(time.time())
            row = conn.execute("SELECT COUNT(*) FROM events").fetchone()
            out["bridge"]["events_total"] = row[0] if row else 0
            row = conn.execute(
                "SELECT COUNT(*) FROM events WHERE ts > ?", (t - 3600,)
            ).fetchone()
            out["bridge"]["events_last_hour"] = row[0] if row else 0
            row = conn.execute(
                "SELECT COUNT(*) FROM events WHERE ts > ?", (t - 60,)
            ).fetchone()
            out["bridge"]["events_last_minute"] = row[0] if row else 0
    except Exception:
        pass

    # ---- slots (reuse list_slots snapshot, trim to summary fields) ----
    list_snap = _list_slots_snapshot()
    out["slots"] = [{
        "name":               s["name"],
        "project":            s["project"],
        "tmux_alive":         s["tmux_alive"],
        "containers_running": s["containers_running"],
        "containers_total":   s["containers_total"],
        "git_branch":         s.get("git_branch"),
        "last_event_ts":      (s.get("last_event") or {}).get("ts"),
    } for s in list_snap["slots"]]

    try:
        with db_connect() as conn:
            _kv_set(conn, "system_status_v1", json.dumps(out))
    except Exception:
        pass
    return out


# --- tmux helpers (slot-aware) ---

def _tmux_session_name(slot: str) -> str:
    return f"claude-{slot}"


def _tmux_has_session(slot: str) -> bool:
    r = subprocess.run(
        ["tmux", "has-session", "-t", _tmux_session_name(slot)],
        capture_output=True,
    )
    return r.returncode == 0


def tmux_capture(slot: str, lines: int = 50) -> str | None:
    """Return tmux pane contents for `claude-<slot>`, or None if no session."""
    if not _tmux_has_session(slot):
        return None
    r = subprocess.run(
        ["tmux", "capture-pane", "-t", _tmux_session_name(slot), "-p", "-S", f"-{lines}"],
        capture_output=True, text=True,
    )
    return r.stdout


def _last_claude_preview(slot: str, max_chars: int = 240) -> str | None:
    """Strip ANSI; return the most recent non-chrome line from `claude-<slot>`."""
    text = tmux_capture(slot, lines=30)
    if not text:
        return None
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    lines = [
        ln for ln in lines
        if not ln.startswith(("╭", "╰", "│", "❯", "───", "━━━", "⎿"))
        and not re.match(r"^[\s*▐▜▛▓░]+$", ln)
    ]
    if not lines:
        return None
    last = lines[-1]
    return last[-max_chars:] if len(last) > max_chars else last


def tmux_inject(slot: str, text: str, urgent: bool = False) -> dict:
    """Inject a message into `claude-<slot>` REPL and submit it.

    Claude Code's REPL uses bracketed-paste. If text and Enter are sent in one
    `tmux send-keys` call, Enter is consumed as a newline INSIDE the paste
    block — the message appears in the input buffer but never submits. We use
    a 3-phase sequence:
      1. Write the text to a temp file; tmux load-buffer + paste-buffer (-d
         deletes the buffer). Handles embedded newlines and long text without
         send-keys quoting hell.
      2. Wait long enough for the REPL to finish accepting the paste (0.9s).
      3. Send Enter as a separate send-keys call, OUTSIDE the bracketed-paste
         block, so it lands as a real submit keystroke.
    """
    session = _tmux_session_name(slot)
    if not _tmux_has_session(slot):
        return {"ok": False, "error": f"no tmux session '{session}'"}
    before_state = state_from_db(slot)
    if urgent:
        subprocess.run(["tmux", "send-keys", "-t", session, "Escape"],
                       capture_output=True)
        time.sleep(0.35)

    import tempfile, os as _os
    tmp_fd, tmp_path = tempfile.mkstemp(prefix="flowslot-inject-", suffix=".txt")
    try:
        with _os.fdopen(tmp_fd, "w") as f:
            f.write(text)
        buf_name = f"flowslot-inject-{int(time.time()*1000)}"
        subprocess.run(["tmux", "load-buffer", "-b", buf_name, tmp_path],
                       capture_output=True)
        subprocess.run(["tmux", "paste-buffer", "-d", "-b", buf_name, "-t", session],
                       capture_output=True)
    finally:
        try: _os.unlink(tmp_path)
        except Exception: pass

    time.sleep(0.9)
    subprocess.run(["tmux", "send-keys", "-t", session, "Enter"],
                   capture_output=True)
    return {
        "ok":   True,
        "mode": "interrupted_and_sent" if urgent else "queued",
        "claude_state_at_send": before_state,
    }


def watch_for_stop(slot: str, timeout_sec: int) -> dict:
    """Block up to timeout_sec; return when a new `stop` event fires for slot."""
    with db_connect() as conn:
        baseline = conn.execute(
            "SELECT ts FROM events WHERE slot = ? AND type='stop' "
            "ORDER BY ts DESC LIMIT 1",
            (slot,),
        ).fetchone()
    baseline_ts = baseline["ts"] if baseline else 0
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT ts FROM events WHERE slot = ? AND type='stop' AND ts > ? "
                "ORDER BY ts DESC LIMIT 1",
                (slot, baseline_ts),
            ).fetchone()
        if row:
            return {
                "stopped": True,
                "stop_ts": row["ts"],
                "last_claude_preview": _last_claude_preview(slot),
            }
        time.sleep(1)
    return {"stopped": False, "last_claude_preview": _last_claude_preview(slot)}


# --- HTTP handlers ---

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def _signature_ok(self, body: bytes) -> bool:
        sig = (self.headers.get("X-Flowslot-Signature")
               or self.headers.get("x-flowslot-signature"))
        if sig and verify_hmac(self.path, body, sig):
            return True
        token = (self.headers.get("X-Flowslot-Token")
                 or self.headers.get("x-flowslot-token")
                 or self.headers.get("Authorization"))
        return verify_static_token(token)

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
        log(f"[bridge] {self.command} {self.path} -> {status} ({len(data)}B)")

    def _unauthorized(self):
        self._reply(401, {"error": "invalid signature"})

    def _bad_request(self, msg: str, **extra):
        self._reply(400, {"error": msg, **extra})

    def _not_found(self, msg: str = "not found", **extra):
        self._reply(404, {"error": msg, **extra})

    @staticmethod
    def _resolve_slot(query: dict, body_obj: dict | None) -> str | None:
        """Read slot from query first, then body. Validate format. None on miss."""
        candidate = None
        q_vals = query.get("slot") or query.get("slot_name")
        if q_vals:
            candidate = q_vals[0]
        elif body_obj and isinstance(body_obj.get("slot"), str):
            candidate = body_obj["slot"]
        if not candidate:
            return None
        candidate = candidate.strip()
        return candidate if SLOT_NAME_RE.match(candidate) else None

    # --- dispatch ---

    def do_GET(self):
        try:
            body = self._read_body()  # ElevenLabs sometimes sends GET bodies
            if not self._signature_ok(body):
                log(f"[bridge] 401 GET {self.path} (bad signature)")
                return self._unauthorized()

            parsed = urlparse(self.path)
            q = parse_qs(parsed.query)
            path = parsed.path

            # ---- slot-less endpoints ----
            if path == "/bridge/slots":
                return self._reply(200, _list_slots_snapshot())

            if path == "/bridge/system_status":
                return self._reply(200, system_status_snapshot())

            if path == "/bridge/health":
                slots = _list_slots_snapshot().get("slots", [])
                return self._reply(200, {
                    "ok": True,
                    "slots_total": len(slots),
                    "slots_with_session": sum(1 for s in slots if s.get("tmux_alive")),
                })

            # ---- slot-aware endpoints ----
            slot = self._resolve_slot(q, None)
            if slot is None:
                return self._bad_request("slot required",
                                         hint="call /bridge/slots to list")

            if path == "/bridge/state":
                return self._reply(200, state_from_db(slot))

            if path == "/bridge/output":
                lines = int((q.get("lines") or ["50"])[0])
                lines = max(1, min(lines, 500))
                text = tmux_capture(slot, lines=lines)
                if text is None:
                    return self._not_found(
                        f"no claude session for slot '{slot}'",
                        hint=f"start one with: slot claude --slot {slot}")
                text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
                return self._reply(200, {"slot": slot, "output": text,
                                         "session": _tmux_session_name(slot)})

            if path == "/bridge/watch":
                if not _tmux_has_session(slot):
                    return self._not_found(
                        f"no claude session for slot '{slot}'",
                        hint=f"start one with: slot claude --slot {slot}")
                timeout = int((q.get("timeout") or ["60"])[0])
                timeout = max(1, min(timeout, 300))
                return self._reply(200, watch_for_stop(slot, timeout))

            return self._not_found()
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
            q = parse_qs(parsed.query)

            if parsed.path == "/bridge/inject":
                try:
                    payload = json.loads(body) if body else {}
                except Exception as e:
                    return self._bad_request(f"invalid JSON: {e}")
                slot = self._resolve_slot(q, payload)
                if slot is None:
                    return self._bad_request("slot required",
                                             hint="call /bridge/slots to list")
                text = (payload.get("text") or "").strip()
                urgent = bool(payload.get("urgent", False))
                if not text:
                    return self._bad_request("missing 'text'")
                if not _tmux_has_session(slot):
                    return self._not_found(
                        f"no claude session for slot '{slot}'",
                        hint=f"start one with: slot claude --slot {slot}")
                return self._reply(200, tmux_inject(slot, text, urgent=urgent))

            return self._not_found()
        except Exception as e:
            log(f"[bridge] ERROR {self.path}: {e}")
            return self._reply(500, {"error": str(e)})


# --- main ---

def main():
    # Boot-time idempotent schema migration. Safe to run on every start.
    with db_connect() as conn:
        _ensure_schema(conn)
    slots = _discover_slots()
    log(f"[bridge] starting on 127.0.0.1:{PORT}, db={DB_PATH}, slots_discovered={len(slots)}")
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("[bridge] shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
