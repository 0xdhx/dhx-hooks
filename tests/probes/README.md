# tests/probes/

Probe scripts that back the **"Probe evidence"** pointers in `docs/decisions.md` and the closed rows in `docs/backlog.md`.

## Convention

A **probe** is a one-shot validator written alongside a decision to prove that the implementation does what the decision says it does. Once committed, a probe becomes a **regression test**: it ran green when the code was written, and a future regression will flip assertions to red.

Naming: `probe-<subject>.{sh,js}`. Use whichever language the subject lives in (probes for Node code → `.js`, probes for bash hooks → `.sh`). Mixed-surface probes pick the language that exercises the composition point.

Top-of-file comment should state:
1. What invariant / behavior this probe exercises.
2. Which `docs/decisions.md` row or architectural invariant it backs.
3. How to run it (`node tests/probes/probe-foo.js` or `bash tests/probes/probe-foo.sh`).

Output: one line per assertion with `OK ` / `FAIL` prefix, ending with a `N passed, M failed` summary. Exit non-zero on any failure so CI can gate on the run.

## Stdout-detachment for D-state-capable syscalls

Any probe invoking `sync`, `fsync`, `dd`, or a syscall that can enter uninterruptible kernel sleep (D state) **MUST redirect stdout, not just stderr**: `>/dev/null 2>&1`, never `2>/dev/null` alone.

**Failure mode** (observed 2026-05-15 — see `docs/decisions.md` 2026-05-15 sync-fd-leak row and commits `16b129d` / `cc932a6`): two probes ran `sync 2>/dev/null` inside a pre-commit hook whose stdout was piped to `tail -20` via the `git commit … | tail -20` wrapper. Under multi-CC-session I/O pressure, `sync` entered D state. The probe's `timeout 30` killed the probe process, but the orphaned `sync` (PPID=1, **unkillable** — D state ignores SIGKILL) survived holding fd 1 on the inherited pipe. `tail` blocked forever waiting for EOF; each commit retry seeded another orphan; 4 accumulated before diagnosis.

**Rule:**

- Don't use `sync` / `fsync` in probes unless you can prove it's load-bearing. `wait $PID` ensures writer subprocesses exited; POSIX read-after-write within the same OS makes subsequent reads see those writes regardless of disk flush.
- If a D-state-capable syscall IS load-bearing: `cmd >/dev/null 2>&1` minimum. **`timeout` does NOT bound wall time on D-state processes** — SIGTERM is queued but ignored; `timeout`'s `wait` blocks on actual exit, not signal dispatch.
- Diagnostic recipe when `git commit … | tail -N` hangs without output: `readlink /proc/<tail_pid>/fd/0` reveals the pipe inode; iterating `/proc/*/fd/*` for that inode lists every writer-side holder.

## Integration probes

A probe is an **integration probe** when it exercises the composition of multiple code paths that are architecturally independent but share a runtime invariant. These surface UX/timing issues that per-chunk probes can't.

Worked example: `probe-sym-health-override.js` — tests the interaction of `readHealthCache()` consuming both `health.json` (written by `dhx-health-check.sh` at SessionStart) and `sym-health.json` (written by skills-repo `/dhx:sym`). Each cache's writer was correct in isolation, but the UX asymmetry (60s drift refresh vs SessionStart-only plugin-keys) only surfaced when both paths ran together against fixture caches — and that observation triggered the chunk-2 scope evolution (`ee02180`).

If you find yourself writing a probe that exercises two or more components' outputs together — write it as an integration probe, and flag future plans to consider the latency/composition shape of adjacent work.

## Supersession-watchdog probes

A probe is a **supersession-watchdog probe** when it asserts the negative premise that an upstream-CC behavior has NOT changed — i.e., the probe answers "is our scoped work still warranted, or has upstream shipped a fix that supersedes it?" Exit 0 = premise holds (work warranted). Exit non-zero = supersession found, scope shrinks.

**Distinct from** regression probes (which assert "still works" — green is good) and integration probes (which exercise composition). Supersession-watchdog probes assert "still needed" — exit 0 is the GOOD news that work warranted; exit non-zero is the GOOD news that work can be cancelled.

**Lifecycle:**
- **Authored** alongside a v1.x feature scope where the scope's premise rests on a current-CC behavior that may shift upstream.
- **Re-run** on every CC version bump (manual or via future `health.sh` opt-in mode) until upstream supersession actually occurs.
- **Retired** by a follow-up `docs/decisions.md` row when supersession is observed (move to `tests/probes/.inactive/` per HP-probe convention).

