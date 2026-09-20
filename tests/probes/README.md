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

## Liveness guards for absence and equality assertions

An assertion that tests for the **absence** of a token, or the **equality** of two reads, is satisfied by a harness that produced **nothing**. Both report OK in precisely the situation where they can tell you least: the binary under test never ran.

**Failure mode** (found 2026-09-15 by `probe-health-lane-scoping.sh` auditing its own assertions, after the close-gate reviewer separately found that a recorded negative-control recipe could not red the assertion it named). Two cases in that file:

- an absence case rendered the statusline and grepped for a token, failing only when one was **present** — so a missing wrapper, a dead node spawn, or a `$WRAPPER` resolving outside the repo left an empty render that contained no token, and the assertion held;
- an equality case compared a helper's before/after output, where the helper echoed `ABSENT` for a file that was not there — so against a producer that wrote no file at all the comparison was `ABSENT == ABSENT`.

Both were confirmed by replacing the producer with `/bin/true`: of twenty-one assertions, those two were the **only** ones that still claimed success.

**Rule:**

- **Prove the subject ran before judging what it produced.** Capture the rc and require non-empty output, then branch — and report a dead harness as a `PROBE ERROR`, never as a satisfied assertion. `probe-health-lane-scoping.sh`'s `render_live()` is the reference shape.
- **Compare against a literal, not against another read of the same surface**, wherever the fixture makes the expected value knowable. `chk … "$got" "undefined"` cannot pass on an empty read; `chk … "$after" "$before"` can. Where the self-comparison is the thing being asserted, anchor the before-value on a literal first.
- **A sentinel like `ABSENT` is a value, not an error.** Any helper that substitutes one for a missing file has made its callers' equality checks vacuous by default; guard at each call site, or return a distinguishable rc.
- **Negative controls are the test of the test.** An assertion that stays green when the surface it covers is broken is decoration. Run each new assertion against a deliberately broken subject and record which one reddened — that recording is the artifact, and it has caught an assertion authored so that both sides read the same value and it passed its own control.

## A guard has two layers, and either can be a spelling

The section above says run a negative control. This one is the gap *past* it: on **2026-09-17 three
guard assertions in this repo were found hollow on the same day, every one of them green, every one
with a passing positive control, and not one caught by its own author.** They failed in two distinct
places, and the negative control each author had actually run could not reach either.

**The tooth** is the assertion that fires when the guarded thing is wrong. **The net** is whatever
decides which things the tooth is applied to. Both are code, both can be an enumeration or a
spelling, and a hollow net is worse than a hollow tooth — an unguarded case does not fail, it is
never looked at.

The three measured cases:

| | layer | what was asserted | what slipped through |
|---|---|---|---|
| `probe-hermetic-tier-no-tree-writes.sh` | tooth | the discriminator *mentions* `DHX_PROBE_HERMETIC` | an **inverted** guard (`== "0"`) — the token is still on the line, so the grep still matched |
| `probe-drift-detection.js` [19e] | tooth | a hardcoded list of bystander filenames survives the sweep | an unanchored `/\.log/` instead of `/\.log(\.1)?$/` — no name in the list carried both the `drift-debug-` prefix and a non-terminal `.log`, so it passed **all ten** arms |
| `probe-hermetic-tier-no-tree-writes.sh` | net | discovery via `grep -l 'PROBE_DIR="${XDG_RUNTIME_DIR'` | the brace-free `$XDG_RUNTIME_DIR` form — an ordinary way to write it, and the probe was **invisible**, not uncaught |

**Rule — three checkable questions, asked of the assertion, not of the subject:**

- **Would an INVERTED guard pass this, not just a deleted one?** Deletion is the mutation everyone
  reaches for and the easiest to catch. Inversion keeps every token, symbol and structure in place
  and changes only the sense. If the assertion greps for a name, inversion beats it by construction.
  Assert the **behaviour the guard produces** — that the subject *says* it ignored the latch, that
  the predicate *deleted exactly this set* — never that the guard's vocabulary is present.
- **What decides the set this is applied to, and is that a mechanism or a spelling?** Net on the
  thing that cannot be avoided (you cannot build the latch without referencing `XDG_RUNTIME_DIR`;
  you cannot match a filename without a prefix and a suffix), then require each candidate to
  classify itself. **Fail closed:** a candidate with no discriminator is a red for a human to
  triage, never a silent pass. Going fail-closed cost almost nothing in both repairs — the
  populations were four probes and two predicate dimensions.
