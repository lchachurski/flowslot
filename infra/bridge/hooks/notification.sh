#!/bin/bash
# Claude Code hook: Notification → record event.
exec "$(dirname "$0")/_record.py" notification