**Cross-version cadence (v1.3+):** outcome JSON files land at `tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/` (e.g., `v1.3-multi-cc-ver/2.1.140/`). The outcome JSON `cc_version` field — populated live from `claude --version` at probe-run time, NOT a literal — is the cross-version comparison key. v1.3+ ops re-run probes and append to `tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/` without code edits. (v1.2 baseline cells live at `tests/probes/.results/v1.2-phase-{0,6}/` per the Phase 3/Phase 6 layout that authored them.)

**Header tag convention (Phase 3 onward):** supersession-watchdog probes carry two top-of-file tags as supplementary fields in the existing comment block:
- `# SAFE_FOR_LIVE: yes|no` — `yes` if the probe is read-only against live state (e.g., file-gated wrapper edit); `no` if it requires sandbox isolation (e.g., subprocess invocation against `CLAUDE_CONFIG_DIR=$mktemp_d`).
- `# RUNTIME: ~Ns` — order-of-magnitude wallclock budget; informs operator scheduling.

These tags are a **supersession-watchdog convention only** — regression and integration probes do NOT need them retroactively.

**"Arm the probe" gesture (D-16/D-17 convention; live-capture-style probes):**

When a supersession-watchdog probe needs to capture data from a long-running CC process (e.g., the statusline-wrapper), an **env-var-gated handshake is impossible** — environment variables do not propagate from a probe-shell parent to an already-running CC subprocess (verified across 4 CC mechanisms; statusline `env` field, hooks reference, `CLAUDE_ENV_FILE`, `CLAUDECODE`). The canonical alternative is a **fixed-path file-presence convention**:

