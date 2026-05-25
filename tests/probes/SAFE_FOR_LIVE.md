# SAFE_FOR_LIVE Classification

Generated 2026-05-01 per Phase 4 D-11/D-12. Each `tests/probes/probe-*.{sh,js}`
carries a `# SAFE_FOR_LIVE: yes|no` (or `// SAFE_FOR_LIVE:` for .js) header tag.
`scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes` (Plan 02 Task 0) and
`scripts/health.sh --probes` (delegated) invoke only `yes`-tagged probes;
probes lacking ANY tag are refused with diagnostic. `--probes-unsafe` (which
delegates to `--filter SAFE_FOR_LIVE=no`) bypasses the yes-only filter but
refuses if PWD or `CLAUDE_CONFIG_DIR` resolves under `~/.ccs` (D-27).

Audit covers all probes under `tests/probes/probe-*.{sh,js}`, not just the
6 health.sh invokes (D-11). New probes inherit this convention via
`tests/probes/probe-safe-for-live-tags.sh` runtime invariant.

**D-29 note:** The row for `probe-safe-for-live-tags.sh` is reserved upfront
here in Task 1. The file itself lands in Task 3 of this plan; the row is a
forward reference (the audit artifact is documentation, not a generated
manifest). After Task 3 commits, `bash tests/probes/probe-safe-for-live-tags.sh`
asserts row count == file count.

