# Flowslot

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**The practical infrastructure for vibe coding with Cursor and Claude Code.**

Run multiple parallel AI-assisted development streams — each with isolated context, infrastructure and Git branch.

---

## TL;DR

```bash
# After prerequisites (Mutagen, Tailscale, AWS CLI)
cd ~/.flowslot/infra && ./create-instance.sh    # One-time: create server
cd ~/your-project && slot self init              # One-time: init project

# Daily
slot server start                    # Start EC2
slot create feature-x feat/new-ui    # Create a slot
cursor ~/your-project-slots/feature-x # Open in Cursor
# Access from any device: http://web.your-project.flowslot.dev:7001
slot server stop                     # End of day
```

---

## Why Flowslot?

Vibe coding with AI agents hits real limits fast:

| Problem | What happens |
|---------|--------------|
| **Can't run multiple environments locally** | Your machine can't handle 2-4 full Docker stacks at once |
| **File collisions between sessions** | Two Cursor agents editing the same files = chaos |
| **Testing is a nightmare** | Constantly stopping/starting containers, switching branches |
| **Can't test on phone/tablet** | Containers on localhost are unreachable from other devices |
| **Sharing requires staging deploy** | Deploy to staging just to show a coworker a feature |
| **RAM gets expensive** | Buying a beefier machine just for parallel dev work |

Flowslot solves this with **slots** — isolated environments on a remote server, synced in real-time with your local code.

```
Local (Cursor + code)                    Remote Server (containers + builds)
┌──────────────────────────────────┐     ┌──────────────────────────────────────────┐
│                                  │     │                                          │
│  Cursor Window 1                 │     │  Slot: auth (branch: fix/auth-bug)       │
│  └── ~/myapp-slots/auth/         │ ──► │  └── Docker containers on ports 7000+    │
│                                  │sync │      web:7001  api:7003  db:7004         │
│  Cursor Window 2                 │     │                                          │
│  └── ~/myapp-slots/feature/      │ ──► │  Slot: feature (branch: feat/new-ui)     │
│                                  │sync │  └── Docker containers on ports 7100+    │
│  Cursor Window 3                 │     │      web:7101  api:7103  db:7104         │
│  └── ~/myapp-slots/experiment/   │ ──► │                                          │
│                                  │sync │  Slot: experiment (branch: main)         │
│                                  │     │  └── Docker containers on ports 7200+    │
│                                  │     │      web:7201  api:7203  db:7204         │
└──────────────────────────────────┘     └──────────────────────────────────────────┘
```

**Each Cursor window has its own isolated AI context.** The AI only sees the code for that slot's branch — no confusion, no cross-contamination.

**Secure by default.** All traffic flows through Tailscale's private mesh — no public ports, no exposure to the internet.

*Works great for traditional development too — no AI required.*

---

## Quick Start

**Time:** ~20 minutes first-time, then ~2 minutes daily.

### Prerequisites

```bash
brew install mutagen-io/mutagen/mutagen    # File sync
brew install --cask tailscale               # Private networking (open app and sign in)
brew install awscli                         # AWS CLI
```

### Step 1: Install Flowslot

```bash
git clone https://github.com/lchachurski/flowslot.git ~/.flowslot && \
  cd ~/.flowslot && git fetch --tags && git checkout latest && \
  echo 'export PATH="$PATH:$HOME/.flowslot/scripts"' >> ~/.zshrc && \
  source ~/.zshrc
```

### Step 2: Create Server

**2a. Get Tailscale Auth Key**

1. Go to https://login.tailscale.com/admin/settings/keys
2. Create key: **Reusable** = Yes, **Expiry** = 90 days
3. Export it:
   ```bash
   export TAILSCALE_AUTH_KEY=tskey-auth-xxx
   ```

**2b. Create EC2 Instance**

```bash
aws sso login                        # Authenticate with AWS
cd ~/.flowslot/infra && ./create-instance.sh
```

