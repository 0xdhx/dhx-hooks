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
// PHASE 18 POSTURE FLIP (D-13) — THESE SETS ARE NOW LOAD-BEARING FOR DRIFT
// -----------------------------------------------------------------------
// Pre-Phase-18 these content sets backed ONLY the `⚠ cc-novel` novel detector,
// so a content-set GAP was a novel-detector FALSE POSITIVE (annoying, self-
// healing). Post-inversion (D-03) `content`-classified entries drive the
// `⚠ restart plugins` DRIFT signal and `novel` entries are EXCLUDED from the
// drift mtime/count — so a content-set gap is now a drift FALSE-NEGATIVE: a
// real plugin file change under an unrecognized path silently fails to fire
// `⚠ restart plugins`. RESEARCH.md FINDING-1 measured 1670/4271 live leaves
// (39.1%) classifying `novel` under the pre-Phase-18 sets. Two structural
// fixes land here (Phase 18 Plan 01) BEFORE the inversion (Plan 02) makes the
// sets load-bearing:
//   (1) D-13 Path A widening — `legitContentSegments` is widened with the
//       unrecognized real-content INTERMEDIATE segments enumerated in
//       RESEARCH.md § Content-Allowlist Gap Analysis (office/schemas/scripts/
//       docx/pptx/xlsx/…). SHAPE-AWARE constraint: widen ONLY by path-scoped
//       segment patterns and named basenames — NEVER by allowlisting bare-hex
//       object-hash basenames or loosening versionDirPattern, which would
//       re-open the false-negative hole from the other side (RESEARCH.md §
//       Anti-Patterns). `.git/` internals are handled by the path-scoped
//       gitInternalsPathPattern below, never by basename allowlisting.
//   (2) D-24d LEAF RULE — classifyEntry no longer requires the LEAF basename
//       to be in legitContentBasenames; a leaf with an arbitrary basename
//       under fully-recognized intermediate ancestry classifies `content`.
//       This (not basename enumeration) is the actual mechanism that closes
//       the 39.1% gap; `novel` then fires only on an unrecognized INTERMEDIATE
//       segment or unknown marketplace. See classifyEntry below.
// The WIDEN-ON-FALSE-POSITIVE posture above still holds for residual gaps; the
// consequence of a gap is what flipped (drift false-negative, not just novel
// false-positive).
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

// --- gitInternalsPathPattern ------------------------------------------------
// Path-scoped bookkeeping for `.git/` internals of in-cache plugin git
// checkouts (D-13 Path A / D-26). RESEARCH.md FINDING-1 found a COMPLETE git
// repository checked out inside `claude-plugins-official/superpowers/5.0.7/
// .git/` — its `.git/objects/` loose-object basenames (2-hex dir + 38-hex
// file) match neither versionDirPattern (anchored 8-12 hex) nor any basename
// set, so the `.git` segment and every object under it classified `novel`. A
// git operation inside a plugin's OWN VCS metadata is NOT a plugin content
// change, so `.git/` internals classify `bookkeeping` (silent).
//
// SHAPE-AWARE (RESEARCH.md § Anti-Patterns): the `.git/` surface is handled
// ENTIRELY by this path-scoped pattern, NEVER by allowlisting the bare-hex
// object-hash basenames — a loose hex-basename widening would re-open the
// false-negative hole. classifyEntry checks this BEFORE the D-24d leaf rule,
// so bare-hex object hashes never reach the leaf rule.
//
// SEPARATOR-AGNOSTIC (D-26): uses the `[/\\]` character class to match the
// module's established `.split(/[/\\]+/)` idiom — NOT a bare `\/`. Belt-and-
// suspenders given D-20 forward-slash-normalizes the path the wrapper feeds
// in, but the module's own convention is separator-agnostic so the new pattern
// aligns with it. Linux-only repo per CLAUDE.md, so this is consistency
// hygiene, not cross-platform breakage.
const gitInternalsPathPattern = /(^|[/\\])\.git([/\\]|$)/;

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
  // --- widened (D-13 Path A) — ROOT-level plugin config files -------------
  // These recur as plugin-ROOT leaves (e.g. <marketplace>/<plugin>/<version>/
  // package.json) where there is no recognized INTERMEDIATE segment for the
  // D-24d leaf rule to lean on, so they are named explicitly. SHAPE-AWARE
  // constraint (RESEARCH.md § Anti-Patterns): named config basenames only —
  // NO bare-hex object-hash basenames, NO font/schema EXTENSIONS (those leaves
  // reach `content` via the D-24d leaf rule under their recognized parent
  // segments `schemas/`/`canvas-fonts/`, not via this set).
  'package.json',
  'package-lock.json',
  'tsconfig.json',
]);

