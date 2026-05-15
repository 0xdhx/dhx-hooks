# dhx-hooks

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Plugin Manifest](https://img.shields.io/badge/registration-plugin--manifest-green.svg)](dhx-plugin/)
[![Probes](https://img.shields.io/badge/probes-22%20regression-blue.svg)](tests/probes/)

Claude Code hooks for the GSD (`get-shit-done`) workflow ecosystem. Plugin-manifest registered (rewriter-safe), probe-tested, ships as a public reference surface for the `dhx-` prefixed hook family. Active development happens in a private workflow repo; this mirror tracks the code surface only.

For an overview of how the five hook surfaces compose, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Quick Start

Install via the local plugin marketplace pattern:

```bash
git clone https://github.com/0xdhx/dhx-hooks.git ~/repos/dhx-hooks
claude plugin marketplace add ~/repos/dhx-hooks/dhx-plugin
claude plugin install dhx@dhx-local
```

The plugin manifest at `dhx-plugin/plugins/dhx/hooks/hooks.json` registers all hooks. Restart Claude Code for registration to take effect (settings load at session start only).

Most hook commands reference `$HOME/.claude/hooks/dhx-*.sh` paths. The expected install pattern is symlinks: `ln -s ~/repos/dhx-hooks/dhx/<file> ~/.claude/hooks/<file>`. The SessionStart dispatcher uses `${CLAUDE_PLUGIN_ROOT}` and works without symlinks.

## Hooks

### SessionStart

| Hook | Purpose |
|------|---------|
| `session-start.sh` (dispatcher) | Logs probe; dispatches to dhx-health-check, dhx-dirty-tree, dhx-plugin-registry-heal, dhx-stale-worktree-sweep. |
| `dhx-health-check.sh` | Runs fork verification + symlink checks; writes `~/.cache/dhx/health.json` baseline. |
| `dhx-dirty-tree.sh` | Reports uncommitted changes once per session. Silent on clean trees. |
| `dhx-plugin-registry-heal.sh` | Heals `installed_plugins.json` when unreadable, unparseable, or missing the dhx entry (HP-025 detector companion). |
| `dhx-stale-worktree-sweep.sh` | Scans `.git/worktrees/*/locked` and removes stale entries when three safety gates pass (gh#36182 mitigation). |

### UserPromptSubmit

| Hook | Purpose |
|------|---------|
| `dhx-routing.sh` | Detects `/gsd:*` and `/gsd-*` prompts and routes to DHX equivalents (redirect or augment). |
| `dhx-main-branch-warning.sh` | Warns once per boot when working directly on `main`/`master`. |

### PreToolUse

| Hook | Matcher | Purpose |
|------|---------|---------|
| `dhx-assessed-guard.sh` | `Write\|Edit` | Prevents `[assessed]` markers without explicit user approval. |
| `dhx-read-guard.js` | `Write\|Edit` | Read-before-edit advisory using a 7200s global TTL on `~/.cache/dhx/read-cache.jsonl`. Three-state advisory (silent/soft/strong). |
| `dhx-worktree-write-guard.sh` | `Edit\|Write\|MultiEdit` | Blocks writes whose absolute path escapes the enclosing CC-managed worktree (gh#36182 mitigation). |
| `dhx-ui-vision-guard.sh` | `Agent` | Ensures `z-gsdui` project skill exists when GSD UI subagents spawn. |
| `dhx-agent-leak-snapshot.sh` | `Agent` | Captures pre-dispatch `git status` baseline for paired post-check (subagent-leak detection). |
| `dhx-poll-guard.sh` | `Read` | Rate-limits busy-polling on background-task output files (escalating cooldowns). |
| `dhx-read-cache.sh` | `Read` | Sole writer for `~/.cache/dhx/read-cache.jsonl`. Lock-free `>>` appends; flock-protected prune. |

### PostToolUse

| Hook | Matcher | Purpose |
|------|---------|---------|
| `dhx-merge-reminder.sh` | `Skill` | After milestone-completion skills, reminds user to merge working branch. |
| `dhx-new-milestone-promote-reminder.sh` | `Skill` | After `/gsd-new-milestone`, reminds `/dhx:backlog promote-next` if `next`-tagged briefs exist. |
| `dhx-source-write-flag.sh` | `Write\|Edit` | Sets per-turn flag for the test-gate when source files are written. |
| `dhx-write-cache.sh` | `Write\|Edit` | Mirrors successful writes into the read cache (`source:"write"` entries) — closes Write→Edit false-positive class. |
| `dhx-context-gate.sh` | `Write` | Blocks (exit 2) when CONTEXT.md is missing required DHX sections. |
| `dhx-execute-checkpoint.sh` | `Agent` | Drift detection calibration injected when a `gsd-executor` agent completes. |
| `dhx-execute-review.sh` | `Agent` | Execution fidelity review on `gsd-verifier` completion (includes phase-number derivation from `STATE.md` + pointer to `/dhx:execute` review skill — absorbed `dhx-post-execute-review.sh` 2026-05-03). |
| `dhx-audit-checkpoint.sh` | `Agent` | Audit calibration on `gsd-verifier` completion (counteracts optimistic completion bias). |
| `dhx-agent-leak-check.sh` | `Agent` | Diffs current `git status` against the pre-dispatch baseline; warns on isolation leaks. |

### Stop

| Hook | Purpose |
|------|---------|
| `dhx-deferred-check.sh` | Surfaces UNASSESSED deferred items from CONTEXT.md before context clears. |
| `dhx-execute-stop-review.sh` | Safety net: blocks if a phase execution finished without the required `/dhx:execute` review. |
| `dhx-test-gate.sh` | Blocks task completion if tests fail (gated on the source-write flag). 9-step runner-detection cascade. |

### Statusline

The statusline composer is registered via `statusLine.command` (settings.json territory, not the plugin manifest):

| File | Purpose |
|------|---------|
| `dhx/statusline-wrapper.js` | Top-level composer — pipes stdin through the renderer, appends git/cache/burn telemetry, prepends drift + critical-health front. |
| `dhx/dhx-statusline.js` | Renderer — compact model name, CCS profile letter, 5-segment context bar, conditional second line, advisory-health tail. |

## Safety Levels

Hooks follow Claude Code exit-code semantics:

- `exit 0` — silent, allow operation
- `exit 1` — emit stderr as warning to Claude (does NOT block)
- `exit 2` — block tool execution, emit stderr to user

Blocking hooks (use `exit 2`): `dhx-assessed-guard.sh`, `dhx-worktree-write-guard.sh`, `dhx-poll-guard.sh`, `dhx-context-gate.sh`, `dhx-execute-stop-review.sh`, `dhx-test-gate.sh`. The dominant pattern in this repo is observe-and-warn, not block.

## Testing

`tests/probes/` ships regression probes asserting runtime invariants. Run the full suite:

```bash
bash scripts/run-probes.sh
```

Each probe declares its assertion class via an `INVARIANT:` comment. The corpus is more rigorous than typical hooks repos — used as both regression guard and as evidence for upstream feature proposals.

## Drift snapshot

`config/settings.json` is a committed snapshot of the live `~/.ccs/shared/settings.json` (the settings file all CCS profiles resolve to). Run `git diff config/settings.json` to detect silent rewrites by Claude Code or other tools.

## Patterns

Each hook script declares a `# Patterns: HP-XXX, HP-YYY` header listing the runtime invariants it relies on. The HP registry catalog lives in the private workflow repo.

## Forks from upstream

`gsd/` contains read-only snapshots of upstream `gsd-build/get-shit-done` hooks, vendored for fork-tracking. The fork-and-modify lineage for `gsd-read-guard.js` → `dhx/dhx-read-guard.js` is documented in commit history; the fork ships persistent JSONL state-tracking the upstream binary doesn't (see `dhx/dhx-read-cache.sh` + the `probe-read-cache*` probe corpus).

## License

[MIT](LICENSE) — copyright 2026 0xdhx.
