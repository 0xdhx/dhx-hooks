# Changelog

All notable changes to dhx-hooks will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-04-27

### Added
- `ARCHITECTURE.md` — high-level overview of the five hook surfaces (read tracking, drift detection, workflow guards, statusline composition, plugin manifest) and how they compose. Authored as a public-facing companion to `README.md`'s per-event hook tables.

## [0.1.0] - 2026-04-26

Initial public release. Mirror of the dhx hook surface from the private workflow repo. See README for the hook inventory.

### Added
- `dhx/` hook source: SessionStart health/drift/worktree checks, PreToolUse read-cache + read-guard with persistent JSONL state-tracking, workflow + prompt guards, validate-commit, worktree-bash-guard, ui-vision-guard, statusline composition.
- `dhx-plugin/` Claude Code plugin manifest registering all dhx hooks (rewriter-safe via plugin manifest path).
- `tests/probes/` regression probe corpus (~22 active probes) asserting runtime invariants.
- `scripts/run-probes.sh`, `scripts/verify-hooks.sh`, `scripts/sync-public-mirror.sh`.
- `config/settings.json` drift snapshot of live Claude Code settings for change detection.
- `gsd/` read-only snapshots of upstream `gsd-build/get-shit-done` hooks (vendored for fork-tracking).

### Notable hooks
- **Persistent JSONL read-cache** (`dhx-read-cache.sh` + `dhx-read-guard.js`) — cross-tool, cross-session read tracking with 7200s TTL. Three-state advisory (silent / soft / strong) finer-grained than upstream's binary skip. CCS-multi-instance safe.
- **Plugin-manifest registration** — survives Claude Code's atomic settings-rename rewriter.

[0.1.1]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.1.1
[0.1.0]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.1.0
