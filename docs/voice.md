# Voice control for Claude Code on a slot

Run Claude Code on a remote slot and talk to it on the phone — both directions.

You call your slot's number and ask "how's it going?", "what did Claude just say?",
"tell it to commit and push". Claude can also call you when it's done, blocked,
or has a question. Voice is handled by an [ElevenLabs Conversational AI](https://elevenlabs.io/conversational-ai)
agent that talks to a small Python bridge running on your slot's EC2.

This doc is the long-form reference. The README has a one-paragraph intro under
[Voice control with Claude Code](../README.md#voice-control-with-claude-code).

## Why

Claude Code on a slot can run unattended for many minutes — long compiles,
test suites, refactors. You don't want to babysit a terminal. With voice you
can:

- Step away from the laptop and still know what Claude is doing.
- Be interrupted *only* when something matters — Claude calls you when it's
  done, stuck, or has a question.
- Read back exactly what Claude said, verbatim, on demand.
- Queue follow-ups by voice ("when it's done, ask it to open a PR").
- Interrupt a runaway tool call with a single sentence.

## How it works

```
┌────────── Your phone ──────────┐
│                                 │
│ ElevenLabs CAI agent            │
│  ├ STT + TTS + barge-in         │
│  ├ LLM (Claude / GPT, your pick)│
│  └ 5 webhook tools ─────────────┼──► Tailscale Funnel (HTTPS)
│                                 │         │
└─────────────────────────────────┘         ▼
                                  ┌─── Slot EC2 ────────────────┐
                                  │  flowslot-bridge.service    │
                                  │  ├ HMAC-verifies requests   │
                                  │  ├ reads bridge.db (SQLite) │
                                  │  ├ tmux capture / send-keys │
                                  │  └ exposes /bridge/* HTTP   │
                                  │                             │
                                  │  ~/.claude/settings.json    │
                                  │   hooks → bridge.db         │
                                  │  (PreToolUse, PostToolUse,  │
                                  │   Stop, Notification,       │
                                  │   UserPromptSubmit)         │
                                  │                             │
                                  │  tmux: claude-<slot>        │
                                  │   └ claude REPL             │
                                  │      └ MCP: voice-outbound  │
                                  │         (call_user tool)    │
                                  └─────────────────────────────┘
```

Three pieces work together:

1. **ElevenLabs Conversational AI** handles the voice layer — speech-to-text,
   text-to-speech, barge-in, turn-taking, the LLM that interprets your words.
   Same role Twilio's Voice + an LLM stack would play, but it's a single
   product that already does it well. Pick a voice in the dashboard; the
   default in the docs walks you through it.
2. **A Python bridge** (~600 lines, stdlib only) runs as a systemd unit on the
   slot's EC2. It binds to `127.0.0.1:9090` and is exposed publicly via
   Tailscale Funnel — TLS terminates at Funnel, every request must carry a
   valid `X-Flowslot-Signature` HMAC-SHA256, no other auth touches the
   internet.
3. **Claude Code hooks** (`PreToolUse`, `PostToolUse`, `Stop`, `Notification`,
   `UserPromptSubmit`) write structured events into a SQLite DB on the slot
   so the bridge can answer "what's Claude doing right now?" in ~50 ms,
   without scraping the terminal.

## What the agent can do

The CAI agent has five HTTP tools, all webhooks back to the bridge:

| Tool | What it does |
|------|--------------|
| `get_claude_state` | Returns a snapshot: status (`idle` / `executing_tool` / `thinking` / `awaiting_input`), current tool name + brief args, elapsed seconds, and a short preview of recent output. |
| `get_claude_last_output(lines)` | Raw `tmux capture-pane` of Claude's terminal. Used when you ask for the verbatim text. |
| `inject_message(text, urgent)` | Pastes a message into Claude's REPL via tmux paste-buffer. `urgent=true` sends Escape first to interrupt the current tool call. |
| `watch_for_stop(timeout_sec)` | Long-polls until Claude's next turn ends. The agent calls this after every inject so it can proactively report when Claude finishes. |
| `get_system_status` | Host + slot + bridge metrics: uptime, load, RAM, disk, container statuses, event counts. |

What you actually say on the call:

| You say | Agent does |
|---------|------------|
| "How's it going?" | `get_claude_state` (+ `get_claude_last_output` if useful) → 1–2 sentence summary. |
| "What did Claude just say?" | `get_claude_last_output(50)` → summary, in the agent's own words. |
| "Read that back, verbatim." | `get_claude_last_output(50)` → speaks the text word for word. |
| "Tell Claude to commit with message 'wip'." | `inject_message(...)` → `watch_for_stop(90)` → "Claude's done, want me to read the answer?" |
| "Stop, that's wrong." | `inject_message(..., urgent=true)` → "Interrupted. Go ahead." |
| "Stay on the line until it's done." | `watch_for_stop(120)` → reports when Stop event fires. |
| "How's the box doing?" | `get_system_status` → "Load 0.4, 38% RAM, 22% disk, three containers up." |
| "Note for FlowSlot developer: …" | Acknowledged silently, no inject, no follow-up question. |

The agent's behavior — when to summarize vs. read verbatim, how to handle
"that option" without guessing, how to ignore Claude Code's own rating /
feedback prompts — is governed by a system prompt that lives at
[`templates/agent-system-prompt.md`](../templates/agent-system-prompt.md). The
tool schemas live at [`templates/agent-tools.json`](../templates/agent-tools.json).
`slot claude voice agent-config` prints both, with your Funnel URL and HMAC
secret already substituted in, ready to paste into the ElevenLabs dashboard.

## What Claude can do

Claude on the slot gets one new MCP stdio server: `voice-outbound`. It
exposes a single tool:

```
call_user(message: str, reason: "done" | "question" | "blocker")
```

When Claude invokes it, the MCP server POSTs ElevenLabs'
`/v1/convai/twilio/outbound-call` API. Your phone rings; the same CAI agent
greets you with `message` (the agent's `first_message` is overridden per call,
so you immediately hear *Claude's* context, not a generic hello). From that
point the conversation is bidirectional — same five tools, same rules.

You can prompt Claude with things like *"call me when the test suite finishes
and tell me whether anything failed"*, then walk away.

## Setup

### Prerequisites

1. **ElevenLabs account.** Sign up at [elevenlabs.io](https://elevenlabs.io).
   In the dashboard:
   - Generate an **API key** (Profile → API keys).
   - Create a **Conversational AI agent** (any voice, any LLM — `gpt-4o-mini`
     and `claude-haiku` both work fine; the agent's logic comes from the
     system prompt, not the LLM choice). Note its **agent ID**.
   - Register a **phone number** with the agent — either an ElevenLabs-issued
     number or a Twilio number imported into ElevenLabs. Note its
     **phone number ID**.
2. **Tailscale Funnel** enabled for the slot's EC2 node. Funnel terminates
   TLS at Tailscale's edge and forwards to the bridge — no port-forwarding,
   no public AWS security-group rule, no Let's Encrypt to manage. If Funnel
   isn't enabled in your tailnet ACL, `slot claude voice enable` prints the
   one-click URL.
3. A working flowslot setup with at least one slot — `slot create my-slot`
   completes before you go for voice.

### Per-project config

Add to `.slotconfig` (or to `~/.flowslot/config.local`):

```bash
export FLOWSLOT_ELEVENLABS_API_KEY="sk_..."
export FLOWSLOT_ELEVENLABS_AGENT_ID="agent_..."
export FLOWSLOT_ELEVENLABS_PHONE_NUMBER_ID="phnum_..."
export FLOWSLOT_TWILIO_TO="+15551234567"          # your personal phone, E.164
# FLOWSLOT_BRIDGE_HMAC_SECRET is auto-generated on first 'voice enable'
```

`slot self init` also prompts for these on a fresh project.

### Enable

```bash
slot claude voice enable           # picks up the slot you're inside
# or:
slot claude voice enable --slot my-slot
```

This:

1. Cleans up any v2.10 (`call-me`) artifacts from the slot.
2. Installs the bridge under `~/.flowslot/bridge/` and starts the systemd unit.
3. Installs Claude Code hooks (PreTool, PostTool, Stop, Notification,
   UserPromptSubmit) that write events into `~/.flowslot/bridge.db`.
4. Installs the `voice-outbound` MCP server and registers it with
   `claude mcp add --scope user`.
5. Generates `FLOWSLOT_BRIDGE_HMAC_SECRET` if missing.
6. Configures Tailscale Funnel for port 9090 and prints the public URL.
7. Writes a `voice-ready` marker so `slot destroy` can clean up later.

```bash
slot claude voice agent-push       # PATCHes system prompt + tool defs into
                                   # your ElevenLabs agent via API. Done.
# OR:
slot claude voice agent-config     # prints them with Funnel URL + HMAC filled in,
                                   # for manual paste into the ElevenLabs dashboard.
```

```bash
slot claude voice status           # green across?
slot claude voice test             # places a test outbound call
```

Call your ElevenLabs number, say *"what slots do I have?"*, and the agent should
read them off.

### Watching what's happening

```bash
slot claude voice watch
```

Opens a local 3-pane tmux dashboard streaming: live Claude session
(read-only), bridge HTTP log, and hook events. Useful while on a call to see
exactly which tools the agent fires and what they return.

```bash
slot claude voice logs -f          # journalctl -fu flowslot-bridge
```

### Disable / teardown

```bash
slot claude voice disable          # stops bridge, removes hooks, unregisters MCP, Funnel off
```

`slot destroy <slot>` invokes `voice disable` automatically if the
`voice-ready` marker is present, so a normal slot teardown leaves nothing
orphaned.

## Security model

- **Tailscale Funnel** terminates TLS at Tailscale's edge and forwards to
  the bridge on `127.0.0.1:9090`. The bridge never listens on a public
  interface.
- **HMAC-SHA256 over `path + body`**, with a per-slot 32-byte secret
  generated on `voice enable`. Wrong / missing `X-Flowslot-Signature` → 401.
  Funnel URLs are public, so the HMAC is what proves the call came from
  *your* configured ElevenLabs agent.
- **Static bearer token** as a second layer for endpoints that the Funnel
  may proxy from less-trusted contexts.
- All other slot traffic (SSH, mutagen, docker, `slot claude attach`) stays
  on the Tailscale mesh and never touches Funnel.
- The bridge SQLite DB lives at `~/.flowslot/bridge.db` on the slot — local
  only, not exposed.

## Cost

| Item | Cost |
|------|------|
| ElevenLabs Conversational AI | ~$0.10 / minute of conversation, depends on plan |
| Tailscale Funnel | Free on Personal and Starter plans |
| Outbound calls (Claude → you) | A few cents per call (ElevenLabs phone-number rates) |
| The bridge itself | $0 (Python stdlib, runs alongside the slot's EC2) |

A typical day with a few "how's it going" check-ins and one or two Claude
call-backs runs on the order of $1–2.

## Why ElevenLabs (and not X)

The bridge would in principle work with any CAI platform that supports
HTTP-webhook tools — Vapi, Retell, LiveKit, raw Twilio + an LLM. We picked
ElevenLabs because:

- Barge-in and turn-taking work out of the box; we don't tune them.
- Voice quality is a noticeable step up from Polly / Twilio TTS.
- One product handles inbound *and* outbound — Claude calling you uses the
  exact same agent that you call.
- Per-call `first_message` override means Claude's outbound greeting can
  carry context ("hey, the test suite failed on `test_billing.py`").

We only test and document ElevenLabs. If you want to bring your own
provider, the bridge HTTP shape is in
[`infra/bridge/server.py`](../infra/bridge/server.py) and the tool schemas
in [`templates/agent-tools.json`](../templates/agent-tools.json).

## Limitations

- **One bridge per EC2 host, many slots through it.** The bridge serves
  every slot on the host; the agent picks `slot=` per request. Multiple
  hosts each need their own bridge + their own ElevenLabs agent.
- **No historical replay UI.** The bridge DB has every hook event, but we
  don't ship a dashboard.
- **Funnel quota.** Tailscale Funnel has a per-tailnet bandwidth quota;
  voice traffic is well under it, but heavy `get_claude_last_output` use
  on long sessions could matter on free plans.

## Files

| Path | Purpose |
|------|---------|
| [`infra/bridge/server.py`](../infra/bridge/server.py) | Bridge HTTP server (stdlib). |
| [`infra/bridge/schema.sql`](../infra/bridge/schema.sql) | Events table + state KV. |
| [`infra/bridge/hooks/`](../infra/bridge/hooks/) | Claude Code hook scripts. |
| [`infra/voice-outbound-mcp/server.py`](../infra/voice-outbound-mcp/server.py) | `call_user` MCP server. |
| [`infra/flowslot-bridge.service.tmpl`](../infra/flowslot-bridge.service.tmpl) | systemd unit template. |
| [`templates/agent-system-prompt.md`](../templates/agent-system-prompt.md) | Source of truth for the CAI agent system prompt. |
| [`templates/agent-tools.json`](../templates/agent-tools.json) | Source of truth for the CAI agent tool schemas. |
| [`scripts/slot-claude-voice`](../scripts/slot-claude-voice) | The `slot claude voice` subcommands. |
| [`scripts/lib/claude-voice.sh`](../scripts/lib/claude-voice.sh) | Install / teardown helpers. |

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|---------------------|
| Test call rings but agent says "I couldn't reach Claude's session" | HMAC mismatch — re-run `slot claude voice agent-config` and re-paste the tool config. |
| Agent answers but reports `idle, no preview` even though Claude is working | The Claude tmux session isn't named `claude-<slot>` — make sure you started Claude via `slot claude`. |
| `voice enable` fails with "Funnel not enabled" | Click the URL it prints to enable Funnel in your tailnet ACL. |
| Agent reads a "rate this conversation" prompt out loud | Re-paste the latest system prompt (`slot claude voice agent-config`). The current prompt filters those. |
| Claude calls you but the call drops immediately | Check `FLOWSLOT_TWILIO_TO` is in E.164 (`+15551234567`) and the phone number is registered with the ElevenLabs agent. |
| Bridge running but `inject_message` doesn't submit | Run `slot claude voice logs -f` and look for tmux paste-buffer errors; the bridge needs the `claude-<slot>` tmux session to exist. |

For deeper debugging, `journalctl -fu flowslot-bridge` on the slot shows
every request the agent makes, with HMAC verification result and tool
response.
