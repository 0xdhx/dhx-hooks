# LIVE_RUNTIME Classification

Authored 2026-08-20. Companion to `SAFE_FOR_LIVE.md`, answering a different
question about the same probe set.

## The three axes

| tag | question it answers | untagged means |
|---|---|---|
| `SAFE_FOR_LIVE` | *May this probe touch live state?* | **refused** — never assume safety |
| `LIVE_RUNTIME` | *Can an upstream install flip this probe's verdict with the repository unchanged?* | **`no`** — assume hermetic, keep gating on it |
| `HERMETIC_TIER` | *Is this probe cheap enough to run on every commit?* | **`yes`** — assume cheap, keep gating on it |

The defaults point in different directions on purpose. Each fails toward the
safe side of its own question: an unclassified probe must not be *run* against
live state, and an unclassified probe must not be *dropped* from the commit gate.
A new live probe that forgets its tag therefore lands in the tier that runs more
often, never the one that runs less. The same holds for cost — a probe that
forgets `HERMETIC_TIER` keeps gating commits.

### Why cost needed its own axis (2026-09-05)

`probe-sync-mirror-publish-gate.sh` blocked two unrelated commits by timing out
at the 30s per-probe cap: it runs the real publisher five times, each doing a
full-history `git filter-repo`, so it measures 28s idle / 50s under load and is
**O(commits)** — it worsens permanently as history grows.

Neither existing tag could express that without lying. `SAFE_FOR_LIVE: no` would
claim the probe is unsafe to run (it is not — it pushes to a mktemp bare repo and
its network read is read-only). `LIVE_RUNTIME: yes` would claim an upstream
install can flip its verdict (it cannot). Either would have been a false answer
written to buy a scheduling outcome — and a tag that lies is precisely the defect
`probe-hermetic-tier-contract-parity.sh` was built to prevent, after an
over-claiming summary corrupted a downstream design in 2026-08.

Cost is a genuinely third question, so it got a third tag. **Reclassifying is not
deleting:** a `HERMETIC_TIER: no` probe must be given a home that actually runs
it, named in its own header. The mirror probe's home is the weekly rehearsal in
`.github/workflows/publish-mirror.yml`, which already checks out full history and
installs `git-filter-repo` for the same reasons the probe is slow.

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

## What this tier does NOT guarantee

Added 2026-08-23, after a consumer was built on the wrong reading of it.

The rule above is **narrow on purpose**: one axis, one event class. The hermetic tier's
only guarantee is that a `/dhx:sym gsd-update` cannot flip a verdict in it. It is
**not** a guarantee that a probe's verdict is a pure function of the repository, and
nothing here has ever promised that. Two things a hermetic probe may legitimately do:

- **Read live configuration.** `probe-v1-1-1-gate.sh` reads live state in four of its
  five gates (a git-log epoch, `verify-hooks.sh`, `~/.claude/read-once/reads.jsonl`, and
  the process table via `pgrep`). It is correctly tiered: no gsd-core install flips any
  of them. Every one of those gates carries a runnable seam
  (`DHX_PROBE_VERIFY_HOOKS_RC` and friends) — the seams exist for callers that need
  determinism, and are deliberately **not** defaulted, because a probe that stubs out
  every live read asserts nothing about the machine while still reporting green.
- **Assert on this repo's absolute path.** `scripts/verify-hooks.sh` checks that
  `~/.claude/hooks/*` resolve into `/home/dhx/repos/hooks/dhx/`. That is a fact about
  the installation, and no copy of the tree at any other path can satisfy it.

### The consequence: you cannot run this tier against a reconstructed tree

This is the practical bite, and it is not obvious until you try. On 2026-08-23 the
`DHX_RED_COMMIT` work needed to answer *"was the tier green at the parent commit?"*.
Four ways of reconstructing that tree were measured against a live tree the tier
reports **GREEN**:

| oracle | result |
|---|---|
| `git archive HEAD` | 4 false reds |
| `git worktree add --detach` | **VETOED** by the XR-29 reference-transaction guard |
| `git clone --shared` | 2 false reds |
| `git clone --shared` + `install-hooks.sh` | 1 false red, **irreducible** |

The last is the absolute-path assertion above: structural, not a setup gap. The gate
shipped using **staged attribution** instead — deciding from what the commit stages,
which needs no reconstruction at all. See `docs/decisions.md` 2026-08-23 and the header
of `tests/probes/probe-red-commit-attribution.sh`.

### Considered and rejected: making the tier actually repo-pure

Sweeping every hermetic probe until the name is literally true was rejected. It fights
an axis that was chosen on measured evidence rather than by omission; it is unbounded
(a screening grep flags candidates but cannot separate "reads live state" from "reads
live state in a way that can flip"); it would subtract coverage from the commit gate to
make a description accurate; and the only consumer that ever needed purity — the
parent-reconstruction oracle — is abandoned. If a future consumer needs a repo-pure
tier, it needs a **new** tag and a new roster, not a redefinition of this one.

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
