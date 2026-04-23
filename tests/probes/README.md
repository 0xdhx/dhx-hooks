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

## Integration probes

A probe is an **integration probe** when it exercises the composition of multiple code paths that are architecturally independent but share a runtime invariant. These surface UX/timing issues that per-chunk probes can't.

Worked example: `probe-sym-health-override.js` — tests the interaction of `readHealthCache()` consuming both `health.json` (written by `dhx-health-check.sh` at SessionStart) and `sym-health.json` (written by skills-repo `/dhx:sym`). Each cache's writer was correct in isolation, but the UX asymmetry (60s drift refresh vs SessionStart-only plugin-keys) only surfaced when both paths ran together against fixture caches — and that observation triggered the chunk-2 scope evolution (`ee02180`).

If you find yourself writing a probe that exercises two or more components' outputs together — write it as an integration probe, and flag future plans to consider the latency/composition shape of adjacent work.

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
| `probe-drift-detection.js` | decisions.md 2026-04-18 drift-detection audit row (companion to probe-settings-hash.js + probe-migration.js) | `node tests/probes/probe-drift-detection.js` |
| `probe-drift-cleanup.sh` | decisions.md 2026-04-19 drift-cache orphan-sweep row (dhx-health-check.sh) | `bash tests/probes/probe-drift-cleanup.sh` |
| `probe-deferred-check-req-id-regex.sh` | decisions.md 2026-04-20 deferred-check D-NN false-positive row | `bash tests/probes/probe-deferred-check-req-id-regex.sh` |
| `probe-deferred-check-header-fallback.sh` | decisions.md 2026-04-23 header-fallback h3 overmatch row | `bash tests/probes/probe-deferred-check-header-fallback.sh` |

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