| Probe | SAFE_FOR_LIVE | Reason |
|-------|---------------|--------|
| `probe-agent-leak-check.sh` | no | writes baselines under live `$HOME/.cache/dhx/` (session-tag prefixed + trap cleanup, but writes hit the live cache directory) |
| `probe-backlog-frontmatter-gate.sh` | yes | structural checks are read-only grep/readlink against in-repo files; behavioral block/pass cells run entirely inside a throwaway mktemp git repo (copies the dispatcher + 10- leaf + validator, installs a sandbox symlink); never mutates the live repo index, history, or `.git/hooks` (260522-ib4 backlog-frontmatter-gate convention enrollment probe) |
| `probe-bashrc-wrapper-heal.sh` | yes | grep-only against live `~/.bashrc` and in-repo files; no writes |
| `probe-cache-age-anchor.js` | yes | re-implements function locally; tmp-file fixtures only |
| `probe-cc-check-update-ttl.sh` | yes | mktemp cache dir + `CC_CHECK_UPDATE_CACHE` env-override injects a fixture cache; never reads or writes live `~/.cache/cc` (Phase 17 RAT-06 TTL-gate regression probe) |
| `probe-cc-check-update-worker.sh` | yes | stubbed `npm`/`claude` on a tmp PATH + `CC_CACHE_FILE` override points the worker at a fixture cache; no network, never reads or writes live `~/.cache/cc` (RAT-06b installed_at_check capture probe) |
| `probe-cc-novel-patterns.sh` | yes | mktemp fixture trees + `node -e require` of the live wrapper with explicit fixture-root arg; scenario 5 drives `checkDrift` under HOME + CLAUDE_CONFIG_DIR overrides; never reads live `~/.claude` or `~/.cache/dhx` (Phase 17 RAT-04 D-13a/D-15/D-22 enumeration regression probe) |
| `probe-cc-residual-signal.sh` | yes | mktemp fixture tree + `node -e require` of the live wrapper (`scanRecursive` + `hashWarnSettings`) with explicit fixture paths; fixture mtimes set via `fs.utimesSync`; never reads live `~/.claude` or `~/.cache/dhx` (Phase 17 RAT-01 D-01 residual-signal demonstration probe) |
| `probe-deferred-check-canonical-classifier.sh` | yes | static grep + sourcing test against in-repo classifier; mktemp fixture for source-test |
| `probe-deferred-check-header-fallback.sh` | yes | static sed-pattern equality + read-only repo-file inspection |
| `probe-deferred-check-req-id-regex.sh` | yes | regex-equality static check against hook source; no writes |
| `probe-dhx-statusline.js` | yes | re-implements helpers via require; no FS writes outside whatever the renderer does internally on tmp paths |
| `probe-drift-cleanup.sh` | no | sets `$TMPHOME/.cache/dhx` and runs `dhx-health-check.sh` under HOME=$TMPHOME (sandboxed); but uses HOME override and live `/proc` reads — sandbox confines writes |
| `probe-drift-allowlist.sh` | yes | mktemp fixture trees + node -e require of the live wrapper (checkDrift/scanRecursive/enumerateNovelPatterns) + classifyEntry from plugin-cache-allowlist.js under HOME + CLAUDE_CONFIG_DIR overrides; mtime via fs.utimesSync; never reads live ~/.claude or ~/.cache/dhx (Phase 18 DRIFT-ALLOW-03 3-state D-21 + D-20 structural + D-24a residual-novel + glob-not-guess schema-migration D-22 probe) |
| `probe-drift-detection.js` | yes | mkdtempSync + tmp-file fixtures; reimplemented compare core; no live writes |
| `probe-drift-multi-anchor-distinct-surfacing.sh` | yes | mktemp + env-override DHX_DRIFT_CACHE; invokes dhx-gsd-drift-surface.sh against fixture caches; never touches the live dhx drift cache (Phase 16 REQ-DRIFT-ACTION-05 positive probe) |
| `probe-drift-single-anchor-no-overcount.sh` | yes | mktemp + env-override DHX_DRIFT_CACHE; single-entry fixture cache; never touches the live dhx drift cache (Phase 16 REQ-DRIFT-ACTION-05 negative probe) |
| `probe-effort-level-stdin-absent.sh` | yes | read-only via file-gated wrapper edit; no live mutation (Phase 3 D-14 supersession-watchdog tag preserved per Task 2 idempotency) |
| `probe-execute-hooks-subagent-stop.sh` | yes | per-test mktemp HOME / TMPDIR; cwd passed via stdin payload (HP-001 cwd field) so hooks read `.planning` fixtures from the sandbox dir; no live `~/.cache/dhx`, `~/.claude`, or git state touched (2026-05-07 SubagentStop migration probe) |
| `probe-execute-stop-review.sh` | yes | mktemp + isolated subprocess invocation of hook with HOME=$TMP; no live writes |
| `probe-execute-stop-review-state-allowlist.sh` | yes | per-scenario mktemp fixture + isolated subprocess; cwd points at $TMP via stdin payload (HP-001); no live writes |
| `probe-fleet-statusline-render.js` | yes | uses `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per spawn); fixture fleet-statusline.json planted inside the tmp `.cache/dhx/`; never touches live `~/.cache/dhx` (phase-10 SURF-02 readFleetFeed render probe; mirrors `probe-health-suffix.js`) |
| `probe-gate-6-canonical-mirror-discipline.sh` | yes | read-only `diff -q` against live `~/.claude/get-shit-done/` + `~/.claude/gsd-local-patches/` trees; derives file set from backup-meta.json; never writes (Phase 16 REQ-DRIFT-ACTION-04 byte-equality probe) |
| `probe-gate-6-cross-repo-parity.sh` | yes | read-only sha256 of the Gate 6 doc section across hooks-side + `~/repos/cross-repo/`; never modifies cross-repo (Phase 16 REQ-DRIFT-ACTION-04 verify-only parity probe; D-21/D-24) |
| `probe-gsd-canonical-mirror-gate-tiered-outcome.sh` | yes | mktemp + env-overrides DHX_DRAFT_BUFFER_DIR + DHX_BACKUP_META; fixture marker dir + backup-meta; never touches the live dhx cache or live gsd-local-patches (Phase 16 REQ-DRIFT-ACTION-03 tiered-outcome probe) |
| `probe-gsd-fork-aware-drift.sh` | yes | mktemp + node -e require with explicit liveRoot/forkRoot args; never reads live `~/.claude` |
| `probe-health-check-session-id-rm-safety.sh` | yes | static grep of in-repo `dhx/dhx-health-check.sh` + allowlist-regex primitive + integration over a mktemp cache dir; never touches `$HOME` or the live cache (Phase 20 WR-01 session_id rm-glob safety) |
| `probe-health-sh-no-side-effects.sh` | no | mktemp + fake HOME; full env-var isolation (Wave 2 tag preserved) |
| `probe-health-sh-tiering.sh` | no | mktemp + fake HOME; uses stub-leaf-tool fixtures (Wave 2 tag preserved) |
| `probe-health-suffix.js` | yes | uses `_make-fake-home` (mktemp + HOME override per spawn); fully sandboxed |
| `probe-hooks-wiring.sh` | yes | mktemp + full env-var override (HOME, DHX_HOOKS_MANIFEST, DHX_HOOKS_REPO_ROOT, DHX_HOOKS_INSTALL_DIR); never touches live repo |
| `probe-install-plugin-idempotency.sh` | no | mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology (Wave 1 tag preserved) |
| `probe-install-plugin-multi-instance.sh` | no | mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology (Wave 1 tag preserved) |
| `probe-installed-plugins-badjson-natural-heal.sh` | no | sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess (Phase 6 C1 BADJSON branch supersession probe — D-07a) |
| `probe-installed-plugins-no-natural-heal.sh` | no | requires `ANTHROPIC_API_KEY`; runs real `claude` subprocess (supersession-watchdog) |
| `probe-installed-plugins-uninstalled-dhx-natural-heal.sh` | no | sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess (Phase 6 C1 UNINSTALLED:dhx@dhx-local branch supersession probe — D-07b) |
| `probe-known-marketplaces-natural-heal.sh` | no | sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess (Phase 6 C1 km mini-probe — D-11 HEAL-07) |
| `probe-first-prompt-segment.js` | yes | re-implements function locally; tmp-file fixtures only |
| `probe-migration.js` | yes | re-implemented compare core; tmp-file fixtures via os.tmpdir |
| `probe-milestone-close-blocker-check.sh` | yes | mktemp + isolated subprocess invocation of hook with HOME=$TMP; no live `~/.cache/dhx`, `~/.claude`, or git state touched (mirrors `probe-execute-stop-review.sh` precedent) |
| `probe-milestone-close-blocker-pretooluse.sh` | yes | mktemp + isolated subprocess invocation of hook with HOME=$TMP + PreToolUse:Skill stdin payload (tool_input.skill=gsd-complete-milestone); no live `~/.cache/dhx`, `~/.claude`, or git state touched (Plan 13-03 Shape B regression probe; mirrors Plan 13-01 probe shape adapted for HP-009 PreToolUse exit-2 semantics) |
| `probe-milestone-close-vocab-parity.sh` | yes | static grep + awk against in-repo hook + canonical `~/.claude/dhx-tools/backlog-regen.cjs`; soft-skips with WARN if dhx-tools absent; no writes, no subprocess invocation of CC |
| `probe-new-milestone-promote-reminder.sh` | yes | mktemp dirs passed as `cwd` in hook stdin JSON; hook reads only via cwd; no HOME mutation |
| `probe-phase-10-doc-contracts.sh` | yes | read-only token-presence grep against committed `docs/hook-patterns.md`, `docs/decisions.md`, `.planning/REQUIREMENTS.md`; no subprocesses, no writes, no env mutation (Phase 10 Nyquist gap-fill 2026-05-13 — HEAL-07-06 + HEAL-07-07 doc-contract regression probe) |
| `probe-enumerate-novel-patterns.js` | yes | mkdtempSync fixture trees + `require()` of the live wrapper with an explicit fixture-root arg; no live `~/.claude` or `~/.cache/dhx` access (Phase 17 RAT-04 D-20 enumeration-helper export probe) |
| `probe-plugin-cache-allowlist.js` | yes | pure-unit: `require()`s `scripts/lib/plugin-cache-allowlist.js` + asserts the predicate/structure; no fs, no subprocess, no live mutation (Phase 17 RAT-04 D-06/D-14 allowlist probe) |
| `probe-plugin-keys.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; live read of settings is jq -e only |
| `probe-plugin-registry-heal.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/` |
| `probe-plugin-cache-staleness.sh` | yes | mktemp + fake HOME + env-var override (DHX_CACHE_STALENESS_LIVE_MANIFEST, DHX_CACHE_STALENESS_CACHE_ROOT); never touches live `~/.claude/plugins/cache/dhx-local` or live `dhx-plugin/` manifest |
| `probe-plugin-registry.sh` | yes | mktemp tmpdir-as-config; HOME=$cfg/cache-dhx-home; never mutates live registry |
| `probe-read-cache.sh` | yes | mktemp HOME isolation; session-scoped partial-detect store writes contained in $TMPHOME/.cache/dhx (Option C collapse — partial-detection writer) |
| `probe-read-guard-partial-detection.sh` | yes | mktemp HOME isolation; guard reads a seeded session-scoped detect store + emits NOTE; reads/writes confined to $TMPHOME/.cache/dhx (Option C collapse) |
| `probe-read-guard-native-enforcement-tripwire.sh` | no | spawns `claude -p` subprocesses against a sandbox CLAUDE_CONFIG_DIR + mktemp out-of-band targets; supersession-watchdog asserting CC still hard-blocks unread Edit/Write (Option C Q3); operator-invoked, requires `ANTHROPIC_API_KEY` (a sandboxed `claude -p` is logged out, and seeding an OAuth credentials_file is unsafe — see the probe header AUTH note + 2026-05-24 decisions row) |
| `probe-repair-installed-plugins.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/`; no claude subprocess, no auth, no network; fixture-only — no live registry mutation (Phase 19 SYM-REPAIR D-10/D-15 repair-action probe; SC2 empirical anchor) |
| `probe-restart-plugins-stop-hook.sh` | yes | mktemp + HOME=$TMP per scenario; transcript fixtures synthesized in $TMP |
| `probe-settings-hash.js` | yes | reads `~/.ccs/shared/settings.json` read-only as seed; writes only to `/tmp/probe-settings-*.json` fixtures (predictable paths, no live mutation) |
| `probe-settings-path-invariant.sh` | yes | readlink + stat read-only against live settings chain; no writes |
| `probe-sigpipe-pipefail-shapes.sh` | yes | static lint grepping in-repo `dhx/*.sh` for pipeline shapes; no writes |
| `probe-stale-hooks-filter-retired.js` | yes | read-only assertions against repo-tracked source files |
| `probe-stale-worktree-sweep.sh` | yes | mktemp + fake worktree state; never operates on live worktrees |
| `probe-subagent-stop-sync.sh` | yes | arming-mode writes only to `${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe/` (per-process scratch); fixtures-only mode is read-only when probe dir absent (BG-AGENT-2 / Phase 9 sync+bg SubagentStop verification probe; mirrors `probe-effort-level-stdin-absent.sh` D-32 / SCHEMA-04 file-gated convention) |
| `probe-statusline-load.js` | yes | child-spawn renderer invocation via --require shim (Phase 5 D-03 regression baseline); child stdout captured via stdio:'pipe'; renderer's bridge-file write lands at `/tmp/claude-ctx-probe-load.json` (predictable path, conventional fixture per probe-settings-hash.js heuristic note) |
| `probe-statusline-self-diag.js` | yes | mktemp HOME + `process.env.HOME` override per subtest; appendFile lands under temp HOME only |
| `probe-statusline-wrapper.js` | yes | pure require + helper function tests; no FS writes |
| `probe-sym-health-override.js` | yes | mkdtempSync; tmp-file fixtures only |
| `probe-test-gate-cgroup.sh` | no | invokes real `systemd-run --user --scope` to enforce cgroup MemoryMax / RuntimeMaxSec on subprocesses; HOME / TMPDIR / CLAUDE_PROJECT_DIR all override to per-scenario mktemp dir, but the transient systemd-run scope units land under live user@.service (self-cleanup on exit; not config drift) |
| `probe-test-gate-host-preconditions.sh` | yes | 2-tier read-only capability check — Tier 1 grep on `cgroup.controllers` for delegated `memory` controller; Tier 2 `systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 -p RuntimeMaxSec=60s true` dry-run inside a transient scope unit that self-cleans on exit. No persistent FS writes, no live ~/.cache/dhx or ~/.claude touched (2026-05-19 Phase 14 TEST-GATE-07 host-precondition probe; D-11 2-tier shape) |
| `probe-test-gate-phase-aware.sh` | yes | mktemp + HOME / TMPDIR / CLAUDE_PROJECT_DIR overrides; per-fixture `git init` confines git state to the sandbox; runner is a stub `python` that records argv (no real pytest); no live writes (2026-05-07 phase-aware skip regression probe) |
| `probe-tiers-parity.sh` | yes | read-only grep + jq parse over repo files; no live mutation (Wave 2 tag preserved) |
| `probe-triad-duration-enrichment.sh` | yes | mktemp + env-overrides DHX_DRIFT_CACHE + DHX_TRIAD_LIVE_ROOT + DHX_TRIAD_CANONICAL_ROOT; fixture live+canonical fork-tree pair with deliberate divergence; never reads live `~/.claude` or the live dhx drift cache (Phase 16 REQ-DRIFT-ACTION-06 enrichment probe; D-32) |
| `probe-v1-1-1-gate.sh` | yes | read-only: git log + stat + pgrep + ps + jq -e against settings.json + bash scripts/verify-hooks.sh (also read-only); 8 env-var overrides for companion-test injection (DHX_PROBE_*); no FS writes (Phase 7 LEGACY closure doctrine artifact) |
| `probe-verify-drift-gate.sh` | yes | mktemp HOME isolation; cd $TMP so `.planning/` + `docs/decisions.md` resolution targets the sandbox; no live `.planning/`, decisions.md, or manifest writes (scenario 6 reads the manifest only) |
| `probe-verify-hooks-worktree.sh` | yes | mktemp tmproot + fake HOME; sandboxed git repo + worktree contained in $TMPROOT; no live `~/.claude/hooks/` or `.git/worktrees/` writes |
| `probe-watch-check.sh` | yes | per-test mktemp_state registry with trap cleanup; no live writes |
| `probe-watch-digest.sh` | yes | per-test mktemp_state registry with trap cleanup; no live writes |
| `probe-worktree-bash-guard.sh` | yes | hook subshell test with synthetic stdin; no real writes (write-attempt strings are blocked by hook before execution) |
| `probe-worktree-write-guard.sh` | yes | hook subshell test with synthetic stdin; assertions on hook exit code only |
| `probe-writeatomic-leak-cleanup.js` | yes | mkdtempSync fixtures + require of live wrapper's `writeAtomic`; mocks `fs.renameSync` then restores it; no live `~/.cache/dhx` or `~/.claude` writes (IN-03 leaked-tmp cleanup invariant probe) |
| `probe-safe-for-live-tags.sh` | yes | (D-29 reserved row) read-only grep over repo files; runtime invariant for the audit itself; lands in Task 3 of this plan |

