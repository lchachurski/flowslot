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
# v2.16+: lifecycle helpers (create/destroy/start-claude) live next to server.py.
BIN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")
# Port allocation mirrors scripts/lib/common.sh: base 7000, 100 ports per slot.
PORT_BASE_START = 7000
PORT_RANGE      = 100
PORT_BASE_MAX   = 9000
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
        # No events recorded for this slot yet. Either the slot was just
        # created (Stop hook hasn't fired) or hooks aren't wired up. The bare
        # one-line `last_claude_preview` here is almost always the
        # bypass-permissions banner — surfacing only that string trains the
        # agent to say "Claude hasn't responded". Include `bootstrapping:true`
        # and a multi-line `output_tail` so the agent has the actual buffer
        # to read instead of falling back to a wrong conclusion.
        return {
            **base,
            "status": "idle",
            "current_tool": None,
            "tool_args_brief": None,
            "elapsed_seconds": 0,
            "waiting_for_input": False,
            "last_claude_preview": _last_claude_preview(slot) if tmux_alive else None,
            "last_event_ts": None,
            "bootstrapping": True,
            "output_tail": _last_output_tail(slot) if tmux_alive else None,
            "needs_login": _claude_needs_login(slot) if tmux_alive else False,
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
        "needs_login": _claude_needs_login(slot) if tmux_alive else False,
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


# v2.19: Claude Code prints these two strings verbatim when its OAuth token
# has expired and the REPL will 401 on the next input. Detecting them from
# the tmux scrollback is the only signal we have — hooks don't fire for
# auth failures, and the process stays alive at the prompt. Motivation:
# conv_6801kxzvwkntexh83k9vhen2rvsc turn 30 (2026-07-20) where the agent
# reported "idle and ready" for 5+ minutes while Claude was silently
# blocked on an expired token, and the user had to notice manually.
_NEEDS_LOGIN_RE = re.compile(
    r"(OAuth access token has expired|Please run /login)"
)


def _claude_needs_login(slot: str) -> bool:
    """True iff the tmux scrollback contains a Claude auth-expired banner."""
    text = tmux_capture(slot, lines=120)
    if not text:
        return False
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
    return bool(_NEEDS_LOGIN_RE.search(text))


def _last_output_tail(slot: str, lines: int = 40) -> str | None:
    """ANSI-stripped tail of tmux scrollback for `claude-<slot>`. Used as a
    fallback signal when the bridge DB has no events yet (newly created
    slot) — `last_claude_preview` is a single line and can mislead the agent
    into reporting 'no response' when Claude has actually been chatting on
    screen but hooks haven't fired/landed yet."""
    text = tmux_capture(slot, lines=lines * 4)
    if not text:
        return None
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
    out_lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    if not out_lines:
        return None
    return "\n".join(out_lines[-lines:])


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


# --- slot lifecycle (v2.16+) ---

def _tool_failure_body(action: str, run_result: dict, hint: str | None = None) -> dict:
    """Format a tool-script failure as a 200-able body. ElevenLabs CAI does
    not forward 5xx bodies to the agent's LLM (the agent only sees the status
    code as a generic 'internal error'), so wrap downstream failures in 200
    + ok=false so the agent can speak the real cause to the user."""
    body = {
        "ok":          False,
        "action":      action,
        "error":       f"{action} failed (rc={run_result['rc']})",
        "rc":          run_result["rc"],
        "stderr_tail": (run_result["stderr"] or "").splitlines()[-6:],
        "stdout_tail": (run_result["stdout"] or "").splitlines()[-4:],
    }
    if hint:
        body["hint"] = hint
    return body


def _compose_volume_hint(stderr: str) -> str | None:
    """If compose complained about an undefined volume `postgres-data-N`, tell
    the user exactly which entry to add to their docker-compose.flowslot.yml.
    """
    m = re.search(r'refers to undefined volume\s+([a-zA-Z0-9._-]+)', stderr or "")
    if m:
        vol = m.group(1)
        return (f"add `  {vol}:` under the `volumes:` block in your "
                f"`docker-compose.flowslot.yml`, then retry create")
    return None


def _run_bin(script: str, *args: str, timeout: float = 300.0) -> dict:
    """Run a script from BIN_DIR with args, capture rc/stdout/stderr."""
    path = os.path.join(BIN_DIR, script)
    if not os.path.isfile(path):
        return {"rc": -1, "stdout": "", "stderr": f"missing helper: {path}"}
    try:
        r = subprocess.run(
            ["bash", path, *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return {"rc": r.returncode, "stdout": r.stdout, "stderr": r.stderr}
    except subprocess.TimeoutExpired:
        return {"rc": -2, "stdout": "", "stderr": f"timeout after {timeout}s"}
    except Exception as e:
        return {"rc": -3, "stdout": "", "stderr": f"{type(e).__name__}: {e}"}


def _detect_host_default_model() -> str:
    """Inspect `ps -eo args` for any other `claude --model X`; pick the most
    common id, fall back to 'opus'. Lets a voice-created session adopt the
    model the host is already using on its other slots."""
    raw = _shell(["bash", "-c", "ps -eo args | grep -E '^claude .*--model' || true"])
    counts: dict[str, int] = {}
    for line in raw.splitlines():
        # Tokenize, find --model and the next arg.
        toks = line.split()
        for i, t in enumerate(toks):
            if t == "--model" and i + 1 < len(toks):
                m = toks[i + 1].strip("'\"")
                counts[m] = counts.get(m, 0) + 1
                break
    if not counts:
        return "opus"
    return max(counts.items(), key=lambda kv: kv[1])[0]


def _slot_dir_for(slot: str) -> str | None:
    """Return the first slot dir matching /srv/*/<slot>-NNNN, or None."""
    for path in glob.glob(f"/srv/*/{slot}-[0-9][0-9][0-9][0-9]"):
        if os.path.isdir(path) and _SLOT_DIR_RE.match(path):
            return path
    return None


def _ports_in_use() -> set[int]:
    """Set of port_base values currently allocated to slots on this host."""
    return {s["port_base"] for s in _discover_slots()}


def _find_available_port_base() -> int | None:
    """First free port base in [PORT_BASE_START..PORT_BASE_MAX), step PORT_RANGE.
    Mirrors find_available_port_base in scripts/lib/common.sh."""
    in_use = _ports_in_use()
    for p in range(PORT_BASE_START, PORT_BASE_MAX, PORT_RANGE):
        if p not in in_use:
            return p
    return None


def _get_project_config() -> dict | None:
    """Discover project / repo_url / compose_files / remote_base.

    Priority for each field:
    - **repo_url**: env `FLOWSLOT_REPO_URL` (shipped by `write_bridge_env`
      from the Mac's `.slotconfig`), else `git remote get-url origin` on the
      first slot dir that has a valid origin. Old slots created before
      `init_slot_git` ran have no origin — skip them.
    - **compose_files**: env `FLOWSLOT_COMPOSE_FILES` (the authoritative list
      from the Mac), else glob discovery as a last-resort fallback.
    - **project / remote_base**: derived from any discovered slot dir.

    Returns None if there are no slots at all AND no `FLOWSLOT_REPO_URL` —
    the user has to bootstrap the first slot from a Mac.
    """
    slots   = _discover_slots()
    env_url = os.environ.get("FLOWSLOT_REPO_URL", "").strip()
    env_cf  = os.environ.get("FLOWSLOT_COMPOSE_FILES", "").strip()
    env_pj  = os.environ.get("FLOWSLOT_PROJECT_NAME", "").strip()

    if not slots and not env_url:
        return None

    project     = env_pj or (slots[0]["project"] if slots else None)
    remote_base = os.path.dirname(slots[0]["remote_path"]) if slots else f"/srv/{project}"

    # repo_url: env wins; else first slot with a valid origin
    repo_url = env_url
    if not repo_url:
        for s in slots:
            u = _shell(["git", "-C", s["remote_path"], "remote", "get-url", "origin"]).strip()
            if u:
                repo_url = u
                break

    # compose_files: env wins; else glob discovery on any slot dir
    if env_cf:
        compose_files = env_cf
    elif slots:
        path = slots[0]["remote_path"]
        compose = [os.path.basename(f)
                   for f in sorted(glob.glob(f"{path}/docker-compose*.yml"))
                   if os.path.basename(f) not in ("docker-compose.flowslot.yml",
                                                   "docker-compose.prod.yml")]
        compose_files = " ".join(compose)
    else:
        compose_files = ""

    return {
        "project":       project,
        "repo_url":      repo_url,
        "compose_files": compose_files,
        "remote_base":   remote_base,
    }


def _slot_dir_size_mb(path: str) -> int | None:
    """`du -sm` for a slot dir, or None on failure."""
    out = _shell(["du", "-sm", path], timeout=5.0).strip()
    if not out:
        return None
    try:
        return int(out.split()[0])
    except Exception:
        return None


def _invalidate_slots_cache() -> None:
    """Bust the `slots_snapshot_v1` / `system_status_v1` caches so the next
    /bridge/slots reflects a fresh create/destroy/restart immediately."""
    try:
        with db_connect() as conn:
            conn.execute("DELETE FROM bridge_state WHERE key IN "
                         "('slots_snapshot_v1','system_status_v1')")
            conn.commit()
    except Exception:
        pass


def _slot_session_containers(slot: str, project: str) -> int:
    """Count of running compose containers belonging to the slot (for destroy plan)."""
    prefix = f"{project}-{slot}"
    return sum(1 for (name, _) in _docker_ps() if prefix in name)


# ElevenLabs CAI gateway times out tool calls around ~28s. We cap the
# server-side block at 22s so the agent gets a clean 200 + still_working
# response instead of a 504 it would have to surface as a tool error.
WATCH_MAX_WAIT_SEC = 22


def watch_for_stop(slot: str, timeout_sec: int) -> dict:
    """Block up to min(timeout_sec, WATCH_MAX_WAIT_SEC); on Stop event return
    `stopped: true`; on cap, return `stopped: false, still_working: true` so
    the caller knows to loop. Always 200 — never let the upstream gateway
    time out the HTTP connection."""
    capped = max(1, min(int(timeout_sec or WATCH_MAX_WAIT_SEC), WATCH_MAX_WAIT_SEC))
    with db_connect() as conn:
        baseline = conn.execute(
            "SELECT ts FROM events WHERE slot = ? AND type='stop' "
            "ORDER BY ts DESC LIMIT 1",
            (slot,),
        ).fetchone()
    baseline_ts = baseline["ts"] if baseline else 0
    deadline = time.time() + capped
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
    return {
        "stopped":             False,
        "still_working":       True,
        "waited_seconds":      capped,
        "last_claude_preview": _last_claude_preview(slot),
        "hint":                "call again to keep waiting",
    }


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
                timeout = int((q.get("timeout") or [str(WATCH_MAX_WAIT_SEC)])[0])
                # watch_for_stop internally caps to WATCH_MAX_WAIT_SEC; the
                # outer clamp just guards against negative input.
                timeout = max(1, timeout)
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

            # --- v2.16: slot lifecycle endpoints ---

            if parsed.path == "/bridge/slot/create":
                return self._handle_slot_create(body, q)
            if parsed.path == "/bridge/slot/start_claude":
                return self._handle_slot_start_claude(body, q)
            if parsed.path == "/bridge/slot/restart_claude":
                return self._handle_slot_restart_claude(body, q)
            if parsed.path == "/bridge/slot/destroy":
                return self._handle_slot_destroy(body, q)

            return self._not_found()
        except Exception as e:
            log(f"[bridge] ERROR {self.path}: {e}")
            return self._reply(500, {"error": str(e)})

    # --- lifecycle handlers ---

    def _parse_lifecycle(self, body: bytes, query: dict) -> tuple[dict | None, str | None]:
        """Decode JSON body, resolve+validate slot. Return (payload, slot)
        or send a 400 reply and return (None, None)."""
        try:
            payload = json.loads(body) if body else {}
        except Exception as e:
            self._bad_request(f"invalid JSON: {e}")
            return (None, None)
        slot = self._resolve_slot(query, payload)
        if slot is None:
            self._bad_request("slot required", hint="call /bridge/slots to list")
            return (None, None)
        return (payload, slot)

    def _handle_slot_create(self, body: bytes, q: dict):
        payload, slot = self._parse_lifecycle(body, q)
        if payload is None:
            return
        if _slot_dir_for(slot) is not None:
            return self._reply(409, {
                "error": f"slot '{slot}' already exists",
                "hint":  "pick a different name, or destroy the existing slot first",
            })
        cfg = _get_project_config()
        if cfg is None:
            return self._reply(409, {
                "error": "no existing slot on host to derive project config from",
                "hint":  "bootstrap the first slot from your Mac with 'slot create <name>'",
            })
        port = _find_available_port_base()
        if port is None:
            return self._reply(409, {"error": "no free port range",
                                     "hint": "destroy an old slot to reclaim a port"})
        branch = (payload.get("branch") or slot).strip()
        plan = {
            "slot":          slot,
            "project":       cfg["project"],
            "port_base":     port,
            "branch":        branch,
            "remote_path":   f"{cfg['remote_base']}/{slot}-{port}",
            "repo_url":      cfg["repo_url"],
            "compose_files": cfg["compose_files"],
        }
        if not payload.get("confirm"):
            return self._reply(200, {"would_create": plan})

        t0 = time.time()
        r = _run_bin("slot_create_remote.sh",
                     slot, cfg["project"], cfg["repo_url"], str(port),
                     cfg["remote_base"], cfg["compose_files"], branch,
                     timeout=300.0)
        ms = int((time.time() - t0) * 1000)
        if r["rc"] != 0:
            # 200 with ok=false so ElevenLabs CAI surfaces the body to the
            # agent's LLM — a raw 500 hides everything behind a generic
            # "Internal Server Error" string and the user can't act on it.
            return self._reply(200, _tool_failure_body(
                "create", r, hint=_compose_volume_hint(r["stderr"])))

        # v2.17: launch Claude immediately so the slot is usable on return —
        # one round-trip from the voice agent's perspective (create + ready).
        # Failure to start Claude doesn't fail the create; the slot is fine,
        # the agent can recover with start_claude_on_slot.
        model = (payload.get("model") or _detect_host_default_model() or "opus").strip()
        cr = _run_bin("slot_claude_remote.sh",
                      slot, plan["remote_path"], cfg["project"], model,
                      timeout=30.0)
        claude_started = cr["rc"] == 0
        _invalidate_slots_cache()
        resp = {"created": True, "duration_ms": ms,
                "claude_started": claude_started,
                "model": model,
                "session": _tmux_session_name(slot),
                **plan}
        if not claude_started:
            resp["claude_error"] = {
                "rc":          cr["rc"],
                "stderr_tail": (cr["stderr"] or "").splitlines()[-4:],
                "hint":        "call start_claude_on_slot to retry",
            }
        return self._reply(200, resp)

    def _handle_slot_start_claude(self, body: bytes, q: dict):
        payload, slot = self._parse_lifecycle(body, q)
        if payload is None:
            return
        slot_dir = _slot_dir_for(slot)
        if slot_dir is None:
            return self._not_found(f"slot '{slot}' does not exist",
                                   hint="call /bridge/slots to list")
        if _tmux_has_session(slot):
            return self._reply(200, {
                "started": False, "reason": "already running",
                "session": _tmux_session_name(slot), "slot": slot,
            })
        model = (payload.get("model") or _detect_host_default_model() or "opus").strip()
        project = os.path.basename(os.path.dirname(slot_dir))
        r = _run_bin("slot_claude_remote.sh", slot, slot_dir, project, model, timeout=30.0)
        if r["rc"] != 0:
            return self._reply(200, _tool_failure_body("start_claude", r))
        _invalidate_slots_cache()
        return self._reply(200, {"started": True, "slot": slot,
                                 "session": _tmux_session_name(slot), "model": model})

    def _handle_slot_restart_claude(self, body: bytes, q: dict):
        payload, slot = self._parse_lifecycle(body, q)
        if payload is None:
            return
        slot_dir = _slot_dir_for(slot)
        if slot_dir is None:
            return self._not_found(f"slot '{slot}' does not exist",
                                   hint="call /bridge/slots to list")
        if not payload.get("confirm"):
            current = state_from_db(slot) if _tmux_has_session(slot) else None
            return self._reply(200, {
                "would_restart": {
                    "slot":        slot,
                    "tmux_alive":  _tmux_has_session(slot),
                    "current_state": current,
                },
                "hint": "call again with confirm: true to proceed",
            })
        model = (payload.get("model") or _detect_host_default_model() or "opus").strip()
        if _tmux_has_session(slot):
            subprocess.run(["tmux", "kill-session", "-t", _tmux_session_name(slot)],
                           capture_output=True)
            # tmux may report success before fully releasing the session name.
            time.sleep(0.3)
        project = os.path.basename(os.path.dirname(slot_dir))
        r = _run_bin("slot_claude_remote.sh", slot, slot_dir, project, model, timeout=30.0)
        if r["rc"] != 0:
            return self._reply(200, _tool_failure_body("restart_claude", r))
        _invalidate_slots_cache()
        return self._reply(200, {"restarted": True, "slot": slot,
                                 "session": _tmux_session_name(slot), "model": model})

    def _handle_slot_destroy(self, body: bytes, q: dict):
        payload, slot = self._parse_lifecycle(body, q)
        if payload is None:
            return
        slot_dir = _slot_dir_for(slot)
        if slot_dir is None:
            return self._not_found(f"slot '{slot}' does not exist")
        m = _SLOT_DIR_RE.match(slot_dir)
        if not m:
            return self._reply(500, {"error": f"could not parse slot path: {slot_dir}"})
        project = m.group("project")
        port    = int(m.group("port"))
        last_ev = _slot_last_event(slot)
        plan = {
            "slot":             slot,
            "project":          project,
            "remote_path":      slot_dir,
            "port_base":        port,
            "containers_count": _slot_session_containers(slot, project),
            "dir_size_mb":      _slot_dir_size_mb(slot_dir),
            "tmux_alive":       _tmux_has_session(slot),
            "last_event":       last_ev,
        }
        if not payload.get("confirm"):
            return self._reply(200, {"would_destroy": plan,
                                     "hint": "call again with confirm: true to proceed"})

        cfg = _get_project_config()
        compose_files = (cfg or {}).get("compose_files", "")
        remote_base   = os.path.dirname(slot_dir)
        t0 = time.time()
        r = _run_bin("slot_destroy_remote.sh", slot, project, str(port),
                     remote_base, compose_files, timeout=180.0)
        ms = int((time.time() - t0) * 1000)
        if r["rc"] != 0:
            return self._reply(200, _tool_failure_body("destroy", r))
        _invalidate_slots_cache()
        return self._reply(200, {"destroyed": True, "duration_ms": ms, **plan})


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
