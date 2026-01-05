# Flowslot Agent Guide

This file helps AI assistants (Cursor, Claude Code, etc.) understand and operate Flowslot.

## What is Flowslot?

Flowslot manages isolated development environments ("slots") on a remote EC2 server. Each slot:
- Has its own Git branch (via worktree)
- Runs its own Docker containers with unique ports
- Syncs files in real-time via Mutagen
- Is accessible via Tailscale private network

## Key Concepts

| Concept | Description |
|---------|-------------|
| **Slot** | An isolated dev environment = local worktree + remote containers |
| **Slot directory** | Local path: `~/project-slots/<slot-name>/` |
| **Remote path** | `/srv/<project>/<slot-name>/` on EC2 |
| **Port range** | Slot 0: 7000-7099, Slot 1: 7100-7199, etc. |
| **`.slotconfig`** | Project config file with instance ID, remote host, etc. |

## Commands Reference

### Slot Lifecycle
```bash
slot create <name> [branch]  # Create new slot
slot stop [name]             # Stop containers (keeps files)
slot resume [name]           # Resume existing slot
slot destroy [name]          # Delete slot completely
```

### Slot Operations
```bash
slot list                    # Show all slots
slot info [name]             # Show slot details (URLs, ports)
slot compose [name] <args>   # Run docker compose on remote
```

### Server Management
```bash
slot server start            # Start EC2 instance
slot server stop             # Stop EC2 instance
slot server status           # Show EC2 status
slot server info             # Show resources (CPU, RAM, disk)
slot server recreate         # Terminate and create new instance (for Spot issues)
```

### Meta
```bash
slot self init               # Initialize project for flowslot
slot self upgrade [--remote] # Update flowslot
slot self version            # Show version
```

## Auto-Detection

When user is inside a slot directory, `[name]` is auto-detected:
```bash
cd ~/myapp-slots/feature-x
slot info              # Auto-detects "feature-x"
slot compose logs web  # Auto-detects "feature-x"
```

## Common Tasks

### User wants to start working
```bash
slot server start
slot resume <name>   # or slot create <name> <branch>
```

### User wants to rebuild containers
```bash
slot compose <name> build --no-cache
slot compose <name> up -d
```

### User wants to see logs
```bash
slot compose <name> logs -f <service>
```

### User wants to run a command in container
```bash
slot compose <name> exec <service> <command>
# Example: slot compose feature-x exec api npm run migrate
```

### User wants to check what's running
```bash
slot list
slot info <name>
```

### User wants to stop everything
```bash
slot stop <name>        # Stop one slot
slot server stop        # Stop entire EC2
```

## File Locations

| File | Purpose |
|------|---------|
| `~/.flowslot/` | Flowslot installation |
| `~/.flowslot/scripts/` | CLI commands |
| `~/.flowslot/infra/` | EC2 setup scripts |
| `<project>/.slotconfig` | Project configuration |
| `<project>/flowslot-ports.sh` | Port definitions |
| `<project>/docker-compose.flowslot.yml` | Slot-specific overrides |

## Environment Variables in Slots

These are exported when running containers:

| Variable | Example | Description |
|----------|---------|-------------|
| `SLOT` | `0` | Slot number (0-based) |
| `SLOT_NAME` | `feature-x` | Slot name |
| `SLOT_PORT_BASE` | `7000` | Base port |
| `SLOT_REMOTE_IP` | `100.119.84.18` | Tailscale IP |
| `COMPOSE_PROJECT_NAME` | `myapp-feature-x` | Docker project name |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Server not running | `slot server start` |
| Slot not found | Check `slot list`, use `slot create` if new |
| Port conflict | Each slot needs unique ports; check `flowslot-ports.sh` |
| Sync not working | `mutagen sync list` to check status |
| Container issues | `slot compose <name> logs -f` to debug |

## URLs

Slots are accessible via:
- **Tailscale IP**: `http://100.x.x.x:<port>`
- **Wildcard DNS**: `http://<service>.<project>.flowslot.dev:<port>`

Port assignments are defined in `flowslot-ports.sh` (e.g., `SLOT_PORT_WEB`, `SLOT_PORT_API`).

## Notes for Agents

1. **Always check server status first** — if commands fail, server might be stopped
2. **Use `slot compose` instead of SSH** — it handles remote execution automatically
3. **Slot names are lowercase with hyphens** — no spaces or special characters
4. **File sync is bidirectional** — changes on remote sync back to local
5. **Each slot is isolated** — changes in one don't affect others