## Classification Heuristic

- **yes** ⇐ read-only against live state (jq -e, grep, file existence checks)
- **yes** ⇐ sandboxed via mktemp + fake HOME + full env-var isolation, AND no `claude` CLI subprocess against live config
- **no** ⇐ runs `claude` CLI subprocess against live state
- **no** ⇐ supersession-watchdog
- **no** ⇐ writes to `~/.cache/dhx/`, `~/.ccs/`, or any tracked file under live `$HOME`
- **no** ⇐ env override incomplete (PATH override without HOME override, etc.)

## Notes on classification edge cases (2026-05-01)

- **`probe-effort-level-stdin-absent.sh`** carries `yes` from Phase 3 D-14. The
  Phase 4 plan's example row for this probe was `no` ("supersession-watchdog;
  arms live-capture mode") but the existing tag `yes` was authored deliberately
  alongside the file-gated wrapper convention (read-only against live state;
  arming-mode writes only to `${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe/`
  which is per-process scratch, not live config). Per Task 2 acceptance
  criterion "Existing Phase 3 tags preserved", the existing `yes` is kept and
  the audit row matches.

- **`probe-agent-leak-check.sh`** writes baseline files to LIVE `$HOME/.cache/dhx/`
  (session-tag prefixed + trap-cleaned, but real-cache writes nonetheless). It
  doesn't run `claude` subprocesses, so the prior `no` heuristic ("runs `claude`")
  doesn't apply directly — it falls under the "writes to `~/.cache/dhx/` under
  live `$HOME`" criterion.

