# Changelog

All notable changes to Flowslot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See [RELEASES.md](RELEASES.md) for versioning details.

## [Unreleased]

## [2.14.0] - 2026-06-12

### Added

- **Model selection for `slot claude`.** Two ways to control which
  Claude model the slot uses, mirroring the existing
  `SLOT_CLAUDE_DEFAULT` pattern:
  - **`.slotconfig`**: `SLOT_CLAUDE_MODEL=<alias-or-id>` — sticks
    across every `slot claude` invocation on that project. Accepts a
    Claude Code alias (`opus`, `sonnet`, `haiku`) or a full ID
    (`claude-sonnet-4-6`, etc.).
  - **CLI flag**: `slot claude --model <id>` — one-off override that
    wins over `.slotconfig`.
  - **Default (unset)**: defer to the Claude Code CLI default — same
    behaviour as before.
  - Plumbed through all four launch paths: local interactive,
    local headless, remote interactive (tmux), remote headless
    (stream-json over SSH).

## [2.13.2] - 2026-05-20

### Fixed

- **`slot claude --local` now passes `--dangerously-skip-permissions`.**
  Remote mode (the default) already used it on every invocation; local
  mode was the lone gap, so running Claude against your Mac's source
  dir would prompt for every tool call. Now both modes start Claude
  with permissions skipped by default — matching the rest of the
  Flowslot UX, where the slot (or your local checkout under
  `slot claude --local`) is treated as a sandbox.

## [2.13.1] - 2026-05-03

Documentation + a small system-prompt fix. No code changes on the slot.

### Added

- **README section: "Voice control with Claude Code".** High-level
  overview alongside Tailscale, Mutagen, dnsmasq, etc. — explains
  ElevenLabs Conversational AI as the voice layer, what the agent can
  do, cost, and a setup-at-a-glance checklist.
- **New `docs/voice.md`.** Long-form reference: architecture diagram,
  full tool list, security model (HMAC over path+body, Tailscale Funnel
  TLS), per-project config, setup walkthrough, why ElevenLabs, known
  limitations, troubleshooting. Linked from the README.

### Changed — agent system prompt

- **Skip Claude Code rating / feedback prompts.** When Claude Code
  surfaces a "rate this conversation" / "leave feedback" / survey-style
  prompt at the end of a session, the voice agent now filters it out
  instead of reading it. Such meta-prompts from the Claude Code UI are
  useless on a phone — the agent reports only the substantive task work
  and never injects a rating on the user's behalf. Re-paste the system
  prompt from `slot claude voice agent-config` into the ElevenLabs
  dashboard to pick this up.

## [2.13.0] - 2026-05-02

Three flowslot-developer tasks identified by transcript review of the
last 3 days of voice calls.

### Added

- **New bridge endpoint `GET /bridge/system_status`** — host + slot +
  bridge metrics in one ~150ms call: server uptime, load averages,
  memory usage, root disk %, slot's tmux state, slot disk usage, slot
  git branch + clean state, container statuses, bridge event counts
  (total / last hour / last minute). Surfaced to the ElevenLabs agent
  as a new tool `get_system_status`. Use case: ask the agent "how's
  the box doing", "any containers crashed", "how much disk", etc. and
  it pulls real numbers instead of guessing.
  Source: conv_9501kqjaxemkfv8rxc7hp8mkk3t0 @258s (2026-05-01).

### Changed — agent system prompt

- **Distinguish "you" (the agent) from "Claude" (the slot).** New rules
  added so the agent answers questions about itself or general tech
  topics directly using its own LLM, instead of injecting them to
  Claude. References "Claude / slot / codex / the developer" → use
  Claude tools. References "you / the agent / ElevenLabs" or general
  tech ("how does X work") → answer from own LLM.
  Source: conv_9501 @258s.
- **"Note for FlowSlot developer" auto-acknowledgment.** Any phrase
  matching "note for [the] developer" / "note for myself" /
  "note for FlowSlot" is now recognized as a meta-note for the human
  developer. Agent acknowledges with one short sentence and DOES NOT
  inject anything to Claude, doesn't call tools, doesn't ask follow-ups.
  Source: conv_6501kqjq629nedh92z07q5xzb6be @4s (2026-05-01).
- **Agent voice changed from Chris to Jessica** (American female,
  expressive). User-driven iteration over the last 24h: Brian → Chris
  → Charlotte (British) → Lily → Jessica.

### Plan provenance

- conv_9501 @258s: monitoring tool — done.
- conv_9501 @258s: agent vs Claude distinction — done.
- conv_6501 @4s: auto-acknowledge "note for developer" — done.

## [2.12.1] - 2026-05-01

Two follow-up tweaks identified by reviewing 7 days of voice-call
transcripts. Both addressed via ElevenLabs API + system-prompt update;
no code changes on the slot.

### Changed

- **Agent now auto-fetches `get_claude_last_output` whenever a state
  query benefits from context.** On every "what's Claude doing", "is
  it done", "any update" question — not just the first turn — the
  agent now decides whether to also pull recent output:
  - status `idle`: always (the user wants to know what just finished).
  - status `executing_tool` / `thinking` with `elapsed_seconds > 60`:
    yes (long-running work needs in-flight context).
  - status `awaiting_input`: yes (so the agent can describe what
    Claude is asking about).
  - status `executing_tool` / `thinking` with `elapsed_seconds <= 60`:
    no — skip the extra call, just report state. Keeps short-task
    state queries snappy.
  Previously this only happened on the very first turn, leaving the
  user re-asking "what did it actually say?" mid-call.
