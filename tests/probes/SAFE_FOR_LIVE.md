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
| `probe-assessed-guard-position-anchoring.sh` | yes | hook subshell with synthetic stdin against mktemp fixture CONTEXT.md files; the review-marker exception cell writes/removes a `/tmp` marker keyed to the fixture cwd's md5 (cannot collide with a live session cwd hash); no live repo, `.planning/`, or config writes (2026-07-07 CL-H.assessed-guard position-anchoring probe) |
| `probe-backlog-frontmatter-gate.sh` | yes | structural checks are read-only grep/readlink against in-repo files; behavioral block/pass cells run entirely inside a throwaway mktemp git repo (copies the dispatcher + 10- leaf + validator, installs a sandbox symlink); never mutates the live repo index, history, or `.git/hooks` (260522-ib4 backlog-frontmatter-gate convention enrollment probe) |
| `probe-backlog-vocab-check.sh` | yes | fixture-only mktemp repo (`.planning/MILESTONES.md` + `STATE.md` + a few briefs across top-level and terminal subdirs); stdin-simulated JSON to the hook; reads live `~/.claude/dhx-tools/backlog-regen.cjs` via `--check` against the throwaway tree but never touches the live `.planning/` directory (2026-05-27 backlog `target_milestone` value-enum write-time advisory probe) |
| `probe-bashrc-wrapper-heal.sh` | yes | grep-only against live `~/.bashrc` and in-repo files; no writes |
| `probe-cache-age-anchor.js` | yes | re-implements function locally; tmp-file fixtures only |
| `probe-cc-check-update-ttl.sh` | yes | mktemp cache dir + `CC_CHECK_UPDATE_CACHE` env-override injects a fixture cache; never reads or writes live `~/.cache/cc` (Phase 17 RAT-06 TTL-gate regression probe) |
| `probe-cc-check-update-worker.sh` | yes | stubbed `npm`/`claude` on a tmp PATH + `CC_CACHE_FILE` override points the worker at a fixture cache; no network, never reads or writes live `~/.cache/cc` (RAT-06b installed_at_check + RAT-06c max_published capture probe) |
| `probe-cc-novel-patterns.sh` | yes | mktemp fixture trees + `node -e require` of the live wrapper with explicit fixture-root arg; scenario 5 drives `checkDrift` under HOME + CLAUDE_CONFIG_DIR overrides; never reads live `~/.claude` or `~/.cache/dhx` (Phase 17 RAT-04 D-13a/D-15/D-22 enumeration regression probe) |
| `probe-cc-residual-signal.sh` | yes | mktemp fixture tree + `node -e require` of the live wrapper (`scanRecursive` + `hashWarnSettings`) with explicit fixture paths; fixture mtimes set via `fs.utimesSync`; never reads live `~/.claude` or `~/.cache/dhx` (Phase 17 RAT-01 D-01 residual-signal demonstration probe) |
| `probe-cc-snooze.js` | yes | sets `process.env.HOME` to a `mkdtempSync` throwaway dir before `require`ing `scripts/lib/cc-snooze.js`, so the module's snooze file + the renderer-integration child (`HOME=tmp`, explicit `DISABLE_AUTOUPDATER=1`, seeded fixture `cc-update-check.json`) resolve entirely inside the temp tree; never reads or writes the operator's live `~/.cache/dhx` (2026-05-31 cc-warning-snooze probe) |
| `probe-cc-version-guard-wiring.sh` | yes | read-only grep of the in-repo dispatcher (`dhx-plugin/.../session-start.sh`) for the cc-version-guard wiring; conditional behavioral smoke runs the guard with `CC_PINNED_VERSION_FILE`/`CC_BIN_LINK`/`CC_VERSIONS_DIR` seams pointed at a `mktemp` sandbox; never reads or writes live `~/.local/bin/claude` or `~/.ccs/shared/cc-pinned-version` (2026-06-02 cc-version-guard SessionStart wiring probe) |
| `probe-claude-md-link-check.sh` | yes | mktemp fake `$HOME` per case + HOME/CLAUDE_CONFIG_DIR override; runs the real `dhx-health-check.sh` across four `~/.claude/CLAUDE.md` states (intact symlink / regular file / missing / wrong target); the script's only writes/rm land under the fake `$HOME/.cache/dhx`; never touches live `$HOME` (2026-06-15 config-symlink integrity producer probe) |
| `probe-dashboard-notify-wiring.sh` | yes | read-only grep of in-repo hooks.json / banner script / dispatcher for the vitals-banner wiring; conditional behavioral smoke runs `dhx-dashboard.cjs notify`/`count`, which only READ feeds + write a JSON {systemMessage} to stdout (no file writes — `render` is the separate writer); output to a `mktemp` dir; never mutates live state (2026-06-04 dhx-dashboard vitals banner wiring probe) |
| `probe-deferred-check-canonical-classifier.sh` | yes | static grep + sourcing test against in-repo classifier; mktemp fixture for source-test |
| `probe-deferred-check-header-fallback.sh` | yes | static sed-pattern equality + read-only repo-file inspection |
| `probe-deferred-check-req-id-regex.sh` | yes | regex-equality static check against hook source; no writes |
| `probe-dhx-statusline.js` | yes | re-implements helpers via require; no FS writes outside whatever the renderer does internally on tmp paths |
| `probe-draft-buffer-gate-key-parity.sh` | yes | mktemp sandbox HOME + a dhx-shared symlink + DHX_DRAFT_BUFFER_DIR/DHX_BACKUP_META overrides; drives the buffer (resolver-keyed write) + gate (stdin-keyed read) against fixtures; resolver unit checks via $CLAUDE_CODE_SESSION_ID + SI_SESSION_PIDFILE seam; SKIPs when the skills resolver lib is unmounted; never reads/writes live ~/.cache/dhx/ or ~/.claude/ (2026-06-13 current-session-stamp retirement: buffer↔gate marker-key source parity) |
| `probe-session-id-env-stdin-parity.sh` | yes | LIVE-OBSERVER, read-only: reads $CLAUDE_CODE_SESSION_ID + the shared session-identity resolver + ~/.claude/dhx-session-registry.tsv (real UserPromptSubmit-captured stdin .session_id) + the /proc-resolved pid-file; asserts env↔stdin↔pid-file equality inside a live session, SKIPs cleanly (exit 0) in CI / fresh session / non-Linux; the bridged leg fires only on a real bridged session (pid-file .bridgeSessionId present); never writes (2026-07-15 real-bridged-session capture — live-observer companion to probe-draft-buffer-gate-key-parity.sh, pinning the CC-internal env==stdin equality that probe defers) |
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
| `probe-gh-issue-write.sh` | yes | hook subshell with synthetic stdin; `CLAUDE_CONFIG_DIR` redirected to a mktemp dir so the `.upstream-marker-<session>` read/write lands on a fixture, never live `~/.claude/dhx-tools`; the hooks.json rename-contract check is a read-only jq predicate; no repo/config/git writes (2026-07-10 gh-issue-write soft-deny generalize+JSON-surface probe) |
| `probe-git-destructive-guard.sh` | yes | hook subshell test with synthetic stdin; no real git invocations — force-push command strings are blocked by the hook before any shell execution (2026-05-25 dhx-git-destructive-guard PreToolUse:Bash backstop for +refspec / -C / --git-dir / -c k=v / bundled short-cluster syntactic bypasses HP-037 cannot catch) |
| `probe-grep-satisfies-read-before-edit.sh` | no | spawns `claude -p` subprocesses against a sandbox CLAUDE_CONFIG_DIR + mktemp out-of-band targets; version-gated behavior probe (companion to `probe-read-guard-native-enforcement-tripwire.sh`) asserting a single-file bash grep satisfies CC's native read-before-edit check on >=2.1.160 (BLOCK <2.1.160); operator-invoked, requires `ANTHROPIC_API_KEY` (no key → clean `skipped`; OAuth credentials_file unsafe — see probe header + 2026-05-24 decisions row) |
| `probe-gsd-canonical-mirror-gate-tiered-outcome.sh` | yes | mktemp + env-overrides DHX_DRAFT_BUFFER_DIR + DHX_BACKUP_META; fixture marker dir + backup-meta; never touches the live dhx cache or live gsd-local-patches (Phase 16 REQ-DRIFT-ACTION-03 tiered-outcome probe) |
| `probe-gsd-fork-aware-drift.sh` | yes | mktemp + node -e require with explicit liveRoot/forkRoot args; never reads live `~/.claude` |
| `probe-gsd-hook-version-mirrors-runtime.sh` | yes | grep-only against in-repo `dhx/statusline-wrapper.js` (marker + inline anti-hand-bump guard) + read-only `cat` of live `~/.claude/gsd-core/VERSION`; skips the mirror assertion when gsd-core absent; no writes (2026-06-15 gsd-hook-version marker mirrors gsd-core VERSION — a reconciliation stamp, not a wrapper-content version) |
| `probe-gsd-roots-resolve.sh` | yes | grep-only against in-repo `dhx/statusline-wrapper.js` + `dhx/dhx-health-check.sh` for the gsd-runtime path literals + read-only `[[ -d ]]` existence checks on live `~/.claude/gsd-core` + fork mirror; no writes (2026-06-05 gsd-core 1.3.1 rename — hooks follow-ups: source path constants must track the live gsd dir name) |
| `probe-gsd-update-cache-name-resolves.js` | yes | per-case mktemp HOME + `CLAUDE_CONFIG_DIR` override; package-identity stub + fixture caches live only under the temp dir; child-spawn render is read-only; live `~/.cache` + `~/.claude` never written (2026-06-05 gsd-update cache-name — renderer must resolve the package-namespaced cache filename, not a hardcoded generic) |
| `probe-health-check-session-id-rm-safety.sh` | yes | static grep of in-repo `dhx/dhx-health-check.sh` + allowlist-regex primitive + integration over a mktemp cache dir; never touches `$HOME` or the live cache (Phase 20 WR-01 session_id rm-glob safety) |
| `probe-health-sh-no-side-effects.sh` | no | mktemp + fake HOME; full env-var isolation (Wave 2 tag preserved) |
| `probe-health-sh-tiering.sh` | no | mktemp + fake HOME; uses stub-leaf-tool fixtures (Wave 2 tag preserved) |
| `probe-health-suffix.js` | yes | uses `_make-fake-home` (mktemp + HOME override per spawn); fully sandboxed |
| `probe-hooks-wiring.sh` | yes | mktemp + full env-var override (HOME, DHX_HOOKS_MANIFEST, DHX_HOOKS_REPO_ROOT, DHX_HOOKS_INSTALL_DIR); never touches live repo |
| `probe-inception-posture.sh` | yes | read-only grep over in-repo hooks.json + hook source, plus fixture-JSON piped to the hook subshell (hook only reads stdin, writes JSON to stdout); no file, cache, or config writes (2026-07-09 dhx-inception-posture build-posture-injection probe) |
| `probe-install-plugin-idempotency.sh` | no | mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology (Wave 1 tag preserved) |
| `probe-install-plugin-multi-instance.sh` | no | mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology (Wave 1 tag preserved) |
| `probe-installed-plugins-badjson-natural-heal.sh` | no | sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess (Phase 6 C1 BADJSON branch supersession probe — D-07a) |
| `probe-installed-plugins-no-natural-heal.sh` | no | requires `ANTHROPIC_API_KEY`; runs real `claude` subprocess (supersession-watchdog) |
| `probe-installed-plugins-uninstalled-dhx-natural-heal.sh` | no | sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess (Phase 6 C1 UNINSTALLED:dhx@dhx-local branch supersession probe — D-07b) |
| `probe-known-marketplaces-natural-heal.sh` | no | sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess (Phase 6 C1 km mini-probe — D-11 HEAL-07) |
| `probe-first-prompt-segment.js` | yes | re-implements function locally; tmp-file fixtures only |
| `probe-memory-scope-guard.sh` | yes | hook subshell with synthetic stdin against mktemp fixture paths only (a fake `.ccs/…/memory/` tree under `mktemp -d`); no live repo, config, or memory-store writes (2026-07-08 memory-scope-guard write-time front-stop probe) |
| `probe-migration.js` | yes | re-implemented compare core; tmp-file fixtures via os.tmpdir |
| `probe-milestone-close-blocker-check.sh` | yes | mktemp + isolated subprocess invocation of hook with HOME=$TMP; no live `~/.cache/dhx`, `~/.claude`, or git state touched (mirrors `probe-execute-stop-review.sh` precedent) |
| `probe-milestone-close-blocker-pretooluse.sh` | yes | mktemp + isolated subprocess invocation of hook with HOME=$TMP + PreToolUse:Skill stdin payload (tool_input.skill=gsd-complete-milestone); no live `~/.cache/dhx`, `~/.claude`, or git state touched (Plan 13-03 Shape B regression probe; mirrors Plan 13-01 probe shape adapted for HP-009 PreToolUse exit-2 semantics) |
| `probe-milestone-close-vocab-parity.sh` | yes | static grep + awk against in-repo hook + canonical `~/.claude/dhx-tools/backlog-regen.cjs`; soft-skips with WARN if dhx-tools absent; no writes, no subprocess invocation of CC |
| `probe-new-milestone-promote-reminder.sh` | yes | mktemp dirs passed as `cwd` in hook stdin JSON; hook reads only via cwd; no HOME mutation |
| `probe-phase-10-doc-contracts.sh` | yes | read-only token-presence grep against committed `docs/hook-patterns.md`, `docs/decisions.md`, `.planning/REQUIREMENTS.md`; no subprocesses, no writes, no env mutation (Phase 10 Nyquist gap-fill 2026-05-13 — HEAL-07-06 + HEAL-07-07 doc-contract regression probe) |
| `probe-enumerate-novel-patterns.js` | yes | mkdtempSync fixture trees + `require()` of the live wrapper with an explicit fixture-root arg; no live `~/.claude` or `~/.cache/dhx` access (Phase 17 RAT-04 D-20 enumeration-helper export probe) |
| `probe-pkg-install-filter.sh` | yes | fixtures-on-stdin to the summarizer + JSON-payload to the rewriter (read-only); end-to-end runs the rewritten wrapper against a fake `npm`/`pip` on a mktemp PATH catting mktemp fixture files; never invokes a real package manager, never touches the network or live `~/.cache`/`~/.claude`/git state (2026-05-31 package-install output-reducer regression probe) |
| `probe-plugin-cache-allowlist.js` | yes | pure-unit: `require()`s `scripts/lib/plugin-cache-allowlist.js` + asserts the predicate/structure; no fs, no subprocess, no live mutation (Phase 17 RAT-04 D-06/D-14 allowlist probe) |
| `probe-plugin-keys.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; live read of settings is jq -e only |
| `probe-plugin-registry-heal.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/` |
| `probe-plugin-cache-staleness.sh` | yes | mktemp + fake HOME + env-var override (DHX_CACHE_STALENESS_LIVE_MANIFEST, DHX_CACHE_STALENESS_CACHE_ROOT); never touches live `~/.claude/plugins/cache/dhx-local` or live `dhx-plugin/` manifest |
| `probe-plugin-registry.sh` | yes | mktemp tmpdir-as-config; HOME=$cfg/cache-dhx-home; never mutates live registry |
| `probe-pytest-cgroup-cap.sh` | yes | PATH stub satisfies `dhx_cgroup_available()` so only the rewritten command STRING is asserted (never executed); fixtures + stub bins under a per-run mktemp; no real systemd-run, no live `~/.cache/dhx`/`~/.claude`/user-systemd touched (2026-06-30 DHX-7 mid-session pytest cgroup-cap deterministic probe) |
| `probe-pytest-cgroup-cap-e2e.sh` | no | executes real `systemd-run --user --scope` to OOM-kill a memory-hungry faked pytest (cap-fires 137 + exit-code preservation); transient scope units self-clean under live user@.service; fixtures under mktemp; host-gated soft-skip when the memory controller is undelegated (2026-06-30 DHX-7 cap-fires e2e probe; mirrors `probe-test-gate-cgroup.sh`) |
| `probe-read-cache.sh` | yes | mktemp HOME isolation; session-scoped partial-detect store writes contained in $TMPHOME/.cache/dhx (Option C collapse — partial-detection writer) |
| `probe-read-dedup.sh` | yes | mktemp cache+data via `DHX_READ_DEDUP_STATE_DIR` + `DHX_READ_DEDUP_DATA_DIR` env-overrides (D-20), injected in lockstep across every sub-sandbox; V-STATS-ROTATE additionally sets `DHX_READ_DEDUP_STATS_MAX_BYTES` and its `.jsonl.1` backup lands only under $SBX/data; all state/stats writes contained in $SBX (sibling `cache`/`data` subdirs); never reads or writes live `~/.cache/dhx`, `~/.local/share/dhx`, or Boucle's `~/.claude/read-once` (read-once restoration BUILD — Phase 1 log-only hook; STATS relocated to XDG_DATA_HOME 2026-06-09, V-DURABLE-SPLIT wipes only its own mktemp cache) |
| `probe-read-guard-partial-detection.sh` | yes | mktemp HOME isolation; guard reads a seeded session-scoped detect store + emits NOTE; reads/writes confined to $TMPHOME/.cache/dhx (Option C collapse) |
| `probe-read-guard-native-enforcement-tripwire.sh` | no | spawns `claude -p` subprocesses against a sandbox CLAUDE_CONFIG_DIR + mktemp out-of-band targets; supersession-watchdog asserting CC still hard-blocks unread Edit/Write (Option C Q3); operator-invoked, requires `ANTHROPIC_API_KEY` (a sandboxed `claude -p` is logged out, and seeding an OAuth credentials_file is unsafe — see the probe header AUTH note + 2026-05-24 decisions row) |
| `probe-repair-installed-plugins.sh` | yes | mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/`; no claude subprocess, no auth, no network; fixture-only — no live registry mutation (Phase 19 SYM-REPAIR D-10/D-15 repair-action probe; SC2 empirical anchor) |
| `probe-restart-plugins-stop-hook.sh` | yes | mktemp + HOME=$TMP per scenario; transcript fixtures synthesized in $TMP |
| `probe-roadmap-verification-gate.sh` | yes | each case builds a throwaway `mktemp` `.planning/` tree (ROADMAP.md + phase dirs ± VERIFICATION.md) and pipes a synthetic PreToolUse Write/Edit envelope at the hook; the hook only READS that fixture tree + the fixture `file_path` it is handed — never the live repo, the live `.planning/`, or `~/.claude` (2026-06-18 ROADMAP-[x]→VERIFICATION.md verifier-spawn gate behavioral probe) |
| `probe-run-probes-convention-a.sh` | yes | per-case mktemp REPO-shaped sandbox; copies `scripts/run-probes.sh` into the tmp tree + plants one fake probe + fixture outcome JSON; never touches the live repo, `~/.claude`, or `~/.cache/dhx` (quick-260526-1qm Convention-A FAIL-gating regression probe) |
| `probe-routing.sh` | yes | read-only grep over in-repo hooks.json + hook source, plus fixture-JSON piped to the hook subshell (hook only reads stdin, writes JSON to stdout); no file, cache, or config writes (2026-07-09 dhx-routing `.user_prompt`→`.prompt` regression-guard probe) |
| `probe-sandbox-escape-allow.sh` | yes | read-only: fixture-JSON piped to the hook subshell (reads stdin, writes JSON to stdout) + greps over in-repo hook source and plugin hooks.json; no file, cache, or config writes (2026-07-13 dhx-sandbox-escape-allow shape-allowlist probe) |
| `probe-session-registry.sh` | yes | drives all three registry hooks (start/end + the 2026-06-09 UserPromptSubmit backfill) under a `mktemp` `$HOME` (rows land in the throwaway `$T/.claude/`, never the live registry) + a PATH `tmux` stub (no live tmux server); reads nothing live (2026-06-08 alive-session-recovery registry producer probe; backfill assertions added 2026-06-09; 2026-06-15 pane-walk + kill-switch via an arg-aware stub whose `list-panes` emits the probe's own pid as a `/proc`-ancestor `pane_pid` — still no live tmux/registry touch) |
| `probe-settings-hash.js` | yes | reads `~/.ccs/shared/settings.json` read-only as seed; writes only to `/tmp/probe-settings-*.json` fixtures (predictable paths, no live mutation) |
| `probe-skill-desc-audit.sh` | yes | worker + chain script driven entirely through env seams (`DHX_SKILL_DESC_{COLLECTOR,STATE,EXEMPTIONS,NOW}`, `DHX_SKILL_DESC_WORKER`) pointed at a mktemp sandbox — stub collector, fixture state/registry, frozen clock; never reads or writes live `~/.claude/dhx-tools/` or `config/skill-desc-exemptions.json` (2026-07-17 skill-desc delta auditor probe) |
| `probe-settings-path-invariant.sh` | yes | readlink + stat read-only against live settings chain; no writes |
| `probe-sigpipe-pipefail-shapes.sh` | yes | static lint grepping in-repo `dhx/*.sh` for pipeline shapes; no writes |
| `probe-skill-pressure.js` | yes | mkdtempSync tmp `reports/skills/*/actionable/` fixtures; the fixture-injection scenario reads the skills-repo `tests/fixtures/actionable/` by path (read-only); no live writes (Phase 24 PRESSURE-06 cross-repo skill-pressure agreement probe) |
| `probe-stale-hooks-filter-retired.js` | yes | read-only assertions against repo-tracked source files |
| `probe-stale-worktree-sweep.sh` | yes | mktemp + fake worktree state; never operates on live worktrees |
| `probe-subagent-stop-sync.sh` | yes | arming-mode writes only to `${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe/` (per-process scratch); fixtures-only mode is read-only when probe dir absent (BG-AGENT-2 / Phase 9 sync+bg SubagentStop verification probe; mirrors `probe-effort-level-stdin-absent.sh` D-32 / SCHEMA-04 file-gated convention) |
| `probe-statemd-phase-line-lint.js` | yes | `require`s the hook module + writes STATE.md fixtures only under an `mkdtempSync` dir (removed on exit); reads `~/.claude/gsd-core/bin/lib/{phase-id,state,state-document,frontmatter}.cjs` READ-ONLY for the per-module mirror-drift pins (widened 2026-07-16) and SKIPs them cleanly when gsd-core is absent; never mutates live state (2026-06-25 STATE.md Current-Position phase-line ↔ `current_phase_name` consistency warn-lint probe) |
| `probe-statusline-load.js` | yes | child-spawn renderer invocation via --require shim (Phase 5 D-03 regression baseline); child stdout captured via stdio:'pipe'; renderer's bridge-file write lands at `/tmp/claude-ctx-probe-load.json` (predictable path, conventional fixture per probe-settings-hash.js heuristic note) |
| `probe-statusline-roadmap-progress.js` | yes | re-implements parseRoadmapProgress + readGsdState via require; all fixtures under a mktemp dir removed on exit; never writes live `.planning/` or any path outside tmp (2026-06-18 ROADMAP-table milestone-count derive probe) |
| `probe-statusline-self-diag.js` | yes | mktemp HOME + `process.env.HOME` override per subtest; appendFile lands under temp HOME only |
| `probe-statusline-wrapper.js` | yes | pure require + helper function tests; no FS writes |
| `probe-statusline-wsl-pressure.js` | yes | `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per spawn); plants `wsl-pressure-trip.flag` under the tmp `.local/state/wsl-stack/` + an optional fleet feed under the tmp `.cache/dhx/`; never touches live `~/.local/state/wsl-stack` or `~/.cache/dhx` (2026-06-15 wsl-pressure statusline alarm consumer render probe; mirrors `probe-fleet-statusline-render.js`) |
| `probe-statusline-wsl-probe-broken.js` | yes | `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per spawn); plants `wsl-pressure-broken.flag` (+ optional `wsl-pressure-trip.flag` / fleet feed) under the tmp `.local/state/wsl-stack/` + `.cache/dhx/`; never touches live `~/.local/state/wsl-stack` or `~/.cache/dhx` (2026-06-15 wsl-pressure probe-broken dead-monitor render probe; structural twin of `probe-statusline-wsl-pressure.js`) |
| `probe-sym-health-override.js` | yes | mkdtempSync; tmp-file fixtures only |
| `probe-test-gate-cgroup.sh` | no | invokes real `systemd-run --user --scope` to enforce cgroup MemoryMax / RuntimeMaxSec on subprocesses; HOME / TMPDIR / CLAUDE_PROJECT_DIR all override to per-scenario mktemp dir, but the transient systemd-run scope units land under live user@.service (self-cleanup on exit; not config drift) |
| `probe-test-gate-host-preconditions.sh` | yes | 2-tier read-only capability check — Tier 1 grep on `cgroup.controllers` for delegated `memory` controller; Tier 2 `systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 -p RuntimeMaxSec=60s true` dry-run inside a transient scope unit that self-cleans on exit. No persistent FS writes, no live ~/.cache/dhx or ~/.claude touched (2026-05-19 Phase 14 TEST-GATE-07 host-precondition probe; D-11 2-tier shape) |
| `probe-test-gate-phase-aware.sh` | yes | mktemp + HOME / TMPDIR / CLAUDE_PROJECT_DIR overrides; per-fixture `git init` confines git state to the sandbox; runner is a stub `python` that records argv (no real pytest); no live writes (2026-05-07 phase-aware skip regression probe) |
| `probe-test-gate-subdir-layout.sh` | yes | mktemp + HOME / TMPDIR / CLAUDE_PROJECT_DIR overrides; runner is a stub `python` recording argv + cwd (no systemd-run, no cgroup, no real pytest); no live writes (2026-05-29 subdir/monorepo runner-anchoring regression probe; 8 scenarios / 25 assertions) |
| `probe-tiers-parity.sh` | yes | read-only grep + jq parse over repo files; no live mutation (Wave 2 tag preserved) |
| `probe-triad-duration-enrichment.sh` | yes | mktemp + env-overrides DHX_DRIFT_CACHE + DHX_TRIAD_LIVE_ROOT + DHX_TRIAD_CANONICAL_ROOT + DHX_TRIAD_BACKUP_META; fixtures the live+canonical fork-tree pair (deliberate divergence) AND the backup-meta files[] list; never reads live `~/.claude`, the live backup-meta, or the live dhx drift cache (Phase 16 REQ-DRIFT-ACTION-06 enrichment probe; D-32; meta-fixture added 2026-06-08 for fork-retirement isolation) |
| `probe-triad-empty-files-retired.sh` | yes | mktemp + DHX_TRIAD_BACKUP_META override; fixtures empty / corrupt / missing-key meta shapes; never reads live `~/.claude` or the live backup-meta (2026-06-08 empty-vs-corrupt files[] classification probe — empty files[] → informational exit 0, corrupt/missing → ERROR exit 1) |
| `probe-ui-vision-guard-locked-gate.sh` | yes | hook subshell with synthetic stdin, cwd'd into per-scenario mktemp fixture trees carrying their own `CLAUDE.md` project-root marker; the hook's z-gsdui scaffold writes land under the fixture's `.claude/skills/`; no live repo, `.planning/`, or config writes (2026-07-07 CL-H.ui-vision-guard zero-locked-rows exit-guard probe) |
| `probe-v1-1-1-gate.sh` | yes | read-only: git log + stat + pgrep + ps + jq -e against settings.json + bash scripts/verify-hooks.sh (also read-only); 8 env-var overrides for companion-test injection (DHX_PROBE_*); no FS writes (Phase 7 LEGACY closure doctrine artifact) |
| `probe-verify-drift-gate.sh` | yes | mktemp HOME isolation; cd $TMP so `.planning/` + `docs/decisions.md` resolution targets the sandbox; no live `.planning/`, decisions.md, or manifest writes (scenario 6 reads the manifest only) |
| `probe-verify-hooks-worktree.sh` | yes | mktemp tmproot + fake HOME; sandboxed git repo + worktree contained in $TMPROOT; no live `~/.claude/hooks/` or `.git/worktrees/` writes |
| `probe-watch-action-render.js` | yes | mktemp watch dir fixtures `watchlist.json`; spawns the banner (`dhx-watch-digest.sh`) with `DHX_WATCH_DIR` pointed at the fixture + `DHX_WATCH_HEALTH_CACHE` at a nonexistent path; reads only the fixture, never live `~/repos/cross-repo/watch` or `~/.cache/dhx/` (2026-05-28 watch action-required banner-consumer render probe) |
| `probe-watch-check.sh` | yes | per-test mktemp_state registry with trap cleanup; no live writes |
| `probe-watch-digest.sh` | yes | per-test mktemp_state registry with trap cleanup; no live writes |
| `probe-watch-health-render.js` | yes | `_make-fake-home` (mktemp + HOME override per spawn) fixtures `dhx-watch-health.json`; spawns the banner (`dhx-watch-digest.sh`, `DHX_WATCH_DIR` pointed at a nonexistent dir) + the statusline wrapper under the fake `$HOME`; never reads or writes live `~/.cache/dhx/` (2026-05-28 watch-health cache consumer render probe) |
| `probe-worktree-bash-guard.sh` | yes | hook subshell test with synthetic stdin; no real writes (write-attempt strings are blocked by hook before execution) |
| `probe-worktree-guard-adversarial.test.js` | yes | node:test spawns the bash + write guards in a bash subshell against synthetic stdin; write-attempt command strings are blocked by the hook before any shell execution — no real writes (Phase 43 D-02/D-06/D-10/D-14 adversarial scope + deny-contract suite) |
| `probe-worktree-guard-settings-scan.sh` | yes | read-only grep over live settings.json/settings.local.json hooks blocks for the four guard basenames; no mutation (Phase 43 D-04c/D-13 static double-fire assertion) |
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
| `probe-grep-satisfies-read-before-edit.sh` | ~90-180s | `ANTHROPIC_API_KEY` **only** (no key → clean `skipped`; OAuth credentials_file unsafe — 2026-05-24) | mktemp + `CLAUDE_CONFIG_DIR=$SANDBOX` + out-of-band `printf` targets | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-grep-satisfies-read-before-edit.sh` (version-gated behavior probe — exit 0+pass = single-file grep read-state matches the CC-version expectation [BLOCK <2.1.160 / ALLOW >=2.1.160]; exit 1 = changelog claim contradicted/regressed; exit 0+skipped = inconclusive/no auth) |

**Routing via `--probes-unsafe`:** `bash scripts/run-probes.sh --probes-unsafe`
delegates to `--filter SAFE_FOR_LIVE=no` and runs all four probes (plus any
other `no`-tagged probes). Refused if `PWD` or `CLAUDE_CONFIG_DIR` resolves
under `~/.ccs` (D-27 sandboxing gate). Direct `bash <probe>` invocation
bypasses the wrapper entirely — preferred for long-runtime probes that
exceed the 30s/probe budget.

**Outcome consumption:**
- Heal probes: per-cell outcome JSON at `tests/probes/.results/v1.2-phase-6/<probe>.json`. Convention A exit semantics (0/1/2 all valid).
- SCHEMA-02 probe: per-cell verdicts at `tests/probes/.results/v1.2-phase-6/schema-02-verdicts.jsonl`. exit 0 unconditional per D-03 / SCHEMA-03; consumers MUST grep `classification=` from stdout (HIGH/MEDIUM/LOW/INVALID per D-18c + WR-03 zero-cell guard) — exit-status alone hides INVALID. Mapping: HIGH → READ-FUT-02-IMPL trigger; everything else → REFUTE-default per SCHEMA-05 (READ-FUT-02 closes as not-needed).
