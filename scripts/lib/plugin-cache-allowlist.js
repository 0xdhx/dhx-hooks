'use strict';
//
// scripts/lib/plugin-cache-allowlist.js
// =====================================
// Shared in-code allowlist for `~/.claude/plugins/cache/*` content. This is
// the D-06 consolidation realized as a shared module per D-14: the RAT-04
// novel-pattern allowlist must be consumed by TWO runtimes —
//   1. dhx/statusline-wrapper.js  — enumeration (`enumerateNovelPatterns`)
//   2. dhx/dhx-statusline.js      — Plan 03's render-time re-filter
// so it cannot live as inline constants in the wrapper. `scripts/lib/` is the
// established shared-code home (statusline-wrapper.js already
// `require('../scripts/lib/tiers.json')` at :641); this module sits beside
// tiers.json.
//
// WIDEN-ON-FALSE-POSITIVE POSTURE
// ------------------------------
// This allowlist is REVERSE-ENGINEERED. No authoritative CC manifest of
// legitimate plugins/cache content exists — the sets below are seeded from a
// live `ls -R ~/.claude/plugins/cache/` survey (2026-05-21) plus the RAT-04
// brief's enumerated set. The first few CC upgrades are EXPECTED to surface
// false positives: a legitimate new file class the operator triages by adding
// a pattern here. D-13a's intended steady state — "the `⚠ cc-novel` warning
// clears when the operator widens the allowlist" — is made real by Plan 03's
// render-time re-filter (D-14): the renderer re-applies `isAllowlisted` at
// render time, so a widened allowlist clears the segment on the next refresh
// without waiting for a CC version bump. Phase 18 DRIFT-ALLOW-01 inherits this
// module's structure directly and inverts it (allowlist → drift-suppression
// allowlist for the `plugins` trigger).
//
// PURITY (D-12)
// -------------
// This module is pure JS — no `require('fs')`, no subprocess. It is reviewed
// CODE, not data; it crosses no process or network boundary. `isAllowlisted`
// is a total function over (string, string).
//
// DUAL-USE CONSTRAINT
// -------------------
// `bookkeepingBasenames` (Set) and `bookkeepingPathPattern` (RegExp) ALSO
// drive `scanRecursive`'s existing `ignoreBasenames` / `ignorePathPattern`
// filter in statusline-wrapper.js — that call signature requires exactly a
// `Set` and a `RegExp`, so the two members keep those concrete types. The
// drift-filter behavior of the `plugins` trigger MUST stay byte-identical to
// the pre-consolidation inline constants.

// --- bookkeepingBasenames ---------------------------------------------------
// CC-internal bookkeeping leaf files that churn without reflecting
// user-actionable state. Was the inline `PLUGIN_CACHE_IGNORE` constant.
// Drives scanRecursive's `ignoreBasenames`.
const bookkeepingBasenames = new Set([
  '.orphaned_at', // CC writes during session-start orphan sweeps + periodic GC
]);

// --- bookkeepingPathPattern -------------------------------------------------
// Two classes of CC-internal bookkeeping that only appear as INTERMEDIATE
// path components (never as a leaf basename). Was the inline
// `PLUGIN_CACHE_PATH_IGNORE` constant. Drives scanRecursive's
// `ignorePathPattern`.
//   (1) temp_git_<epoch_ms>_<token>/ — CC install-cycle clone dirs (no GC)
//   (2) .in_use/<pid>                — CC session-lifetime lock markers
const bookkeepingPathPattern = /(^|\/)(temp_git_\d+_[a-z0-9]+|\.in_use)(\/|$)/;

// --- legitContentBasenames --------------------------------------------------
// Legitimate plugin LEAF files. Seeded from the live survey + the RAT-04
// brief's enumerated set. `.claude-plugin` appears here AND in
// legitContentSegments because it occurs both as a leaf entry name and as an
// intermediate directory segment.
const legitContentBasenames = new Set([
  'plugin.json',
  'README.md',
  'README',
  'THIRD_PARTY_NOTICES.md',
  'LICENSE.txt',
  'LICENSE',
  'SKILL.md',
  '.gitignore',
  '.claude-plugin',
]);

// --- legitContentSegments ---------------------------------------------------
// Legitimate directory path SEGMENTS seen in the live survey.
const legitContentSegments = new Set([
  'skills',
  'spec',
  'template',
  'templates',
  'canvas-fonts',
  '.claude-plugin',
]);

