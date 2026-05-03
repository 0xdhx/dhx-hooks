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
#   5. Force-push to git@github.com:0xdhx/dhx-hooks.git
#   6. Verify a sample of permalinks resolve HTTP 200
#
# Idempotent — safe to re-run. Re-runs republish the public-side history
# from current private HEAD; all derived public hashes change atomically.
#
# Patterns: HP-007, HP-017
set -euo pipefail

REPO_ROOT=$(git -C "$(dirname "$(realpath "$0")")/.." rev-parse --show-toplevel)
PUBLIC_REMOTE="${PUBLIC_REMOTE:-git@github.com:0xdhx/dhx-hooks.git}"
TAG_VERSION="${TAG_VERSION:-v0.2.0}"
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
# scripts/ inventory.
rm -f scripts/sync-public-mirror.sh scripts/public-paths.txt

# --- 3. Scrub pass ---------------------------------------------------------
echo "[sync] scrubbing cross-references..."

# Class A: delete `# Backs ... docs/decisions.md ...` and `// Backs ... docs/decisions.md ...` lines
find tests/probes -type f \( -name '*.sh' -o -name '*.js' \) \
  -exec sed -i '/^# Backs[a-z]*:\?[[:space:]]\+docs\/decisions\.md/d; /^\/\/ Backs[a-z]*:\?[[:space:]]\+docs\/decisions\.md/d' {} +

# Class A surgical: read-cache probe headers fuse `# Backs the v1.1 Phase 1
# atomic-commit decisions.md row` with substantive text on continuation lines.
# Single-line regex above can't safely delete those without orphaning English.
# Per-file rewrites preserve substantive content while stripping cross-refs.
sed -i 's|^# Backs the v1.1 Phase 1 atomic-commit decisions\.md row (Option B retire$|# Replaces ~/.claude/read-once/ with a dhx-owned read-tracking stack (Option B retire|' tests/probes/probe-read-cache.sh
# Now line 5 still says "# ~/.claude/read-once/, own the read-tracking stack). Asserts:"
# which becomes redundant — collapse it:
sed -i 's|^# ~/\.claude/read-once/, own the read-tracking stack)\. Asserts:$|# ~/.claude/read-once/). Asserts:|' tests/probes/probe-read-cache.sh

sed -i 's|^# Backs the v1.1 Phase 1 atomic-commit decisions\.md row (REQ READ-06,$|# Asserts (REQ READ-06,|' tests/probes/probe-read-cache-concurrency.sh

# probe-read-cache-cross-session.sh: 3-line block — replace lines 4 and 5,
# delete line 6's "(the load-bearing citation...)" parenthetical.
sed -i 's|^# Backs the v1.1 Phase 1 atomic-commit decisions\.md row (REQ READ-03,$|# Asserts (REQ READ-03,|' tests/probes/probe-read-cache-cross-session.sh
sed -i 's|^# READ-11) AND reports/done/2026-04-15-read-guard-session-scoping-false-positives\.md$|# READ-11) that the|' tests/probes/probe-read-cache-cross-session.sh
sed -i '/^# (the load-bearing citation for the global-TTL design)\. Asserts that the$/d' tests/probes/probe-read-cache-cross-session.sh

sed -i 's|^# Backs the v1.1 Phase 1 atomic-commit decisions\.md row (D-13 rename-then-$|# Backs the D-13 rename-then-|' tests/probes/probe-read-cache-prune-concurrency.sh

# probe-write-cache.sh has a similar pattern
sed -i 's|^# Backs the 2026-04-19 decisions\.md row "dhx-write-cache\.sh: PostToolUse|# Asserts dhx-write-cache.sh PostToolUse|' tests/probes/probe-write-cache.sh

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

# Class D: forgefinder → acme-app in test fixtures
sed -i 's|/home/dhx/repos/forgefinder|/home/dhx/repos/acme-app|g' tests/probes/probe-worktree-bash-guard.sh
sed -i 's|forgefinder Phase 26|a real-world Phase 26|' tests/probes/probe-deferred-check-header-fallback.sh

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

DOCS_PATTERN="docs/(decisions|architecture|backlog|hook-patterns|hook-dev-guide|statusline-wrapper|troubleshooting|upstream-proposal-discipline|research|design)[/.][a-z0-9./-]+\.md"
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
| `dhx-main-branch-warning.sh` | Warns once per boot when working directly on `main`/`master`. |

### PreToolUse