- **Agent voice changed from Brian to Chris** (id `iP95p4xoKVk53GoZ742B`)
  for a more upbeat, conversational tone. Brian's calm-narrator
  prosody read as tired on short factual replies. Chris is rated
  warmer / more energetic in ElevenLabs' catalog.
- **TTS settings tuned for energy:** `stability` 0.5 → 0.45 (slightly
  more expressive), `speed` 1.0 → 1.05 (5% faster, less drawn-out).
  `eleven_flash_v2` model unchanged for low latency.
- **System prompt: tone / cadence guidance.** Explicit anti-patterns
  added: no sighs, no slow trail-offs, no "weeellll", no
  throat-clearing intros ("So, I just checked..."). Lead with the
  answer, drop fillers ("um", "uh", "you know", "sort of"). Speak
  like a sharp colleague giving a phone update, not a narrator.

### Plan provenance

Tasks identified by scanning 7 days of ElevenLabs conversation
transcripts (65 calls) for explicit "note for the flowslot developer"
flags from the user:
- conv_8201 @447s (2026-04-25): idle vs thinking detection — done in
  v2.12.0.
- conv_9601 @26s (2026-04-29): always surface last_output — done here.
- conv_5101 @269s (2026-04-28): cheerful/energetic voice — done here.

## [2.12.0] - 2026-04-30

Two-week iteration on `slot claude voice` based on real end-to-end usage.
v2.11.0 shipped the architecture; this release fixes the bugs that surfaced
when actually using it. Plus: slots now have working git push out of the box.

### Added — new features

- **`slot claude voice watch`** — a 3-pane local tmux dashboard streaming
  the slot live: top pane attaches read-only to Claude's REPL, middle pane
  follows the bridge's HTTP log (every CAI tool webhook with status), bottom
  pane streams Claude Code hook events from `bridge.db` as they fire. Use it
  while on a phone call to see exactly what the agent + Claude are doing.
- **`thinking` state** — bridge can now distinguish "Claude is reasoning
  between tool calls" from "Claude is idle". Backed by a new
  `UserPromptSubmit` hook recorded in `bridge.db`. State priorities are now:
  `executing_tool` > `thinking` > `awaiting_input` > `idle`. The CAI agent
  reports thinking accurately ("Claude is processing — about thirty seconds
  in, no tool yet") instead of incorrectly saying "idle".
- **Slot-side git push, automatic.** `slot create` now sets up a real `.git`
  on the slot's remote dir linked to origin (fetches a shallow copy of the
  target branch, runs `git reset --mixed FETCH_HEAD` so the working tree —
  the mutagen-synced files — stays untouched while HEAD/index align with
  upstream). Combined with a global git credential helper that reads from
  `~/.git-credentials`, slots can `git commit` and `git push` to real GitHub
  branches with no further setup. Required new config var
  `FLOWSLOT_GITHUB_TOKEN` (fine-grained PAT, contents: read/write).
- **Outbound first_message override.** When Claude calls via `call_user`,
  the agent's opening line is now Claude's actual report (passed via
  `conversation_initiation_client_data.agent.first_message`), not the
  static "Hey, Claude's session is up". Users hear what Claude wants to say
  the moment they pick up.
- **Inbound auto-state-check.** New first-turn behavior in the agent: on
  the very first user turn after connect, the agent immediately calls
  `get_claude_state` (and `get_claude_last_output` if idle) and replies
  with a single 1–2 sentence state summary. No "what do you need" trailing
  prompts; the user speaks again if they want to continue.
- **Static-token auth alongside HMAC.** Bridge now accepts both
  `X-Flowslot-Signature` (HMAC-SHA256) and `X-Flowslot-Token` (static
  bearer). ElevenLabs CAI's tool config supports static headers cleanly
  but doesn't sign per-request HMACs — this is the path that actually
  makes the integration work in practice.
- **Per-request bridge log line** — every webhook now logs
  `[bridge] METHOD PATH -> STATUS (BYTES)` to `journalctl`. Essential for
  debugging via `slot claude voice logs -f`.
- **Auto-watch after inject.** After every `inject_message`, the agent now
  automatically chains `watch_for_stop(90)` and proactively reports when
  Claude finishes — no more "has it answered yet?" round-trips.

### Changed — agent system prompt overhaul

Driven by real conversation transcripts where the agent fabricated
content, hallucinated state, or read verbatim when summary was wanted:

- **Default response style is summary, not verbatim.** All tool outputs are
  summarized in 1–3 sentences by default. Verbatim mode is opt-in only
  (triggered by explicit phrases: "verbatim", "word for word", "exact
  words", "read it out", "as-is", "literal text", etc.). Previously the
  agent defaulted to verbatim for short outputs.
- **Forbid fabricating inject content.** Agent must faithfully translate
  what the user actually said. Specific technical content the user did NOT
  speak (branch names, commit SHAs, command flags, option numbers) must
  never be invented. Pronouns like "this option" / "the second one" are
  resolved from the explicit conversation context, never guessed.
- **Forbid quoting own tool params as user speech.** When asked "why did
  you do that?", the agent reconstructs from the user's words only — never
  cites its own `inject_message` arguments back as evidence of what the
  user said.
- **Anti-hallucination rule for prior activity.** Agent has no memory
  beyond the current call's tool responses; it must never claim Claude
  "previously did X" unless the tool output literally contains that text.
- **Inbound first_message** is a Claude-specific question
  ("Hey — want me to check what Claude's up to?") that puts the
  conversation on the right rails immediately, instead of the previous
  generic "Hey, Claude's session is up" or the misleading "let me check"
  promise.

### Fixed

- **`inject_message` now actually submits.** Claude Code's REPL uses
  bracketed-paste handling — sending text and Enter in one `tmux send-keys`
  call caused the Enter to be consumed as a newline inside the input
  buffer. The pasted message would appear in the prompt but never submit,
  causing the CAI agent to incorrectly believe Claude was idle. Fix:
  3-phase paste — `load-buffer` → `paste-buffer -d` → 0.9s settle delay →
  separate `send-keys Enter`. Verified end-to-end with multi-hundred-char
  injects.
- **State logic no longer flips to `awaiting_input` mid-tool-call.**
  Previously a stale `Notification` event from an earlier pause could
  override an in-flight tool call. Fix: `executing_tool` takes priority;
  the awaiting-input branch only fires when no tool is currently running
  AND the notification is newer than any subsequent `pre_tool` /
  `user_prompt`.
- **`get_claude_last_output` default lines bumped from 1 to 50.** Agents
  were calling it with `lines: 1`, getting back the REPL footer
  ("? for shortcuts"), and reporting that as "Claude's last response".
  Tool description now warns explicitly against `lines: 1`.
- **Bridge default port changed from 8080 to 9090.** 8080 collided with
  common app ports (and with leftover v2.10 call-me processes). 9090 is
  less contested.
- **Robust v2.10 cleanup.** `voice enable` now reliably kills lingering
  call-me bun processes by walking `/proc/<pid>/cwd` for matches under
  `~/.flowslot/call-me`, instead of fragile command-string matching.
- **`voice enable` always restarts the systemd unit.** `systemctl enable
  --now` is a no-op when the unit is already running, so re-running enable
  used to leave the bridge with stale env vars. Now the unit is always
  restarted to pick up env changes.
- **Bridge auto-installs `sqlite3` and `jq`.** These are needed by the hook
  scripts and MCP registration but aren't on every Ubuntu base image.
- **Tailscale CLI 1.64+ compatibility.** Replaced the deprecated two-step
  `tailscale serve --https=443 --set-path=/ http://127.0.0.1:<port>` +
  `tailscale funnel --bg 443 on` with the single `tailscale funnel --bg
  <port>` CLI introduced in 1.64. First-time funnel-not-enabled errors
  now surface the exact one-click enable URL Tailscale provides.
- **MCP registration uses `claude mcp add`.** Previously wrote into
  `settings.json`'s `mcpServers` key, which Claude Code silently ignores.
  Canonical path is `~/.claude.json` via the CLI; switched accordingly.

### Notes

- The v2.10 fork `lchachurski/call-me` is now fully retired from flowslot
  and is no longer referenced by any code path. Existing slots running
  v2.10 will get the call-me artifacts auto-cleaned on the next
  `slot claude voice enable` run.
- Test pricing per real call: ~$0.11/min inbound (CAI minutes + Polish
  Twilio inbound), ~$0.20/min outbound to Polish mobile. Number rental
  ~$1.15/mo. See README "Cost notes" for details.

## [2.11.0] - 2026-04-22

### Added
- **`slot claude voice` rearchitected around ElevenLabs Conversational AI +
  a Python bridge service.** Two big capability gains over v2.10:
  - **Inbound calls** — you call Claude (not just Claude calling you). The
    ElevenLabs agent picks up and has tools to read Claude's live session:
    "how's it going?", "what did Claude just say?", "tell Claude to X",
    "wait until Claude is done and let me know".
  - **Real barge-in + turn-taking** — ElevenLabs CAI handles this natively,
    replacing call-me's sequential turn loop.
- New bridge service on the slot (`~/.flowslot/bridge/`, systemd-managed):
  Python 3 HTTP server on port 8080, HMAC-authenticated tool webhooks for
  the CAI agent. Four tools:
  - `GET /bridge/state` — structured status snapshot (status, current tool,
    elapsed time, waiting-for-input flag, last Claude preview).
  - `GET /bridge/output?lines=N` — raw `tmux capture-pane` text for
    verbatim relay.
  - `POST /bridge/inject` — send a message into Claude's REPL; optional
    `urgent=true` interrupts the current tool call first.
  - `GET /bridge/watch?timeout=N` — long-poll until Claude's next Stop event.
- New Claude Code hooks (PreToolUse, PostToolUse, Stop, Notification) that
  append events to `~/.flowslot/bridge.db` (SQLite), powering the <50ms state
  queries.
- New `voice-outbound` MCP server (stdio, Python). Gives Claude a `call_user`
  tool that POSTs ElevenLabs' outbound-call API. After Claude places the call,
  the ElevenLabs agent takes over with access to the same 4 bridge tools —
  so outbound calls are also full multi-turn conversations.
- New subcommands:
  - `slot claude voice agent-config` — prints the ElevenLabs agent system
    prompt + the 4 tool-definition JSONs for one-time copy-paste setup.
  - `slot claude voice test` — places an outbound call directly via the
    voice-outbound MCP, bypassing Claude, for end-to-end pipeline verification.
- Config additions in `.slotconfig`:
  - `FLOWSLOT_ELEVENLABS_API_KEY`
  - `FLOWSLOT_ELEVENLABS_AGENT_ID`
  - `FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID`
  - `FLOWSLOT_BRIDGE_HMAC_SECRET` (auto-generated on first `voice enable`)
- `slot self init` now prompts for ElevenLabs credentials instead of Twilio
  (Twilio is still supported indirectly — ElevenLabs can import a Twilio
  number — but flowslot no longer talks to Twilio's API directly).

### Changed (Breaking for `slot claude voice` users of v2.10)
- **call-me integration retired.** `slot claude voice enable` now automatically
  cleans up any v2.10 call-me artifacts on the slot (`~/.flowslot/call-me/`,
  `~/.flowslot/call-me.env`, `~/.flowslot/bin/call-me-mcp`, the MCP
  registration) before installing the v2.11 stack. Existing users can just
  run `slot claude voice enable` on upgrade and everything transitions.
- **Claude's outbound tool shape changed.** Instead of call-me's `initiate_call`
  / `continue_call` / `speak_to_user` / `end_call` (4 tools, sequential
  turn-taking), Claude now has a single `call_user(message, reason)` MCP
  tool. The conversation after pickup is driven by the ElevenLabs agent,
  not Claude's tool calls — simpler for Claude, richer UX for the user.
- `slot claude voice logs` now tails `journalctl -u flowslot-bridge` over SSH
  instead of dumping tmux scrollback.
- `slot claude voice refresh-fork` subcommand removed (no fork to refresh).

### Removed
- `FLOWSLOT_OPENAI_API_KEY` is no longer needed — ElevenLabs CAI handles
  STT and TTS. Existing entries in `.slotconfig` are harmless (ignored).
- `FLOWSLOT_VOICE_PINNED_SHA` is no longer needed — no call-me fork pin.
- The `lchachurski/call-me` fork stays on GitHub as historical record with
  the upstream PRs (#35, #36) still open; flowslot no longer references it.

### Prerequisites (one-time)
- ElevenLabs account, API key, a Conversational AI agent created in their
  dashboard, and a phone number registered with ElevenLabs.
- Tailscale Funnel enabled on the tailnet for the EC2 node (same as v2.10).
- Paste the system prompt + 4 tool configs (printed by
  `slot claude voice agent-config`) into the ElevenLabs agent settings.

## [2.10.0] - 2026-04-21

### Added
- **`slot claude voice enable / disable / status / logs / refresh-fork`** —
  two-way phone conversations with Claude Code on a slot. Claude gains an
  `initiate_call` MCP tool (plus `continue_call`, `speak_to_user`, `end_call`).
  When Claude invokes it, your phone rings; you pick up and actually talk to
  the running Claude session — hear a summary, ask follow-ups, kick off the
  next task, all by voice. Multi-turn conversation supported.
- Voice uses a **forked** [`ZeframLou/call-me`](https://github.com/lchachurski/call-me)
  MCP server (MIT) installed on the slot and registered in `~/.claude/settings.json`.
  The fork adds a `CALLME_PUBLIC_URL` env var so we can skip call-me's default
  ngrok tunnel; upstream PR at
  [ZeframLou/call-me#35](https://github.com/ZeframLou/call-me/pull/35).
- **Tailscale Funnel** is used to expose the webhook endpoint with a real
  HTTPS cert (Twilio rejects self-signed). No EC2 security group changes,
  no Elastic IP, no Let's Encrypt plumbing.
- Config vars (written by `slot self init` → `.slotconfig`):
  - `FLOWSLOT_OPENAI_API_KEY` — required for call-me's Whisper (STT) + `tts-1` (TTS)
  - `FLOWSLOT_VOICE_PINNED_SHA` — override the call-me commit SHA (default in `scripts/lib/claude-voice.sh`)
- New files:
  - `scripts/slot-claude-voice` — dispatcher
  - `scripts/lib/claude-voice.sh` — helpers (bun install, fork clone, env file, Funnel on/off, MCP registration)
- `slot destroy` now tears down voice chat (Funnel + MCP registration) before
  removing the remote directory to avoid orphaned Funnel config.

### Removed
- `infra/flowslot-notify.sh` and the associated `Stop` / `Notification` hook
  deployment (carried over from 2.9.x cleanup). The one-way "task finished"
  nudge is superseded by the two-way voice chat.
- `slot claude logs` subcommand and the `-f` / `--follow` flag — that log path
  only existed for the removed flowslot-notify script. `slot claude voice logs`
  provides the equivalent for voice-chat state.

### Prerequisites (one-time)
- Enable Tailscale Funnel for your EC2 node in the tailnet ACL:
  https://login.tailscale.com/admin/acls
- GitHub CLI (`gh`) authenticated if you want to bump the fork SHA yourself.

## [2.9.1] - 2026-04-20

### Changed (Breaking for `slot claude` users)
- **Switched notification channel from CallMeBot to Twilio Voice.** CallMeBot's
  Telegram-bot voice call doesn't integrate with CallKit on iOS, so the phone
  doesn't actually ring when Telegram is backgrounded — it only surfaces if
  the Telegram app is foreground. Twilio places a real PSTN call that rings
  like any other phone call, bypasses Do Not Disturb when set as emergency,
  and works on locked phones.
- `.slotconfig` variables renamed:
  - `FLOWSLOT_CALLMEBOT_PHONE` / `_APIKEY` / `_CHANNEL` / `_URL_TEMPLATE` removed
  - Added: `FLOWSLOT_TWILIO_ACCOUNT_SID`, `FLOWSLOT_TWILIO_AUTH_TOKEN`,
    `FLOWSLOT_TWILIO_FROM`, `FLOWSLOT_TWILIO_TO`, optional `FLOWSLOT_TWILIO_VOICE`
- `slot self init` now prompts for Twilio credentials.

### Fixed
- `rsync --chmod=F755` flag rejected by macOS's openrsync; now relies on source
  file perms + post-sync `chmod` via ssh.
- `ssh host bash -s -- "$a" "$b" "$c"` silently collapsed empty arguments,
  shifting config values by one slot. `deploy_notify_hook` now builds the conf
  file locally and pipes it via stdin.
- `slot claude bootstrap` (and other subcommands) weren't recognized when they
  appeared after flags; the argument parser now accepts the subcommand
  keyword anywhere in the arg list.
- `exec remote_ssh_tty …` failed because `remote_ssh_tty` is a shell function,
  not an external command. Swapped `exec` for call-and-`exit $?`.

## [2.9.0] - 2026-04-20

### Added
- **`slot claude` — run Claude Code on slots with phone-call notifications**
  - Interactive tmux session on the slot by default (survives laptop sleep)
  - `slot claude --headless "<prompt>"` streams `stream-json` output and still fires notifications
  - `slot claude --local` runs Claude against your local source dir (no SSH)
  - `slot claude attach` reattaches to a running session; `slot claude logs [-f]` tails the notify log
  - `slot claude bootstrap` (and `--refresh`) for explicit install / auth-sync / hook deploy
  - First-use auto-provisioning: installs Claude Code on the slot, rsyncs `~/.claude` credentials from your Mac, deploys `~/.flowslot/bin/flowslot-notify`, merges `Stop` and `Notification` hooks into the slot's `~/.claude/settings.json`
  - Falls back to interactive `/login` inside tmux if credentials don't transfer
  - Real phone-call notifications via Twilio Voice (see 2.9.1 — 2.9.0 shipped with CallMeBot, which was replaced after testing revealed it doesn't ring locked iOS phones)
  - Permissions on the slot use `--dangerously-skip-permissions` (the slot is an isolated per-branch sandbox; blast radius = `slot destroy`)
  - `slot self init` prompts for notification credentials; `slot destroy` tears down any lingering `claude-<slot>` tmux session
- New desktop layout commands:
  - `slot desktop up` — Launch browser/editor pairs for running slots on sequential macOS Spaces
  - `slot desktop down` — Close only windows managed by desktop up
  - `slot desktop restart` — Rebuild layout (`down` then `up`)
- Optional desktop configuration via `.slotdesktop` (or `.slotconfig`) with defaults for:
  - `DESKTOP_START_SPACE`, `DESKTOP_LAYOUT`, `DESKTOP_BROWSER`, `DESKTOP_EDITOR`
  - `DESKTOP_TOP_OFFSET`, `DESKTOP_SWITCH_DELAY`, `DESKTOP_WINDOW_TIMEOUT`
- State tracking file `.slotdesktop.state` to safely target managed windows during cleanup

## [2.8.0] - 2026-02-01

### Changed
- **Domain migration** — Changed from `flowslot.dev` to `flowslot.cc`
  - The `.dev` TLD is on the browser HSTS preload list, forcing HTTPS
  - Using `.cc` allows HTTP for local development
  - Updated all references in docs, configs, and scripts

## [2.7.0] - 2026-01-27

### Changed (Breaking)
- **Port-based directory naming** — Remote directories now include port base in name
  - New format: `/srv/project/slotname-7000/` (port base embedded)
  - Old format still supported for backward compatibility
  - Example: `ls /srv/thunder/` shows `pagespeed-7100/`, `release-7000/`
- **Port recycling** — Destroyed slots' port ranges are now reused
  - When slot #1 is destroyed, next slot creation can get port 7100
  - Previously, port numbers only incremented (no recycling)
- **`slot list` shows port ranges** — New column shows which ports each slot uses

### Added
- Helper functions in `lib/common.sh`:
  - `get_slot_name_from_dir()` — Extract slot name from directory
  - `get_port_base_from_dir()` — Extract port base from directory
  - `find_slot_dir()` — Find slot directory (supports both formats)
  - `find_available_port_base()` — Find next available port with recycling

### Fixed
- **Slot numbers now persist** — Previously derived from container ports (lost on prune)
  - Port is now encoded in directory name, survives `docker container prune`
  - No more port conflicts after container cleanup
- Slot detection now works even when all containers are stopped/removed

### Breaking
- Old-format slots (without port suffix) are no longer supported
- Recreate existing slots with `slot destroy` + `slot create`

## [2.6.0] - 2026-01-06

### Changed
- **Simplified .env file copying** — `.env` files are now copied directly from source project during slot creation
  - Removed `.env-templates/` directory indirection layer
  - `.env` files are always fresh — no more stale templates
  - Simpler mental model: new slots get current `.env` files from source

### Removed
- `.env-templates/` directory creation from `slot self init`
- `SLOT_TEMPLATE_DIR` configuration variable
- Legacy `repo.git/` directory (leftover from worktree migration)

### Fixed
- Missing environment variables in new slots (e.g., `ANTHROPIC_API_KEY`) — now always copied from source

## [2.5.0] - 2026-01-06

### Added
- **Automatic Split DNS updates** — Tailscale Split DNS is now updated automatically when creating a new instance
  - Uses Tailscale API to update `flowslot.dev → <new Tailscale IP>`
  - No more manual DNS configuration after `slot server recreate`
- **Centralized config file** (`~/.flowslot/config.local`)
  - All API keys and configuration in one place
  - Automatically sourced by all slot commands
  - Gitignored for security
- `config.example` template for easy setup

### Changed
- Main `slot` command now sources `config.local` at startup
- Improved error messages in `slot server recreate` to mention config.local option
- Instance detection now uses security group filter (more reliable than tag filter)

### Configuration
New variables in `config.local`:
- `TS_API_KEY` — Tailscale API key for Split DNS automation
- `TS_TAILNET` — Your tailnet name (e.g., `example.ts.net`)
- `TS_SPLIT_DOMAIN` — Domain for Split DNS (default: `flowslot.dev`)

## [2.4.1] - 2026-01-05

### Changed
- Removed lockfile mechanism entirely — AWS instance check is the only duplicate prevention
- Script is now stateless; AWS is the source of truth

### Removed
- Local lockfile (`/tmp/flowslot-create-instance.lock`)
- PID file and cleanup trap

## [2.4.0] - 2026-01-05

### Changed
- **Removed SSH lockdown** — SSH remains open for easier debugging
- Added check for existing `flowslot-dev` instance before creating new one (prevents duplicates)
- Improved lockfile mechanism using `mkdir` (works on macOS)
- More verbose progress updates during cloud-init wait (every 15 seconds)

### Fixed
- Multiple instances being created when script times out (now prevented by pre-check)
- Lockfile not working on macOS (flock not available)

## [2.3.0] - 2026-01-05

### Changed (Breaking)
- **Switched from Spot to On-Demand instances**
  - More reliable — no more "InsufficientInstanceCapacity" errors
  - Always available on start
  - Cost: ~$0.15/hr when running (same $0 when stopped)
  - Simpler create-instance.sh script (no fallback types needed)

### Removed
- Spot instance fallback logic (t4g.2xlarge → t4g.xlarge → m6g.xlarge → r6g.large)
- Spot capacity error handling in `slot server start`

## [2.2.0] - 2026-01-05

### Changed (Breaking)
- **Slots now use simple clones instead of Git worktrees**
  - Eliminates detached HEAD issues forever
  - Each slot is a full, independent repository clone
  - Standard Git workflow: `git checkout`, `git push`, `git pull` work normally
  - No more bare repository (`repo.git`) needed
  - Simpler mental model: each slot = standalone project folder
- Branch defaults to slot name if not specified (e.g., `slot create auth` → branch `auth`)

### Removed
- Bare repository cloning during `slot self init`
- Git worktree pruning during `slot destroy`

### Benefits
- No more "detached HEAD" confusion
- IDEs like Cursor recognize the repository correctly
- Easier to debug Git issues (each slot is independent)
- Can push commits from any slot without worrying about branch state

## [2.1.0] - 2026-01-05

### Added
- `slot server recreate` command to terminate and create new instance when Spot capacity unavailable
- `remote_ssh` helper function for automatic host key handling after server recreate
- Spot capacity error detection in `slot server start` with helpful error messages
- Fallback instance types in `create-instance.sh` (t4g.2xlarge → t4g.xlarge → m6g.xlarge → r6g.large)
- Automatic retry through instance types when Spot capacity is unavailable
- Spot capacity troubleshooting section in README
- AGENTS.md for AI assistant guidance

### Changed
- README reorganized for clarity: added TL;DR, consolidated Quick Start, added use cases
- Added multi-device testing and coworker sharing to "Why Flowslot?" section
- Updated cost estimates to reflect fallback instance types ($0.03-0.08/hr)

### Fixed
- Script no longer hangs on Spot capacity errors - fails fast with actionable guidance

## [2.0.2] - 2025-01-01

### Fixed
- Worktrees now always created on named branches, never detached HEAD
- New slots properly track their branch for commits

## [2.0.1] - 2025-01-01

### Fixed
- Slot numbering now counts container port bindings instead of directories
- Works correctly with stopped containers (uses `docker inspect`)
- First slot correctly gets slot 0 (ports 7000-7099)
- Prevents conflicts when stale directories exist without containers

## [2.0.0] - 2025-01-01

### Changed (Breaking)
- **Command renames for clarity:**
  - `slot open` → `slot create`
  - `slot close` → `slot stop`
  - `slot init` → `slot self init`
  - `slot update` → `slot self upgrade`
  - `slot version` → `slot self version`
  - `slot status` → `slot server info`
- Commands now clearly indicate their context (slot, server, or CLI meta)
- No backward compatibility - old commands removed

### Added
- `slot destroy [name]` - Fully delete a slot (local + remote)
- `slot server info` - Show server resource usage (merged from `slot status`)
- Auto-detection of slot name for `slot stop` (when inside slot directory)

### Improved
- Command structure organized into clear categories:
  - **Slot Lifecycle**: create, stop, resume, destroy
  - **Slot Operations**: list, info, compose
  - **Server**: start, stop, status, info
  - **Meta**: self init, self upgrade, self version

## [1.7.6] - 2025-12-31

### Fixed
- `slot resume` now correctly detects slot number from stopped containers
- Uses `docker inspect` instead of `docker ps -a` to get port bindings
- Fixes issue where resume would fail after `slot close` + `slot server stop/start`

## [1.7.5] - 2025-12-28

### Added
- `slot resume [name]` command to resume existing slots without wiping remote files
- Auto-detection of slot name from current directory for `slot resume`
- Auto-start server if stopped when resuming a slot
- Preserves remote-only files (node_modules, build caches) when resuming

### Changed
- `slot open` now errors if slot already exists (single responsibility)
- `slot open` no longer resumes existing slots - use `slot resume` instead

### Fixed
- Slot number detection in `slot resume` uses existing container ports (works even after `slot close`)

## [1.7.4] - 2025-12-28

### Changed
- Removed `.slot_num` file tracking - slot numbering now fully dynamic
- `slot open`: Counts existing slot directories (with docker-compose files) to determine new slot number
- `slot info` / `slot compose`: Detects actual port from running containers to determine slot number
- More reliable: slot numbers derived from actual state, not persisted files

### Fixed
- Slot number mismatch between open time and query time
- No more stale `.slot_num` files causing port conflicts

## [1.7.3] - 2025-12-28

### Changed
- Slot numbering now 0-based (first slot = 0)
- Port range starts at 7000 (slot 0: 7000-7099, slot 1: 7100-7199)
- PORT_BASE_START changed from 7100 to 7000

## [1.7.2] - 2025-12-28

### Fixed
- Slot number assignment now uses MAX+1 instead of finding gaps
- Prevents container name conflicts when old slots are deleted but containers still running
- Numbers always increase, never reused

## [1.7.1] - 2025-12-28

### Fixed
- dnsmasq now waits for Tailscale to be connected before starting
- Prevents dnsmasq from failing to bind to Tailscale IP on EC2 boot
- Added systemd `ExecStartPre` check that polls `tailscale status` up to 30 seconds
- Added `Restart=on-failure` with 5-second delay for resilience

## [1.7.0] - 2025-12-27

### Added
- Two URL patterns available: simple and extended
  - Simple: `{service}.{project}.flowslot.dev:{port}` (port identifies slot)
  - Extended: `{service}.{slot}.{project}.flowslot.dev:{port}` (slot name in domain)
- `slot info` now shows both URL patterns
- `SLOT_DOMAIN` and `SLOT_DOMAIN_FULL` variables in flowslot-ports.sh template
- `SLOT_NAME` and `SLOT_PROJECT_NAME` now exported to remote environment

### Changed
- README updated with both URL pattern options and when to use each

## [1.6.5] - 2025-12-27

### Changed
- Domain changed from fake TLD `.flowslot` to real domain `flowslot.dev`
- URL pattern now: `{service}.{slot}.{project}.flowslot.dev:{port}`
- All documentation and configs updated to use `flowslot.dev`
- Google OAuth now works with proper public TLD

### Fixed
- OAuth compatibility - `.flowslot` was rejected by Google as invalid TLD

## [1.6.4] - 2025-12-27

### Fixed
- Idle-check script no longer detects false positives from auth.log modifications
- Removed auth.log modification check - now only checks for active SSH sessions using `who`
- Prevents systemd-logind and other system processes from resetting idle timer

## [1.6.3] - 2025-12-27

### Fixed
- Increased cloud-init wait time from 3 to 7 minutes (cloud-init takes 4-6 min)
- SSH lockdown now conditional - only locks if Tailscale IP was obtained
- Prevents inaccessible instances when cloud-init takes longer than expected

### Changed
- AWS_KEY_NAME environment variable now recommended for SSH key attachment

## [1.6.2] - 2025-12-27

### Documentation
- Added safety features section to README (lockfile, timeouts, auto-lockdown)

## [1.6.1] - 2025-12-27

### Added
- Lockfile protection to prevent multiple `create-instance.sh` processes running simultaneously
- Reduced Tailscale wait timeout from 5 minutes to 3 minutes

### Fixed
- SSH connection timeout reduced for faster polling
- Added BatchMode to SSH to prevent hanging on prompts

## [1.6.0] - 2025-12-27

### Changed
- `slot info` now generates service URLs dynamically from `SLOT_PORT_*` variables (project-agnostic)
- `create-instance.sh` now waits for Tailscale, auto-locks SSH, shows exact Split DNS steps with real IP
- All examples in README and scripts are now generic (`myapp`, `feature-x`) - no project-specific references

### Improved
- Split DNS reminder now shows exact Tailscale IP and copy-paste ready `.slotconfig` values
- Better UX: script waits for cloud-init completion before showing next steps

## [1.5.2] - 2025-12-27

### Fixed
- Removed `--ssh` flag from Tailscale setup - Tailscale SSH requires browser auth which breaks Mutagen
- Fixed resolv.conf being overwritten by systemd-resolved symlink
- Added hostname to /etc/hosts to fix "unable to resolve host" sudo warnings

### Changed
- Regular SSH over Tailscale now used instead of Tailscale SSH (still secure, works with Mutagen)

## [1.5.1] - 2025-12-27

### Fixed
- Tailscale auth key substitution in user-data script (was not being applied correctly)
- dnsmasq installation order - now stops systemd-resolved before installing to avoid port 53 conflict
- Uses external DNS temporarily during dnsmasq installation to ensure apt-get works

## [1.5.0] - 2025-12-27

### Added
- Wildcard DNS support via dnsmasq (`*.flowslot.dev` domain)
- User Data (cloud-init) based EC2 setup for full reproducibility
- URL pattern: `{service}.{slot}.{project}.flowslot.dev:{port}`
- Infrastructure as Code approach - all config files live in repo
- Automatic Tailscale authentication via reusable auth key

### Changed
- EC2 infra refactored to Infrastructure as Code approach
- All config files now live in repo (no manual SSH setup required)
- Tailscale auth key used for automatic authentication (no manual `tailscale up`)
- `create-instance.sh` now passes user-data script to EC2 for automatic bootstrap

### Infrastructure
- New: `infra/user-data.sh` - complete bootstrap script (Docker, Tailscale, dnsmasq, idle-check)
- New: `infra/configs/` - dnsmasq and idle-check configs
- Updated: `infra/create-instance.sh` - passes user-data to EC2, supports `TAILSCALE_AUTH_KEY` env var

## [1.4.2] - 2025-12-26

### Fixed
- Idle-check CPU threshold raised from 0.5% to 5% to avoid false positives from Postgres background tasks

## [1.4.1] - 2025-12-25

### Fixed
- Domain detection in `slot info` - now shows `flowslot.dev` domain URLs instead of IP
- Install command now uses `latest` tag for easier installation

### Changed
- Install command simplified to use `git checkout latest` instead of calculating latest tag

## [1.4.0] - 2025-12-25

### Added
- Auto-detection of slot name from current directory
- `slot info` and `slot compose` now work without explicit slot name when inside a slot directory

### Changed
- `slot info [name]` - slot name is now optional
- `slot compose [name] <args...>` - slot name is now optional when inside slot directory

## [1.3.0] - 2025-12-25

### Added
- `slot info <name>` command - shows slot details (URLs, ports, containers, sync status)
- `slot compose <name> <args...>` command - proxy docker compose commands to remote slot

### Changed
- README reorganized with command categories (Slot Management, Slot Operations, Server & System)
- Clarified which commands require slot names

## [1.2.0] - 2025-12-25

### Fixed
- Idle-check script permission error - state file moved from `/var/run/` to `/tmp/`

## [1.1.0] - 2025-12-25

### Fixed
- `slot update --remote` now correctly finds `.slotconfig` before changing directories

## [1.0.0] - 2025-12-25

### Added
- Initial stable release
- `slot init` - initialize flowslot for a project
- `slot open <name> [branch]` - create/open a slot
- `slot close <name>` - stop a slot's containers
- `slot list` - list all active slots
- `slot status` - show remote server resources
- `slot server start/stop/status` - EC2 instance control
- `slot update [--edge] [--remote]` - update flowslot CLI
- `slot version` - show version
- Mutagen-based file sync
- Dynamic port allocation (7100-7199, 7200-7299, etc.)
- Tailscale-only access (public SSH locked down after setup)
- Auto-stop after 2 hours of inactivity
- Tag-based versioning with `slot self upgrade` command

[Unreleased]: https://github.com/lchachurski/flowslot/compare/v2.0.2...HEAD
[2.0.2]: https://github.com/lchachurski/flowslot/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/lchachurski/flowslot/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/lchachurski/flowslot/compare/v1.7.6...v2.0.0
[1.7.6]: https://github.com/lchachurski/flowslot/compare/v1.7.5...v1.7.6
[1.7.5]: https://github.com/lchachurski/flowslot/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/lchachurski/flowslot/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/lchachurski/flowslot/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/lchachurski/flowslot/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/lchachurski/flowslot/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/lchachurski/flowslot/compare/v1.6.5...v1.7.0
[1.6.5]: https://github.com/lchachurski/flowslot/compare/v1.6.4...v1.6.5
[1.6.4]: https://github.com/lchachurski/flowslot/compare/v1.6.3...v1.6.4
[1.6.3]: https://github.com/lchachurski/flowslot/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/lchachurski/flowslot/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/lchachurski/flowslot/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/lchachurski/flowslot/compare/v1.5.2...v1.6.0
[1.5.2]: https://github.com/lchachurski/flowslot/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/lchachurski/flowslot/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/lchachurski/flowslot/compare/v1.4.2...v1.5.0
[1.4.2]: https://github.com/lchachurski/flowslot/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/lchachurski/flowslot/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/lchachurski/flowslot/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/lchachurski/flowslot/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/lchachurski/flowslot/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/lchachurski/flowslot/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/lchachurski/flowslot/releases/tag/v1.0.0