- **`probe-drift-cleanup.sh`** uses `TMPHOME=$(mktemp -d)` + `HOME=$TMPHOME` for
  the hook invocation, BUT the comment explicitly notes "/proc is real (can't
  cheaply stub); live-tick case samples the current system." Sample reads from
  `/proc` are read-only, but the live-tick test branch behavior is system-state
  dependent. Classified `no` because the live-tick sampling makes it
  not-fully-sandboxed under the strict heuristic.

- **`probe-settings-hash.js`** is unusual: it reads `~/.ccs/shared/settings.json`
  directly as a seed but only with `readFileSync` (no live writes). All
  fixture writes go to `/tmp/probe-settings-*.json` (predictable paths, NOT
  mktemp). Classified `yes` because the live touch is read-only and the
  predictable `/tmp` paths are conventional fixture handling, not live-state
  mutation.

## Long-runtime / auth-required probes — invocation runbook

Authored 2026-05-03 from Phase 6 CR-01 follow-on. These probes are tagged
`SAFE_FOR_LIVE: no` and excluded from the default `bash scripts/run-probes.sh`
sweep (which filters `SAFE_FOR_LIVE=yes`). They run a real `claude -p`
subprocess against a sandboxed `CLAUDE_CONFIG_DIR`, require auth, and
exceed the 30s/probe wrapper budget.