| Hook | Matcher | Purpose |
|------|---------|---------|
| `dhx-assessed-guard.sh` | `Write\|Edit` | Prevents `[assessed]` markers without explicit user approval. |
| `dhx-read-guard.js` | `Write\|Edit` | Read-before-edit advisory using a 7200s global TTL on `~/.cache/dhx/read-cache.jsonl`. Three-state advisory (silent/soft/strong). |
| `dhx-worktree-write-guard.sh` | `Edit\|Write\|MultiEdit` | Blocks writes whose absolute path escapes the enclosing CC-managed worktree (gh#36182 mitigation). |
| `dhx-ui-vision-guard.sh` | `Agent` | Ensures `z-gsdui` project skill exists when GSD UI subagents spawn. |
| `dhx-agent-leak-snapshot.sh` | `Agent` | Captures pre-dispatch `git status` baseline for paired post-check (subagent-leak detection). |
| `dhx-poll-guard.sh` | `Read` | Rate-limits busy-polling on background-task output files (escalating cooldowns). |
| `dhx-read-cache.sh` | `Read` | Sole writer for `~/.cache/dhx/read-cache.jsonl`. Lock-free `>>` appends; flock-protected prune. |

### PostToolUse

| Hook | Matcher | Purpose |
|------|---------|---------|
| `dhx-merge-reminder.sh` | `Skill` | After milestone-completion skills, reminds user to merge working branch. |
| `dhx-new-milestone-promote-reminder.sh` | `Skill` | After `/gsd-new-milestone`, reminds `/dhx:backlog promote-next` if `next`-tagged briefs exist. |
| `dhx-source-write-flag.sh` | `Write\|Edit` | Sets per-turn flag for the test-gate when source files are written. |
| `dhx-write-cache.sh` | `Write\|Edit` | Mirrors successful writes into the read cache (`source:"write"` entries) — closes Write→Edit false-positive class. |
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

`gsd/` contains read-only snapshots of upstream `gsd-build/get-shit-done` hooks, vendored for fork-tracking. The fork-and-modify lineage for `gsd-read-guard.js` → `dhx/dhx-read-guard.js` is documented in commit history; the fork ships persistent JSONL state-tracking the upstream binary doesn't (see `dhx/dhx-read-cache.sh` + the `probe-read-cache*` probe corpus).

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
- `dhx/` hook source: SessionStart health/drift/worktree checks, PreToolUse read-cache + read-guard with persistent JSONL state-tracking, workflow + prompt guards, validate-commit, worktree-bash-guard, ui-vision-guard, statusline composition.
- `dhx-plugin/` Claude Code plugin manifest registering all dhx hooks (rewriter-safe via plugin manifest path).
- `tests/probes/` regression probe corpus (~22 active probes) asserting runtime invariants.
- `scripts/run-probes.sh`, `scripts/verify-hooks.sh`, `scripts/sync-public-mirror.sh`.
- `config/settings.json` drift snapshot of live Claude Code settings for change detection.
- `gsd/` read-only snapshots of upstream `gsd-build/get-shit-done` hooks (vendored for fork-tracking).

### Notable hooks
- **Persistent JSONL read-cache** (`dhx-read-cache.sh` + `dhx-read-guard.js`) — cross-tool, cross-session read tracking with 7200s TTL. Three-state advisory (silent / soft / strong) finer-grained than upstream's binary skip. CCS-multi-instance safe.
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
  echo "[sync] DRY_RUN=1 — skipping push to $PUBLIC_REMOTE and tag"
  echo "[sync] would-be public HEAD: $PUB_HEAD"
  echo "[sync] BUILD_DIR retained for inspection: $BUILD_DIR/dhx-hooks"
  trap - EXIT  # disable cleanup
  exit 0
fi

echo "[sync] pushing to $PUBLIC_REMOTE..."
git remote add public "$PUBLIC_REMOTE" 2>/dev/null || git remote set-url public "$PUBLIC_REMOTE"
git push --force public HEAD:main >/dev/null 2>&1

# Tag if absent (idempotent — `git tag` exits non-zero if tag already exists locally)
if ! git rev-parse "$TAG_VERSION" >/dev/null 2>&1; then
  git tag -a "$TAG_VERSION" -m "Release $TAG_VERSION"
fi
git push --force public "$TAG_VERSION" >/dev/null 2>&1

# --- 6. Verify permalinks --------------------------------------------------
echo "[sync] verifying permalinks (HTTP 200)..."
sleep 5  # GitHub propagation
PERMALINK_FAILS=0
for path in \
  dhx/dhx-read-cache.sh \
  dhx/dhx-read-guard.js \
  tests/probes/probe-read-cache.sh \
  tests/probes/probe-read-cache-concurrency.sh \
  tests/probes/probe-read-cache-prune-concurrency.sh \
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
