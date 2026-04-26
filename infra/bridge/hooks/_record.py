#!/usr/bin/env python3
"""Shared hook recorder: append a row to ~/.flowslot/bridge.db.

Hooks pipe Claude Code's event JSON into this script via stdin. Usage from
the per-hook wrapper:

    cat | _record.py <type>

Where <type> ∈ {pre_tool, post_tool, stop, notification}.

Python stdlib only (sqlite3, json, sys, os).
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import time

DB_PATH = os.path.expanduser(os.environ.get("FLOWSLOT_BRIDGE_DB", "~/.flowslot/bridge.db"))


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: _record.py <type>", file=sys.stderr)
        return 2
    event_type = sys.argv[1]
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception as e:
        payload = {"_parse_error": str(e), "_raw": raw[:500]}

    ts = int(time.time())
    tool = payload.get("tool_name")
    args = payload.get("tool_input")
    # UserPromptSubmit events carry `prompt` instead of `tool_input`. Stash the
    # prompt text in `args` so the bridge can show it in state queries.
    if args is None and payload.get("prompt") is not None:
        args = {"prompt": payload["prompt"]}
    result = payload.get("tool_response") or payload.get("tool_output")
    message = payload.get("message") or payload.get("reason") or payload.get("notification_type")
    session_id = payload.get("session_id")

    with sqlite3.connect(DB_PATH, timeout=5) as conn:
        conn.execute(
            "INSERT INTO events (ts, type, tool, args, result, message, session_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                ts,
                event_type,
                tool if isinstance(tool, str) else None,
                json.dumps(args, ensure_ascii=False) if args is not None else None,
                json.dumps(result, ensure_ascii=False) if result is not None else None,
                message if isinstance(message, str) else None,
                session_id if isinstance(session_id, str) else None,
            ),
        )
        conn.commit()
    # Hooks must exit 0; non-zero can block Claude's execution per Claude Code spec.
    return 0


if __name__ == "__main__":
    sys.exit(main())
