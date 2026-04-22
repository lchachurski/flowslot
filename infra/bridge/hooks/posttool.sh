#!/bin/bash
# Claude Code hook: PostToolUse → record event.
exec "$(dirname "$0")/_record.py" post_tool
