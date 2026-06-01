# Changelog

All notable changes to dhx-hooks will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-28

### Added
- **HP-028 SIGPIPE+pipefail static lint** — `tests/probes/probe-sigpipe-pipefail-shapes.sh` + `scripts/verify-hook-patterns.sh` check #5 enforce the `cmd | grep -[qm] PATTERN` shape as a structural invariant via two surfaces: at-rest probe (auto-discovered by `run-probes.sh`) + commit-time gate. HP-028 documents the broader runtime class (`grep -q`, `grep -m N`, `head -N`, `awk` early-exit, `sed N q`); the lint enforces the `grep -[qm]` subset where SIGPIPE bites control flow.
- **Probe-suite pre-commit gate** — `verify-hook-patterns.sh` check #8 runs `scripts/run-probes.sh` when `dhx/*.js` or `tests/probes/*` are staged. Catches wrapper-fixture drift at commit time.
- **Restart-plugins acknowledgment marker** — `dhx/dhx-restart-plugins-stop.sh` Stop hook scans transcript for `/reload-plugins` / `/restart-plugins` and writes a per-session marker the statusline consumes to clear stale-plugin warnings without a full session restart.
- **Plugin-registry drift detector** — `statusline-wrapper.js::checkPluginRegistry` surfaces 6 corruption shapes (UNREADABLE, BADJSON, MISSING:dhx-local, etc.) as a critical-tier statusline warning.
- **Hooks-json wiring canary** — `dhx/dhx-health-check.sh` verifies every manifest-referenced hook script's `~/.claude/hooks/<basename>` symlink resolves back to the dhx repo. Catches symlink-side drift the plugin-keys check can't see.
- **Plugin registry self-heal** — `dhx/dhx-plugin-registry-heal.sh` writes a valid `installed_plugins.json` seed at SessionStart when the file is unreadable, unparseable, or missing the dhx entry (HP-025 detector companion).
- **Fake-`$HOME` fixture helper** — `tests/probes/_make-fake-home.js` centralizes wrapper require-boundary scaffolding for probes that exercise `dhx/statusline-wrapper.js` end-to-end.

### Changed
- **HP-028 SIGPIPE+pipefail sweep across 8 hooks** — `cmd | grep -q PATTERN` patterns replaced with here-string / process-substitution forms (rounds 1 + 2). Audit-clean: `grep -rn '| *grep -q' dhx/` returns zero matches outside HP-028 reference comments.
- **Statusline wrapper refactor** — repo signals moved out of the renderer's `runStatusline()` body and exposed as wrapper-level imports; composer places signals after cache/git on line 1 (live-signal cluster reads cache → git → signals left-to-right). Drops milestone name; rearranges L1/L2.
- **Hairline meta-glyph** — leftmost glyph aggregates health/drift/sigil signals into one character: dim green `∙` (clean) / bright yellow `⌃` (warn). Recedes on clean path while preserving "watcher dead" detection.
- **Statusline self-diagnosis sigils** — each segment crash produces a red `⚠ <segment>?` glyph + JSONL log entry (1MB rotation) instead of silently collapsing the whole statusline.
- **Last-user-prompt segment** — line 2 surfaces a truncated form of the most recent user prompt for at-a-glance context recall.
- **Mobile mosh collapse** — line 2 collapses on narrow terminals to keep the L1 telemetry cluster visible.

### Fixed
- **Probe runner env leak** — `scripts/run-probes.sh` unsets inherited `GIT_*` env vars so probes that build tmpdir fixtures (`git init`, worktree-add) don't inherit the parent commit's git state. Latent bug since the runner was authored; surfaced first time the probe suite ran from inside a `git commit`.
- **Stale-worktree sweep allowlist** — `dhx/dhx-stale-worktree-sweep.sh` Gate 2 allows `.claude/`-prefix untracked entries to auto-sweep; tracked-file modifications still block. Mitigates `gh#36182` worktree-leak class.
- **Drift detector false positives** — filters CC's `temp_git_*` install-cycle clones; skips directory mtimes in plugin scans (was firing daily on plugin-cache orphan-sweep across all sessions).
- **ccburn status enum sync** — picked up `at_pace` → `on_pace` rename so session emoji renders correctly.
- **Fork-aware GSD drift suppression** — drift warnings no longer fire on dhx-owned forks of upstream gsd hooks (the fork content diverges by design; mtime drift is expected).

## [0.1.1] - 2026-04-27

### Added
- `ARCHITECTURE.md` — high-level overview of the five hook surfaces (read tracking, drift detection, workflow guards, statusline composition, plugin manifest) and how they compose. Authored as a public-facing companion to `README.md`'s per-event hook tables.

## [0.1.0] - 2026-04-26

Initial public release. Mirror of the dhx hook surface from the private workflow repo. See README for the hook inventory.

### Added
- `dhx/` hook source: SessionStart health/drift/worktree checks, PreToolUse read-cache + read-guard (session-scoped partial-read detection), workflow + prompt guards, validate-commit, worktree-bash-guard, ui-vision-guard, statusline composition.
- `dhx-plugin/` Claude Code plugin manifest registering all dhx hooks (rewriter-safe via plugin manifest path).
- `tests/probes/` regression probe corpus (~22 active probes) asserting runtime invariants.
- `scripts/run-probes.sh`, `scripts/verify-hooks.sh`, `scripts/sync-public-mirror.sh`.
- `config/settings.json` drift snapshot of live Claude Code settings for change detection.
- `gsd/` read-only snapshots of upstream `gsd-build/get-shit-done` hooks (vendored for fork-tracking).

### Notable hooks
- **Partial-read advisory** (`dhx-read-cache.sh` + `dhx-read-guard.js`) — session-scoped detection of files Read with `offset`/`limit` then edited outside the read window, surfaced as a soft PARTIAL-READ NOTE. Covers CC's partial-read blindness (its native read-gate is binary — a partial read satisfies it for an edit anywhere); CC's runtime owns full read-before-edit enforcement.
- **Plugin-manifest registration** — survives Claude Code's atomic settings-rename rewriter.

[0.2.0]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.2.0
[0.1.1]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.1.1
[0.1.0]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.1.0
