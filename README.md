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

Access each slot's services via wildcard DNS (recommended) or Tailscale IP:

**Wildcard DNS (recommended):**
| Slot | Web App | API | Database |
|------|---------|-----|----------|
| auth | `http://web.auth.thunder.flowslot:7101` | `http://api.auth.thunder.flowslot:7103` | `api.auth.thunder.flowslot:7104` |
| feature | `http://web.feature.thunder.flowslot:7201` | `http://api.feature.thunder.flowslot:7203` | `api.feature.thunder.flowslot:7204` |
| experiment | `http://web.experiment.thunder.flowslot:7301` | `http://api.experiment.thunder.flowslot:7303` | `api.experiment.thunder.flowslot:7304` |

**Tailscale IP (fallback):**
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
# Open Tailscale app and sign in

# AWS CLI (if not installed)
brew install awscli
```

### 2. Install Flowslot

```bash
git clone https://github.com/lchachurski/flowslot.git ~/.flowslot && \
  cd ~/.flowslot && \
  git fetch --tags && \
  git checkout latest && \
  echo 'export PATH="$PATH:$HOME/.flowslot/scripts"' >> ~/.zshrc && \
  source ~/.zshrc
```

This installs the latest stable release. The `latest` tag always points to the most recent release. To install a specific version, replace `latest` with the tag name (e.g., `v1.4`).

### Updating Flowslot

```bash
slot update            # Update to latest stable version
slot update --edge     # Update to main branch (bleeding edge)
slot update --remote   # Also update remote server scripts
```

Check your version:
```bash
slot version
# or
slot -v
```

**First-time upgraders:** If you installed flowslot before v1.0:

```bash
cd ~/.flowslot && git fetch --tags && git checkout $(git tag --sort=v:refname | tail -1)
```

### 3. Server Setup (One-time)

Create an AWS EC2 Spot instance to run your containers.

#### Authenticate with AWS

```bash
aws sso login
aws sts get-caller-identity  # Verify
```

#### Create Tailscale Auth Key (One-time)

Before creating the instance, get a reusable Tailscale auth key:

1. Go to https://login.tailscale.com/admin/settings/keys
2. Create auth key with:
   - **Reusable:** Yes
   - **Expiry:** 90 days (or never for dev)
   - **Tags:** `tag:flowslot` (optional)
3. Export it:
   ```bash
   export TAILSCALE_AUTH_KEY=tskey-auth-xxx
   ```

#### Create EC2 Instance

```bash
cd ~/.flowslot/infra
./create-instance.sh
```

This creates:
- Security group `flowslot-dev`
- t4g.2xlarge ARM Spot instance (8 vCPU, 32GB RAM, 100GB disk)
- **Automatically installs:** Docker, Tailscale, dnsmasq, idle-check script
- Outputs instance ID and public IP

**Note:** The script uses Ubuntu 22.04 ARM64 AMI for eu-central-1. For other regions, update `AMI_ID` in `create-instance.sh`:
```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text \
  --region YOUR_REGION
```

**What happens:** The instance runs a user-data script (cloud-init) that:
- Installs Docker and adds `ubuntu` user to docker group
- Installs Tailscale and authenticates with your auth key
- Configures dnsmasq for wildcard DNS (`*.flowslot`)
- Deploys the idle-check script and cron job
- Creates `/srv` directory for slots

Wait 2-3 minutes for cloud-init to complete. View logs:
```bash
ssh ubuntu@<public-ip> 'sudo cat /var/log/user-data.log'
```

#### Configure Tailscale Split DNS (One-time)

After the instance is running and Tailscale is connected:

1. Get the Tailscale IP from the instance or Tailscale admin console
2. Go to https://login.tailscale.com/admin/dns
3. In the **Nameservers** section, add:
   - **Custom nameserver:** `<tailscale-ip>` (e.g., `100.98.3.125`)
   - **Restrict to domain:** `flowslot`
4. Save

This enables wildcard DNS resolution for `*.flowslot` from all your Tailscale devices.

#### Lock Down Security Group

After Tailscale is working, remove public SSH access:

```bash
aws ec2 revoke-security-group-ingress \
  --group-name flowslot-dev \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --region eu-central-1
