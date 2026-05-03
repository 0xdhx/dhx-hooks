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
| `probe-bashrc-wrapper-heal.sh` | yes | grep-only against live `~/.bashrc` and in-repo files; no writes |
| `probe-cache-age-anchor.js` | yes | re-implements function locally; tmp-file fixtures only |
| `probe-deferred-check-canonical-classifier.sh` | yes | static grep + sourcing test against in-repo classifier; mktemp fixture for source-test |
| `probe-deferred-check-header-fallback.sh` | yes | static sed-pattern equality + read-only repo-file inspection |
| `probe-deferred-check-req-id-regex.sh` | yes | regex-equality static check against hook source; no writes |
| `probe-dhx-statusline.js` | yes | re-implements helpers via require; no FS writes outside whatever the renderer does internally on tmp paths |
| `probe-drift-cleanup.sh` | no | sets `$TMPHOME/.cache/dhx` and runs `dhx-health-check.sh` under HOME=$TMPHOME (sandboxed); but uses HOME override and live `/proc` reads — sandbox confines writes |
| `probe-drift-detection.js` | yes | mkdtempSync + tmp-file fixtures; reimplemented compare core; no live writes |
| `probe-effort-level-stdin-absent.sh` | yes | read-only via file-gated wrapper edit; no live mutation (Phase 3 D-14 supersession-watchdog tag preserved per Task 2 idempotency) |
| `probe-execute-stop-review.sh` | yes | mktemp + isolated subprocess invocation of hook with HOME=$TMP; no live writes |
| `probe-gsd-fork-aware-drift.sh` | yes | mktemp + node -e require with explicit liveRoot/forkRoot args; never reads live `~/.claude` |
| `probe-health-sh-no-side-effects.sh` | no | mktemp + fake HOME; full env-var isolation (Wave 2 tag preserved) |
| `probe-health-sh-tiering.sh` | no | mktemp + fake HOME; uses stub-leaf-tool fixtures (Wave 2 tag preserved) |
| `probe-health-suffix.js` | yes | uses `_make-fake-home` (mktemp + HOME override per spawn); fully sandboxed |
| `probe-hooks-wiring.sh` | yes | mktemp + full env-var override (HOME, DHX_HOOKS_MANIFEST, DHX_HOOKS_REPO_ROOT, DHX_HOOKS_INSTALL_DIR); never touches live repo |
| `probe-install-plugin-idempotency.sh` | no | mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology (Wave 1 tag preserved) |
| `probe-install-plugin-multi-instance.sh` | no | mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology (Wave 1 tag preserved) |
| `probe-installed-plugins-no-natural-heal.sh` | no | requires `ANTHROPIC_API_KEY`; runs real `claude` subprocess (supersession-watchdog) |
| `probe-last-prompt-segment.js` | yes | re-implements function locally; tmp-file fixtures only |
| `probe-migration.js` | yes | re-implemented compare core; tmp-file fixtures via os.tmpdir |
| `probe-new-milestone-promote-reminder.sh` | yes | mktemp dirs passed as `cwd` in hook stdin JSON; hook reads only via cwd; no HOME mutation |
| `probe-plugin-keys.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; live read of settings is jq -e only |
| `probe-plugin-registry-heal.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/` |
| `probe-plugin-registry.sh` | yes | mktemp tmpdir-as-config; HOME=$cfg/cache-dhx-home; never mutates live registry |
| `probe-read-cache-concurrency.sh` | yes | mktemp HOME isolation (`$TMPHOME`); 50-writer concurrency stays inside `$TMPHOME/.cache/dhx/` |
| `probe-read-cache-cross-session.sh` | yes | mktemp HOME isolation; CCS-swap simulation contained in $TMPHOME |
| `probe-read-cache-prune-concurrency.sh` | yes | mktemp HOME isolation; adversarial prune contention contained in $TMPHOME |
| `probe-read-cache.sh` | yes | mktemp HOME isolation; XDG cache writes contained in $TMPHOME/.cache/dhx |
| `probe-restart-plugins-stop-hook.sh` | yes | mktemp + HOME=$TMP per scenario; transcript fixtures synthesized in $TMP |
| `probe-settings-hash.js` | yes | reads `~/.ccs/shared/settings.json` read-only as seed; writes only to `/tmp/probe-settings-*.json` fixtures (predictable paths, no live mutation) |
| `probe-settings-path-invariant.sh` | yes | readlink + stat read-only against live settings chain; no writes |
| `probe-sigpipe-pipefail-shapes.sh` | yes | static lint grepping in-repo `dhx/*.sh` for pipeline shapes; no writes |
| `probe-stale-hooks-filter-retired.js` | yes | read-only assertions against repo-tracked source files |
| `probe-stale-worktree-sweep.sh` | yes | mktemp + fake worktree state; never operates on live worktrees |
| `probe-statusline-load.js` | yes | child-spawn renderer invocation via --require shim (Phase 5 D-03 regression baseline); child stdout captured via stdio:'pipe'; renderer's bridge-file write lands at `/tmp/claude-ctx-probe-load.json` (predictable path, conventional fixture per probe-settings-hash.js heuristic note) |
| `probe-statusline-self-diag.js` | yes | mktemp HOME + `process.env.HOME` override per subtest; appendFile lands under temp HOME only |
| `probe-statusline-wrapper.js` | yes | pure require + helper function tests; no FS writes |
| `probe-sym-health-override.js` | yes | mkdtempSync; tmp-file fixtures only |
| `probe-test-gate-cgroup.sh` | no | invokes real `systemd-run --user --scope` to enforce cgroup MemoryMax / RuntimeMaxSec on subprocesses; HOME / TMPDIR / CLAUDE_PROJECT_DIR all override to per-scenario mktemp dir, but the transient systemd-run scope units land under live user@.service (self-cleanup on exit; not config drift) |
| `probe-tiers-parity.sh` | yes | read-only grep + jq parse over repo files; no live mutation (Wave 2 tag preserved) |
| `probe-watch-check.sh` | yes | per-test mktemp_state registry with trap cleanup; no live writes |
| `probe-watch-digest.sh` | yes | per-test mktemp_state registry with trap cleanup; no live writes |
| `probe-worktree-bash-guard.sh` | yes | hook subshell test with synthetic stdin; no real writes (write-attempt strings are blocked by hook before execution) |
| `probe-worktree-write-guard.sh` | yes | hook subshell test with synthetic stdin; assertions on hook exit code only |
| `probe-write-cache.sh` | yes | mktemp HOME isolation; cache writes contained in $TMPHOME/.cache/dhx |
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
