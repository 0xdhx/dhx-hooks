# Architecture

dhx-hooks composes Claude Code lifecycle hooks across five concerns. This document describes how the surfaces fit together at a high level — for the per-event hook inventory see the tables in `README.md`.

## The five surfaces

### 1. Read tracking

The `dhx-read-cache.sh` PreToolUse:Read hook records files Read with `offset`/`limit` (partial reads) to a session-scoped detection store at `~/.cache/dhx/partial-read-detect-<session_id>.jsonl`, keyed on `session_id`. The `dhx-read-guard.js` PreToolUse:Edit/Write hook fires a single soft advisory when the target was partial-read this session:

- **PARTIAL-READ NOTE** — the file was Read with offset/limit (not in full) this session, then edited (potentially outside the read window). Non-blocking; suggests a full Read if unsure. Deduped once per `(session_id, CC-process)`.

This covers the one gap Claude Code's native runtime leaves. CC hard-blocks edits/writes to files never Read this session, but its read-gate is **binary** — a partial (`limit:N`) read satisfies it for an edit *anywhere* in the file. The shim covers exactly that blindness; CC owns full read-before-edit enforcement. Detection keys on `session_id` alone so it survives a plain `/exit`+`--resume` (the id is preserved); a CCS profile-swap rotates the id — the one accepted lost case (fail-toward-silence: CC still allows the edit, only the soft note is missed). This is a 2026-05-24 collapse of a former three-state (silent/soft/strong) global-TTL cache — the strong and silent states were removed once probes confirmed CC's native enforcement makes them redundant.

### 2. Drift detection

Claude Code rewrites `~/.ccs/shared/settings.json` atomically as part of plugin install / settings-edit flows. The committed `config/settings.json` is a snapshot; `git diff config/settings.json` after any session surfaces silent rewrites. The statusline aggregates drift signals into a leftmost meta-glyph (`∙` clean / `⌃` warn) for at-a-glance read.

Companion: `dhx-health-check.sh` runs at SessionStart and writes per-session metrics (fork verification, symlink integrity, plugin registry state) to `~/.cache/dhx/health.json`. The statusline consumes that file rather than re-running checks each render. `dhx-plugin-registry-heal.sh` self-repairs `installed_plugins.json` when it goes unreadable, unparseable, or loses the dhx entry.

### 3. Workflow guards

Block-or-warn hooks observing tool calls in real time. Hooks follow Claude Code exit-code semantics: `exit 0` silent, `exit 1` warn (stderr to Claude as advisory), `exit 2` block.

- **PreToolUse:Edit/Write** — `dhx-assessed-guard.sh` (block on `[assessed]` markers without explicit user approval), `dhx-read-guard.js` (read-before-edit advisory), `dhx-worktree-write-guard.sh` (block writes whose absolute path escapes the enclosing CC-managed worktree).
- **PreToolUse:Read** — `dhx-read-cache.sh` (records partial reads to a session-scoped detection store), `poll-guard.sh` (rate-limit busy-polling on background-task output).
- **PreToolUse:Bash** — `dhx-worktree-bash-guard.sh` (block destructive bashes from worktrees touching main repo paths).
- **PreToolUse:Agent** — `dhx-ui-vision-guard.sh`, `dhx-agent-leak-snapshot.sh` (capture pre-dispatch `git status` baseline for paired post-check).
- **PostToolUse:Write/Edit** — `dhx-source-write-flag.sh` (per-turn flag for the test-gate), `dhx-context-gate.sh` (block when CONTEXT.md is missing required sections).
- **PostToolUse:Skill** — `dhx-merge-reminder.sh`, `dhx-new-milestone-promote-reminder.sh` (event-class-scoped reminders that fire after specific skills complete).
- **PostToolUse:Agent** — `dhx-agent-leak-check.sh` (diff against the pre-dispatch baseline; warn on isolation leaks), plus the execute-* family (calibration injections after `gsd-executor` / `gsd-verifier` agents complete).
- **Stop** — `dhx-deferred-check.sh` (surface UNASSESSED deferred items before context clears), `dhx-execute-stop-review.sh` (block if a phase execution finished without the required review), `dhx-test-gate.sh` (block task completion if tests fail, gated on the source-write flag).