This creates a t4g.2xlarge ARM Spot instance (~$0.08/hour) with Docker, Tailscale, and dnsmasq pre-configured. Wait 2-3 minutes for setup to complete.

**2c. Configure Split DNS**

1. Get the Tailscale IP from the script output
2. Go to https://login.tailscale.com/admin/dns
3. Add nameserver: `<tailscale-ip>` → Restrict to `flowslot.dev`

### Step 3: Initialize Your Project

```bash
cd ~/development/your-project
slot self init
# Enter your Instance ID and Tailscale IP when prompted
```

### Step 4: Create Your First Slot

```bash
slot server start
slot create my-feature main
```

**Done!** Open `~/development/your-project-slots/my-feature/` in Cursor.

---

## Daily Workflow

### Morning Setup

```bash
slot server start

slot create auth fix/auth-bug
slot create feature feat/new-ui
slot create experiment main
```

### Your Desktop Layout

Open each slot in a separate Cursor window, with its browser beside it:

```
┌─────────────────────────────────┬─────────────────────────────────┐
│                                 │                                 │
│  Cursor: ~/myapp-slots/auth/    │  Browser: web.myapp.flowslot.dev:7001
│  (branch: fix/auth-bug)         │  (auth slot's web app)          │
│                                 │                                 │
├─────────────────────────────────┼─────────────────────────────────┤
│                                 │                                 │
│  Cursor: ~/myapp-slots/feature/ │  Browser: web.myapp.flowslot.dev:7101
│  (branch: feat/new-ui)          │  (feature slot's web app)       │
│                                 │                                 │
└─────────────────────────────────┴─────────────────────────────────┘
```

**Each Cursor window sees only its slot's code.** The AI's context is clean.

### Test on Your Phone

1. Install Tailscale app on your phone
2. Sign in to the same Tailscale account
3. Browse to `http://web.myapp.flowslot.dev:7001`

Works on any device connected to your Tailnet — phone, tablet, laptop, another computer.

### Share with a Coworker

Two options:

1. **Same Tailscale account:** Add them to your Tailscale account → they can access all slot URLs
2. **Share a single device:** Use Tailscale's device sharing feature

No staging deploy needed. They see your running slot instantly.

### End of Day

```bash
slot stop auth
slot stop feature
slot stop experiment
slot server stop
```

---

## Commands

### Cheat Sheet

| Command | What it does |
|---------|--------------|
| `slot create <name> [branch]` | Create new slot on a branch |
| `slot stop [name]` | Stop containers (keeps files) |
| `slot resume [name]` | Resume existing slot |
| `slot destroy [name]` | Delete slot completely |
| `slot list` | Show all slots |
| `slot info [name]` | Show slot details (URLs, ports, status) |
| `slot compose [name] <args>` | Run docker compose on remote slot |
| `slot server start` | Start EC2 instance |
| `slot server stop` | Stop EC2 instance |
| `slot server status` | Show EC2 status |
| `slot server info` | Show server resources (CPU, RAM, disk) |
| `slot self init` | Initialize flowslot for current project |
| `slot self upgrade` | Upgrade flowslot (add `--remote` for server) |
| `slot self version` | Show version |

**Auto-detection:** When inside a slot directory, `[name]` is optional — detected from path.

### When to Use Which

| Scenario | Command |
|----------|---------|
| First time creating a slot | `slot create <name>` |
| After `slot stop` | `slot resume` |
| After `slot server stop` + `start` | `slot resume` |
| Want a fresh start (wipe everything) | `slot destroy` then `slot create` |

### Remote Container Control

Run any docker compose command on a remote slot:

```bash
cd ~/myapp-slots/feature-x
slot compose ps                    # List containers
slot compose build --no-cache      # Rebuild
slot compose logs -f web           # Follow logs
slot compose exec api bash         # Shell into container
```

---

## URLs & Wildcard DNS

All slots are accessible via human-readable URLs through Tailscale Split DNS.

### URL Patterns

