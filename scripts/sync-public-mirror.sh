#!/usr/bin/env bash
# Sync public mirror 0xdhx/dhx-hooks from this private repo.
#
# Refreshes the public mirror via:
#   1. Fresh clone of this repo to a temp dir
#   2. git filter-repo --paths-from-file scripts/public-paths.txt
#      (subset history to public-eligible paths)
#   3. Deterministic scrub pass on cross-references to private paths
#      (Class A: probe Backs comments; B/C/D: dhx + statusline-wrapper)
#   4. Add/update public README, CHANGELOG, LICENSE
#   5. Force-push to git@github.com:0xdhx/dhx-hooks.git (with --force-with-lease;
#      only on --push, and normally reached via the publish-mirror workflow, not locally)
#   6. Verify a sample of permalinks resolve HTTP 200
#
# Idempotent — safe to re-run. Re-runs republish the public-side history
# from current private HEAD; all derived public hashes change atomically.
#
# Patterns: HP-007, HP-017
set -euo pipefail

# --- 0. Argument parsing ---------------------------------------------------
# INCIDENT 2026-07-21: this script accepted `DRY_RUN=1` as an env var ONLY and had NO
# argument parsing at all. `bash sync-public-mirror.sh --dry-run` therefore ran the FULL
# LIVE PATH — force-pushing the public mirror — while printing nothing to contradict the
# operator's belief that it was a rehearsal. That is exactly what happened: two
# unintended force-pushes to 0xdhx/dhx-hooks. A flag that silently does the opposite of
# what it says is worse than no flag.
# Three rules now hold:
#
#   1. REHEARSE BY DEFAULT. A bare invocation does NOT publish. Publishing requires the
#      explicit `--push`. This is the layer that does not depend on anyone remembering
#      anything: a forgotten flag, a typo, a stale runbook line, or a copy-paste all
#      degrade to a rehearsal. A flag-guarded dangerous DEFAULT is the same trap with an
#      extra step — the default itself has to be the safe one.
#   2. `--dry-run`/`-n` is a real flag (now a no-op reaffirming the default, kept because
#      existing runbooks and muscle memory pass it).
#   3. An UNRECOGNIZED argument is a hard refusal. The failure mode must never be
#      "publish anyway."
#
# There is NO env publish path. `DRY_RUN=0` used to be one; the Codex review below
# showed an exported 0 from an unrelated earlier command turned a BARE invocation into a
# force-push, so env may now only push the mode toward rehearsal. Automation publishes by
# passing --push, like a human. Regression-guarded by
# tests/probes/probe-sync-mirror-publish-gate.sh — if someone flips the default back or
# restores the env path, that probe goes red before the mirror moves.
#
# The SANCTIONED publish path is now the `publish-mirror` GitHub Actions workflow
# (.github/workflows/publish-mirror.yml, 2026-07-22): the deploy key lives in GitHub's
# secret store, and the publish job waits on a required reviewer approving in a browser —
# a human channel no local process can drive. A local `--push` still works and is
# BREAK-GLASS; the banner says so on every live run.
# Codex adversarial review 2026-07-21 (findings C5, C1-order, C2-parse-only, empty-override)
# closed four holes that survived the first fix:
#   - `export DRY_RUN=0` made a BARE invocation publish, and the banner still claimed
#     "(--push given)" — a lying banner on the exact surface built to stop a lie.
#     The env var can now only push the mode toward REHEARSE; publishing requires argv.
#   - `--dry-run --push` published (last flag won), so a wrapper appending --push could
#     defeat a caller explicitly asking to rehearse. Conflicting mode flags now REFUSE.
#   - `--print-mode` was not parse-only: it ran repo discovery and created a temp dir
#     before exiting. It now exits before any filesystem or git work.
#   - `PUBLIC_REMOTE=""` (set-but-empty) fell through `:-` to the PRODUCTION remote.
#     Set-but-empty is now a refusal, not a silent promotion to production.
DRY_RUN=1                 # always start safe; argv is the only way to change it
SAW_DRY_FLAG=0
SAW_PUSH_FLAG=0
PRINT_MODE=0
case "${DRY_RUN_ENV:-${DRY_RUN:-}}" in
  # Env may only ever push toward rehearsal. `DRY_RUN=0` is deliberately NOT a publish
  # path: an exported 0 from an unrelated command hours earlier must not turn a bare
  # invocation into a force-push. Automation publishes by passing --push, like a human.
  1) DRY_RUN=1 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) SAW_DRY_FLAG=1; shift ;;
    --push)       SAW_PUSH_FLAG=1; shift ;;
    --print-mode) PRINT_MODE=1; shift ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *)
      echo "REFUSE: unrecognized argument '$1'." >&2
      echo "        Usage: $0 [--push] [--dry-run|-n] [--print-mode]" >&2
      echo "        Default is a REHEARSAL; --push is required to publish." >&2
      echo "        Refusing rather than falling through — see the 2026-07-21" >&2
      echo "        incident note above." >&2
      exit 2 ;;
  esac
done

if [ "$SAW_DRY_FLAG" = "1" ] && [ "$SAW_PUSH_FLAG" = "1" ]; then
  echo "REFUSE: --dry-run and --push are contradictory; refusing to guess." >&2
  echo "        (Last-flag-wins would let a wrapper append --push and silently" >&2
  echo "        override a caller that explicitly asked to rehearse.)" >&2
  exit 2
fi
[ "$SAW_PUSH_FLAG" = "1" ] && DRY_RUN=0

# Destination resolution. Set-but-EMPTY is a refusal: `${PUBLIC_REMOTE:-<production>}`
# would treat it as unset and quietly aim at production — the shape that turns a
# half-applied test override into a live publish.
if [ "${PUBLIC_REMOTE+set}" = "set" ] && [ -z "$PUBLIC_REMOTE" ]; then
  echo "REFUSE: PUBLIC_REMOTE is set but empty. Refusing to fall back to the" >&2
  echo "        production remote — an emptied override is a bug, not a default." >&2
  exit 2
fi
PUBLIC_REMOTE="${PUBLIC_REMOTE:-git@github.com:0xdhx/dhx-hooks.git}"
TAG_VERSION="${TAG_VERSION:-v0.2.0}"

# Say which mode is running, up front and unmissably, and say it TRUTHFULLY — the
# banner must name the reason it believes it is publishing.
if [ "$DRY_RUN" = "1" ]; then
  echo "[sync] MODE: DRY RUN (default) — nothing will be pushed to $PUBLIC_REMOTE"
