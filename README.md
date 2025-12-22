# Flowslot

**The practical infrastructure for vibe coding with Cursor and Claude Code.**

Run multiple parallel AI-assisted development streams on a remote server — each with isolated context, its own Git branch, and zero resource conflicts on your local machine.

---

## Why Flowslot?

When you're vibe coding with AI, you often want to:

- **Explore multiple directions at once** — try different approaches on different branches
- **Keep AI context clean** — each Cursor window should only see its own branch
- **Not burn your laptop** — Docker containers and builds eat RAM and CPU
- **Switch between features instantly** — without waiting for containers to rebuild

Flowslot solves this by giving you **slots** — isolated development environments that run on a remote server, synced in real-time with your local code.

```
Your Mac (fast, cool, quiet)          Remote Server (does the heavy lifting)
┌─────────────────────────────┐       ┌────────────────────────────────────────┐
│                             │       │                                        │
│  Cursor Window 1            │       │  Slot: auth (branch: fix/auth-bug)     │
│  └── ~/slots/auth/          │ ───── │  └── Docker containers on ports 7101+  │
│                             │  sync │                                        │
│  Cursor Window 2            │       │  Slot: feature (branch: feat/new-ui)   │
│  └── ~/slots/feature/       │ ───── │  └── Docker containers on ports 7201+  │
│                             │  sync │                                        │
│  Cursor Window 3            │       │  Slot: experiment (branch: main)       │
│  └── ~/slots/experiment/    │ ───── │  └── Docker containers on ports 7301+  │
│                             │       │                                        │
└─────────────────────────────┘       └────────────────────────────────────────┘
```

**Each Cursor window has its own isolated AI context.** The AI only sees the code for that slot's branch — no confusion, no cross-contamination.

---

## The Vibe Coding Workflow

```bash
# Morning: Start your remote server
slot server start

# Open a slot for the auth bug you're fixing
slot open auth fix/auth-bug

# Open another slot to experiment with a new feature
slot open feature feat/new-ui

# Open each slot's directory in separate Cursor windows
# Each window = clean AI context = better suggestions

# End of day: Close slots and stop server
slot close auth
slot close feature
slot server stop
```

**Your laptop stays cool.** All the Docker containers, database instances, and builds run on the remote server. Your local machine just runs Cursor and syncs files.

---

## Quick Start

### 1. Install Prerequisites

```bash
# Mutagen for file sync
brew install mutagen-io/mutagen/mutagen

# Tailscale for private networking
brew install --cask tailscale
```

### 2. Setup Remote Server (One-time)

See [infra/README.md](infra/README.md) for AWS EC2 Spot instance setup.

### 3. Initialize Your Project

```bash
cd ~/development/your-project
slot init
```

### 4. Create Your First Slot

```bash
slot server start
slot open my-feature main
# Opens Cursor-ready directory at ~/development/your-project-slots/my-feature/
```

---

## Commands

| Command | What it does |
|---------|--------------|
| `slot init` | Initialize flowslot for current project |
| `slot open <name> [branch]` | Create/open a slot on a branch |
| `slot close <name>` | Stop a slot's containers |
| `slot list` | Show all active slots |
| `slot status` | Show remote server resources |
| `slot server start` | Start the EC2 instance |
| `slot server stop` | Stop the EC2 instance |

---

## How It Works

1. **Git Worktrees** — Each slot is a separate checkout of your repo on a specific branch
2. **Mutagen Sync** — Real-time bidirectional file sync (sub-second latency)
3. **Dynamic Ports** — Slot 1 gets ports 7100-7199, Slot 2 gets 7200-7299, etc.
4. **Tailscale** — Private network access to your server without exposing public ports
5. **Docker Compose** — Your existing setup, just with port overrides per slot

---

## Project Setup

Add two files to your project:

**`slot-ports.sh`** — Define your service ports:
```bash
export SLOT_PORT_WEB=$((SLOT_PORT_BASE + 1))
export SLOT_PORT_API=$((SLOT_PORT_BASE + 3))
export SLOT_PORT_DB=$((SLOT_PORT_BASE + 4))
```

**`docker-compose.slot.yml`** — Override ports for slots:
```yaml
services:
  web:
    ports:
      - "${SLOT_PORT_WEB}:3000"
  api:
    ports:
      - "${SLOT_PORT_API}:8080"
```

See [templates/](templates/) for complete examples.

---

## Cost

- **EC2 Spot Instance:** ~$0.10/hour (t3.2xlarge in eu-central-1)
- **Auto-stop:** Server stops after 1 hour of inactivity
- **Typical daily cost:** $0.80-1.20 for an 8-hour workday

Your laptop's fans will thank you.

---

## Why "Flowslot"?

A **slot** is a development flow — a branch, an idea, an experiment. You open slots when you need them, close them when you're done. Multiple slots, multiple flows, zero conflicts.

Perfect for the way AI-assisted development actually works: exploring multiple directions, iterating fast, keeping context clean.

---

## See Also

- [Infrastructure Setup](infra/README.md) — AWS EC2 configuration
- [Templates](templates/) — Example configuration files

---

*Built for developers who vibe code with Cursor, Claude Code, and other AI assistants.*