- **If a new instance were added tomorrow, spelled differently, would it be RED or INVISIBLE?** A
  `COUNT >= 1` check on a discovery net only catches *total* discovery failure; two of three
  matching leaves the third unguarded and green. Prefer a generated set (cross-product the
  dimensions) or an asserted count over a list someone must remember to extend.

**Two disciplines for the mutation run itself**, both of which caught something the same day:

- **Assert each mutant differs from the base by exactly one hunk** before reading any result, and
  **re-run that assertion over the WHOLE set every time the base moves** — not just for the mutants
  you added. This failed twice in one session. First: a table built from mutants generated at
  different times attributed one arm's catch to seven mutations it had nothing to do with. Then,
  after the rule was written down, adding a feature and rebuilding only the three NEW mutants left
  the older nine stale against the new base, and they each carried two differences again. Both times
  the tell was the same impossible pattern — a mutation in one subsystem appearing to break an
  unrelated one (a sweeper-predicate mutation "breaking" rotation; a dedupe mutation "breaking" an
  archive round-trip). `diff` every mutant against a pristine base and print the hunk count as part
  of the run; do not trust your memory of which ones you regenerated.
- **Run the NULL mutant first.** An unmutated copy must come back fully green. A harness that
  *crashes* emits **no FAIL lines at all**, which reads identically to "every mutant survived" — a
  nine-row table of `*** SURVIVED ***` was printed from a harness with a JavaScript identifier
  collision, and only the NULL run distinguished the two.

**A red must describe itself correctly.** One repair initially emitted two failures for an
unclassified probe, the second reading "SAYS it ignored the latch" — an accurate outcome with a
misleading reason, since the subject was not a latch probe at all. A red that misnames its cause
sends the next investigation down the wrong path, which costs more than the silence did.

**The companion failure, and it is the one that caught three of these:** a positive control proves the
*instrument* works, not that you aimed it at the right condition. Both sessions cleared a live defect
that way on 2026-09-17 — one ran a genuine `head -c1` SIGPIPE control and concluded a sanitizer gate
was safe, having fed it the one payload shape that could not fire (it failed open, `0447556f`); the
other wrote a repro whose failure branch printed a conclusion the test never established, and was
right by luck. Write-up, with the discriminator table and the retired single-factor stories:
`~/repos/cross-repo/docs/research/2026-09-17-a-positive-control-proves-the-instrument-not-the-aim.md`
(`85f5cba68`).

Provenance: `docs/decisions.md` 2026-09-17 (the drift-debug row's `[19e2]` and corrected-mutant-table
paragraphs) and commits `df2bb624`, `5a507827`, `16ee63f7`, `0447556f`. The pattern was found by two sessions
each applying the other's unrelated finding to its own work — worth knowing, because in all three
cases the author's own suite could not surface it.

## A classifier's INPUT is a surface too

The section above says a guard has two layers — the tooth and the net — and that either can be
hollow. This is the layer *neither* of them inspects: **the string the tooth is applied to.**

**Measured 2026-09-18.** Three `probe-installed-plugins-*-natural-heal.sh` watchdogs reported
`timeout_124` on **every rc=0 cell, 3/3**. Nothing was wrong with their logic. Claude Code reads the
applicable `settings.json`, and for each rule it considers questionable it echoes that rule
**verbatim** to stderr. The operator's live settings carry `Bash(timeout * gh *)`, so the literal
word `timeout` arrived inside the same `2>&1` capture the classifier `grep -qiE 'timeout|deadline'`
then read. The tooth fired correctly on text that was never evidence about the child.

Three things make this its own failure class rather than a flaky regex:

- **The contaminating input is the operator's own configuration**, which is not where anyone looks
  for one. A probe author reasons about what the child under test prints. This text is not produced
  by the thing being tested — it arrives from outside the experiment, describing the machine.
- **It is silent in the direction that matters.** The forged verdict routed to a SKIP
  (`did not complete — inconclusive`). A forged FAIL gets investigated; a forged SKIP is a probe
  that has quietly stopped testing, and the suite stays green.
- **It had never fired before** because the cells had been exiting 127 at the wrapper since
  2026-08-07. Fixing the binary is what exposed it — a repair revealing a second, older defect.

**Rule — route the capture, then classify it.**