// --- versionDirPattern ------------------------------------------------------
// Matches a `<git-hash>` directory segment (8-12 lowercase hex chars, e.g.
// `690f15cac7f7`) OR a dotted-semver directory INCLUDING prerelease/canary
// suffixes (D-16) — so `2.1.146-canary.2` and `1.0.0-beta.1` are allowlisted,
// not flagged novel. The semver branch is the D-16 mandate:
//   /^v?\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?$/
// The two shapes are expressed as one combined alternation, anchored as a
// full path segment.
const versionDirPattern =
  /^(?:[0-9a-f]{8,12}|v?\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?)$/;

// --- marketplaceTopLevel ----------------------------------------------------
// The three current top-level marketplace dirs (live survey 2026-05-21). This
// is a SEEDED allowlist (D-15) — an unknown 4th marketplace directory is
// INTENDED RAT-04 signal. `isAllowlisted` checks the first path segment ONLY
// against this set (no wildcard) so a new marketplace name itself surfaces as
// novel.
const marketplaceTopLevel = new Set([
  'anthropic-agent-skills',
  'claude-plugins-official',
  'dhx-local',
]);

const PLUGIN_CACHE_ALLOWLIST = {
  bookkeepingBasenames,
  bookkeepingPathPattern,
  legitContentBasenames,
  legitContentSegments,
  versionDirPattern,
  marketplaceTopLevel,
};

// --- isAllowlisted(filePath, basename) --------------------------------------
// The D-14 predicate. Given a path RELATIVE to `plugins/cache` (forward-slash,
// segment-joined) and a leaf `basename`, return `true` iff the entry is a
// known-safe pattern, `false` iff it is novel.
//
// PATH SHAPE (live survey 2026-05-21):
//   <marketplace>/<plugin>/<git-hash-or-version>/<...content...>
// Segment 0 is the marketplace dir, segment 1 is the plugin name, segment 2
// is a git-hash / version dir, segments 3+ are plugin content.
//
// Allowlisted (true) when ANY of:
//   - basename ∈ bookkeepingBasenames
//   - basename ∈ legitContentBasenames
//   - filePath matches bookkeepingPathPattern
//   - EVERY path segment is recognized, where:
//       * segment 0 (the marketplace dir) is checked ONLY against
//         marketplaceTopLevel — seeded, NO wildcard (D-15: an unknown 4th
//         marketplace surfaces as novel)
//       * segment 1 (the plugin name) under an allowlisted marketplace is
//         accepted — a plugin name is operator-installed content reached via
//         an already-vetted marketplace, not a novel-pattern signal; D-15's
//         "do not wildcard the FIRST segment" constrains the marketplace dir
//         only, and RESEARCH.md scenario 6 requires `<marketplace>/
//         document-skills/<git-hash>/...` to report 0 novel
//       * every later segment matches legitContentSegments OR
//         versionDirPattern OR legitContentBasenames (the leaf basename) OR
//         bookkeepingBasenames
//
// Novel (false) otherwise.
function isAllowlisted(filePath, basename) {
  // Fast bookkeeping checks — these short-circuit before per-segment work.
  if (typeof basename === 'string') {
    if (bookkeepingBasenames.has(basename)) return true;
    if (legitContentBasenames.has(basename)) return true;
  }
  if (typeof filePath === 'string' && bookkeepingPathPattern.test(filePath)) {
    return true;
  }

  if (typeof filePath !== 'string' || filePath === '') return false;

  // Per-segment evaluation. Normalize separators, drop empties (leading/
  // trailing/double slashes).
  const segments = filePath.split(/[/\\]+/).filter(Boolean);
  if (segments.length === 0) return false;

  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    if (i === 0) {
      // Segment 0 is the marketplace dir — seeded set ONLY (D-15). An
      // unknown 4th marketplace is intended RAT-04 signal.
      if (!marketplaceTopLevel.has(seg)) return false;
      continue;
    }
    if (i === 1) {
      // Segment 1 is the plugin name under an already-vetted marketplace.
      // Any plugin name here is operator-installed content, not a novel
      // pattern — accept it. (A novel pattern would surface in segments 2+
      // or via an unrecognized leaf basename.)
      continue;
    }
    // Segment 2+ : a legit directory segment, a version/git-hash dir, a
    // known leaf basename (the final segment is the leaf), or bookkeeping.
    if (legitContentSegments.has(seg)) continue;
    if (versionDirPattern.test(seg)) continue;
    if (legitContentBasenames.has(seg)) continue;
    if (bookkeepingBasenames.has(seg)) continue;
    return false; // a segment matched nothing → novel
  }
  return true;
}

module.exports = { PLUGIN_CACHE_ALLOWLIST, isAllowlisted };