| Pattern | Format | Example |
|---------|--------|---------|
| **Simple** | `{service}.{project}.flowslot.dev:{port}` | `http://web.myapp.flowslot.dev:7001` |
| **Extended** | `{service}.{slot}.{project}.flowslot.dev:{port}` | `http://web.feature.myapp.flowslot.dev:7101` |

**When to use which:**

| Pattern | Best for | Why |
|---------|----------|-----|
| **Simple** | OAuth, 3rd-party integrations | Whitelist once (e.g., `web.myapp.flowslot.dev`), works for all slots |
| **Extended** | Multi-tenant apps, clean URLs | When subdomain is part of your product |

### Security

- **No public internet exposure** — all traffic via Tailscale mesh
- Only devices on your Tailnet can access slot URLs
- Works from any device: laptop, phone, tablet, coworker's machine (if on Tailnet)

### How It Works

1. **dnsmasq on EC2** resolves `*.flowslot.dev` → EC2's Tailscale IP
2. **Tailscale Split DNS** routes `*.flowslot.dev` queries to the EC2
3. **Your browser** connects via Tailscale's private network

---

## Adapting Your Project

Flowslot needs dynamic ports so multiple slots run without conflicts.

### Step 1: Parameterize docker-compose

```yaml
# BEFORE (hardcoded)
services:
  web:
    ports:
      - "3000:3000"
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
  postgres:
    container_name: ${POSTGRES_CONTAINER_NAME:-myapp-postgres}
    ports:
      - "${SLOT_PORT_DB:-5432}:5432"
    volumes:
      - ${POSTGRES_VOLUME:-postgres-data}:/var/lib/postgresql/data
```

**Key:** `${VAR:-default}` uses `$VAR` if set, otherwise `default`. Local dev works unchanged.

### Step 2: Create flowslot-ports.sh

```bash
#!/bin/bash
# SLOT_PORT_BASE is set by flowslot: 7000, 7100, 7200, etc.
# SLOT is the slot number: 0, 1, 2, etc.

export SLOT_PORT_WEB=$((SLOT_PORT_BASE + 1))      # 7001, 7101, 7201, ...
export SLOT_PORT_API=$((SLOT_PORT_BASE + 3))      # 7003, 7103, 7203, ...
export SLOT_PORT_DB=$((SLOT_PORT_BASE + 4))       # 7004, 7104, 7204, ...

export POSTGRES_CONTAINER_NAME="myapp-postgres-${SLOT}"
export POSTGRES_VOLUME="postgres-data-${SLOT}"
```

### Step 3: (Optional) Create docker-compose.flowslot.yml

For slot-specific overrides:

```yaml
services:
  web:
    environment:
      - NEXT_PUBLIC_API_URL=http://${SLOT_REMOTE_IP}:${SLOT_PORT_API}

volumes:
  postgres-data-0:
  postgres-data-1:
  postgres-data-2:
```

### Available Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `SLOT` | `0` | Slot number (0-based) |
| `SLOT_PORT_BASE` | `7000` | Base port for this slot |
| `SLOT_REMOTE_IP` | `100.112.147.63` | Tailscale IP of remote server |
| `COMPOSE_PROJECT_NAME` | `myapp-auth` | Unique project name per slot |

See [templates/](templates/) for complete examples.

---

## How It Works

### Directory Structure

```
~/development/
├── myapp/                      # Your original project
│   ├── .slotconfig             # Flowslot configuration
│   ├── docker-compose.yml
│   ├── docker-compose.flowslot.yml
│   └── flowslot-ports.sh
│
└── myapp-slots/                # Slot worktrees (created by flowslot)
    ├── repo.git/               # Bare clone
    ├── auth/                   # Slot: auth → Open in Cursor Window 1
    ├── feature/                # Slot: feature → Open in Cursor Window 2
    └── experiment/             # Slot: experiment → Open in Cursor Window 3
```

On remote: `/srv/myapp/<slot-name>/` with synced files and running containers.

### The Stack