```bash
# shellcheck source=lib/cc-cell-stderr.sh
source "$(dirname "$0")/lib/cc-cell-stderr.sh"

raw=$(claude -p "$prompt" ... 2>&1 || true)
n=$(count_cc_config_advisories "$raw")           # so a cleaned noisy cell is
[ "$n" -gt 0 ] && echo "INFO $n advisory line(s) dropped" >&2   # distinguishable
strip_cc_config_advisories "$raw"                # from a genuinely clean one
```

Filter at the **single capture site** — inside the `drive()` helper, not at each classifier — so no
future cell can be added that classifies a raw stream. `lib/cc-cell-stderr.sh` drops only lines
describing the INPUT CONFIG (`Permission allow rule (…)`, `Permission deny rule (…)`) and the
sandbox's own missing-hook noise (`<Event> hook [...] failed:`). Real auth, network and timeout
failures are reported on their own lines and survive — `probe-cc-binary-resolution.sh` § 5 asserts
exactly that, with a positive control.

**Do NOT fix this by tightening the classifier.** Specificity is what makes
`probe-agent-registry-session-start-cached.sh`'s exposure zero today — its `AUTH_FAIL_RE` is eleven
specific multi-word phrases, and grepping the live settings for the whole alternation returns 0. It
is one settings edit from being wrong: a rule naming `Authorization`, `401` or `unauthorized`
reaches classifiers that look nothing like the `timeout` one. A fix that depends on nobody adding
such a rule is not a fix; it is the current accident, written down.

**Every file under `tests/probes/` that can reach a Claude Code binary carries exactly one tag.**
`probe-cc-stderr-classifier-net.sh` is the net and it **fails closed** — an untagged candidate is a
RED for a human to triage, never a silent pass:

| tag | meaning |
|---|---|
| `# CC-STDERR: filtered` | routes its capture through `lib/cc-cell-stderr.sh` before any regex touches it |
| `# CC-STDERR-EXEMPT: <why>` | a config echo cannot reach its classifier — stated as a claim **with its measurement** |
| `# CC-STDERR-UNMEASURED: <what>` | same mechanism, on a surface not yet measured; the count is pinned so a new one cannot merge untriaged |

The net is **deliberately over-inclusive**, because the obvious population — "probes matching
`claude -p`" — is a *spelling*, and the section above is about exactly that. Measured while building
it: that spelling **over-counts** (4 files match on a comment and spawn no child) and
**under-counts** (5 more reach a CC binary as `$CC_BIN`, `resolve-cc-binary` or `claude --version`
and match none of it). A false candidate costs one tag. A missed one is an unguarded classifier
nobody ever looks at.

An exemption is a **claim, not an opt-out**. `probe-read-guard-model-set-pin.sh`'s is the reference
shape: *the one CC invocation is `claude --version 2>/dev/null` — stderr is discarded at the call
site*. That is checkable. "This classifier is specific enough" is not, unless the grep that shows it
is in the comment.

**What the net cannot catch, stated rather than implied:** a `filtered` probe that calls the filter
and then **discards** the result. That inversion is invisible to static text — it is covered instead
by `probe-cc-binary-resolution.sh` § 5, which drives the filter's *behaviour* on a verbatim live
advisory. Section 5 of the net probe closes the other half from the live side: it crosses every
permission rule in the resolved `settings.json` against every classifier regex harvested from the
filtered probes, and asserts the filter drops the advisory for each match. Today that reports **3
live hazards, 3 defended** — the original `Bash(timeout * gh *)` finding, re-derived from the
machine on every run rather than remembered.

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

`probe-effort-level-stdin-absent.sh` is the reference implementation of this convention — the **arming gesture**, which is what this section describes, and which it still implements unchanged. It is **no longer a supersession watchdog** (inverted 2026-09-18, see below); the gesture and the exit-code convention are separate things, and only the latter changed. `probe-subagent-stop-sync.sh` is a second implementation of the same gesture.

**Current supersession-watchdog probes:**

| Probe | Backs | Run |
|-------|-------|-----|
| `probe-installed-plugins-no-natural-heal.sh` | decisions.md 2026-04-30 supersession-watchdog row + REQ PROBE-02 + HP-025 | `ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-installed-plugins-no-natural-heal.sh` |
| `probe-installed-plugins-badjson-natural-heal.sh` | decisions.md 2026-05-03 Phase 6 C1 + REQ HEAL-07 + HP-025 | Operator-invoked; `ANTHROPIC_API_KEY` only (no key → clean `skipped`; OAuth credentials_file unsafe — 2026-05-24) |
| `probe-installed-plugins-uninstalled-dhx-natural-heal.sh` | decisions.md 2026-05-03 Phase 6 C1 + REQ HEAL-07 + HP-025 | Operator-invoked; `ANTHROPIC_API_KEY` only (no key → clean `skipped`) |
| `probe-known-marketplaces-natural-heal.sh` | decisions.md 2026-05-03 Phase 6 C1 + REQ HEAL-07 + HP-025 (km path) + 2026-09-15 pre-launch row (rewrite: per-state natural heal + heal-then-launch acceptance against the real binary) | `bash tests/probes/probe-known-marketplaces-natural-heal.sh` — no API key needed; also run detached once per installed CC version by `dhx/dhx-km-acceptance.sh` (`--acceptance-out`) |