| Probe | Runtime | Auth | Sandbox | Operator command |
|-------|---------|------|---------|------------------|
| `probe-installed-plugins-badjson-natural-heal.sh` | ~30s | `ANTHROPIC_API_KEY` **only** (no key → clean `skipped`; an OAuth credentials_file is NOT a safe sandbox-auth path — copying it can rotate/invalidate the source token, 2026-05-24 finding) | mktemp + `CLAUDE_CONFIG_DIR=$SANDBOX` | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-installed-plugins-badjson-natural-heal.sh` |
| `probe-installed-plugins-uninstalled-dhx-natural-heal.sh` | ~30s | same as above (`ANTHROPIC_API_KEY` **only**; OAuth credentials_file unsafe — 2026-05-24) | mktemp + `CLAUDE_CONFIG_DIR=$SANDBOX` | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-installed-plugins-uninstalled-dhx-natural-heal.sh` |
| `probe-known-marketplaces-natural-heal.sh` | ~30s | same as above (`ANTHROPIC_API_KEY` **only**; OAuth credentials_file unsafe — 2026-05-24) | mktemp + `CLAUDE_CONFIG_DIR=$SANDBOX` | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-known-marketplaces-natural-heal.sh` |
| `probe-read-guard-native-enforcement-tripwire.sh` | ~60-120s | `ANTHROPIC_API_KEY` **only** (no API key → clean `skipped`; an OAuth credentials_file is NOT a safe sandbox-auth path — copying it can rotate/invalidate the source token, 2026-05-24 finding) | mktemp + `CLAUDE_CONFIG_DIR=$SANDBOX` + out-of-band `printf` targets | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-read-guard-native-enforcement-tripwire.sh` (Option C Q3 supersession-watchdog — exit 0+premise_holds = CC block holds; exit 1 = revive signal; exit 0+skipped = inconclusive/no auth, never a false pass) |

**Routing via `--probes-unsafe`:** `bash scripts/run-probes.sh --probes-unsafe`
delegates to `--filter SAFE_FOR_LIVE=no` and runs all four probes (plus any
other `no`-tagged probes). Refused if `PWD` or `CLAUDE_CONFIG_DIR` resolves
under `~/.ccs` (D-27 sandboxing gate). Direct `bash <probe>` invocation
bypasses the wrapper entirely — preferred for long-runtime probes that
exceed the 30s/probe budget.

**Outcome consumption:**
- Heal probes: per-cell outcome JSON at `tests/probes/.results/v1.2-phase-6/<probe>.json`. Convention A exit semantics (0/1/2 all valid).
- SCHEMA-02 probe: per-cell verdicts at `tests/probes/.results/v1.2-phase-6/schema-02-verdicts.jsonl`. exit 0 unconditional per D-03 / SCHEMA-03; consumers MUST grep `classification=` from stdout (HIGH/MEDIUM/LOW/INVALID per D-18c + WR-03 zero-cell guard) — exit-status alone hides INVALID. Mapping: HIGH → READ-FUT-02-IMPL trigger; everything else → REFUTE-default per SCHEMA-05 (READ-FUT-02 closes as not-needed).
