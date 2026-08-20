# LIVE_RUNTIME Classification

Authored 2026-08-20. Companion to `SAFE_FOR_LIVE.md`, answering a different
question about the same probe set.

| tag | question it answers | untagged means |
|---|---|---|
| `SAFE_FOR_LIVE` | *May this probe touch live state?* | **refused** — never assume safety |
| `LIVE_RUNTIME` | *Can an upstream install flip this probe's verdict with the repository unchanged?* | **`no`** — assume hermetic, keep gating on it |

The two defaults point in opposite directions on purpose. Each fails toward the
safe side of its own question: an unclassified probe must not be *run* against
live state, and an unclassified probe must not be *dropped* from the commit gate.
A new live probe that forgets its tag therefore lands in the tier that runs more
often, never the one that runs less.

## Why the tier exists

`scripts/verify-hook-patterns.sh` check #8 used to run the whole suite whenever a
commit staged `dhx/*.js` or `tests/probes/*` — 223 of 1245 tracked files. Six of
those probes assert against the installed `~/.claude/gsd-core`, so a
`/dhx:sym gsd-update` in another session could flip a commit's verdict without the
repository changing. On 2026-08-19 exactly that happened: a `statusline-wrapper.js`
version bump sat blocked behind an unrelated statemd mirror red, on a shared tree
with concurrent sessions.

Measured over 120 days: 1659 commits, ~450 arming the trigger, against **21
gsd-core reconciliations since April — one per ~6 days**. The gate was checking an
install-triggered invariant at commit time, ~22 times per breakage it could catch.

Commit time is the wrong event for an install-triggered check. The split moves the
live differentials to the event that can actually break them, and keeps them
un-skippable with a version stamp rather than with a blast radius.

## The rule

> A probe belongs in the live tier iff a `/dhx:sym gsd-update` alone can change its
> verdict with the repository unchanged. **Time-to-green is explicitly NOT the
> axis** — see `docs/decisions.md` 2026-08-20 for why that hypothesis was tested
> and rejected.

`LIVE_SUBJECT` declares the repo files whose staging should make the probe gate a
commit. An empty `LIVE_SUBJECT` is meaningful, not an omission: it marks a probe
whose red is cleared by a **live-state action**, never by a repo edit, so no commit
should ever be held for it.

## Roster

| Probe | LIVE_SUBJECT | Flip demonstrated by | What clears a red |
|---|---|---|---|
| `probe-gsd-hook-version-mirrors-runtime.sh` | `dhx/statusline-wrapper.js` | copied `VERSION` 1.11.0 → 1.12.0 → rc=1 | repo, **seconds** — one-line marker bump |
| `probe-statemd-phase-line-lint.js` | `dhx/dhx-statemd-phase-line-lint.js` | dropped the name field-rung from copied `state.cjs` → 2 diverge of 30, rc=1 | repo, **session** — re-derive the mirror |
| `probe-deferred-gate-disjointness.sh` | `dhx/dhx-deferred-check.sh`, `dhx/dhx-milestone-close-blocker-pretooluse.sh`, `dhx/dhx-milestone-close-blocker-check.sh` | renamed `scanDeferredItems` in copied `audit.cjs` → rc=1 | repo, **session** — re-open the decisions row |
| `probe-stale-hooks-filter-retired.js` | `dhx/statusline-wrapper.js` | dropped a `# gsd-hook-version:` header from a copied installed hook → rc=1 | upstream/repo, session |
| `probe-gsd-roots-resolve.sh` | `dhx/dhx-gsd-canonical-mirror-gate.sh`, `dhx/dhx-gsd-drift-surface.sh`, `scripts/dhx-gsd-triad.sh`, `scripts/dhx-draft-buffer.sh` | demonstrated by absence of `skills/gsd-*` (weaker: not a faithful install simulation) | repo, session |
| `probe-gate-6-canonical-mirror-discipline.sh` | *(none — deliberate)* | appended a line to the copied live `ui-review.md` → rc=2 | **live state** — re-apply the fork |

Every flip above was produced by mutating a **copy** of `~/.claude/gsd-core` under a
scratch `$HOME`. The live runtime was never mutated.

### Considered and excluded

`probe-gsd-canonical-mirror-gate-tiered-outcome.sh` references
`~/.claude/gsd-core/...` and `~/.claude/agents/gsd-ui-auditor.md`, but uses them as
**path strings only** — its backup-meta is a mktemp fixture and
`dhx-gsd-canonical-mirror-gate.sh` never stats the target file. Referencing a live
path is not the same as asserting on live content.

The remaining probes that read live paths without a fake `$HOME` (29 of the 35
surveyed) depend on `~/.claude/dhx-tools/*` or `~/.ccs/shared/settings.json`. They
carry a real and *measured* version of this hazard — five of them flip, and one
(`c90d734`, 2026-05-22) already blocked a clean-HEAD commit — but **they cannot join
this roster, and that is a ruling, not a backlog item.**

`~/.claude/dhx-tools/` is 33 symlinks into `~/repos/skills/scripts/` and
`~/repos/cross-repo/scripts/` — live working trees, not an installed snapshot. There
is no install event and no version file, so there is nothing for a freshness stamp to
key on; a content hash over two peer repos' `scripts/` trees would go stale on every
keystroke in either. The tier's safety comes entirely from `#8c` being able to ask
"has the live tier run against the *currently installed* gsd-core?", and that question
has no counterpart here.

The answer for that class is to **de-pin** — those probes assert on upstream *source
text*, and one reds on a pure `headerFor` → `headerLabel` rename with zero behavioural
change. See `docs/decisions.md` § 2026-08-20 "The non-gsd live-dependent probes…" and
`.planning/backlog/2026-08-20-non-gsd-live-dependent-probes-untiered.md`.

The tag is still named `LIVE_RUNTIME` rather than `GSD_FLIPPABLE` — a naming choice made
before the ruling above, kept because it costs nothing. Do not read it as a reserved slot
for that class.

## Invocation

```bash
# hermetic tier — what pre-commit check #8a runs
bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no

# live tier + stamp — run after a gsd-core install; clears the 8c block
bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=yes --stamp

# bare — UNCHANGED, still the whole suite (health.sh --probes, sync-public-mirror.sh)
bash scripts/run-probes.sh
```

`--stamp` writes `tests/probes/.results/live-tier/status.json` (gitignored,
machine-local) recording the gsd-core version the tier **ran against** and which
probes were red. It is written on failure too — gating the write on success would
reinstate the deadlock this split removes.

Enforced by `tests/probes/probe-live-runtime-tier.sh`.