> **`probe-effort-level-stdin-absent.sh` left this family on 2026-09-18** and is deliberately absent from the table above. Its watchdog premise — that CC's stdin payload carries no `effort` key — died 2026-05-13, and it spent four months reporting that into `[SUPERSESSION OBSERVED]`, where nothing surfaces it. It is now a **Convention B** (`exit_0_means_pass`) regression guard asserting that the effort level CC publishes is one `EFFORT_RENDER` can actually render; on an absent level it emits `skipped` rather than a verdict, because one armed capture cannot separate a dropped key from a transient miss. Its rows in the corpus table below are the **unchanged historical record** and are not re-run or rewritten — the corpus is immutable evidence, and `supersession_found_drop_p3` is what those runs actually concluded. The new `regression_found_*` token it introduces is the shared taxonomy's first decisive-negative. See `docs/decisions.md` 2026-09-18.

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
| `probe-cc-stderr-classifier-net.sh` | decisions.md 2026-09-18 stderr-classifier-input row + § "A classifier's INPUT is a surface too" (fail-closed net: every file that can reach a CC binary carries exactly one `# CC-STDERR*` tag; § 5 crosses the live settings' permission rules against the classifier regexes harvested from the tree) | `bash tests/probes/probe-cc-stderr-classifier-net.sh` |
| `probe-empirical-arm-oracle.sh` | decisions.md 2026-09-19 "the D-01 arm needs credentials" row (the arm's verdict oracle in `lib/empirical-arm-classify.sh`: REFUTE needs ≥1 Stop-dispatch line; the credential gate; § 4 is the pre-fix rule as negative control) | `bash tests/probes/probe-empirical-arm-oracle.sh` |
| `probe-settings-hash.js` | decisions.md 2026-04-16 drift settings_hash row | `node tests/probes/probe-settings-hash.js` |
| `probe-migration.js` | same row (graceful schema migration) | `node tests/probes/probe-migration.js` |
| `probe-plugin-keys.sh` | decisions.md 2026-04-16 plugin-keys row (direct jq-check + sym-health.json fast-path) | `bash tests/probes/probe-plugin-keys.sh` |
| `probe-health-suffix.js` | decisions.md 2026-04-16 actionable-hints row (one-trailing-suffix format) + 2026-09-15 lane-scoping row (render half — `symlinks:?`, refused foreign stamp, no legacy leak) | `node tests/probes/probe-health-suffix.js` |
| `probe-health-lane-scoping.sh` | decisions.md 2026-09-15 health-cache lane-scoping row + 2026-09-16 plugin-keys lane-scoping row (producer half + the cross-lane contract + the bash/JS lane-id agreement invariant; cases `[4a]`-`[4d]` pin which fields sit in the shared object versus the per-lane sidecar, each absence assertion anchored on a live-producer value) | `bash tests/probes/probe-health-lane-scoping.sh` |
| `probe-sym-health-lane-stamp.sh` | decisions.md 2026-09-15 sym-health lane-stamp row + skills `DEC-2026-09-15-sym-health-lane-stamp` (the cross-repo `config_dir` stamp; both consumers refuse a foreign or unstamped verdict; the 60s post-repair clear survives for the repairing lane; publisher/hook/wrapper agreement over five spellings in both outcomes) + decisions.md 2026-09-16 plugin-keys lane-scoping row (case `[14]`: the stored verdict is per-lane, so one lane's SessionStart cannot overwrite another's — the reproduction that motivated the move, kept as an assertion) | `bash tests/probes/probe-sym-health-lane-stamp.sh` |
| `probe-symlink-target-check.sh` | decisions.md 2026-09-15 symlink-destination-check row (a link resolving to the wrong target is counted; branch order; ultimate-referent semantics; the renamed `symlinks:<N>` token) | `bash tests/probes/probe-symlink-target-check.sh` |
| `probe-sym-health-override.js` | decisions.md 2026-04-17 sym-health.json consumer + critical/advisory split rows | `node tests/probes/probe-sym-health-override.js` |
| `probe-settings-path-invariant.sh` | architecture.md § Settings file chain (cross-language canonical resolution) | `bash tests/probes/probe-settings-path-invariant.sh` |
| `probe-bashrc-wrapper-heal.sh` | decisions.md 2026-04-17 plugin-keys load-gating + bashrc auto-heal row, and the 2026-09-15 plugin-keys row (the heal has one home, `dhx-plugin-keys-heal.sh` run by `dhx-prelaunch.sh`; `.bashrc` keeps only its post-exit symlink repair; jq predicate parity across the heal, `dhx-health-check.sh`, `probe-plugin-keys.sh`, `install-plugin.sh`) | `bash tests/probes/probe-bashrc-wrapper-heal.sh` |
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
| `probe-cc-version-observer-wiring.sh` | decisions.md 2026-09-17 cc-version-observer SessionStart wiring row + the 2026-09-17 attendedness-gate row (dispatcher invokes the cross-repo observer via the `~/.claude/dhx-tools/` indirection behind `[ -e ]`/`< /dev/null`/`\|\| true`, under `_dhx_child`, with stdout NOT redirected — the notice is the deliverable; behavioral smoke T1-T9b via override seams, incl. T3b asserting the notice names a keyed brief and skips a decoy, **T6 the two-consumer cell** — an unattended daemon start neither emits nor stamps while the operator-facing start that follows still receives the notice, T7 the fail-open polarity, T8 eight concurrent attended consumers producing exactly one emission, T9/T9b stale-claim steal vs fresh-claim respect). T6 and T8 are the only cells that can adjudicate the 2026-09-17 fix — every other cell passes both before and after it. | `bash tests/probes/probe-cc-version-observer-wiring.sh` |
| `probe-session-start-child-failure-surface.sh` | decisions.md 2026-09-14 child-failure first-sight surface row (`_dhx_child`: first-sight two-line surface + per-label signature, repeat-silent, changed-message re-surface, success-clears, empty-stderr, stdin passthrough, wiring greps, no-digest-tool fail-open) | `bash tests/probes/probe-session-start-child-failure-surface.sh` |
| `probe-session-start-child-timing.sh` | decisions.md 2026-09-19 watch-digest residuals row, R2 (`_dhx_child` wall-time samples: `<epoch> <ms>` per run, log bounded 40→20; `_dhx_child_slow_check`: median of the last 10 vs the label's declared budget, first-sight two-line ⚠ surface + `<label>.slow` marker, re-arms when the median drops, one outlier cannot move it, <10 samples no verdict, unbudgeted labels silent, comma-locale `EPOCHREALTIME`, fail-open on an unwritable dir and when `_dhx_child` is sourced without the sampler, wiring: the check runs once after the last child) | `bash tests/probes/probe-session-start-child-timing.sh` |
| `probe-prelaunch-wiring.sh` | decisions.md 2026-09-15 pre-launch row (claude-capped.sh and clodex-bridge call `dhx-prelaunch.sh` before launch, bounded and stdin-less; processWrapper → bridge; through the real wrappers the registry is repaired before a fake binary starts, argv and stdin intact; fail-open on a hanging or missing child; no stdout; keys heal ordered before registry heal; the HP-017 clobber shape repaired through the real bridge) | `bash tests/probes/probe-prelaunch-wiring.sh` |
| `probe-plugin-keys-heal.sh` | decisions.md 2026-09-15 plugin-keys row (`dhx-plugin-keys-heal.sh`: healthy runs one jq and writes nothing; each missing key restored with every other key preserved; a declared path never replaced; symlinked settings keep the link and the mode; unparseable or non-object settings refused unchanged, printed once; identity guard only when the source is written; lock contention and stale takeover; default marketplace dir) | `bash tests/probes/probe-plugin-keys-heal.sh` |
| `probe-km-acceptance-trigger.sh` | decisions.md 2026-09-15 pre-launch row (`dhx-km-acceptance.sh`: once-per-CC-version detached acceptance run, stored pass silent, stored fail surfaced once, in-flight marker and stale takeover, error result for a dead probe, dispatcher wiring after registry-heal) | `bash tests/probes/probe-km-acceptance-trigger.sh` |
| `probe-dashboard-notify-wiring.sh` | decisions.md 2026-06-04 dhx-dashboard vitals **correction** row (badge=shell precmd not a hook; banner=`systemMessage` SessionStart hook `dhx-vitals-banner.sh` registered in hooks.json, dead dispatch line removed; behavioral smoke asserts `notify` emits valid JSON `.systemMessage`, carries NO OSC/SetUserVar escape, is labeled-distinct from the digest's "Action required" inbox, and is silent-when-0) | `bash tests/probes/probe-dashboard-notify-wiring.sh` |
| `probe-statemd-phase-line-lint.js` | decisions.md 2026-06-25 STATE.md phase-line lint row (`dhx-statemd-phase-line-lint.js` warns ONLY on a genuine first-paren-≠-`current_phase_name` mismatch at aligned phase numbers; convention-zoo PASS shapes + WARN/SUPPRESSED pair + dual-channel e2e + mirror-drift vs live gsd-core) | `node tests/probes/probe-statemd-phase-line-lint.js` |
| `probe-inception-posture.sh` | decisions.md 2026-07-09 dhx-inception-posture row (UserPromptSubmit build-posture injection fires ONLY on `/gsd-new-project`/`/gsd-new-milestone`, silent otherwise; reads `.prompt` not the `.user_prompt` routing bug; carries #1 runtime + #3 gated-commercial principles) | `bash tests/probes/probe-inception-posture.sh` |
| `probe-routing.sh` | decisions.md 2026-07-09 dhx-routing `.user_prompt`→`.prompt` fix row (regression guard: routing FIRES on a real `.prompt` payload across all routed GSD commands / redirect-vs-calibration mode / silent otherwise — the coverage gap that hid a 3-month silent no-op) | `bash tests/probes/probe-routing.sh` |
| `probe-dirty-tree-attribution-gate.sh` | decisions.md 2026-07-28 dirty-tree attribution enrichment row + 2026-07-30 degrade-voice row (allowlist gate: non-allowlisted repo = byte-identical bare line + zero helper invocations; TRANSIENT degrades stay silent and byte-identical — absent / hung / malformed / `--version`-rc-nonzero / zero-byte; PERMANENT degrades emit bare count + exactly one factual line — exit-3 canary, protocol mismatch, over-cap payload; payload replaces bare line, `--repo`+`--self` argv; wording guard: no banned action verb / relative-age token) | `bash tests/probes/probe-dirty-tree-attribution-gate.sh` |
| `probe-hermetic-tier-green-token.sh` | decisions.md 2026-09-14 hermetic-tier green-token row (check #8a: a green tier run writes a token keyed on HEAD + candidate tree + forced worktree snapshot + git config/hooks; identical rerun hits and is not re-run; staged change, worktree-only edit, `info/exclude`-hidden probe and hooks-dir change all re-run; a red writes nothing; a `DHX_RED_COMMIT=1` green writes and hits; TTL expiry and `DHX_PROBE_TIER_TTL=0`/`off` force; real index untouched; one mutation control — constant snapshot term wrongly hits) | `bash tests/probes/probe-hermetic-tier-green-token.sh` |
| `probe-hermetic-tier-no-tree-writes.sh` | decisions.md 2026-09-17 hermetic-tier-refuses-live-capture row + baseline-publish-gate row (the gate's own `--filter` invocation exports `DHX_PROBE_HERMETIC=1` while bare and live-tier invocations do not; CLASS parity is BEHAVIOURAL, not textual, and DISCOVERY is fail-closed on the mechanism rather than on a spelling — every probe referencing `XDG_RUNTIME_DIR` is a candidate that must prove itself (guarded discriminator, or comment-only references), each armed via its own assignment under whatever variable name and brace spelling it uses and run with the marker, asserting rc 0 + an explicit "arming dir present but IGNORED" line + zero writes under `.results/`, so a third such probe added later is exercised automatically and reds here. Mutation-measured 2026-09-17: the structural grep alone caught the marker being DELETED but MISSED it being INVERTED (`== "0"`, token still present); the behavioural arm catches inversion, deletion, and a newcomer latch probe that omits the guard entirely (3 mutants, all caught by name); both latches armed plus the marker writes nothing under `.results/` while the effort probe still passes its fixtures; one positive control — the same armed latch UNMARKED walks past the discriminator into the live arm and stops at the missing flag file with rc 2; the baseline publish gate withholds and then, under `DHX_PROBE_PUBLISH=1`, writes) | `bash tests/probes/probe-hermetic-tier-no-tree-writes.sh` |
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