```

**Note:** If you didn't provide `TAILSCALE_AUTH_KEY`, you'll need to manually authenticate Tailscale:
```bash
ssh ubuntu@<public-ip> "sudo tailscale up"
```
Follow the URL to authenticate, then configure Split DNS and lock down the security group.

### 4. Initialize Your Project

```bash
cd ~/development/your-project
slot init
# Enter your AWS Instance ID and Tailscale IP when prompted
```

### 5. Create Your First Slot

```bash
slot server start
slot open my-feature main
# Opens Cursor-ready directory at ~/development/your-project-slots/my-feature/
```

---

## Commands

**Note:** Commands with `<name>` require a slot name (e.g., `spider-seo`, `auth`, `feature`). Slot names must be lowercase alphanumeric with hyphens only.

### Slot Management

| Command | What it does |
|---------|--------------|
| `slot init` | Initialize flowslot for current project |
| `slot open <name> [branch]` | Create/open a slot on a branch |
| `slot close <name>` | Stop a slot's containers |
| `slot list` | Show all active slots |

### Slot Operations

| Command | What it does |
|---------|--------------|
| `slot info [name]` | Show slot details (URLs, ports, containers, sync status). Auto-detects slot name if inside slot directory. |
| `slot compose [name] <args...>` | Proxy docker compose commands to remote slot. Auto-detects slot name if inside slot directory. |

### Server & System

| Command | What it does |
|---------|--------------|
| `slot status` | Show remote server resources (all slots) |
| `slot server start` | Start the EC2 instance |
| `slot server stop` | Stop the EC2 instance |
| `slot update [--edge] [--remote]` | Update flowslot CLI (stable by default, --edge for main branch) |
| `slot version` | Show flowslot version |

---

## Working with Slots

### Auto-detection

When working inside a slot directory, slot names are **auto-detected** from the current path:

```bash
cd ~/myapp-slots/spider-seo
slot info              # Auto-detects "spider-seo"
slot compose ps        # Auto-detects "spider-seo"
slot compose logs web  # Auto-detects "spider-seo"
```

You can still specify the slot name explicitly to control a different slot:

```bash
cd ~/myapp-slots/spider-seo
slot info auth-fix     # Explicitly uses "auth-fix" instead
```

**Note:** If you're not inside a slot directory, you must provide the slot name explicitly. Use `slot list` to see available slots.

### View Slot Information

Get detailed information about a slot, including service URLs and container status:

```bash
slot info spider-seo   # Explicit slot name
slot info              # Auto-detected (if inside slot directory)
```

Output shows:
- Local and remote paths
- Git branch
- Service URLs (web, API, etc.)
- Container status
- Mutagen sync status

### Remote Container Control

Use `slot compose` to run any docker compose command on the remote slot without manually SSHing:

```bash
# From inside slot directory (auto-detected)
cd ~/myapp-slots/spider-seo
slot compose ps
slot compose build --no-cache
slot compose logs -f web
slot compose exec thunder bash