- The probe (and its wrapper edit, if any) reads from a fixed path under `${XDG_RUNTIME_DIR:-/tmp}/<probe-slug>/`.
- The wrapper checks `fs.existsSync(<dir>/flag)` on every invocation; the gate is no-op when the directory is absent.
- The probe arms live-capture mode by `mkdir -p` of the fixed dir, writes the run_id into the flag file content (D-32 — env vars don't propagate sideways to wrapper subprocesses), waits for the wrapper to write a run-id-stamped capture file, then trap-cleans.
- The probe ALSO uses directory presence as a **mode discriminator**: dir present → live-capture; dir absent → fixtures-only-mode + exit 0 (the `bash scripts/run-probes.sh` integration path).

`probe-effort-level-stdin-absent.sh` is the reference implementation of this convention.

**Current supersession-watchdog probes:**

| Probe | Backs | Run |
|-------|-------|-----|
| `probe-effort-level-stdin-absent.sh` | decisions.md 2026-04-30 supersession-watchdog row + REQ PROBE-01 | `mkdir -p ${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe && bash tests/probes/probe-effort-level-stdin-absent.sh` |
| `probe-installed-plugins-no-natural-heal.sh` | decisions.md 2026-04-30 supersession-watchdog row + REQ PROBE-02 + HP-025 | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-installed-plugins-no-natural-heal.sh` |
| `probe-installed-plugins-badjson-natural-heal.sh` | decisions.md 2026-05-03 Phase 6 C1 + REQ HEAL-07 + HP-025 | Operator-invoked; `ANTHROPIC_API_KEY` only (no key → clean `skipped`; OAuth credentials_file unsafe — 2026-05-24) |
| `probe-installed-plugins-uninstalled-dhx-natural-heal.sh` | decisions.md 2026-05-03 Phase 6 C1 + REQ HEAL-07 + HP-025 | Operator-invoked; `ANTHROPIC_API_KEY` only (no key → clean `skipped`) |
| `probe-known-marketplaces-natural-heal.sh` | decisions.md 2026-05-03 Phase 6 C1 + REQ HEAL-07 + HP-025 (km path) + 2026-09-15 pre-launch row (rewrite: per-state natural heal + heal-then-launch acceptance against the real binary) | `bash tests/probes/probe-known-marketplaces-natural-heal.sh` — no API key needed; also run detached once per installed CC version by `dhx/dhx-km-acceptance.sh` (`--acceptance-out`) |

**Cross-version corpus state (per-probe × per-CC-version):**

| Probe | CC 2.1.121 (v1.2 baseline) | CC 2.1.140 (v1.3 Phase 15) | CC 2.1.145 (v1.3 Phase 18) | CC 2.1.148 (v1.4 Phase 19) | CC 2.1.150 (v1.4 — live 2026-05-26) |
|-------|---------------------------|---------------------------|---------------------------|---------------------------|-------------------------------------|
| `probe-effort-level-stdin-absent.sh` | `supersession_found_drop_p3` (`v1.2-phase-0/`) | `supersession_found_drop_p3` (`v1.3-multi-cc-ver/2.1.140/`) | — (not re-run) | — (not re-run) | — (not re-run; no-key probe, not in the 2026-05-26 live batch) |
| `probe-installed-plugins-no-natural-heal.sh` | `supersession_found_drop_heal` (`v1.2-phase-0/`) | `v1_2_work_warranted` (`v1.3-multi-cc-ver/2.1.140/`) — **flipped** | — (not re-run) | `ambiguous` — `cell_outcome=auth_failure`; Cell 2 needs `ANTHROPIC_API_KEY` (unset) (`v1.3-multi-cc-ver/2.1.148/`) | `v1_2_work_warranted` — `cell_outcome=clean_no_heal`; decisively authed via `ANTHROPIC_API_KEY` (no 2.1.148-style `auth_failure`) (`v1.3-multi-cc-ver/2.1.150/`) |
| `probe-installed-plugins-badjson-natural-heal.sh` | `supersession_found_drop_heal` (`v1.2-phase-6/`) | `ambiguous` (`v1.3-multi-cc-ver/2.1.140/`) — stale-anchor probe-fragility | `v1_2_work_warranted` — `cell_outcome=badjson_no_heal` (`v1.3-multi-cc-ver/2.1.145/`) | `ambiguous` — substantive `cell_outcome=badjson_no_heal` (work warranted); conclusion `ambiguous` only because 2.1.148 not in the probe's stale `cc_version` allow-list (`v1.3-multi-cc-ver/2.1.148/`) | `v1_2_work_warranted` — `cell_outcome=badjson_no_heal`, `confidence=HIGH` (`v1.3-multi-cc-ver/2.1.150/`) |
| `probe-installed-plugins-uninstalled-dhx-natural-heal.sh` | `supersession_found_drop_heal` (`v1.2-phase-6/`) | `ambiguous` (`v1.3-multi-cc-ver/2.1.140/`) — stale-anchor probe-fragility | `v1_2_work_warranted` (`v1.3-multi-cc-ver/2.1.145/`) | `ambiguous` — substantive `cell_outcome=uninstalled_hn_heals` (Hn() rehydrated dhx + preserved fakes — a HEAL signal); conclusion `ambiguous` only because 2.1.148 not in the probe's stale `cc_version` allow-list (`v1.3-multi-cc-ver/2.1.148/`) | `supersession_found_drop_heal` — `cell_outcome=uninstalled_hn_heals` (Hn() rehydrated dhx + preserved fakes), `confidence=HIGH` (`v1.3-multi-cc-ver/2.1.150/`) |
| `probe-known-marketplaces-natural-heal.sh` | `v1_2_work_warranted` (`v1.2-phase-6/`) | `v1_2_work_warranted` (`v1.3-multi-cc-ver/2.1.140/`) | `v1_2_work_warranted` — `cell_outcome=km_no_heal` (`v1.3-multi-cc-ver/2.1.145/`) | `ambiguous` — substantive `cell_outcome=km_no_heal` (work warranted — km path NOT healed); conclusion `ambiguous` only because 2.1.148 not in the probe's stale `cc_version` allow-list (`v1.3-multi-cc-ver/2.1.148/`) | `v1_2_work_warranted` — `cell_outcome=km_no_heal`, `confidence=HIGH` (`v1.3-multi-cc-ver/2.1.150/`) |

> **Note on the 2.1.148 `ambiguous` conclusions (Phase 19 re-run) — HISTORICAL, allow-list RETIRED 2026-05-26:** for the three IP-/km-path probes the probe-level `conclusion` was `ambiguous` *only* because each probe used to hardcode a `cc_version` allow-list (`2.1.121 2.1.140 2.1.145`) that was never lifted to include `2.1.148` (`cc_version_match=false` → `confidence=LOW`). The **substantive observation** (`cell_outcome`) ran cleanly against a real `claude -p` subprocess and is the load-bearing evidence: `badjson_no_heal` + `km_no_heal` (work warranted) and `uninstalled_hn_heals` (a natural-heal signal). **As of 2026-05-26 (quick task 260525-xav) the allow-list is RETIRED:** the probes no longer downgrade to `ambiguous`/`LOW` on a version-list miss — `conclusion`/`confidence` now derive from `.observations.cell_outcome`, and `cc_version_match` is a non-gating informational corpus-membership signal. The historical 2.1.148 cells above retain their `conclusion: ambiguous` as the recorded pre-retirement artifact (they are NOT re-run/overwritten by this promotion — the corpus is immutable evidence); a future re-run at any CC version would instead record the decisive `cell_outcome`-derived conclusion directly. The companion path-side relocation refactor (`OUT_DIR` off the immutable baseline — brief `2026-05-13-watchdog-probe-out-dir-cc-version-aware.md`) remains out of scope. The `no-natural-heal` cell is `auth_failure`/`ambiguous` (D-18c) because its still-active two-cell design strictly requires `ANTHROPIC_API_KEY` for Cell 2 and the run shell had only a `credentials_file`. **Auth contract corrected 2026-05-24 (watchdog-probe auth hardening):** all four IP-/km-path probes (and the read-guard tripwire) now gate on `ANTHROPIC_API_KEY` **only** — the OAuth `credentials_file` seeding path was removed as UNSAFE (a sandboxed `claude -p` rotates the refresh token and invalidates the SOURCE credential; measured AUTH_OK→401). So the 2.1.148-style "run shell had only a `credentials_file`" scenario now yields a fast clean `skipped` (`cell_outcome=skipped_no_api_key`, exit 2) instead of seeding — never an unsafe copy, never a false-PASS. See `docs/decisions.md` 2026-05-24 watchdog-probe-auth-hardening row.

**Promotion threshold (probe-corpus governance convention — this README is its canonical home; multi-cell matrix *shape* per the SCHEMA-04 precedent):** at ≥3 distinct CC versions per probe, promote to full multi-cell matrix. **N≥3 promotion threshold MET — promotion EXECUTED 2026-05-26** (quick task 260525-xav; `docs/decisions.md` 2026-05-26 row closes the row-220 retirement gate). The IP-path probes + the km control each span 2.1.121 / 2.1.140 / 2.1.145 / 2.1.148 (`-no-natural-heal.sh` spans 2.1.121 / 2.1.140 / 2.1.148); the per-(cc_version) result cells under `tests/probes/.results/v1.3-multi-cc-ver/<ver>/` (+ the `v1.2-phase-6` baseline) are now THE source of truth for each probe's `conclusion`/`confidence`, and the hardcoded cc-version allow-list has been RETIRED from all 3 supersession-watchdog probes (`conclusion`/`confidence` now derive from `.observations.cell_outcome`; `cc_version_match` is a non-gating informational corpus-membership signal). Trigger row: `docs/decisions.md` 2026-05-13 (titled "HP-024 promotion trigger for supersession-watchdog corpus" *there* — see naming note below); promotion-executed row: `docs/decisions.md` 2026-05-26.

> **Naming note (canonical, 2026-05-26):** pre-2026-05-26 artifacts call this the **"HP-024 N≥3 threshold"** — a numbering slip. **HP-024 is the unrelated Notification-events runtime pattern** (`docs/hook-patterns.md`). The N≥3 corpus-promotion threshold and the supersession-watchdog re-run trigger are **probe-corpus governance rules** (our test methodology), not verified CC runtime behaviors — so this README is their canonical home and HP entries merely *cite* them. The dated `docs/decisions.md` 2026-05-13 trigger row, the Phase 19 plan set, `.planning/STATE.md`/`MILESTONES.md`, and the `docs/prompts/done/` artifacts retain the old "HP-024" label as the **unchanged dated record**; only forward-looking live references were corrected.

> **2.1.150 column (added 2026-05-26):** first corpus growth *after* the `OUT_DIR` relocation (quick task `260526-10r`), and the first column written entirely under the RETIRED allow-list — all four live-run cells carry decisive `cell_outcome`-derived conclusions (no version-miss `ambiguous`), and the `no-natural-heal` two-cell probe authed cleanly via `ANTHROPIC_API_KEY` (contrast the 2.1.148 `auth_failure`). The run mutated zero v1.2 baselines (relocation verified under live load — `git diff` clean, all 5 baseline SHA-256 byte-identical). `uninstalled_hn_heals` is now unanimous across the corpus (v1.2 baseline + 2.1.140/2.1.145/2.1.148/2.1.150) — corroborating the **D-04 version-conditional posture** (operator recovery via `/dhx:sym repair`, shipped Phase 19), NOT a new retire-the-heal trigger.

## Schema-evolution probes

A probe is a **schema-evolution probe** when it answers "should we migrate this data shape?" — i.e., the probe enforces an invariant in current code and would surface as exit non-zero IF the code's data schema regressed. Distinct from supersession-watchdog (which asks "is upstream still broken?") and integration probes (which exercise composition).

**Lifecycle:**
- **Authored** alongside a v1.x scope where the question "should we migrate the schema?" needs an empirical answer.
- **Re-run** at each milestone close to detect regression OR validate that the migration is needed.
- **Retired** when the migration ships (REFUTE → close as not-needed; PASS → schedule v1.x impl phase).

**Header tag convention:** schema-evolution probes carry `# SAFE_FOR_LIVE: yes` (read-only against live state by design — they SCAN, they don't mutate). Per D-24 strengthened parity test, every probe in `tests/probes/*.sh` MUST carry the `# SAFE_FOR_LIVE:` header (yes or no); missing headers fail the parity test.

**Soft-verdict semantics (SCHEMA-02 pattern):** observation-only probes emit per-cell JSONL verdicts; aggregator computes HIGH/MED/LOW consensus per SCHEMA-05. HIGH gate required for irreversible decisions. Anything other than HIGH defaults to REFUTE preserving the existing branch. Per D-18a (cross-AI review), verdicts derive from CC's structured event stream (`claude -p --output-format stream-json --include-hook-events --verbose`), NOT from file content.

**Multi-cell matrix protocol (SCHEMA-04):** when the probe needs cross-axis evidence, follow the SCHEMA-04 multi-cell precedent: full cross-product (e.g., 3 instances × 3 modes × 2 sessions = 18 main cells) + 2 negative-control cells running as a PRE-FLIGHT GATE (D-18f). Pre-register protocol in phase CONTEXT.md before any cell runs. Aggregator threshold is dynamic (D-18c): `main_cells = total - 2`; HIGH = 100% main rejected; MED = ≥80%; LOW otherwise; INVALID = control failure.

**Current schema-evolution probes:**

| Probe | Backs | Run |
|-------|-------|-----|
| `probe-read-cache-d17-invariant.sh` | decisions.md 2026-05-03 SCHEMA-01 row + REQ READ-FUT-01 | `bash tests/probes/probe-read-cache-d17-invariant.sh` (~1s) |
| `probe-read-guard-strong-signal.sh` | decisions.md 2026-05-03 SCHEMA-02 row + REQ READ-FUT-02 + 20-cell aggregator | `bash tests/probes/probe-read-guard-strong-signal.sh` (operator-invoked; ~9-15min wallclock; DOES NOT fit inside `run-probes.sh` 30s/probe budget — invoke directly) |

## Version-gated behavior probes

A probe is a **version-gated behavior probe** when it asserts a *per-CC-version* EXPECTED result — the asserted cell's expectation is keyed on the running `claude --version` (via a `ver_ge` semver gate) and **flips at a known version boundary**. Convention B: **exit 0 = pass** (observed == version-expected); exit non-zero = the observed behavior CONTRADICTS the version's expectation (changelog claim false, or behavior regressed → revisit the backing memory/decisions row). Distinct from supersession-watchdog (which asserts the *negative* premise "upstream has NOT changed") — a version-gated probe asserts a **positive, version-conditional** expectation that is *supposed* to change at the boundary, and pins the exact version where it does.

**Lifecycle:**
- **Authored** with a pre-change baseline result on the old binary + a version-gated assertion that flips at the boundary CC version.
- **Re-run** after the boundary upgrade lands, recording a new per-version result under `tests/probes/.results/<area>/<cc-version>/outcome.json`; the dual corpus (pre-boundary BLOCK / post-boundary ALLOW) is the evidence.
- **Auth/method:** the canonical path drives a *sandboxed* `claude -p` (needs `ANTHROPIC_API_KEY`). **This machine HAS one** — `~/.env-keys` (0600); a session reporting it unset is holding a stale launch-env snapshot (`dhx-keys status` → `STALE-restart`), and `set -a; . ~/.env-keys; set +a` in the invoking shell is enough for a subprocess. Do not conclude "no key" from an env check. Genuinely key-less machines have **two no-key fallbacks**: (1) the **in-session-live** method that produced the pre-change baseline (you ARE an authenticated session) — but it can only observe tools the *current* session actually has; (2) a **live-dir `claude -p` child** — spawn `CLAUDE_CONFIG_DIR=<live-instance> claude -p …` WITHOUT a sandbox: it auths via the live OAuth and exposes the FULL classic toolset. Use (2) when the session itself is trimmed and lacks the tool under test (e.g. the native `Grep` tool is absent from interactive deferred-tools sessions — this is how the 2026-06-03 Grep-tool boundary was closed with no API key). **Do NOT seed OAuth creds into a *sandbox* dir** — that rotates the refresh token into a throwaway dir and invalidates the source (2026-05-24 watchdog-auth-hardening row). A live-dir child writes the rotated token back to the live dir, so it is safe — identical to a normal concurrent session (tradeoff: non-isolated — it runs real hooks + writes the real transcript).

**Header tag convention:** carries `# SAFE_FOR_LIVE: no` when it spawns `claude -p` subprocesses — kept out of the default `run-probes.sh` suite; operator-invoked directly.

**Current version-gated behavior probes:**

| Probe | Backs | Boundary | Run |
|-------|-------|----------|-----|
| `probe-grep-satisfies-read-before-edit.sh` | decisions.md 2026-06-03 single-file-grep read-before-edit satisfier row + read-guard memory (`reference-cc-native-read-block-vs-dhx-advisory`) | CC **2.1.160**: single-file bash `grep`/`egrep`/`fgrep` satisfies read-state. Corpus `2.1.159` BLOCK → `2.1.161` ALLOW (`.results/grep-read-state/<ver>/`). Open boundaries: multi-file grep pinned BLOCK (2026-06-03); Grep *tool* → **BLOCK** (does NOT satisfy — closed 2026-06-03 via a live-dir `claude -p` child; only bash `grep` COMMANDS satisfy, not CC's Grep tool). NUANCE: the satisfier matches the **literal** file-arg string — an unexpanded `$VAR` in the grep path does NOT satisfy; use a resolved abs path. | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-grep-satisfies-read-before-edit.sh` (operator-invoked; `SAFE_FOR_LIVE: no`) |

## Current probes

| Probe | Backs | Run |
|-------|-------|-----|
| `probe-settings-hash.js` | decisions.md 2026-04-16 drift settings_hash row | `node tests/probes/probe-settings-hash.js` |
| `probe-migration.js` | same row (graceful schema migration) | `node tests/probes/probe-migration.js` |
| `probe-plugin-keys.sh` | decisions.md 2026-04-16 plugin-keys row (direct jq-check + sym-health.json fast-path) | `bash tests/probes/probe-plugin-keys.sh` |
| `probe-health-suffix.js` | decisions.md 2026-04-16 actionable-hints row (one-trailing-suffix format) | `node tests/probes/probe-health-suffix.js` |
| `probe-sym-health-override.js` | decisions.md 2026-04-17 sym-health.json consumer + critical/advisory split rows | `node tests/probes/probe-sym-health-override.js` |
| `probe-settings-path-invariant.sh` | architecture.md § Settings file chain (cross-language canonical resolution) | `bash tests/probes/probe-settings-path-invariant.sh` |
| `probe-bashrc-wrapper-heal.sh` | decisions.md 2026-04-17 plugin-keys load-gating + bashrc auto-heal row | `bash tests/probes/probe-bashrc-wrapper-heal.sh` |
| `probe-cache-age-anchor.js` | decisions.md 2026-04-17 statusline cache-age JSONL anchor row + HP-019 | `node tests/probes/probe-cache-age-anchor.js` |
| `probe-stale-hooks-filter-retired.js` | decisions.md 2026-04-18 stale-hooks-filter retirement row | `node tests/probes/probe-stale-hooks-filter-retired.js` |
| `probe-gsd-update-cache-name-resolves.js` | decisions.md 2026-06-05 gsd-update cache-name row (renderer resolves the package-namespaced cache filename via package-identity, not a hardcoded generic) | `node tests/probes/probe-gsd-update-cache-name-resolves.js` |
| `probe-drift-detection.js` | decisions.md 2026-04-18 drift-detection audit row (companion to probe-settings-hash.js + probe-migration.js) | `node tests/probes/probe-drift-detection.js` |
| `probe-drift-cleanup.sh` | decisions.md 2026-04-19 drift-cache orphan-sweep row (dhx-health-check.sh) | `bash tests/probes/probe-drift-cleanup.sh` |
| `probe-deferred-check-req-id-regex.sh` | decisions.md 2026-04-20 deferred-check D-NN false-positive row | `bash tests/probes/probe-deferred-check-req-id-regex.sh` |
| `probe-deferred-check-header-fallback.sh` | decisions.md 2026-04-23 header-fallback h3 overmatch row | `bash tests/probes/probe-deferred-check-header-fallback.sh` |
| `probe-deferred-check-canonical-classifier.sh` | decisions.md 2026-04-27 cross-repo classifier sync row (sister probe to skills-repo `probe-classifier-cross-repo.sh`) | `bash tests/probes/probe-deferred-check-canonical-classifier.sh` |
| `probe-gsd-fork-aware-drift.sh` | quick task 260425-oeg fork-aware gsd suppression | `bash tests/probes/probe-gsd-fork-aware-drift.sh` |
| `probe-statusline-self-diag.js` | decisions.md 2026-04-26 statusline self-diag row | `node tests/probes/probe-statusline-self-diag.js` |
| `probe-hooks-wiring.sh` | decisions.md 2026-04-26 hooks-wiring canary row | `bash tests/probes/probe-hooks-wiring.sh` |
| `probe-last-prompt-segment.js` | docs/statusline-wrapper.md § "Last user prompt segment" (2026-04-27 statusline session item 1) | `node tests/probes/probe-last-prompt-segment.js` |
| `probe-execute-stop-review.sh` | decisions.md 2026-04-28 SIGPIPE+pipefail audit round-2 row (HP-028 lines 39 / 53 transcript-scan regression) | `bash tests/probes/probe-execute-stop-review.sh` |
| `probe-sigpipe-pipefail-shapes.sh` | decisions.md 2026-04-28 SIGPIPE+pipefail static lint row (HP-028 enforced invariant — at-rest scan paired with verify-hook-patterns.sh check #5) | `bash tests/probes/probe-sigpipe-pipefail-shapes.sh` |
| `probe-backlog-frontmatter-gate.sh` | decisions.md 2026-05-22 backlog-frontmatter-gate enrollment row + INFRA-05 (gate structure + composition with verify-hook-patterns via the run-parts dispatcher; behavioral block/pass in a throwaway mktemp repo) | `bash tests/probes/probe-backlog-frontmatter-gate.sh` |
| `probe-cc-snooze.js` | decisions.md 2026-05-31 cc-warning-snooze row + docs/statusline-wrapper.md § Snooze (parse / round-trip / expiry / perma / fail-open / formatRemaining + renderer dim-collapse integration) | `node tests/probes/probe-cc-snooze.js` |
| `probe-pkg-install-filter.sh` | decisions.md 2026-05-31 package-install output-reducer row + HP-040 + HP-041 (summarizer keep/collapse/drop + rewriter candidate/bypass + hybrid end-to-end: success compaction, failure byte-identical passthrough, exit-code preservation) | `bash tests/probes/probe-pkg-install-filter.sh` |
| `probe-updatedinput-producer-disjointness.sh` | decisions.md 2026-08-23 producer-disjointness row + HP-041 multi-producer completion-order property (enumerates PreToolUse:Bash hooks from the plugin manifest at runtime; fails if any one command draws an `updatedInput` rewrite from two producers; liveness assertion refuses a vacuous green) | `bash tests/probes/probe-updatedinput-producer-disjointness.sh` |
| `probe-cc-version-guard-wiring.sh` | decisions.md 2026-06-02 cc-version-guard SessionStart wiring row (dispatcher invokes the cross-repo guard via the `~/.claude/dhx-tools/` indirection behind `[ -e ]`/`< /dev/null`/`|| true`, NOT a direct `~/repos/cross-repo/` path; behavioral smoke T1-T4 via override seams) | `bash tests/probes/probe-cc-version-guard-wiring.sh` |
| `probe-session-start-child-failure-surface.sh` | decisions.md 2026-09-14 child-failure first-sight surface row (`_dhx_child`: first-sight two-line surface + per-label signature, repeat-silent, changed-message re-surface, success-clears, empty-stderr, stdin passthrough, wiring greps, no-digest-tool fail-open) | `bash tests/probes/probe-session-start-child-failure-surface.sh` |
| `probe-prelaunch-wiring.sh` | decisions.md 2026-09-15 pre-launch row (claude-capped.sh and clodex-bridge call `dhx-prelaunch.sh` before launch, bounded and stdin-less; processWrapper → bridge; through the real wrappers the registry is repaired before a fake binary starts, argv and stdin intact; fail-open on a hanging or missing child; no stdout) | `bash tests/probes/probe-prelaunch-wiring.sh` |
| `probe-km-acceptance-trigger.sh` | decisions.md 2026-09-15 pre-launch row (`dhx-km-acceptance.sh`: once-per-CC-version detached acceptance run, stored pass silent, stored fail surfaced once, in-flight marker and stale takeover, error result for a dead probe, dispatcher wiring after registry-heal) | `bash tests/probes/probe-km-acceptance-trigger.sh` |
| `probe-dashboard-notify-wiring.sh` | decisions.md 2026-06-04 dhx-dashboard vitals **correction** row (badge=shell precmd not a hook; banner=`systemMessage` SessionStart hook `dhx-vitals-banner.sh` registered in hooks.json, dead dispatch line removed; behavioral smoke asserts `notify` emits valid JSON `.systemMessage`, carries NO OSC/SetUserVar escape, is labeled-distinct from the digest's "Action required" inbox, and is silent-when-0) | `bash tests/probes/probe-dashboard-notify-wiring.sh` |
| `probe-statemd-phase-line-lint.js` | decisions.md 2026-06-25 STATE.md phase-line lint row (`dhx-statemd-phase-line-lint.js` warns ONLY on a genuine first-paren-≠-`current_phase_name` mismatch at aligned phase numbers; convention-zoo PASS shapes + WARN/SUPPRESSED pair + dual-channel e2e + mirror-drift vs live gsd-core) | `node tests/probes/probe-statemd-phase-line-lint.js` |
| `probe-inception-posture.sh` | decisions.md 2026-07-09 dhx-inception-posture row (UserPromptSubmit build-posture injection fires ONLY on `/gsd-new-project`/`/gsd-new-milestone`, silent otherwise; reads `.prompt` not the `.user_prompt` routing bug; carries #1 runtime + #3 gated-commercial principles) | `bash tests/probes/probe-inception-posture.sh` |
| `probe-routing.sh` | decisions.md 2026-07-09 dhx-routing `.user_prompt`→`.prompt` fix row (regression guard: routing FIRES on a real `.prompt` payload across all routed GSD commands / redirect-vs-calibration mode / silent otherwise — the coverage gap that hid a 3-month silent no-op) | `bash tests/probes/probe-routing.sh` |
| `probe-dirty-tree-attribution-gate.sh` | decisions.md 2026-07-28 dirty-tree attribution enrichment row + 2026-07-30 degrade-voice row (allowlist gate: non-allowlisted repo = byte-identical bare line + zero helper invocations; TRANSIENT degrades stay silent and byte-identical — absent / hung / malformed / `--version`-rc-nonzero / zero-byte; PERMANENT degrades emit bare count + exactly one factual line — exit-3 canary, protocol mismatch, over-cap payload; payload replaces bare line, `--repo`+`--self` argv; wording guard: no banned action verb / relative-age token) | `bash tests/probes/probe-dirty-tree-attribution-gate.sh` |
| `probe-hermetic-tier-green-token.sh` | decisions.md 2026-09-14 hermetic-tier green-token row (check #8a: a green tier run writes a token keyed on HEAD + candidate tree + forced worktree snapshot + git config/hooks; identical rerun hits and is not re-run; staged change, worktree-only edit, `info/exclude`-hidden probe and hooks-dir change all re-run; a red writes nothing; a `DHX_RED_COMMIT=1` green writes and hits; TTL expiry and `DHX_PROBE_TIER_TTL=0`/`off` force; real index untouched; one mutation control — constant snapshot term wrongly hits) | `bash tests/probes/probe-hermetic-tier-green-token.sh` |
| `probe-deletion-audit-leaf.sh` | decisions.md 2026-09-14 binding-deletion-audit port row (first-sight refusal with raw `-U0` patch + column-0 `DHX-DELETION-AUDIT-FIRST-SIGHT parent=<sha>` sentinel; unchanged rerun proceeds; changed candidate re-surfaced; truncation withholds the sentinel but not the token; firing record shape; two mutation controls — oracle and sentinel) | `bash tests/probes/probe-deletion-audit-leaf.sh` |
| `probe-watch-digest-scan.sh` | decisions.md 2026-09-14 watch-digest single-jq-pass row (the original `probe-watch-digest.sh` scaffold is left byte-identical — the brief's AC-2 names it as the unmodified instrument; exact stdout bytes + `digest_corrupt` count + pointer write for every digest row class on a 12-line negative-control fixture; pointer-compare boundaries — equality, leading zeros both sides, pointer+1, int64 max, pointer 0; six garbage-id shapes corrupt vs null-ish silent; unterminated valid/invalid tails invisible until completed; `PATH`-stubbed failing `jq` stays loud; D-11 block order with a fixtured watchlist. Against the pre-change script it fails exactly S4.a, the recorded `"123\n"` divergence) | `bash tests/probes/probe-watch-digest-scan.sh` |

## Running all probes

```bash
for p in tests/probes/probe-*.{js,sh}; do
  case "$p" in
    *.js) node "$p" ;;
    *.sh) bash "$p" ;;
  esac
  echo "---"
done
```

Exit code propagates from each probe; a red run exits non-zero.