| Layer | What | Why |
|-------|------|-----|
| **Git Worktrees** | Each slot is a local checkout on its own branch | Edit different branches simultaneously |
| **Mutagen Sync** | Real-time bidirectional file sync (~100ms) | Save locally, see changes instantly |
| **Dynamic Ports** | Slot 0: 7000-7099, Slot 1: 7100-7199, etc. | No port conflicts |
| **Tailscale** | Private mesh network (100.x.y.z) | Secure access, no public ports |
| **dnsmasq** | Wildcard DNS (`*.flowslot.dev`) | Human-readable URLs |
| **Docker Compose** | Your existing setup with port overrides | Same containers, isolated per slot |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Port already allocated" | Parameterize ports with `${VAR:-default}` |
| "Container name conflict" | Add `${SLOT}` to `container_name` |
| `slot resume` fails | Containers were deleted; use `slot create` |
| Can't access URLs | Check Tailscale Split DNS configuration |
| Can't access from phone | Install Tailscale app, sign in to same account |
| Coworker can't access | Add them to your Tailscale account or share device |
| Slot exists error on create | Use `slot resume` or `slot destroy` first |
| Service can't find API | Use `SLOT_REMOTE_IP` instead of `localhost` |

### Debug Commands

```bash
slot compose <name> logs -f              # Follow container logs
ssh ubuntu@<tailscale-ip> 'docker ps -a' # List all containers
mutagen sync list                        # Check sync status
```

---

## Cost & Auto-Stop

- **Cost:** ~$0.08/hour (t4g.2xlarge Spot in eu-central-1)
- **Typical day:** $0.64-0.96 for 8-12 hours
- **Auto-stop:** Server shuts down after 2 hours of inactivity

**What counts as activity:** file changes (Mutagen), container CPU usage, SSH connections.

```bash
# Disable auto-stop
ssh ubuntu@<ip> "crontab -l | grep -v flowslot-idle-check | crontab -"

# Re-enable
ssh ubuntu@<ip> "(crontab -l; echo '*/5 * * * * /usr/local/bin/flowslot-idle-check') | crontab -"

# Change timeout (default 7200s = 2h)
ssh ubuntu@<ip> "sudo sed -i 's/IDLE_LIMIT=7200/IDLE_LIMIT=3600/' /usr/local/bin/flowslot-idle-check"
```

---

## Updating Flowslot

```bash
slot self upgrade              # Latest stable
slot self upgrade --edge       # Main branch (bleeding edge)
slot self upgrade --remote     # Also update server scripts
slot self version              # Check version
```

**From pre-v2.0.0:**
```bash
cd ~/.flowslot && git fetch --tags && git checkout $(git tag --sort=v:refname | tail -1)
```

---

## Advanced

### AMI for Other Regions

The default AMI is for eu-central-1. Find your region's Ubuntu 22.04 ARM64 AMI:

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text --region YOUR_REGION
```

Update `AMI_ID` in `create-instance.sh`.

### Manual Tailscale Auth

If you didn't provide `TAILSCALE_AUTH_KEY`:

```bash
ssh ubuntu@<public-ip> "sudo tailscale up"
# Follow the URL to authenticate
```

Then configure Split DNS and lock down SSH.

### View Cloud-Init Logs

```bash
ssh ubuntu@<ip> 'sudo cat /var/log/user-data.log'
```

### Lock Down Public SSH

After Tailscale is working:

```bash
aws ec2 revoke-security-group-ingress \
  --group-name flowslot-dev \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --region eu-central-1
```

---

## Why "Flowslot"?

A **slot** is a development flow — a branch, an idea, an experiment. You open slots when you need them, close them when you're done. Multiple slots, multiple flows, zero conflicts.

Perfect for AI-assisted development: exploring multiple directions, iterating fast, keeping context clean.

---

## License

Flowslot is licensed under the [MIT License](LICENSE).

---

*Built for developers who vibe code with Cursor, Claude Code, and other AI assistants.*
