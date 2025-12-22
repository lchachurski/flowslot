# Flowslot

**The practical infrastructure for vibe coding with Cursor and Claude Code.**

Run multiple parallel AI-assisted development streams — each with isolated context and its own Git branch.

---

## Why Flowslot?

Vibe coding with AI agents hits real limits fast:

| Problem | What happens |
|---------|--------------|
| **Can't run multiple environments locally** | Your machine can't handle 2-4 full Docker stacks at once |
| **File collisions between sessions** | Two Cursor agents editing the same files = chaos |
| **Testing is a nightmare** | Constantly stopping/starting containers, switching branches |
| **Hardware gets expensive** | Buying a beefier machine just for parallel dev work |
| **Tied to one machine** | Can't continue work from another device or location |

Flowslot solves this with **slots** — isolated environments on a remote server, synced in real-time with your local code.

```
Local (Cursor + code)                    Remote Server (containers + builds)
┌──────────────────────────────────┐     ┌──────────────────────────────────────────┐
│                                  │     │                                          │
│  Cursor Window 1                 │     │  Slot: auth (branch: fix/auth-bug)       │
│  └── ~/myapp-slots/auth/         │ ──► │  └── Docker containers on ports 7100+    │
│                                  │sync │      web:7101  api:7103  db:7104         │
│  Cursor Window 2                 │     │                                          │
│  └── ~/myapp-slots/feature/      │ ──► │  Slot: feature (branch: feat/new-ui)     │
│                                  │sync │  └── Docker containers on ports 7200+    │
│  Cursor Window 3                 │     │      web:7201  api:7203  db:7204         │
│  └── ~/myapp-slots/experiment/   │ ──► │                                          │
│                                  │sync │  Slot: experiment (branch: main)         │
│                                  │     │  └── Docker containers on ports 7300+    │
│                                  │     │      web:7301  api:7303  db:7304         │
└──────────────────────────────────┘     └──────────────────────────────────────────┘
```

**Each Cursor window has its own isolated AI context.** The AI only sees the code for that slot's branch — no confusion, no cross-contamination.

---

## The Vibe Coding Workflow

### Morning Setup

```bash
# Start your remote server
slot server start

# Open slots for what you're working on today
slot open auth fix/auth-bug
slot open feature feat/new-ui
slot open experiment main
```

### Your Desktop Layout

Open each slot in a separate Cursor window, with its browser beside it:

```
┌─────────────────────────────────┬─────────────────────────────────┐
│                                 │                                 │
│  Cursor: ~/myapp-slots/auth/    │  Browser: http://100.x.y.z:7101 │
│  (branch: fix/auth-bug)         │  (auth slot's web app)          │
│                                 │                                 │
├─────────────────────────────────┼─────────────────────────────────┤
│                                 │                                 │
│  Cursor: ~/myapp-slots/feature/ │  Browser: http://100.x.y.z:7201 │
│  (branch: feat/new-ui)          │  (feature slot's web app)       │
│                                 │                                 │
└─────────────────────────────────┴─────────────────────────────────┘
```

**Each Cursor window sees only its slot's code.** The AI's context is clean — it won't confuse your auth fix with your UI experiment.

### Testing in Parallel

Every slot runs its own complete stack. Compare implementations side-by-side:

```bash
# Check what's running
slot list

# Output:
# NAME        BRANCH         PORTS       STATUS
# ----------------------------------------------------------------
# auth        fix/auth-bug   7100-7199   running
# feature     feat/new-ui    7200-7299   running
# experiment  main           7300-7399   running
```

Access each slot's services via Tailscale IP:

| Slot | Web App | API | Database |
|------|---------|-----|----------|
| auth | `http://100.x.y.z:7101` | `http://100.x.y.z:7103` | `100.x.y.z:7104` |
| feature | `http://100.x.y.z:7201` | `http://100.x.y.z:7203` | `100.x.y.z:7204` |
| experiment | `http://100.x.y.z:7301` | `http://100.x.y.z:7303` | `100.x.y.z:7304` |

**Real example:** You're testing a new login flow. Open the auth slot's app in one browser, the main branch in another. Click through both. See the difference instantly.

### End of Day

```bash
slot close auth
slot close feature
slot close experiment
slot server stop
```

**Done.** Each slot is isolated — changes in one don't affect the others.

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

### Directory Structure

When you run `slot init` in your project, flowslot creates a sibling directory for slots:

```
~/development/
├── myapp/                      # Your original project
│   ├── .slotconfig             # Flowslot configuration
│   ├── docker-compose.yml      # Your Docker setup
│   ├── docker-compose.flowslot.yml # Port overrides for slots
│   └── flowslot-ports.sh           # Port variable definitions
│
└── myapp-slots/                # Slot worktrees (created by flowslot)
    ├── repo.git/               # Bare clone of your repo
    ├── .env-templates/         # Copied .env files
    │
    ├── auth/                   # Slot: auth (branch: fix/auth-bug)
    │   └── (full checkout)     #   → Open this in Cursor Window 1
    │
    ├── feature/                # Slot: feature (branch: feat/new-ui)
    │   └── (full checkout)     #   → Open this in Cursor Window 2
    │
    └── experiment/             # Slot: experiment (branch: main)
        └── (full checkout)     #   → Open this in Cursor Window 3
```

On the remote server, the same structure exists at `/srv/myapp/`, with each slot running its own Docker containers.

### The Stack

| Layer | What | Why |
|-------|------|-----|
| **Git Worktrees** | Each slot is a separate checkout on its own branch | Edit different branches simultaneously |
| **Mutagen Sync** | Real-time bidirectional file sync (~100ms latency) | Save locally, see changes on remote instantly |
| **Dynamic Ports** | Slot 1: 7100-7199, Slot 2: 7200-7299, etc. | Run multiple stacks without port conflicts |
| **Tailscale** | Private mesh network (100.x.y.z addresses) | Access remote services securely, no public ports |
| **Docker Compose** | Your existing setup with port overrides | Same containers, just isolated per slot |

---

## Project Setup

Add two files to your project:

**`flowslot-ports.sh`** — Define your service ports:
```bash
export SLOT_PORT_WEB=$((SLOT_PORT_BASE + 1))
export SLOT_PORT_API=$((SLOT_PORT_BASE + 3))
export SLOT_PORT_DB=$((SLOT_PORT_BASE + 4))
```

**`docker-compose.flowslot.yml`** — Override ports for slots:
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
