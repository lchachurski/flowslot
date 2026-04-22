#!/bin/bash
# Claude Code hook: Stop → record event.
exec "$(dirname "$0")/_record.py" stop
