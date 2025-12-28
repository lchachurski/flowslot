# Changelog

All notable changes to Flowslot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Tag-based versioning with `slot update` command

[Unreleased]: https://github.com/lchachurski/flowslot/compare/v1.7.3...HEAD
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