// --- legitContentSegments ---------------------------------------------------
// Legitimate directory path SEGMENTS. Comment-split (D-24c) into two
// provenance groups so a future maintainer can tell which entries are
// architecturally guaranteed vs reverse-engineered from the live cache, and
// which to revisit if a future `novel` survey flags a segment-name collision.
const legitContentSegments = new Set([
  // --- plugin structural segments (high-trust, pre-Phase-18) --------------
  // The original Phase 17 seeding set — these are the canonical plugin layout
  // directories (a plugin "shape" guaranteed by the plugin spec / SKILL.md
  // convention), not reverse-engineered from any one cache.
  'skills',
  'spec',
  'template',
  'templates',
  'canvas-fonts',
  '.claude-plugin',

  // --- widened-from-survey segments (D-13 Path A — observed live-cache -----
  //     shape, 2026-05-22) ----------------------------------------------------
  // Added from the RESEARCH.md § Content-Allowlist Gap Analysis live-tree
  // survey (the measurement that produced FINDING-1's 39.1% novel figure).
  // These are real plugin-content INTERMEDIATE directory classes (NOT leaf
  // basenames — leaves classify via the D-24d leaf rule under recognized
  // ancestry). Counts in the comments are the survey's leaf-files-affected.
  // Revisit any of these if a future residual-novel survey (D-24a/D-24b)
  // flags a segment-name collision with a genuinely-novel CC class.
  'scripts',              // 778 — plugin helper scripts (superpowers, document-skills)
  'office',               // 612 — document-skills OOXML resources
  'schemas',              // 468 — XSD schema files (docx/pptx/xlsx)
  'canvas-design',        // 324 — plugin sub-tree
  'ISO-IEC29500-4_2016',  // 324 — plugin sub-tree (OOXML standard)
  'docx',                 // 236 — document-skills format dir
  'pptx',                 // 228 — document-skills format dir
  'xlsx',                 // 208 — document-skills format dir
  'claude-api',           // 155 — API reference docs
  'tests',                // standard plugin sub-tree dir
  'microsoft',            // standard plugin sub-tree dir
  'skill-creator',        // standard plugin sub-tree dir
  'shared',               // standard plugin sub-tree dir
  'validators',           // standard plugin sub-tree dir
  'ecma',                 // standard plugin sub-tree dir
  'docs',                 // standard plugin sub-tree dir
  'hooks',                // standard plugin sub-tree dir
  'agents',               // standard plugin sub-tree dir
  'commands',             // standard plugin sub-tree dir
  'assets',               // standard plugin sub-tree dir
  'examples',             // standard plugin sub-tree dir
  'prompts',              // standard plugin sub-tree dir
  'themes',               // standard plugin sub-tree dir
  'python',               // standard plugin sub-tree dir
  'typescript',           // standard plugin sub-tree dir
]);

// --- versionDirPattern ------------------------------------------------------
// Matches a `<git-hash>` directory segment (8-12 lowercase hex chars, e.g.
// `690f15cac7f7`) OR a dotted-semver directory INCLUDING prerelease/canary
// suffixes (D-16) — so `2.1.146-canary.2` and `1.0.0-beta.1` are allowlisted,
// not flagged novel. The semver branch refines the D-16 mandate:
//   /^v?\d+\.\d+(\.\d+)?(-[0-9A-Za-z][0-9A-Za-z.-]*)?$/
// The prerelease suffix must START with an alphanumeric (IN-04 hardening): a
// pure dot/dash suffix (`1.0.0--`, `1.0.0-...`) is not a real version and now
// surfaces as novel instead of being silently allowlisted. Every legit
// semver/canary suffix (`-beta.1`, `-canary.2`) starts alphanumeric, so this
// only narrows the allowlist toward "miss a novel hit less often" — the safe
// direction under the module's WIDEN-ON-FALSE-POSITIVE posture. The two shapes
// are expressed as one combined alternation, anchored as a full path segment.
const versionDirPattern =
  /^(?:[0-9a-f]{8,12}|v?\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?)$/;

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
  gitInternalsPathPattern,
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
