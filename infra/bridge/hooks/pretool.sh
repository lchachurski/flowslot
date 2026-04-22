#!/bin/bash
# Claude Code hook: PreToolUse → record event.
exec "$(dirname "$0")/_record.py" pre_tool