else
  echo "[sync] MODE: LIVE PUBLISH (--push given) — will FORCE-PUSH $PUBLIC_REMOTE"
  # The sanctioned publish path is the `publish-mirror` GitHub Actions workflow, where the
  # credential lives in GitHub's secret store and a reviewer approves in a browser. A local
  # --push is BREAK-GLASS: it works (the operator's own key can push their own repo), but it
  # carries no human gate beyond this line. Say so, every time.
  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    echo "[sync]       ^ local break-glass publish. Sanctioned path: gh workflow run publish-mirror.yml -f publish=true"
  fi
fi

# --print-mode exits HERE — before repo discovery, before mktemp, before any git call.
# Parse-only means parse-only; the first version of this exit ran `rev-parse` and
# created a temp dir first, which made "side-effect-free" an overstatement.
[ "$PRINT_MODE" = "1" ] && exit 0

REPO_ROOT=$(git -C "$(dirname "$(realpath "$0")")/.." rev-parse --show-toplevel)
BUILD_DIR=$(mktemp -d -t dhx-hooks-public-XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "[sync] REPO_ROOT=$REPO_ROOT"
echo "[sync] BUILD_DIR=$BUILD_DIR"
echo "[sync] PUBLIC_REMOTE=$PUBLIC_REMOTE"

# --- 1. Fresh clone --------------------------------------------------------
cd "$REPO_ROOT"
PRIVATE_HEAD=$(git rev-parse HEAD)
echo "[sync] private HEAD: $PRIVATE_HEAD"

git clone --no-local "$REPO_ROOT" "$BUILD_DIR/dhx-hooks" >/dev/null 2>&1
cd "$BUILD_DIR/dhx-hooks"

# --- 2. Filter to public-eligible paths + scrub commit messages -----------
echo "[sync] filtering history to public paths..."

# Commit-message replacements (applies to commit messages only, not file content).
# Format: OLDTEXT==>NEWTEXT (one per line). Operator-path/private-project mentions
# in older commit messages get sanitized so the public history doesn't carry
# unrelated-project references.
REPLACE_MSG_FILE="$BUILD_DIR/replace-message.txt"
cat > "$REPLACE_MSG_FILE" <<'MSG_EOF'
forgefinder==>acme-app
darkhawkx==>0xdhx
/home/dhx/repos/hooks==>$DHX_HOOKS_REPO
/home/dhx/.ccs==>$HOME/.ccs
/home/dhx/.claude==>$HOME/.claude
joshuaryangreen==>0xdhx
MSG_EOF

git filter-repo \
  --paths-from-file "$REPO_ROOT/scripts/public-paths.txt" \
  --replace-message "$REPLACE_MSG_FILE" \
  --force >/dev/null 2>&1

# Strip operator tooling — the sync script + paths config live under scripts/
# but are private to this private→public flow (and the script self-references
# "forgefinder" in its own scrub patterns, which would false-positive the
# Class D verification below). This matches the live public mirror's existing
# scripts/ inventory. The skill-overrides sync/unsync pair references the
# skills monorepo by design — they're cross-repo operator tooling that has
# no place on the public mirror; dropping them avoids the cross-repo scrub
# pass having to chase same-repo path constants through working code.
rm -f scripts/sync-public-mirror.sh scripts/public-paths.txt
rm -f scripts/sync-skill-overrides.sh scripts/unsync-skill-overrides.sh

# --- 3. Scrub pass ---------------------------------------------------------
echo "[sync] scrubbing cross-references..."

# Class A: delete `# Backs ... docs/decisions.md ...` and `// Backs ... docs/decisions.md ...` lines
find tests/probes -type f \( -name '*.sh' -o -name '*.js' \) \
  -exec sed -i '/^# Backs[a-z]*:\?[[:space:]]\+docs\/decisions\.md/d; /^\/\/ Backs[a-z]*:\?[[:space:]]\+docs\/decisions\.md/d' {} +

# Class A surgical: the read-guard partial-detection probe headers fuse
# `# Backs the 2026-05-24 decisions.md Option C collapse row` with substantive
# text on the same line. The single-line regex above can't delete that without
# orphaning the trailing English, so rewrite per-file. (The pre-Option-C
# read-cache global-cache probe corpus — concurrency/prune/cross-session/
# write-cache — was retired in commit 32d12f5; its scrub rules were removed
# with it.)
sed -i 's|^# Backs the 2026-05-24 decisions\.md Option C collapse row\. After the collapse,$|# After the Option C read-guard collapse,|' tests/probes/probe-read-cache.sh
sed -i 's|^# Backs the 2026-05-24 decisions\.md Option C collapse row\. The collapse removed$|# The Option C read-guard collapse removed|' tests/probes/probe-read-guard-partial-detection.sh

# probe-bashrc-wrapper-heal.sh:17
sed -i 's|^# Backs decisions\.md 2026-04-17 row "plugin-keys load-gating verified +$|# Asserts plugin-keys load-gating verified +|' tests/probes/probe-bashrc-wrapper-heal.sh

# probe-gsd-fork-aware-drift.sh:5
sed -i 's|^# Backs quick task 260425-oeg — fork-aware gsd drift suppression\. The$|# Asserts fork-aware gsd drift suppression. The|' tests/probes/probe-gsd-fork-aware-drift.sh

# Cross-repo skills/reports reference (probe-deferred-check-req-id-regex.sh:15)
sed -i '/^# Parent report: ~\/repos\/skills\/reports\/[0-9-]\+-[a-z0-9-]\+\.md$/d' tests/probes/probe-deferred-check-req-id-regex.sh

# Local reports/done/ Parent-report reference (probe-deferred-check-canonical-classifier.sh:15)
# Orphaned by the Class A "Backs ... docs/decisions.md" scrub above.
sed -i '/^# Parent report: reports\/done\/[0-9-]\+-[a-z0-9-]\+\.md$/d' tests/probes/probe-deferred-check-canonical-classifier.sh

# Cross-repo skills/tests references — surfaced 2026-04-28 by canonical-
# classifier sister-probe additions. Three sites; per-line surgical rewrites
# to preserve substantive content while stripping the cross-repo path.
#
# probe-deferred-check-canonical-classifier.sh: 4-line "Sister probe:" block
# describing the skills-repo companion probe. Delete the whole block; the
# private-repo decisions row + skills-repo classifier story is internal to
# the cross-repo workflow, not relevant to public consumers.
sed -i '/^# Sister probe: ~\/repos\/skills\/tests\/probe-classifier-cross-repo\.sh runs the$/,/^# invariant visible from both repos. test suites\.$/d' tests/probes/probe-deferred-check-canonical-classifier.sh
#
# probe-deferred-check-header-fallback.sh:94: single-line "caught by
# ~/repos/skills/..." reference at the tail of an INVARIANT comment.
# Rewrite to drop the cross-repo path while preserving the drift-detection
# claim.
sed -i 's|^# script and consumers is caught by ~/repos/skills/tests/probe-classifier-cross-repo\.sh\.$|# script and consumers is caught by sister probes in the consumer repos.|' tests/probes/probe-deferred-check-header-fallback.sh
#
# dhx-deferred-check.sh:19-21: 3-line "Drift between this hook and the
# skills-repo consumers ... is enforced by ~/repos/skills/..." sentence
# spanning the end of one paragraph + the cross-repo ref. Truncate line 19
# at "deferred block." then delete the trailing 2 lines that complete the
# cross-repo sentence.
sed -i 's|^# deferred block\. Drift between this hook and the skills-repo consumers$|# deferred block.|' dhx/dhx-deferred-check.sh
sed -i '/^# (\/dhx:defer-review, \/dhx:backlog audit, \/dhx:capture) is enforced by$/d' dhx/dhx-deferred-check.sh
sed -i '/^# ~\/repos\/skills\/tests\/probe-classifier-cross-repo\.sh\.$/d' dhx/dhx-deferred-check.sh
#
# RETIRED 2026-08-27 — probe-milestone-close-vocab-parity.sh no longer carries the
# single-line "Mirrors `~/repos/skills/tests/probe-classifier-cross-repo.sh` discovery +"
# comment this rule was anchored on. The probe was rewritten from a source-text pin on
# backlog-regen.cjs to a rendered-output differential (docs/decisions.md 2026-08-27
# de-pin row) and that comment went with the design-memo block it headed. The rule is
# removed rather than left in place because an anchored sed whose anchor no longer
# exists is a silent no-op that reads as coverage. Any residual `repos/skills` in this
# file is still scrubbed by the Class D/E catch-all sweep further down.

# Fixture: forgefinder pattern reference
sed -i 's|original forgefinder 22\.1 pattern|real-world 22.1 pattern|' tests/fixtures/backtick-collision.md

# Class B: reports/...md references in dhx/ comments
sed -i 's|reports/done/2026-04-15-read-guard-session-scoping-false-positives\.md)\.|session-scoping false positives observed 2026-04-15.|' dhx/dhx-read-guard.js
sed -i 's|actually verify them — see reports/done/2026-04-11-source-write-flag-sh-classification\.md|actually verify them.|' dhx/dhx-source-write-flag.sh
sed -i 's|then accumulate on disk indefinitely\. See reports/2026-04-19-worktree-leak-gh-36182-third-incident\.md\.|then accumulate on disk indefinitely (gh#36182 worktree-leak class).|' dhx/dhx-stale-worktree-sweep.sh
sed -i 's|reports/2026-04-26-statusline-capture-pane-wedge\.md)\. Per-session file|statusline capture-pane wedge incident class). Per-session file|' dhx/dhx-statusline.js
sed -i '/reports\/done\/2026-04-11-deferred-check-sed-tag-collision\.md\./d' dhx/dhx-context-gate.sh
sed -i '/reports\/done\/2026-04-11-deferred-check-sed-tag-collision\.md\./d' dhx/dhx-deferred-check.sh
sed -i '/reports\/done\/2026-04-12-context-tag-corpus-analysis\.md\./d' dhx/dhx-deferred-check.sh
sed -i 's|incident, 2026-04-19, reports/2026-04-19-worktree-leak-gh-36182-third-incident\.md)\.|incident class, 2026-04-19 — gh#36182 worktree-leak).|' dhx/dhx-worktree-bash-guard.sh
sed -i '/Parent report: reports\/done\/2026-04-23-deferred-check-header-fallback-matches-h3\.md/d' tests/probes/probe-deferred-check-header-fallback.sh

# Class C: docs/...md references in dhx/ comments
sed -i 's|post-execution hook point\. See docs/hook-dev-guide\.md § Propagation\.|post-execution hook point.|' dhx/dhx-execute-stop-review.sh
sed -i '/^\/\/ docs\/backlog\.md::ccburn-trace-retire\.$/d' dhx/statusline-wrapper.js
sed -i 's|strict `>` comparison\. See docs/decisions\.md 2026-04-18 drift-bundle row\.|strict `>` comparison.|' dhx/statusline-wrapper.js
sed -i 's|caught\. See docs/decisions\.md 2026-04-23 orphaned_at filter row\.|caught.|' dhx/statusline-wrapper.js
sed -i '/and docs\/statusline-wrapper\.md § "Fork-aware suppression (gsd trigger only)"\.$/d' dhx/statusline-wrapper.js
sed -i '/^[[:space:]]*\/\/ docs\/statusline-wrapper\.md § "Fork-aware suppression (gsd trigger only)"\.$/d' dhx/statusline-wrapper.js
# After deleting the indented `// docs/...` line, the prior comment's
# trailing "above and" becomes a dangling continuation — clean up.
sed -i 's|`isGsdDriftFromForkSync` above and$|`isGsdDriftFromForkSync` above.|' dhx/statusline-wrapper.js
# dhx-statusline.js header references docs/statusline-wrapper.md (not in public mirror)
sed -i '/^\/\/ See docs\/statusline-wrapper\.md for segment table and color semantics\.$/d' dhx/dhx-statusline.js
# Multi-line statusline-wrapper.js trim (line 716 + continuation)
sed -i 's|missed nested writes\. See docs/decisions\.md drift-$|missed nested writes.|' dhx/statusline-wrapper.js
sed -i '/^\/\/ bundle row\.$/d' dhx/statusline-wrapper.js
# Line 921, 924: strip docs/research paths but keep substantive comment + HP-019 reference
sed -i 's|, docs/research/economics/session-cost-mechanics\.md||' dhx/statusline-wrapper.js
sed -i 's| / docs/research/economics/away-summary-billing\.md||' dhx/statusline-wrapper.js

# Class C (2026-05-29): dhx-git-destructive-guard.sh — strip private cross-repo
# doc/report path refs from the security-hook header comments. The deny-history
# docs/research refs (L33+L44) are the docs/ FAIL that blocked the mirror since
# 2026-05-25; the reports/done ref (L23) + the docs/git ref (L8-9) slip the verify
# gate (`docs/git` not in the FAIL alternation, `cross-repo` not in the cross-repo
# gate) but are the same private-path class — scrub all four. Each delete is paired
# with a prose-balance `s` on the prior line so no dangling sentence fragment ships.
# The genericized wording keeps the security content (bypass vectors, council-lock)
# verbatim — only the private path references are removed.
sed -i 's|^# skills-repo v1\.3 /dhx:git (cross-repo$|# skills-repo v1.3 /dhx:git.|' dhx/dhx-git-destructive-guard.sh
sed -i '/^# docs\/git\/destructive-op-enforcement-backstop\.md)\.$/d' dhx/dhx-git-destructive-guard.sh
sed -i 's|^# the live CC matcher in$|# the live CC matcher (bypass-vector audit):|' dhx/dhx-git-destructive-guard.sh
sed -i '/^# cross-repo\/reports\/done\/2026-05-25-git-force-push-deny-rule-bypass-vectors\.md:$/d' dhx/dhx-git-destructive-guard.sh
sed -i 's|^# Permission eval order (canonical:$|# Permission eval order:|' dhx/dhx-git-destructive-guard.sh
sed -i 's|council-locked D-1\.\.D-7 (2026-05-08;$|council-locked D-1..D-7 (2026-05-08):|' dhx/dhx-git-destructive-guard.sh
sed -i '/^# cross-repo\/docs\/research\/2026-05-08-git-reset-hard-worktree-deny-history\.md):$/d' dhx/dhx-git-destructive-guard.sh

# Class C (2026-05-29): dhx-test-gate.sh — strip the bare `docs/decisions.md` refs.
# These don't match the docs/ FAIL alternation (no path segment after `.md`), so
# they slip the gate silently; strip per the Class C convention. The inline form
# (L216) is anchored to its FULL line so its ` See docs/decisions.md …` substring
# does NOT also truncate the standalone L322 (whose leading `# ` would otherwise
# match), which would leave an orphan `#` the verify gate can't catch.
sed -i 's|^# rootdir) and run from there\. See docs/decisions\.md 2026-05-29 row\.$|# rootdir) and run from there.|' dhx/dhx-test-gate.sh
sed -i '/^# See docs\/decisions\.md 2026-05-29 row\.$/d' dhx/dhx-test-gate.sh

# Class D: forgefinder → acme-app in test fixtures
sed -i 's|/home/dhx/repos/forgefinder|/home/dhx/repos/acme-app|g' tests/probes/probe-worktree-bash-guard.sh
sed -i 's|forgefinder Phase 26|a real-world Phase 26|' tests/probes/probe-deferred-check-header-fallback.sh

# Class D (2026-05-31): forgefinder refs in the package-install reducer + its probe
sed -i "s|forgefinder's ff-test-output-filter\.sh|a sibling repo's node:test output-filter|" dhx/dhx-pkg-install-filter.sh
sed -i "s|the forgefinder ff-test-output-filter\.test\.js|a sibling repo's ff-test-output-filter.test.js|" tests/probes/probe-pkg-install-filter.sh

# Class D (2026-07-21): PREFIX-SENSITIVE alias — must run BEFORE the blanket sweep.
# `dhx-worktree-bash-guard.sh` (D-06) draws its boundary at a sibling repo whose name
# is a strict PREFIX of another: `/repos/forge` must not false-match `/repos/forgefinder`
# (forge + 'f', not forge + '/'). The adversarial test asserts exactly that. Mapping
# those two files to `acme-app` would destroy the shared prefix — the assertion would
# still pass while testing nothing, which is worse than a scrub miss because it reads
# green. `forgeworks` preserves the collision property the boundary exists to handle.
sed -i 's|forgefinder|forgeworks|g' \
  dhx/dhx-worktree-bash-guard.sh \
  tests/probes/probe-worktree-guard-adversarial.test.js

# Class D (2026-07-21): blanket sweep for everything else. The surgical rules above
# produce better prose ("a sibling repo's ..."), so they win by running first; this
# only catches residuals — new probes and hooks that pick up a `forgefinder` reference
# between syncs. Without it, every such addition fails the Class D verify and the
# operator hand-writes another one-off sed. Scoped to the whole worktree (not just the
# six dirs the Class D verify greps) so the cross-repo path check below is covered too.
grep -rlI "forgefinder" . --exclude-dir=.git 2>/dev/null \
  | xargs -r sed -i 's|forgefinder|acme-app|g'

# Class E: residual docs/<file>.md cross-references in probe corpus
# probe-dhx-statusline.js has a "// Pairs with: ..." block (4 lines)
sed -i '/^\/\/ Pairs with: docs\/decisions\.md 2026-04-18 statusline-line2 row, and the$/,/^\/\/ formatLine2Signals)\.$/d' tests/probes/probe-dhx-statusline.js

# probe-drift-detection.js: single-line "Backs the ... in docs/decisions.md."
sed -i 's| Backs the drift-detection audit rows in docs/decisions\.md\.$||' tests/probes/probe-drift-detection.js
# probe-drift-detection.js: multi-line "// Backs:" bullet block
sed -i '/^\/\/ Backs:$/,/^\/\/   - docs\/hook-patterns\.md/d' tests/probes/probe-drift-detection.js

# probe-stale-hooks-filter-retired.js: orphaned continuation line after Class A deletion
sed -i '/^\/\/[[:space:]]*docs\/backlog\.md "gsd-stale-hooks-filter-retire"/d' tests/probes/probe-stale-hooks-filter-retired.js

# probe-statusline-wrapper.js: 2-line "Pairs with: ..." attribution + later mid-line refs
sed -i '/^\/\/ Pairs with: docs\/statusline-wrapper\.md "ccburn compact" section,$/d' tests/probes/probe-statusline-wrapper.js
sed -i '/^\/\/ docs\/decisions\.md 2026-04-18 statusline-compaction row\.$/d' tests/probes/probe-statusline-wrapper.js
sed -i 's|^// per docs/decisions\.md 2026-04-26 meta-glyph row (hairline glyphs locked$|// per the meta-glyph design (hairline glyphs locked|' tests/probes/probe-statusline-wrapper.js
sed -i 's|^// 2026-04-26 — see same-day "meta-glyph hairline glyphs" decisions row)\.$|// 2026-04-26).|' tests/probes/probe-statusline-wrapper.js

# tests/probes/README.md: convention text references docs/decisions.md and docs/backlog.md
sed -i 's|Probe scripts that back the \*\*"Probe evidence"\*\* pointers in `docs/decisions\.md` and the closed rows in `docs/backlog\.md`\.|Probe scripts that assert runtime invariants for the dhx hook surface.|' tests/probes/README.md
sed -i 's|2\. Which `docs/decisions\.md` row or architectural invariant it backs\.|2. Which architectural invariant it backs.|' tests/probes/README.md

# probe-worktree-write-guard.sh: hardcoded local-user path in test JSON fixtures
sed -i 's|/home/dhx/repos/hooks/\.claude|/tmp/test-repo/.claude|g' tests/probes/probe-worktree-write-guard.sh

# Class E (2026-07-21): generalized doc-pointer sweep — the residual catcher.
# Every hook or probe that picks up a provenance pointer (`~/repos/cross-repo/docs/
# research/…md`, "skills `docs/decisions/…md`", a bare in-repo `docs/…md`) between
# syncs used to fail the verify below and need another hand-written one-off sed. Six
# accumulated by 2026-07-21. These rules keep the SENTENCE and drop only the PATH, so
# the surrounding prose still reads — deleting whole lines is what orphaned the
# continuation lines the Class A/E surgical rules above exist to clean up.
#
# DOCS_PATTERN is defined ONCE here and reused by the verify (search "$DOCS_PATTERN"
# below): if the scrub and the check ever drifted apart, the mirror would either fail
# on something unscrubbable or ship a pointer the check no longer looks for.
# NOTE: `#` is the sed delimiter throughout — the pattern contains `|` alternations,
# which would otherwise be read as delimiters and split the expression.
DOCS_PATTERN="docs/(decisions|architecture|backlog|hook-patterns|hook-dev-guide|statusline-wrapper|troubleshooting|upstream-proposal-discipline|research|design)[/.][a-z0-9./-]+\.md"

DOC_REF_FILES=$(grep -rlIE "$DOCS_PATTERN" dhx/ tests/probes/ 2>/dev/null || true)
if [ -n "$DOC_REF_FILES" ]; then
  # Order matters: foreign-repo-qualified forms first (they carry the useful noun),
  # bare residuals last.
  echo "$DOC_REF_FILES" | xargs -r sed -Ei \
    -e "s#~?(/home/[a-z0-9_-]+)?/?repos/cross-repo/$DOCS_PATTERN#the cross-repo knowledge base#g" \
    -e "s#~?(/home/[a-z0-9_-]+)?/?repos/skills/$DOCS_PATTERN#the skills-monorepo docs#g" \
    -e "s#cross-repo \`?$DOCS_PATTERN\`?#the cross-repo knowledge base#g" \
    -e "s#skills \`?$DOCS_PATTERN\`?#the skills-monorepo docs#g" \
    -e "s#\`?$DOCS_PATTERN\`?#the project docs#g"
fi

# Class F: cross-repo skills/ references in incidental working files. The
# sync-skill-overrides pair was dropped wholesale via the operator-tooling
# rm above; these scrubs handle places where a single skills-repo path
# appears in otherwise-public content (plugin manifest description text
# and a probe's design-note comment).
#
# dhx-plugin/plugins/dhx/.claude-plugin/plugin.json — description text has
# two `~/repos/skills/dhx/` references in prose explaining the symlink
# topology. Replace with `<skills-monorepo>/dhx/` so the manifest still
# self-documents but doesn't leak the local-disk layout.
sed -i 's|~/repos/skills/dhx/|<skills-monorepo>/dhx/|g' dhx-plugin/plugins/dhx/.claude-plugin/plugin.json

# Class F (2026-07-21): generalized skills-path sweep — same residual-catcher role the
# Class D/E sweeps play. Any remaining `repos/skills` (prose pointer, report citation,
# or a live fallback path like install-hooks.sh's git-safe.sh lookup) becomes
# `repos/<skills-monorepo>`, the alias the plugin-manifest rule above established.
# The angle bracket matters: the verify greps `/repos/(skills|forgefinder)` as a
# SUBSTRING, so a plausible-looking alias such as `repos/skills-monorepo` would still
# trip it — `<skills-monorepo>` does not.
grep -rlI "repos/skills" . --exclude-dir=.git 2>/dev/null \
  | xargs -r sed -i 's|repos/skills|repos/<skills-monorepo>|g'

# tests/probes/probe-plugin-cache-staleness.sh:275 — single-line comment
# citing the skills-repo's dhx-sym.sh dispatch pattern. Narrow path-only
# rewrite preserves the 2-line genitive grammar (line 275 ends in "'s",
# line 276 starts with "cmd_* case-dispatch precedent).") — replace only
# the absolute path, keeping the "'s cmd_* ... precedent" continuation
# intact.
sed -i 's|~/repos/skills/scripts/dhx-sym\.sh|the skills-monorepo dhx-sym.sh|' tests/probes/probe-plugin-cache-staleness.sh

# Class F (2026-05-29): residual `~/repos/skills/` path leaks that surfaced only
# once the guard-hook docs/ FAIL above was cleared. The verify gate exits at the
# FIRST failing check and the docs/ FAIL (checked before the cross-repo gate)
# masked these for ~4 days — they are pre-existing scrub-debt accrued across files
# touched since the last clean sync (2026-04-28). Genericize to `the skills-monorepo
# …` per the Class F convention above (L203 plugin.json, L211 dhx-sym.sh).
sed -i 's|~/repos/skills/scripts/install-hooks\.sh|the skills-monorepo install-hooks.sh|' scripts/install-hooks.sh
sed -i 's|~/repos/skills/scripts/hooks/pre-commit|the skills-monorepo scripts/hooks/pre-commit|' scripts/hooks/pre-commit
sed -i 's|^# ~/repos/skills/reports/done/2026-05-22-classify-deferred-auto-silence-false-positive\.md$|# the skills-monorepo auto-silence false-positive report (2026-05-22).|' tests/probes/probe-deferred-check-req-id-regex.sh
sed -i 's|See ~/repos/skills/reports/done/2026-05-22-classify-deferred-auto-silence-false-positive\.md|See the skills-monorepo auto-silence false-positive report (2026-05-22).|' tests/probes/probe-deferred-check-canonical-classifier.sh

# Class F (2026-05-30): statusline-wrapper.js symlink-topology comment names the
# `~/repos/skills/dhx` realpath target (the skills-repo symlink the segment derives
# the repo root from). Pre-existing scrub-debt unmasked once the prior FAIL cleared
# (the verify gate exits at the first failing check). Genericize the path; the
# load-bearing "realpath PARENT correction" content stays verbatim — only the
# absolute skills-repo path is removed.
sed -i 's|resolves to ~/repos/skills/dhx;|resolves to the skills-monorepo dhx;|' dhx/statusline-wrapper.js

# --- 3b. Scrub verification ------------------------------------------------
echo "[sync] verifying scrubs..."

# Disable pipefail/errexit interaction for the verify block — we want to count
# greps across patterns where 0-match exit is normal, not fatal.
set +e

CLASS_A_OUT=$(grep -rEnI "^(# |// )Backs[a-z]*:?[[:space:]]+docs/decisions\.md" tests/probes/ 2>/dev/null)
CLASS_A_REMAINING=$([ -z "$CLASS_A_OUT" ] && echo 0 || echo "$CLASS_A_OUT" | wc -l)
if [ "$CLASS_A_REMAINING" != "0" ]; then
  echo "[sync] FAIL Class A: $CLASS_A_REMAINING residual probe Backs comments still reference docs/decisions.md"
  echo "$CLASS_A_OUT"
  exit 1
fi

FORGEFINDER_OUT=$(grep -rnI "forgefinder" tests/ dhx/ dhx-plugin/ scripts/ config/ gsd/ 2>/dev/null)
FORGEFINDER_REMAINING=$([ -z "$FORGEFINDER_OUT" ] && echo 0 || echo "$FORGEFINDER_OUT" | wc -l)
if [ "$FORGEFINDER_REMAINING" != "0" ]; then
  echo "[sync] FAIL Class D: $FORGEFINDER_REMAINING residual forgefinder references"
  echo "$FORGEFINDER_OUT"
  exit 1
fi

NAME_OUT=$(grep -rEnI "joshuaryangreen|Joshua Green" . --exclude-dir=.git 2>/dev/null)
NAME_LEAK=$([ -z "$NAME_OUT" ] && echo 0 || echo "$NAME_OUT" | wc -l)
if [ "$NAME_LEAK" != "0" ]; then
  echo "[sync] FAIL operator-name leak: $NAME_LEAK references"
  echo "$NAME_OUT"
  exit 1
fi

REPORTS_OUT=$(grep -rEnI "\breports/(done/)?[0-9-]+-[a-z0-9-]+\.md\b" dhx/ tests/probes/ 2>/dev/null)
DANGLING_REPORTS=$([ -z "$REPORTS_OUT" ] && echo 0 || echo "$REPORTS_OUT" | wc -l)
if [ "$DANGLING_REPORTS" != "0" ]; then
  echo "[sync] WARN: $DANGLING_REPORTS dangling reports/ refs remain in dhx/ or tests/probes/ — review:"
  echo "$REPORTS_OUT"
  echo "[sync] (warn-only — operator review the audit edits if unexpected)"
fi

# DOCS_PATTERN is defined once in the Class E generalized sweep above and reused here
# deliberately — a second definition would let the scrub and this check drift apart.
DOCS_OUT=$(grep -rEnI "$DOCS_PATTERN" dhx/ tests/probes/ 2>/dev/null | grep -v 'docs/x.md')
DANGLING_DOCS=$([ -z "$DOCS_OUT" ] && echo 0 || echo "$DOCS_OUT" | wc -l)
if [ "$DANGLING_DOCS" != "0" ]; then
  echo "[sync] FAIL: $DANGLING_DOCS dangling docs/ refs remain in dhx/ or tests/probes/:"
  echo "$DOCS_OUT"
  exit 1
fi

CROSS_REPO_OUT=$(grep -rEnI "/repos/(skills|forgefinder)" . --exclude-dir=.git 2>/dev/null)
CROSS_REPO=$([ -z "$CROSS_REPO_OUT" ] && echo 0 || echo "$CROSS_REPO_OUT" | wc -l)
if [ "$CROSS_REPO" != "0" ]; then
  echo "[sync] FAIL: $CROSS_REPO cross-repo path leaks (skills/, forgefinder/):"
  echo "$CROSS_REPO_OUT"
  exit 1
fi

# Probe-results PII leak check (D-09 defense-in-depth):
# Outcome JSON files are sanitized at source by the probe scripts (boolean fields
# for path-shaped concerns), but a regression in any probe could write paths.
# This catches such regressions before they reach the public mirror.
RESULTS_OUT=$(grep -rEnI "(/home/|/Users/|$(hostname -s))" tests/probes/.results/ 2>/dev/null)
RESULTS_LEAK=$([ -z "$RESULTS_OUT" ] && echo 0 || echo "$RESULTS_OUT" | wc -l)
if [ "$RESULTS_LEAK" != "0" ]; then
  echo "[sync] FAIL probe-results PII leak: $RESULTS_LEAK references in tests/probes/.results/"
  echo "$RESULTS_OUT"
  exit 1
fi

# Probe-results positive-grep (D-30 cross-machine drift detection):
# Each outcome JSON's observations.published_from_hostname must be a 64-char SHA-256
# hex (synthetic identifier; never literal hostname). This positive-grep block
# matches the synthetic identifier across results files; absence of matches when
# results files exist is a regression signal (probe author may have skipped D-30).
RESULTS_HASH_OUT=$(grep -rEohI '"published_from_hostname"\s*:\s*"[a-f0-9]{64}"' tests/probes/.results/ 2>/dev/null)
if [ -d "tests/probes/.results" ]; then
  RESULTS_FILE_COUNT=$(find tests/probes/.results -name '*.json' 2>/dev/null | wc -l)
  if [ "$RESULTS_FILE_COUNT" != "0" ] && [ -z "$RESULTS_HASH_OUT" ]; then
    echo "[sync] FAIL probe-results published_from_hostname missing (D-30): $RESULTS_FILE_COUNT result files but 0 SHA-256 hostname-hash matches"
    exit 1
  fi
fi

# Positive assertion: every committed outcome JSON is valid JSON
RESULTS_INVALID=0
for f in tests/probes/.results/*/*.json; do
  [ -f "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || { echo "[sync] FAIL invalid JSON in $f"; RESULTS_INVALID=$((RESULTS_INVALID+1)); }
done
if [ "$RESULTS_INVALID" != "0" ]; then
  echo "[sync] FAIL: $RESULTS_INVALID outcome JSON files failed jq parse"
  exit 1
fi

# Local user path leak — accepted as operator-path visibility (not secrets).
USER_PATH_OUT=$(grep -rnI "/home/dhx/repos/hooks" . --exclude-dir=.git 2>/dev/null)
USER_PATH=$([ -z "$USER_PATH_OUT" ] && echo 0 || echo "$USER_PATH_OUT" | wc -l)
if [ "$USER_PATH" != "0" ]; then
  echo "[sync] NOTE: $USER_PATH /home/dhx/repos/hooks references — accepted operator-path visibility"
fi

set -e

echo "[sync] scrubs OK"

# --- 4. Public README, CHANGELOG, LICENSE ---------------------------------
echo "[sync] writing README/CHANGELOG/LICENSE..."

# Copy public-extras files into the build dir (single source of truth for
# files added to the public mirror that don't pre-exist in the private tree).
# Idempotent — re-runs overwrite. Add new files to public-extras/ to ship them.
if [ -f "$REPO_ROOT/public-extras/ARCHITECTURE.md" ]; then
  cp "$REPO_ROOT/public-extras/ARCHITECTURE.md" ./ARCHITECTURE.md
fi

cat > README.md <<'README_EOF'
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

### PreToolUse

| Hook | Matcher | Purpose |
|------|---------|---------|
| `dhx-assessed-guard.sh` | `Write\|Edit` | Prevents `[assessed]` markers without explicit user approval. |
| `dhx-read-guard.js` | `Write\|Edit` | Partial-read advisory (PARTIAL-READ NOTE) — fires on any Edit/Write of a file that was Read with offset/limit this session. No read-window comparison exists — detection is per-path, not per-range. CC's native runtime owns full read-before-edit enforcement; this shim only covers CC's partial-read blindness. |
| `dhx-worktree-write-guard.sh` | `Edit\|Write\|MultiEdit` | Blocks writes whose absolute path escapes the enclosing CC-managed worktree (gh#36182 mitigation). |
| `dhx-ui-vision-guard.sh` | `Agent` | Ensures `z-gsdui` project skill exists when GSD UI subagents spawn. |
| `dhx-agent-leak-snapshot.sh` | `Agent` | Captures pre-dispatch `git status` baseline for paired post-check (subagent-leak detection). |
| `dhx-poll-guard.sh` | `Read` | Rate-limits busy-polling on background-task output files (escalating cooldowns). |
| `dhx-read-cache.sh` | `Read` | Records partial Reads (offset/limit) to a session-scoped detection store (`~/.cache/dhx/partial-read-detect-<session_id>.jsonl`) keyed on session_id; feeds the read-guard's PARTIAL-READ NOTE. |
| `dhx-read-dedup.sh` | `Read` | Content-dedup measurement + Guard-2 short-TTL strict deny: logs re-read bands per (session, agent) to a durable stats file, and DENIES a full→full unchanged re-read <120s after a prior full read in the same agent context (no compaction since) — the content is still in context; the deny reason substitutes for the re-read. Kill-switch `DHX_READ_DEDUP_DENY_DISABLED=1`. |

### PostToolUse

| Hook | Matcher | Purpose |
|------|---------|---------|
| `dhx-merge-reminder.sh` | `Skill` | After milestone-completion skills, reminds user to merge working branch. |
| `dhx-new-milestone-promote-reminder.sh` | `Skill` | After `/gsd-new-milestone`, reminds `/dhx:backlog promote-next` if `next`-tagged briefs exist. |
| `dhx-source-write-flag.sh` | `Write\|Edit` | Sets per-turn flag for the test-gate when source files are written. |
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

`gsd/` contains read-only snapshots of upstream `gsd-build/get-shit-done` hooks, vendored for fork-tracking. The fork-and-modify lineage for `gsd-read-guard.js` → `dhx/dhx-read-guard.js` is documented in commit history; the fork adds session-scoped partial-read detection the upstream binary doesn't (see `dhx/dhx-read-cache.sh` + the `probe-read-cache.sh` / `probe-read-guard-partial-detection.sh` probes).

## License

[MIT](LICENSE) — copyright 2026 0xdhx.
README_EOF

cat > CHANGELOG.md <<'CHANGELOG_EOF'
# Changelog

All notable changes to dhx-hooks will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-28

### Added
- **HP-028 SIGPIPE+pipefail static lint** — `tests/probes/probe-sigpipe-pipefail-shapes.sh` + `scripts/verify-hook-patterns.sh` check #5 enforce the `cmd | grep -[qm] PATTERN` shape as a structural invariant via two surfaces: at-rest probe (auto-discovered by `run-probes.sh`) + commit-time gate. HP-028 documents the broader runtime class (`grep -q`, `grep -m N`, `head -N`, `awk` early-exit, `sed N q`); the lint enforces the `grep -[qm]` subset where SIGPIPE bites control flow.
- **Probe-suite pre-commit gate** — `verify-hook-patterns.sh` check #8 runs `scripts/run-probes.sh` when `dhx/*.js` or `tests/probes/*` are staged. Catches wrapper-fixture drift at commit time.
- **Restart-plugins acknowledgment marker** — `dhx/dhx-restart-plugins-stop.sh` Stop hook scans transcript for `/reload-plugins` / `/restart-plugins` and writes a per-session marker the statusline consumes to clear stale-plugin warnings without a full session restart.
- **Plugin-registry drift detector** — `statusline-wrapper.js::checkPluginRegistry` surfaces 6 corruption shapes (UNREADABLE, BADJSON, MISSING:dhx-local, etc.) as a critical-tier statusline warning.
- **Hooks-json wiring canary** — `dhx/dhx-health-check.sh` verifies every manifest-referenced hook script's `~/.claude/hooks/<basename>` symlink resolves back to the dhx repo. Catches symlink-side drift the plugin-keys check can't see.
- **Plugin registry self-heal** — `dhx/dhx-plugin-registry-heal.sh` writes a valid `installed_plugins.json` seed at SessionStart when the file is unreadable, unparseable, or missing the dhx entry (HP-025 detector companion).
- **Fake-`$HOME` fixture helper** — `tests/probes/_make-fake-home.js` centralizes wrapper require-boundary scaffolding for probes that exercise `dhx/statusline-wrapper.js` end-to-end.

### Changed
- **HP-028 SIGPIPE+pipefail sweep across 8 hooks** — `cmd | grep -q PATTERN` patterns replaced with here-string / process-substitution forms (rounds 1 + 2). Audit-clean: `grep -rn '| *grep -q' dhx/` returns zero matches outside HP-028 reference comments.
- **Statusline wrapper refactor** — repo signals moved out of the renderer's `runStatusline()` body and exposed as wrapper-level imports; composer places signals after cache/git on line 1 (live-signal cluster reads cache → git → signals left-to-right). Drops milestone name; rearranges L1/L2.
- **Hairline meta-glyph** — leftmost glyph aggregates health/drift/sigil signals into one character: dim green `∙` (clean) / bright yellow `⌃` (warn). Recedes on clean path while preserving "watcher dead" detection.
- **Statusline self-diagnosis sigils** — each segment crash produces a red `⚠ <segment>?` glyph + JSONL log entry (1MB rotation) instead of silently collapsing the whole statusline.
- **Last-user-prompt segment** — line 2 surfaces a truncated form of the most recent user prompt for at-a-glance context recall.
- **Mobile mosh collapse** — line 2 collapses on narrow terminals to keep the L1 telemetry cluster visible.

### Fixed
- **Probe runner env leak** — `scripts/run-probes.sh` unsets inherited `GIT_*` env vars so probes that build tmpdir fixtures (`git init`, worktree-add) don't inherit the parent commit's git state. Latent bug since the runner was authored; surfaced first time the probe suite ran from inside a `git commit`.
- **Stale-worktree sweep allowlist** — `dhx/dhx-stale-worktree-sweep.sh` Gate 2 allows `.claude/`-prefix untracked entries to auto-sweep; tracked-file modifications still block. Mitigates `gh#36182` worktree-leak class.
- **Drift detector false positives** — filters CC's `temp_git_*` install-cycle clones; skips directory mtimes in plugin scans (was firing daily on plugin-cache orphan-sweep across all sessions).
- **ccburn status enum sync** — picked up `at_pace` → `on_pace` rename so session emoji renders correctly.
- **Fork-aware GSD drift suppression** — drift warnings no longer fire on dhx-owned forks of upstream gsd hooks (the fork content diverges by design; mtime drift is expected).

## [0.1.1] - 2026-04-27

### Added
- `ARCHITECTURE.md` — high-level overview of the five hook surfaces (read tracking, drift detection, workflow guards, statusline composition, plugin manifest) and how they compose. Authored as a public-facing companion to `README.md`'s per-event hook tables.

## [0.1.0] - 2026-04-26

Initial public release. Mirror of the dhx hook surface from the private workflow repo. See README for the hook inventory.

### Added
- `dhx/` hook source: SessionStart health/drift/worktree checks, PreToolUse read-cache + read-guard (session-scoped partial-read detection), workflow + prompt guards, validate-commit, worktree-bash-guard, ui-vision-guard, statusline composition.
- `dhx-plugin/` Claude Code plugin manifest registering all dhx hooks (rewriter-safe via plugin manifest path).
- `tests/probes/` regression probe corpus (~22 active probes) asserting runtime invariants.
- `scripts/run-probes.sh`, `scripts/verify-hooks.sh`, `scripts/sync-public-mirror.sh`.
- `config/settings.json` drift snapshot of live Claude Code settings for change detection.
- `gsd/` read-only snapshots of upstream `gsd-build/get-shit-done` hooks (vendored for fork-tracking).

### Notable hooks
- **Partial-read advisory** (`dhx-read-cache.sh` + `dhx-read-guard.js`) — session-scoped detection of files Read with `offset`/`limit` this session, surfaced as a soft PARTIAL-READ NOTE on any later Edit/Write of that path (per-path detection; no read-window comparison). Covers CC's partial-read blindness (its native read-gate is binary — a partial read satisfies it for an edit anywhere); CC's runtime owns full read-before-edit enforcement and (since at least 2.1.217) natively notes modified-since-read on Edit.
- **Plugin-manifest registration** — survives Claude Code's atomic settings-rename rewriter.

[0.2.0]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.2.0
[0.1.1]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.1.1
[0.1.0]: https://github.com/0xdhx/dhx-hooks/releases/tag/v0.1.0
CHANGELOG_EOF

cat > LICENSE <<'LICENSE_EOF'
MIT License

Copyright (c) 2026 0xdhx

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE_EOF

# --- 4b. Single squash commit for the doc additions + scrub ---------------
# filter-repo's history is the source of truth; the scrub + docs land as one
# additional commit on top so re-runs produce a stable shape.
git add -A
if git diff --cached --quiet; then
  echo "[sync] no scrub/docs delta — re-run produced identical output (rare; usually a no-op only if last sync was on the same private HEAD with same paths/scrubs)"
else
  git -c user.email=public-mirror@dhx.local -c user.name="dhx-hooks public mirror" \
    commit -m "docs: scrub cross-references + add README, CHANGELOG, LICENSE" >/dev/null
fi

# --- 5. Push to public remote ---------------------------------------------
PUB_HEAD=$(git rev-parse HEAD)

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "[sync] rehearsal — skipping push to $PUBLIC_REMOTE and tag (pass --push to publish)"
  echo "[sync] would-be public HEAD: $PUB_HEAD"
  echo "[sync] BUILD_DIR retained for inspection: $BUILD_DIR/dhx-hooks"
  trap - EXIT  # disable cleanup
  exit 0
fi

echo "[sync] pushing to $PUBLIC_REMOTE..."
git remote add public "$PUBLIC_REMOTE" 2>/dev/null || git remote set-url public "$PUBLIC_REMOTE"

# --- Lease protection (Codex review finding 9) -----------------------------
# A bare `--force` overwrites whatever is on the remote, including a legitimate update
# made by someone else WHILE this run was filtering and scrubbing (that takes minutes).
# Both parties can have passed --push and the result still be unintended. Fetch the
# current remote tip and stake a lease on it: if main moved under us, the push refuses
# and the operator re-runs against the new state.
REMOTE_MAIN=$(git ls-remote public refs/heads/main 2>/dev/null | cut -f1)
if [ -n "$REMOTE_MAIN" ]; then
  git fetch --quiet public refs/heads/main 2>/dev/null || true
  if ! git push --force-with-lease="refs/heads/main:$REMOTE_MAIN" public HEAD:main >/dev/null 2>&1; then
    echo "[sync] FAIL: lease refused — public main moved during this run (expected $REMOTE_MAIN)." >&2
    echo "[sync]       Nothing was published. Re-run to rebuild against the new remote state." >&2
    exit 1
  fi
else
  # Empty remote (first publish / fixture): no tip to stake a lease on.
  git push --force public HEAD:main >/dev/null 2>&1
fi
MAIN_PUBLISHED=1   # from here on, main IS public — see the tag-failure branch below

# Tag if absent (idempotent — `git tag` exits non-zero if tag already exists locally)
if ! git rev-parse "$TAG_VERSION" >/dev/null 2>&1; then
  git tag -a "$TAG_VERSION" -m "Release $TAG_VERSION"
fi
# Partial-publish honesty (Codex review finding 8): main and the tag are two separate
# pushes. If the tag push fails, `set -e` would exit non-zero with main ALREADY public —
# and any caller reading "non-zero" as "nothing published" inherits exactly the
# false-confidence shape of the timeout that caused incident 2. Say it out loud.
if ! git push --force public "$TAG_VERSION" >/dev/null 2>&1; then
  echo "[sync] WARN: tag push failed, but MAIN IS ALREADY PUBLISHED at $(git rev-parse HEAD)." >&2
  echo "[sync]       This run's non-zero exit does NOT mean 'nothing was published'." >&2
  exit 1
fi

# --- 6. Verify permalinks --------------------------------------------------
echo "[sync] verifying permalinks (HTTP 200)..."
sleep 5  # GitHub propagation
PERMALINK_FAILS=0
for path in \
  dhx/dhx-read-cache.sh \
  dhx/dhx-read-guard.js \
  tests/probes/probe-read-cache.sh \
  tests/probes/probe-read-guard-partial-detection.sh \
  README.md \
  CHANGELOG.md \
  LICENSE \
  ARCHITECTURE.md
do
  url="https://raw.githubusercontent.com/0xdhx/dhx-hooks/${PUB_HEAD}/${path}"
  code=$(curl -sf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$code" != "200" ]; then
    PERMALINK_FAILS=$((PERMALINK_FAILS + 1))
    echo "  [FAIL $code] $url"
  else
    echo "  [OK 200] $path"
  fi
done

if [ "$PERMALINK_FAILS" != "0" ]; then
  echo "[sync] WARN: $PERMALINK_FAILS permalinks did not return 200 — re-check after propagation."
fi

# --- 7. Summary -----------------------------------------------------------
echo ""
echo "[sync] DONE"
echo "  private HEAD: $PRIVATE_HEAD"
echo "  public HEAD:  $PUB_HEAD"
echo "  public tag:   $TAG_VERSION"
echo ""
echo "Map private→public hash in docs/decisions.md when filing upstream proposals."
