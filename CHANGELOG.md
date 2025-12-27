# Changelog

All notable changes to Flowslot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.1] - 2025-12-27

### Fixed
- Tailscale auth key substitution in user-data script (was not being applied correctly)
- dnsmasq installation order - now stops systemd-resolved before installing to avoid port 53 conflict
- Uses external DNS temporarily during dnsmasq installation to ensure apt-get works

## [1.5.0] - 2025-12-27

### Added
- Wildcard DNS support via dnsmasq (`*.flowslot` domain)
- User Data (cloud-init) based EC2 setup for full reproducibility
- URL pattern: `{service}.{slot}.{project}.flowslot:{port}`
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
- Tailscale MagicDNS domain detection in `slot info` - now shows domain instead of IP
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

[Unreleased]: https://github.com/lchachurski/flowslot/compare/v1.5.1...HEAD
[1.5.1]: https://github.com/lchachurski/flowslot/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/lchachurski/flowslot/compare/v1.4.2...v1.5.0
[1.4.2]: https://github.com/lchachurski/flowslot/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/lchachurski/flowslot/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/lchachurski/flowslot/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/lchachurski/flowslot/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/lchachurski/flowslot/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/lchachurski/flowslot/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/lchachurski/flowslot/releases/tag/v1.0.0

