# Flowslot

Run multiple isolated development environments on a remote server, each on a different Git branch.

## What is Flowslot?

Flowslot lets you run multiple parallel development environments (slots) on a remote EC2 instance. Each slot:
- Runs on its own Git branch
- Has isolated Docker containers with unique ports
- Syncs files bidirectionally via Mutagen
- Can be opened/closed independently

Perfect for testing multiple features simultaneously without resource conflicts.

## Prerequisites

- **Mutagen** - File synchronization
- **Tailscale** - Private network access
- **AWS CLI** - EC2 instance management (with SSO)
- **Docker** - On remote server (installed via infra setup)

Install locally:
```bash
brew install mutagen-io/mutagen/mutagen
brew install --cask tailscale
```

## Installation

Add flowslot scripts to your PATH:

```bash
echo 'export PATH="$PATH:$HOME/development/flowslot/scripts"' >> ~/.zshrc
source ~/.zshrc
```

## Quick Start

### 1. Setup Infrastructure (One-time)

See [infra/README.md](infra/README.md) for AWS EC2 setup.

### 2. Initialize Project

```bash
cd ~/development/your-project
slot init
```

This creates `.slotconfig` and a sibling `your-project-slots/` directory.

### 3. Start Server

```bash
slot server start
```

### 4. Open a Slot

```bash
slot open auth main
# Creates slot 'auth' on branch 'main', starts containers
```

### 5. List Slots

```bash
slot list
```

### 6. Close Slot

```bash
slot close auth
```

### 7. Stop Server

```bash
slot server stop
```

## Project Setup

Each project needs two files:

1. **`slot-ports.sh`** — Define your service ports relative to `SLOT_PORT_BASE`
2. **`docker-compose.slot.yml`** — Override ports using variables from `slot-ports.sh`

See templates:
- [templates/slot-ports.example.sh](templates/slot-ports.example.sh)
- [templates/docker-compose.slot.example.yml](templates/docker-compose.slot.example.yml)

## Commands

- `slot init` - Initialize flowslot for current project
- `slot open <name> [branch]` - Create/resume a slot
- `slot close <name>` - Stop a slot
- `slot list` - List all slots
- `slot status` - Show remote server resources
- `slot server start` - Start EC2 instance
- `slot server stop` - Stop EC2 instance
- `slot server status` - Show instance status

## How It Works

1. **Git Worktrees** - Each slot is a separate worktree on a different branch
2. **Mutagen Sync** - Real-time bidirectional file sync between local and remote
3. **Dynamic Ports** - Each slot gets unique port range (7100+, 7200+, etc.)
4. **Isolated Containers** - Docker Compose project names ensure isolation
5. **Tailscale** - Private network access without public ports

## Cost

- EC2 Spot instance: ~$0.10/hour when running
- Auto-stops after 1 hour idle (configurable)
- Pay only for active development time

## See Also

- [Infrastructure Setup](infra/README.md) - AWS EC2 configuration
- [Docker Compose Template](templates/docker-compose.slot.example.yml) - Port override example