# From anywhere (explicit slot name)
slot compose spider-seo ps
slot compose spider-seo build --no-cache
slot compose spider-seo logs -f web
slot compose spider-seo exec thunder bash
```

**Why this is useful:** When developing in a slot directory (e.g., `~/myapp-slots/spider-seo/`), you often need to rebuild containers, check logs, or run migrations. Instead of manually SSHing and navigating to the remote directory, `slot compose` handles it all — just like running `docker compose` locally, but on the remote slot.

---

## Wildcard DNS

Flowslot provides wildcard DNS resolution via dnsmasq on the EC2 instance, accessible through Tailscale Split DNS. This enables human-readable URLs instead of raw IP addresses.

### URL Pattern

```
{service}.{slot}.{project}.flowslot:{port}
```

**Components:**
- `{service}` - Service name (e.g., `web`, `api`, `draft--sitename`)
- `{slot}` - Slot name (e.g., `spider-seo`, `auth`, `feature`)
- `{project}` - Project name (e.g., `thunder`, `myapp`)
- `flowslot` - Reserved domain (configured via Tailscale Split DNS)
- `{port}` - Port number (e.g., `7201`, `7203`)

### Examples

```
http://web.spider-seo.thunder.flowslot:7201
http://api.spider-seo.thunder.flowslot:7203
http://draft--rugerexpo.spider-seo.thunder.flowslot:7212
```

### How It Works

1. **dnsmasq on EC2** resolves all `*.flowslot` queries to the EC2's Tailscale IP
2. **Tailscale Split DNS** forwards `*.flowslot` queries from your devices to the EC2 instance
3. **Your browser** resolves `web.spider-seo.thunder.flowslot` → EC2 Tailscale IP → connects to port 7201

### Benefits

- **AI/LLM Testing:** AI assistants can use proper URLs instead of IPs
- **OAuth Redirects:** Services like Google OAuth can whitelist domains instead of IPs
- **Readability:** Easier to remember and share URLs
- **Multi-project:** Each project gets its own subdomain namespace

### Configuration

Wildcard DNS is automatically configured when you create a new EC2 instance via `create-instance.sh`. See [Server Setup](#3-server-setup-one-time) for Tailscale Split DNS configuration.

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

On the remote server, each slot is a directory at `/srv/myapp/<slot-name>/` containing synced files and running Docker containers. No git on remote — files sync via Mutagen.

### The Stack

| Layer | What | Why |
|-------|------|-----|
| **Git Worktrees** | Each slot is a local checkout on its own branch | Edit different branches simultaneously |
| **Mutagen Sync** | Real-time bidirectional file sync (~100ms latency) | Save locally, see changes on remote instantly |
| **Dynamic Ports** | Slot 1: 7100-7199, Slot 2: 7200-7299, etc. | Run multiple stacks without port conflicts |
| **Tailscale** | Private mesh network (100.x.y.z addresses) | Access remote services securely, no public ports |
| **dnsmasq** | Wildcard DNS resolver (`*.flowslot`) | Human-readable URLs for services |
| **Docker Compose** | Your existing setup with port overrides | Same containers, just isolated per slot |

---

## Adapting Your Project

Flowslot needs your docker-compose to support **dynamic ports** so multiple slots can run simultaneously without conflicts. This requires two changes:

### Step 1: Parameterize Ports in docker-compose

Change hardcoded ports to environment variables **with defaults** (so local dev still works):

```yaml
# BEFORE (hardcoded)
services:
  web:
    ports:
      - "3000:3000"
  api:
    ports:
      - "8080:8080"
  postgres:
    container_name: myapp-postgres
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
```

```yaml
# AFTER (parameterized with defaults)
services:
  web:
    ports:
      - "${SLOT_PORT_WEB:-3000}:3000"
  api:
    ports:
      - "${SLOT_PORT_API:-8080}:8080"
  postgres:
    container_name: ${POSTGRES_CONTAINER_NAME:-myapp-postgres}
    ports:
      - "${SLOT_PORT_DB:-5432}:5432"
    volumes:
      - ${POSTGRES_VOLUME:-postgres-data}:/var/lib/postgresql/data
```

**Key points:**
- `${VAR:-default}` means: use `$VAR` if set, otherwise use `default`
- Local dev works unchanged (uses defaults)
- Flowslot sets these variables to unique values per slot
- **Container names must be unique** — use `${POSTGRES_CONTAINER_NAME:-...}` pattern
- **Volumes must be unique** — use `${POSTGRES_VOLUME:-...}` for stateful services

### Step 2: Create flowslot-ports.sh

This file defines your port variables relative to `SLOT_PORT_BASE` (provided by flowslot):

```bash
#!/bin/bash
# flowslot-ports.sh