The dominant pattern is observe-and-warn, not block. Blocking hooks are the exception and are explicitly listed in `README.md § Safety Levels`.

### 4. Statusline composition

`statusline-wrapper.js` composes the multi-segment status line: drift warnings + critical-tier health signals on the front; project state (commits, dirty tree, branch, ahead/behind) + ccburn (Claude usage telemetry) + project sigil + meta-glyph on the rest. Each segment is an isolated promise with per-segment self-diagnosis (red `⚠ <segment>?` sigil if the segment throws, plus a JSONL log for offline replay).

`dhx-statusline.js` is the inner renderer (compact model name, CCS profile letter, 5-segment context bar, conditional second line, advisory-health tail). `statusline-wrapper.js` is the outer composer that pipes stdin through the renderer and appends the rest.

### 5. Plugin manifest

`dhx-plugin/plugins/dhx/hooks/hooks.json` registers all dhx hooks via the Claude Code plugin system rather than `~/.claude/settings.json`. The plugin-manifest path survives Claude Code's atomic settings-rename rewriter; the settings.json path does not. Plugin-manifest registration is the primary path for all event classes (PreToolUse, PostToolUse, UserPromptSubmit, SessionStart, SubagentStart, SubagentStop, Stop, PreCompact, PostCompact, Notification have all been verified plugin-hostable). `settings.json` registration is reserved for project-scoped scoping needs or event classes the plugin loader doesn't yet support.

The plugin manifest references hooks by absolute path into `dhx/`, so the dhx scripts are the single source of truth — the manifest is a thin index.

## How surfaces compose

```
                   SessionStart
                        │
              ┌─────────┴─────────┐
              │                   │
         health checks       drift detection
              │                   │
              └────────┬──────────┘
                       │
                  health.json
                       │
              statusline-wrapper.js  ← every refresh
                       │
                 (rendered statusline)


 PreToolUse:Read (offset/limit) ──► dhx-read-cache.sh ──► ~/.cache/dhx/partial-read-detect-<session_id>.jsonl
                                                                 │
 PreToolUse:Edit/Write ────► dhx-read-guard.js ──────────────────┘
                              │
                          PARTIAL-READ NOTE (soft advisory, deduped)


 Settings rewrite ────► drift in ~/.ccs/shared/settings.json
                              │
                       config/settings.json snapshot
                              │
                       git diff surfaces drift
                              │
                       statusline drift segment fires


 Stop ────► dhx-deferred-check.sh ────► UNASSESSED items surfaced
       └──► dhx-test-gate.sh ─────────► block on test failure (if source-write flag set)
       └──► dhx-execute-stop-review.sh ► block if phase finished without review
```

## Probe corpus

`tests/probes/` ships ~22 active regression probes. Each probe asserts a runtime invariant via `INVARIANT:` comment + executable assertions. Probes are scope-isolated (use `mktemp -d` fixtures, env-var indirections for path overrides, fake `$HOME` where needed). The corpus serves three purposes:

1. **Regression guard** — `bash scripts/run-probes.sh` runs the full suite; the project's pre-commit hook blocks on probe failures.
2. **Documentation** — probes describe expected behavior more precisely than prose comments.
3. **Evidence** — for upstream feature proposals, probe assertions can be cited as evidence of behavior under concurrency / failure conditions (e.g., session-scoped partial-read detection keying, the CC native-enforcement supersession tripwire).

## Conventions

- **Atomic commits.** Every behavior change ships as a single commit covering source + probes + plugin-manifest updates. The commit history reads as a sequence of self-contained behavior changes.
- **`# Patterns: HP-XXX` headers.** Every hook script declares the runtime invariants it relies on. The HP catalog itself lives in the private workflow repo; the convention is public and self-documenting via the headers.
- **Plugin-manifest first.** New hooks register via the manifest, not `settings.json`. The drift snapshot (`config/settings.json`) detects deviations from the expected baseline.

## What this is not

- A starter kit. Hooks reference workflow conventions (`.planning/` directory layout from upstream GSD, CCS profile awareness) — adopt at your own discretion.
- A complete GSD installation. The skills + commands + agents that compose with these hooks live upstream at `gsd-build/get-shit-done`.
- A canonical decisions corpus. Internal rationale lives in a private workflow repo; this architecture doc describes WHAT and HOW, not WHY-by-decision-row.
