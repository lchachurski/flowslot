# Changelog

All notable changes to Flowslot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/lchachurski/flowslot/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/lchachurski/flowslot/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/lchachurski/flowslot/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/lchachurski/flowslot/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/lchachurski/flowslot/releases/tag/v1.0.0