# SLOT_PORT_BASE is set by flowslot: 7200, 7300, 7400, etc.
# SLOT is the slot number: 1, 2, 3, etc.

export SLOT_PORT_WEB=$((SLOT_PORT_BASE + 1))      # 7201, 7301, ...
export SLOT_PORT_API=$((SLOT_PORT_BASE + 3))      # 7203, 7303, ...
export SLOT_PORT_DB=$((SLOT_PORT_BASE + 4))       # 7204, 7304, ...

# Unique container names and volumes per slot
export POSTGRES_CONTAINER_NAME="myapp-postgres-${SLOT}"
export POSTGRES_VOLUME="postgres-data-${SLOT}"
```

### Step 3: Create docker-compose.flowslot.yml (Optional)

For environment-specific overrides that only apply in slots:

```yaml
version: '3.9'

services:
  web:
    environment:
      # Point to slot's API, not localhost
      - NEXT_PUBLIC_API_URL=http://${SLOT_REMOTE_IP}:${SLOT_PORT_API}

# Pre-define volumes for each slot number
volumes:
  postgres-data-1:
  postgres-data-2:
  postgres-data-3:
  postgres-data-4:
```

### Variables Available in Slots

Flowslot exports these before running docker compose:

| Variable | Example | Description |
|----------|---------|-------------|
| `SLOT` | `1` | Slot number (1, 2, 3, ...) |
| `SLOT_PORT_BASE` | `7200` | Base port for this slot |
| `SLOT_REMOTE_IP` | `100.112.147.63` | Tailscale IP of remote server |
| `COMPOSE_PROJECT_NAME` | `myapp-auth` | Unique project name per slot |

Your `flowslot-ports.sh` can define any additional variables you need.

### Common Gotchas

| Issue | Solution |
|-------|----------|
| Port already allocated | Check for hardcoded ports in your compose files |
| Container name conflict | Parameterize all `container_name:` values |
| Volume data collision | Parameterize volume names for stateful services |
| Service can't find API | Use `SLOT_REMOTE_IP` instead of `localhost` in env vars |

See [templates/](templates/) for complete examples.

---

## Cost

- **EC2 Spot Instance:** ~$0.08/hour (t4g.2xlarge ARM in eu-central-1)
- **Auto-stop:** Server stops after 2 hours of inactivity (enabled by default)
- **Typical daily cost:** $0.64-0.96 for an 8-hour workday

---

## Auto-Stop (Idle Detection)

By default, flowslot installs an idle-check script that **automatically shuts down** the EC2 instance after **2 hours of inactivity**. This saves money when you forget to stop the server.

### What counts as activity:
- File changes (Mutagen syncs)
- Container CPU usage (active requests)
- SSH/Tailscale connections

### Disable auto-stop

If you prefer manual control:

```bash
ssh ubuntu@<tailscale-ip> "crontab -l | grep -v flowslot-idle-check | crontab -"
```

### Re-enable auto-stop

```bash
ssh ubuntu@<tailscale-ip> "(crontab -l; echo '*/5 * * * * /usr/local/bin/flowslot-idle-check') | crontab -"
```

### Change idle timeout

Edit the script on the remote (default is 7200 seconds = 2 hours):

```bash
ssh ubuntu@<tailscale-ip> "sudo sed -i 's/IDLE_LIMIT=7200/IDLE_LIMIT=3600/' /usr/local/bin/flowslot-idle-check"
```

---

## Why "Flowslot"?

A **slot** is a development flow — a branch, an idea, an experiment. You open slots when you need them, close them when you're done. Multiple slots, multiple flows, zero conflicts.

Perfect for the way AI-assisted development actually works: exploring multiple directions, iterating fast, keeping context clean.

---

*Built for developers who vibe code with Cursor, Claude Code, and other AI assistants.*
