#!/bin/bash
# Claude Code hook: UserPromptSubmit → record event.
# Fires when the user (or our `inject_message` paste) submits a prompt to Claude.
# Records as type=user_prompt; bridge state logic uses this to distinguish
# "Claude is thinking" from "Claude is idle".
exec "$(dirname "$0")/_record.py" user_prompt
