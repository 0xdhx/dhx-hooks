#!/usr/bin/env bash
# scripts/hooks/pre-commit.d/30-deletion-audit.sh — bind the deletion audit to git's
# real candidate instead of instructing an agent to run it.
#
# ── THIS IS A PORT (2026-09-14), NOT A SHARED FILE ─────────────────────────────────
# Ported from ~/repos/skills/scripts/hooks/pre-commit.d/30-deletion-audit.sh under the
# hooks repo's own protocol. Each repo owns its pre-commit chain, so this file is a COPY:
# no symlink, no vendor-sync — a coupling between the two copies would be the drift
# source, not a cure for it. Below the `set -uo pipefail` line the BODY IS BYTE-IDENTICAL
# to the skills leaf at its authoring SHA except for the two comment blocks named here;
# `diff` the two files to check — every difference must be one of these, or a defect:
#   1. THIS block and the WHY THIS EXISTS measurement: the hooks-repo base rate below
#      was re-measured over hooks-repo transcripts, never inherited from skills'.
#   2. The fixture exemption comment (§ Opt-out): the hooks probe suite has no shared
#      tests/lib.sh. Its fixtures COPY THE DISPATCHER PLUS NAMED LEAVES, never the
#      whole tree (probe-backlog-frontmatter-gate.sh copies pre-commit + the 10- leaf;
#      probe-red-debt-pairing.sh writes its own .git/hooks/pre-commit), so no fixture
#      carries this leaf today. scripts/run-probes.sh still exports
#      DHX_DELETION_AUDIT=off for every probe it runs, so a future fixture that installs
#      the WHOLE chain (e.g. via scripts/install-hooks.sh on a clone) stays exempt by
#      construction; tests/probes/probe-deletion-audit-leaf.sh is the one probe that
#      must watch this leaf fire and unsets it.
#   3. The Probe/Ruling pointers at the end of this header.
# INTENTIONAL NON-DIVERGENCES, stated so nobody "fixes" them:
#   - ORDERING COST. The hooks dispatcher runs 05-verify-hook-patterns.sh FIRST, and
#     that leaf runs the hermetic probe tier whenever dhx/*.js or tests/probes/* is
#     staged (check #8). This leaf sits at 30-, AFTER it, so a first-sight refusal on a
#     probe-touching commit pays the tier once on the refusal and again on the rerun.
#     The filename is kept for cross-repo parity: git-safe.sh, the backlog committers'
#     retry helper, and every ruling name `30-deletion-audit.sh`. Re-number only with a
#     measured tier time in hand and a ruling in docs/decisions.md.
#   - THE FIRING RECORD IS A SHARED INSTRUMENT. Both leaves append under
#     $CLAUDE_CONFIG_DIR/dhx-state/deletion-audit/, one file per repo BASENAME
#     (`hooks.jsonl` here). The RETIRE CONDITION below deletes the whole directory, so
#     retirement is JOINT: retire both writers in the same pass, never one — a surviving
#     writer would recreate the directory and the retired half's sidecar sweep with it.
#   - THE SENTINEL CONTRACT IS THE CONSUMER'S, NOT THIS LEAF'S. The line, its column-0
#     anchoring and its parent= field are pinned by dhx-shared/lib/git-safe.sh
#     (git_safe_commit ≥ 1.9, which `dhx-commit -C ~/repos/hooks` sources) and by the
#     skills-repo backlog committers' shared helper — the same consumers that retry a
#     commit in THIS repo. Emit the same bytes or every scripted commit here blocks on
#     first sight with no retry.
#
# WHY THIS EXISTS. /dhx:skills Step 5a and /dhx:hooks Step 4a require an agent to
# enumerate every deleted line from a raw zero-context patch and name each by class,
# with an unnamed deletion counting as a red. Check 4 in each verification file pins
# that prose. None of it BINDS: every one of those checks asserts that TEXT EXISTS in
# a markdown file, and the thing deciding whether to execute the instruction is the
# same agent the instruction addresses. RE-MEASURED FOR THIS REPO on 2026-09-14 (the
# skills number was not inherited): over hooks-repo transcripts 2026-08-30..2026-09-14,
# of 42 authored commits to ~/repos/hooks inside /dhx:hooks sessions after Step 4a shipped,
# 17 (40.5%) ran the mandated -U0 enumeration, 3 (7.1%) substituted a bare --stat/--numstat
# count (the anti-pattern the floor names by name), and 22 (52.4%) committed with no
# staged-diff surface at all; every one of the 7 library-generated commits (prompt
# closeout, report close) surfaced nothing. Skills measured 32.5/4.6/62.9 over 151 —
# similar, not materially different, so the port ships at full scope. Evidence:
# ~/repos/skills/reports/2026-09-14-hooks-deletion-audit-base-rate-evidence/. This leaf
# closes that gap at the only layer that cannot be skipped.
#
# WHAT IT IS NOT. It is not a confirm gate. It asks no question and accepts an
# unchanged rerun with no input: on FIRST SIGHT of a given (HEAD, write-tree) pair it
# prints git's real candidate patch and exits non-zero; rerun the identical commit and
# it proceeds automatically. A CHANGED candidate is a new pair and is surfaced again.
# See ~/repos/skills/dhx-shared/references/confirm-gate-disposition.md — the two floors it honours are
# "never auto-proceed on a red" and "surface is not silence".
#
# WHAT IT ENFORCES, STATED HONESTLY. It forces the deletion set into context at the
# commit boundary, on every commit, before the commit is durable. It CANNOT force an
# agent to name each deletion by class — nothing can. It converts "the deletion set was
# never seen" into "the deletion set was always seen", which is a bounded gain, not the
# whole floor.
#
# WHY THE CANDIDATE, NOT A RECONSTRUCTION. During a pathspec commit
# (`git commit -- <paths>`) git hands the hook a TEMPORARY index of HEAD plus that
# commit's own pathspec, exported as GIT_INDEX_FILE. Every read below — write-tree,
# numstat, the -U0 patch — therefore describes exactly the tree about to be recorded,
# including the worktree contents a pathspec commit picks up. That closes two defects
# the skill-body recipe cannot: the before/after-staging window, and the worktree-vs-index
# gap (`git commit -- <paths>` records the WORKTREE, not the index an agent audited).
#
# THE AUTHORITY SEMANTICS (~/repos/skills/docs/decisions/2026-09-06-u0-patch-is-the-deletion-authority.md).
# The -U0 patch is the authority on WHICH lines went; --stat/--shortstat are scale. This
# leaf therefore emits the patch RAW and performs NO mechanical stat-vs-patch comparison.
# A leaf that redded whenever a stat total exceeded the patch's `-` count would
# mechanically re-create the exact false red that ruling removed, and this time the
# author could not clear it by reading. Two structural notes:
#   - SCOPE BOUND: not applicable here, by construction. That bound exists because the
#     skill-body recipe pathspecs the patch while leaving the stat commands unscoped. This
#     leaf audits the WHOLE candidate with no pathspec, so a file staged outside an
#     expected set cannot hide — it appears in the emitted patch like any other.
#   - BINARY BOUND: a path git renders `Binary files ... differ` emits no `-` lines and
#     cannot be named line-wise. Those paths are reported SEPARATELY and by name, as the
#     ruling requires them to be accounted separately rather than silently absorbed.
#
# THE DELETION GATE. Deletion-free candidates exit 0 in silence. Firing is keyed on
# `git diff --cached --numstat HEAD`, which is a CONSERVATIVE oracle in the safe
# direction: measured over 300 commits of this repo, numstat and the -U0 patch diverge
# on 3 of 1347 file-changes and never in the concealing direction (0 of 435 text
# file-changes carrying deletions hid a removed line from the patch). So numstat >= the
# patch's deletion set — this gate can over-fire, never under-fire.
#
# CONCURRENCY (this repo runs many sessions against one worktree). The token is
# CONTENT-ADDRESSED on (HEAD, candidate tree), so two concurrent sessions holding
# different candidates compute different keys and cannot wedge each other; there is no
# lock and nothing to contend. An abandoned commit leaves a token that green-lights only
# a BYTE-IDENTICAL candidate on the same parent, and a TTL (default 900s) expires it far
# inside the window in which HEAD moves on this tree anyway. Stale tokens are pruned on
# every run.
#
# THE FIRING RECORD, AND WHAT IT CAN AND CANNOT ANSWER. This leaf enforces EXPOSURE, not
# naming; the conversion between the two — its find rate — was unmeasured at ship. One JSON
# line per event is appended to $CLAUDE_CONFIG_DIR/dhx-state/deletion-audit/<repo>.jsonl —
# OUTSIDE every consumer repo, because an untracked unowned file in a shared working tree is
# debris in every peer's `git status`, not instrumentation (the siting precedent and its
# refusal: ~/repos/skills/docs/decisions/2026-09-02-oracle-prestate-gate-report-only-execute-item-f.md).
# TWO events, and the pair is what carries the signal:
#   surfaced — first sight of a candidate, this leaf refusing
#   passed   — the unchanged rerun proceeding
# Read as a sequence per parent HEAD: surfaced(T1) then passed(T1) then a commit at T1 means
# exposure changed nothing. surfaced(T1) then surfaced(T2) means the candidate moved after
# exposure. A repeated passed(T1) with no surfaced between them means a LATER leaf blocked —
# which is the block-reason discriminator, derived from the log's own shape rather than from
# this leaf knowing anything about its siblings.
# THE SURFACED DELETION SET IS RECORDED, not left to be re-derived. `del_paths` is a list of
# {"p": path, "b": candidate blob sha} captured AT EXPOSURE. Both halves are load-bearing and
# the second is the one that took two review rounds to get right: a path NAME alone cannot
# answer "did anything in the surfaced deletion set change between the candidate and what
# finally committed", because that comparison needs the candidate's CONTENT — and the
# candidate tree is reachable from no ref, so `git gc` prunes it at ~14 days against a 30-day
# horizon. A landed commit is reachable forever, so `b` versus the committed blob at the same
# path answers it from the row alone, with nothing left to re-derive. `del_paths_truncated`
# reports that the inline array is a PREFIX, and `del_paths_spill` then names the sidecar
# under `sets/` holding the COMPLETE set — the cap bounds the row, never the evidence, because
# a discarded tail is exactly the uncomputable case. `repo` carries the absolute toplevel
# because the FILENAME is a bare basename that two checkouts can share. Line granularity is
# NOT recorded and is not claimed: a changed path is as fine as this instrument resolves.
# WHAT IT STILL CANNOT DO, stated so nobody reads more out of it than is there. It measures
# post-exposure CHANGE, which is an upper bound on the find rate, never causation — a peer
# moving HEAD or an unrelated gate forcing a re-stage looks the same from here. The value is
# asymmetric: a near-zero rate refutes this leaf decisively; a high rate proves little. And
# it does NOT name which sibling leaf refused: a leaf cannot observe a later leaf's exit, and
# the only component that can is the vendored dispatcher, which this repo does not hand-edit.
# What stands in for it is the log's own shape — a repeated `passed` with no `surfaced`
# between them means something after this leaf blocked, without naming it.
# RETENTION AND POSTURE, decided rather than deferred. WHERE: outside every consumer repo,
# under $CLAUDE_CONFIG_DIR/dhx-state/deletion-audit/, so the question of tracked-vs-ignored
# does not arise — the file is in no working tree and no `.gitignore` governs it. WHAT PRUNES
# IT: the writer itself, keeping the most recent DHX_DELETION_AUDIT_RECORD_CAP (5000) lines,
# which is far above the horizon's expected volume and exists so growth is bounded by a rule
# instead of by a promise. WHOLE-FILE END: the retire condition below deletes it outright.
# RETIRE CONDITION, written here so the later ruling is not re-derived: at 100 `surfaced`
# events, or 2026-10-08, whichever comes first — read the record once, rule on the leaf, then
# DELETE THE WHOLE $CLAUDE_CONFIG_DIR/dhx-state/deletion-audit/ DIRECTORY — the record file AND
# the sets/ sidecars — along with this block and its writer. Naming only the record file would
# orphan the sidecars permanently: retiring the writer removes the only code that prunes them. An instrument with no retire
# condition becomes permanent instrumentation nobody reads. Opt out with
# DHX_DELETION_AUDIT_RECORD=off; redirect with DHX_DELETION_AUDIT_RECORD_DIR (the probe sets
# it, so fixtures never pollute the sample).
#
# THE FIRST-SIGHT SENTINEL — a PINNED CONTRACT, not incidental output.
# A SCRIPTED caller cannot do what an interactive agent does (read the patch, rerun). It
# commits once and branches on the return code, so it reports a failed transition and hands
# the operator something that reads like a git fault. Three channels were tried and two are
# dead: a reserved EXIT CODE cannot reach any caller because git NORMALIZES hook exit status
# (a hook exiting 42 yields `git commit` rc 1; control: exit 0 yields rc 0), and bare TOKEN
# EXISTENCE cannot attribute a failure, because this leaf exits 0 on second sight so later
# leaves run — a surviving token plus a LATER leaf's refusal is indistinguishable from a
# first-sight refusal here. What survives is stderr, and it is attributable BY CONSTRUCTION:
# each `git commit` is its own process with its own stderr, so a sentinel on it cannot be
# confused with a later leaf's failure or a concurrent session's candidate.
#
# THE LINE, exactly:   DHX-DELETION-AUDIT-FIRST-SIGHT parent=<40-hex HEAD sha>
#
# THE MATCHER CONTRACT consumers pin: a stderr line whose START is the literal
# `DHX-DELETION-AUDIT-FIRST-SIGHT ` (trailing space included). ANCHORING AT COLUMN 0 IS
# LOAD-BEARING, not style: this leaf's own surface embeds a raw patch, and a commit that
# DELETES a line quoting the sentinel renders it as `-DHX-DELETION-AUDIT-FIRST-SIGHT …`.
# Every content and header line of a -U0 patch carries a prefix byte, so a bare sentinel at
# column 0 is producible by nothing but this leaf. An unanchored substring match would let a
# documentation edit forge a refusal.
#
# WHY `parent=` AND NOT `tree=`. The consumer needs two facts: that THIS leaf refused, and
# that HEAD has not moved under it. `parent` carries the second, so the retry's precondition
# reads off the one line. The candidate TREE is deliberately absent: a faithful retry re-runs
# the IDENTICAL commit with no re-staging, which presents the same tree implicitly, and a
# worktree that moved between attempts is a NEW candidate this leaf surfaces afresh — which a
# bounded single retry then correctly declines. Carrying it would add 46 chars, wrap the line,
# and answer nothing.
#
# EMITTED AFTER THE PATCH, AND THAT ORDERING IS A GUARANTEE. The sentinel is the final line
# THIS LEAF writes, so its presence implies the whole surface — scope, binary accounting,
# patch — was written. A sentinel reaching a caller WITHOUT its patch would license a retry of
# a commit whose deletion set never reached anyone, which is the exact failure the token's
# write-after-emit ordering below exists to prevent. Truncation therefore fails CLOSED: no
# sentinel, no retry.
#   AND IT IS SUPPRESSED ENTIRELY WHEN THE PATCH IS TRUNCATED (DHX_DELETION_AUDIT_CAP).
#   The sentinel licenses an unattended retry, which is only sound while the emitted surface
#   IS the deletion set; a truncated patch is not. Measured 2026-09-12 before the guard:
#   at CAP=3 on a 59-deletion candidate the retry fired, the commit LANDED, and ZERO deletion
#   lines reached the caller. The audit was automated past on exactly the big sweeps it exists
#   for. The token is still written, so an INTERACTIVE rerun proceeds as before.
#
#   NOT the last line of the COMMIT's stderr, and a consumer must not assume it is. The
#   run-parts dispatcher (scripts/hooks/pre-commit) appends its own
#   `pre-commit: blocked by <leaf> (exit N)` line after whichever leaf refused, so anything
#   downstream of this leaf adds lines this leaf does not control. Match the sentinel
#   ANYWHERE in stderr, anchored at column 0 — never by reading the tail. (Measured
#   2026-09-12: a last-line probe arm went RED on the dispatcher's trailer while the leaf
#   was behaving correctly; the arm now asserts the sentinel FOLLOWS the final patch line.)
#
# EMITTED ON FIRST-SIGHT REFUSAL ONLY — never on the passing second sight. A sentinel on the
# `passed` path would assert a refusal that did not happen and break attribution outright.
#
# CONSUMERS (a reword must break all of them loudly, which the probe enforces). All of
# them live in ~/repos/skills and commit into THIS repo through the shared tooling:
#   ~/repos/skills/dhx-shared/lib/git-safe.sh          git_safe_commit >= 1.9 (dhx-commit -C ~/repos/hooks)
#   ~/repos/skills/scripts/lib/deletion-audit-retry.cjs  all FOUR backlog committers (.planning/backlog/ here)
#   ~/repos/skills/tests/probe-deletion-audit-scripted-retry.sh   pins these exact bytes
# Ruling: ~/repos/skills/docs/decisions/2026-09-12-deletion-audit-first-sight-sentinel-bounded-retry.md
#
# Probe (this repo): tests/probes/probe-deletion-audit-leaf.sh
# Ruling (this repo): docs/decisions.md 2026-09-14 row "binding deletion audit ported to the hooks pre-commit chain"
# Source ruling: ~/repos/skills/docs/decisions/2026-09-07-pre-commit-deletion-audit-binds-at-the-candidate.md
# Source leaf:   ~/repos/skills/scripts/hooks/pre-commit.d/30-deletion-audit.sh

set -uo pipefail

# ── Opt-out ────────────────────────────────────────────────────────────────────────
# A fixture commit is not an authored work commit and has no audit to bind. In THIS repo
# no probe fixture carries this leaf today (fixtures copy the dispatcher plus named
# leaves — see the PORT block above), but scripts/run-probes.sh exports
# DHX_DELETION_AUDIT=off for every probe it runs so a future whole-chain fixture stays
# exempt by construction. That runner export is the ONLY sanctioned use;
# tests/probes/probe-deletion-audit-leaf.sh unsets it because it must watch this leaf fire.
case "${DHX_DELETION_AUDIT:-}" in
  off|0|skip) exit 0 ;;
esac

# ── Guards: nothing to audit ───────────────────────────────────────────────────────
# Initial commit — no HEAD, so every path is an addition and no deletion is possible.
git rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 0

# Unmerged index — `git write-tree` cannot produce a candidate and a partial commit is
# refused by git anyway. Leave the merge machinery alone.
if [ -n "$(git ls-files --unmerged 2>/dev/null)" ]; then
  exit 0
fi

TREE="$(git write-tree 2>/dev/null)" || exit 0
[ -n "$TREE" ] || exit 0
HEAD_SHA="$(git rev-parse --verify HEAD 2>/dev/null)" || exit 0

# ── Deletion oracle ────────────────────────────────────────────────────────────────
# numstat: "<added>\t<deleted>\t<path>", with "-\t-\t<path>" for binary.
NUMSTAT="$(git diff --cached --no-ext-diff --no-textconv --numstat HEAD 2>/dev/null)"
[ -n "$NUMSTAT" ] || exit 0

TEXT_DELETIONS=0
BINARY_PATHS=""
while IFS=$'\t' read -r added deleted path; do
  [ -n "${path:-}" ] || continue
  if [ "$added" = "-" ] || [ "$deleted" = "-" ]; then
    BINARY_PATHS="${BINARY_PATHS}${path}"$'\n'
  else
    case "$deleted" in
      ''|*[!0-9]*) : ;;
      *) TEXT_DELETIONS=$(( TEXT_DELETIONS + deleted )) ;;
    esac
  fi
done <<< "$NUMSTAT"

# A binary path only matters here if it can CARRY a deletion — a pure addition cannot.
#
# REAL PATHNAMES ONLY, via -z. The numstat read above is NOT -z, so git QUOTES any path it
# deems unsafe for a terminal — a non-ASCII byte, a double quote, a backslash, a control
# byte — and renders it as "caf\303\251.bin". That rendered string is not a pathspec: fed
# back to git it matches nothing, the status reads EMPTY, and the branch below files the
# binary as a pure addition. Measured 2026-09-14 (close-gate refutation of the hooks-repo
# port, executed counterexample): a MODIFIED binary named café.bin committed at rc 0 with
# no surface at all, while plain.bin in the same candidate was caught. So the status map and
# the binary set are both read -z, one pass each, and joined by the real name. A rename in
# -z output carries its two paths as the two tokens after the status / count token.
BINARY_CHANGED=""
if [ -n "$BINARY_PATHS" ]; then
  declare -A _bst=()
  _st=""; _p1=""
  while IFS= read -r -d '' _tok; do
    if [ -z "$_st" ]; then _st="$_tok"; _p1=""; continue; fi
    case "$_st" in
      R*|C*)
        if [ -z "$_p1" ]; then _p1="$_tok"; continue; fi
        _bst["$_p1"]="$_st"; _bst["$_tok"]="$_st"; _st=""; _p1="" ;;
      *) _bst["$_tok"]="$_st"; _st="" ;;
    esac
  done < <(git diff --cached --no-ext-diff --no-textconv --name-status -z HEAD 2>/dev/null)
  # EVERY token is read RAW (IFS empty, -r, NUL delimiter). Under -z the only byte a pathname
  # cannot contain is NUL, so a TAB, a newline, a quote, a backslash, a DEL or a leading space
  # are all legal path bytes here — and `IFS=$'\t' read` would split a path on its tab, which
  # is exactly how the round-2 close-gate counterexample ($'sub\té.bin', a pure rename) got
  # past this oracle. Only the COUNT token is structured: `<add>\t<del>\t<path>` for an
  # ordinary entry, `<add>\t<del>\t` (empty path) followed by two bare path tokens for a
  # rename or copy. The counts never contain a tab, so the path is everything after the
  # SECOND tab, taken by prefix-strip rather than by field splitting.
  _rn=0; _bina=""; _bind=""
  while IFS= read -r -d '' _tok; do
    if [ "$_rn" -gt 0 ]; then
      # rename/copy continuation: this whole token IS a path (source first, then destination)
      _rn=$(( _rn - 1 ))
      [ "$_rn" -eq 0 ] || continue          # skip the source; the destination is the live path
      _p="$_tok"; _a="$_bina"; _d="$_bind"
    else
      _a="${_tok%%$'\t'*}"; _rest="${_tok#*$'\t'}"
      _d="${_rest%%$'\t'*}"; _p="${_rest#*$'\t'}"
      if [ -z "$_p" ]; then _rn=2; _bina="$_a"; _bind="$_d"; continue; fi
    fi
    [ "$_a" = "-" ] || [ "$_d" = "-" ] || continue
    st="${_bst[$_p]:-}"
    case "$st" in
      A|'') : ;;
      *)
        # Name it UNAMBIGUOUSLY. The surface is newline-delimited, so a path carrying a
        # control byte (TAB, LF, DEL, …) is rendered in bash's $'…' form; every other name
        # is printed raw, as the operator would type it.
        case "$_p" in
          *[[:cntrl:]]*) _disp="$(printf '%q' "$_p")" ;;
          *)             _disp="$_p" ;;
        esac
        BINARY_CHANGED="${BINARY_CHANGED}${_disp} (${st})"$'\n' ;;
    esac
  done < <(git diff --cached --no-ext-diff --no-textconv --numstat -z HEAD 2>/dev/null)
fi

# Deletion-gated: a candidate that removes nothing has nothing for this leaf to surface.
if [ "$TEXT_DELETIONS" -eq 0 ] && [ -z "$BINARY_CHANGED" ]; then
  exit 0
fi

# ── Record inputs: the surfaced deletion set, with the CANDIDATE BLOB per path ─────
# Runs only past the gate, so an addition-only commit pays nothing for it.
#
# WHY `--raw` AND NOT `--numstat` FOR IDENTITY. `--numstat` and `--stat` render a renamed
# path as a DISPLAY expression — `.planning/backlog/{ => shipped}/x.md` — which is neither
# the old path nor the new one and intersects with nothing. That is a property of those two
# formats alone: `--raw` emits the real old and new paths in separate TAB fields, plus both
# blob shas, and never a brace. So identity comes from `--raw`, with rename detection LEFT
# ON, and `--numstat` is read only for its line counts, joined POSITIONALLY because the two
# formats walk the same diff queue in the same order and numstat's own path field is the
# unusable one. (Recorded because an earlier cut reached for `--no-renames` instead: that
# hides the brace by splitting the pair into D(old) + A(new), and then every deletion sits
# on the old half while the DESTINATION — where a post-exposure correction actually lands —
# carries zero deletions and drops out of the set entirely. It traded a wrong path for a
# missing one.)
#
# A RENAME CONTRIBUTES BOTH ENDPOINTS. The source vanishes from the candidate, so it is
# recorded with an all-zero blob; the destination is recorded with its candidate blob,
# because that is where a correction to the surfaced deletion would appear. Recording only
# the source makes such a correction indistinguishable from no change at all.
#
# BOUND, stated rather than discovered: paths are carried through TAB- and newline-delimited
# text, so a path containing either is not represented.
# REAL NAMES VIA -z (2026-09-14, the record half of the quoted-display-form defect). The
# non -z --raw / --numstat forms QUOTE any path git deems unsafe for a terminal, so the
# record carried "caf\303\251.bin" where the tree holds café.bin — and the retire-time
# comparison of `b` against the committed blob AT THAT PATH would have missed every such
# name. Both streams are now read -z, one pass each, joined by the real bytes: --raw -z
# gives "<header>\0<path>\0" (R/C: "<header>\0<src>\0<dst>\0") with the candidate blob in
# the header's 4th field; --numstat -z gives "<add>\t<del>\t<path>\0" (R/C: "<add>\t<del>\t"
# then two bare path tokens). The keep rule is unchanged from the awk join it replaces.
# The TAB/newline bound stands (the collection is TSV): a path carrying either is SKIPPED
# rather than emitted broken, which is the same unrepresentability stated below.
DELETION_SET="$(
  ZERO=0000000000000000000000000000000000000000
  declare -A _rst=() _rblob=()
  _st=""; _blob=""; _p1=""
  while IFS= read -r -d '' _tok; do
    if [ -z "$_st" ]; then
      set -- $_tok; _blob="${4:-}"; _st="${5:-?}"; _p1=""; continue   # header: no path bytes here
    fi
    case "$_st" in
      R*|C*) if [ -z "$_p1" ]; then _p1="$_tok"; continue; fi
             _rst["$_p1"]="$_st"; _rblob["$_p1"]="$ZERO"
             _rst["$_tok"]="$_st"; _rblob["$_tok"]="$_blob"; _st="" ;;
      *)     _rst["$_tok"]="$_st"; _rblob["$_tok"]="$_blob"; _st="" ;;
    esac
  done < <(git diff --cached --no-color --no-ext-diff --no-textconv --raw -z --abbrev=40 HEAD 2>/dev/null)
  _rn=0; _bina=""; _bind=""
  while IFS= read -r -d '' _tok; do
    if [ "$_rn" -gt 0 ]; then
      _rn=$(( _rn - 1 ))
      if [ "$_rn" -eq 1 ]; then _src="$_tok"; continue; fi     # source first
      _p="$_tok"; _a="$_bina"; _d="$_bind"; _isr=1
    else
      _a="${_tok%%$'\t'*}"; _rest="${_tok#*$'\t'}"
      _d="${_rest%%$'\t'*}"; _p="${_rest#*$'\t'}"; _isr=0; _src=""
      if [ -z "$_p" ]; then _rn=2; _bina="$_a"; _bind="$_d"; continue; fi
    fi
    _s="${_rst[$_p]:-?}"; _keep=0
    if [ "$_a" = "-" ] || [ "$_d" = "-" ]; then [ "$_s" != "A" ] && _keep=1
    else case "$_d" in ''|*[!0-9]*) : ;; *) [ "$_d" -gt 0 ] && _keep=1 ;; esac; fi
    [ "$_keep" -eq 1 ] || continue
    _b="${_rblob[$_p]:-$ZERO}"; [ -n "$_b" ] || _b="$ZERO"
    if [ "$_isr" -eq 1 ]; then
      case "$_src" in *$'\t'*|*$'\n'*) : ;; *) printf '%s\t%s\n' "$_src" "$ZERO" ;; esac
    fi
    case "$_p" in *$'\t'*|*$'\n'*) : ;; *) printf '%s\t%s\n' "$_p" "$_b" ;; esac
  done < <(git diff --cached --no-color --no-ext-diff --no-textconv --numstat -z HEAD 2>/dev/null)
)"

# ── Two-phase token, content-addressed on (HEAD, candidate tree) ───────────────────
TTL="${DHX_DELETION_AUDIT_TTL:-900}"
TOKEN_DIR="$(git rev-parse --git-path dhx-deletion-audit 2>/dev/null)"
[ -n "$TOKEN_DIR" ] || TOKEN_DIR=".git/dhx-deletion-audit"
mkdir -p "$TOKEN_DIR" 2>/dev/null || true

KEY="$(printf '%s %s' "$HEAD_SHA" "$TREE" | sha1sum 2>/dev/null | cut -d' ' -f1)"
[ -n "$KEY" ] || KEY="${HEAD_SHA}-${TREE}"
TOKEN="${TOKEN_DIR}/${KEY}"

# ── Firing record (see THE FIRING RECORD above; retires 2026-10-08 or at 100 surfaced) ──
# Never allowed to affect the commit: every step is best-effort and the function always
# returns 0. One short line appended O_APPEND is atomic under PIPE_BUF, so concurrent
# sessions on this shared tree cannot interleave a partial write.
_dhx_record() {
  case "${DHX_DELETION_AUDIT_RECORD:-}" in off|0|skip) return 0 ;; esac
  _rd="${DHX_DELETION_AUDIT_RECORD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-state/deletion-audit}"
  mkdir -p "$_rd" 2>/dev/null || return 0
  # The FILENAME is a basename and two checkouts can share one; `repo` carries the absolute
  # toplevel so a row stays attributable when they do. Do not read the filename as identity.
  _root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$_root" ] || _root=unknown
  _repo="$(basename "$_root" 2>/dev/null)"
  [ -n "$_repo" ] || _repo=unknown
  _file="${_rd}/${_repo}.jsonl"

  # del_paths — [{"p":<path>,"b":<candidate blob>}]. One sed over the whole set, never one
  # process per path: a pre-commit leaf pays this on every deletion-carrying commit. Capped,
  # and the cap is REPORTED rather than silently applied, so a truncated row is never read
  # as a complete deletion set. `b` is what makes the row self-sufficient once the candidate
  # tree is gc-pruned: compare it against the committed blob at the same path.
  _pcap="${DHX_DELETION_AUDIT_PATH_CAP:-200}"
  # NO control character may reach the JSON. One raw control byte inside a string makes the
  # whole line unparseable, and a pathname may legally contain any of them — an earlier range
  # spared 011/012/015 and so let CARRIAGE RETURN through, which emitted rows nothing could
  # parse. Losing a control byte from a recorded path is a stated bound; emitting a row nobody
  # can read is a defect.
  #
  # The two escapers take DIFFERENT ranges and that is deliberate, not drift. `_root` is one
  # scalar with no internal structure, so every control goes. `$DELETION_SET` is still
  # TAB-delimited records at this point and is split below, so TAB and NEWLINE must survive
  # the escape — stripping them collapses each record into one field and the blob disappears
  # into the path. Neither can occur INSIDE a field: a path containing one is already
  # unrepresentable in this collection, which is the bound stated where it is built.
  _dhx_json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\001-\037'; }
  _esc="$(printf '%s' "$DELETION_SET" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\001-\010\013-\037')"
  _arr=""; _n=0; _trunc=false
  while IFS="$(printf '\t')" read -r _p _b; do
    [ -n "$_p" ] || continue
    if [ "$_n" -ge "$_pcap" ]; then _trunc=true; break; fi
    if [ "$_n" -gt 0 ]; then _arr="${_arr},"; fi
    _arr="${_arr}{\"p\":\"${_p}\",\"b\":\"${_b}\"}"
    _n=$(( _n + 1 ))
  done <<< "$_esc"

  # SPILL — the cap bounds the ROW, never the EVIDENCE. A truncated inline array used to
  # discard the remainder outright, which made `del_paths` a strict prefix of the surfaced
  # deletion set and left the intersection uncomputable for exactly the commits that most
  # need it. Measured over the last 1500 commits here: median 1 deletion-carrying path, p99
  # 14, but three commits over 200 and a maximum of 552 — rare, and precisely the big sweeps.
  # So the complete set goes to a sidecar keyed by the same (HEAD, tree) sha the token uses,
  # and the row names it. The inline prefix stays for cheap reading; nothing is lost.
  _spill=null
  if [ "$_trunc" = true ] && [ -n "${KEY:-}" ]; then
    if mkdir -p "${_rd}/sets" 2>/dev/null &&
       printf '%s' "$DELETION_SET" > "${_rd}/sets/${KEY}.tsv" 2>/dev/null; then
      _spill="\"${KEY}\""
    fi
  fi
  _rootesc="$(_dhx_json_esc "$_root")"

  printf '{"ts":"%s","event":"%s","repo":"%s","parent":"%s","tree":"%s","deletions":%s,"binary":%s,"del_paths":[%s],"del_paths_truncated":%s,"del_paths_spill":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$_rootesc" "$HEAD_SHA" "$TREE" "$TEXT_DELETIONS" \
    "$([ -n "$BINARY_CHANGED" ] && echo true || echo false)" "$_arr" "$_trunc" "$_spill" \
    >> "$_file" 2>/dev/null || true

  # RETENTION, implemented rather than merely promised. The whole file is deleted at the
  # retire condition; between now and then this cap is what bounds it. Rewrite-and-rename
  # is atomic, so a concurrent appender loses at most its own in-flight line — acceptable
  # for best-effort telemetry, and stated instead of discovered.
  # Sidecar backstop, and it is ONLY a backstop. 45 days is deliberately ABOVE the 30-day
  # horizon, so this can never remove a set some row still needs; in a run that retires on
  # time it therefore never fires, and retirement deleting the whole directory is what
  # actually collects them. It exists for the run that is NOT retired on time.
  if [ -d "${_rd}/sets" ]; then
    find "${_rd}/sets" -maxdepth 1 -type f -mtime +45 -delete 2>/dev/null || true
  fi
  _lcap="${DHX_DELETION_AUDIT_RECORD_CAP:-5000}"
  _lines="$(wc -l < "$_file" 2>/dev/null)"
  case "${_lines:-0}" in
    ''|*[!0-9]*) : ;;
    *) if [ "$_lines" -gt "$_lcap" ]; then
         _tmp="${_file}.prune.$$"
         if tail -n "$_lcap" "$_file" > "$_tmp" 2>/dev/null; then
           mv -f "$_tmp" "$_file" 2>/dev/null || true
         fi
         rm -f "$_tmp" 2>/dev/null || true
       fi ;;
  esac
  return 0
}

# Prune expired tokens so an abandoned candidate cannot green-light a later identical one.
if [ -d "$TOKEN_DIR" ]; then
  find "$TOKEN_DIR" -maxdepth 1 -type f -mmin "+$(( (TTL + 59) / 60 ))" -delete 2>/dev/null || true
fi

# Second sight of an UNCHANGED candidate: the audit was surfaced, proceed with no input.
#
# The token is NOT consumed here, and its mtime is NOT refreshed. Consuming it would
# re-surface this same candidate on every retry whenever a LATER leaf (40-, 50-) blocks
# after this one passed — an audit loop with no new information in it. Leaving it lets
# TTL expire it from the moment of first sight. Nothing unrelated is green-lit by this:
# the key is content-addressed, so the only candidate a surviving token admits is a
# BYTE-IDENTICAL tree on the same parent, which is the very content already surfaced.
if [ -f "$TOKEN" ]; then
  _dhx_record passed
  exit 0
fi

PATCH_CAP="${DHX_DELETION_AUDIT_CAP:-1500}"

{
  echo
  echo "pre-commit: deletion audit — FIRST SIGHT of this candidate"
  echo "  parent HEAD    ${HEAD_SHA}"
  echo "  candidate tree ${TREE}"
  echo "  text deletions ${TEXT_DELETIONS} (numstat; conservative — never under-reports the patch)"
  echo
  echo "-- scope: every path in the candidate --"
  git diff --cached --no-color --no-ext-diff --no-textconv --stat HEAD 2>/dev/null

  if [ -n "$BINARY_CHANGED" ]; then
    echo
    echo "-- binary paths: CANNOT be named line-wise, account for these separately --"
    printf '%s' "$BINARY_CHANGED" | sed 's/^/  /'
  fi

  echo
  echo "-- which lines went: raw -U0 patch, the authority on WHICH lines went --"
  PATCH="$(git diff --cached --no-color --no-ext-diff --no-textconv --unified=0 HEAD 2>/dev/null)"
  PATCH_LINES="$(printf '%s\n' "$PATCH" | wc -l)"
  if [ "$PATCH_LINES" -gt "$PATCH_CAP" ]; then
    printf '%s\n' "$PATCH" | head -n "$PATCH_CAP"
    echo
    echo "  !! TRUNCATED at ${PATCH_CAP} of ${PATCH_LINES} lines — this is NOT a clean read."
    echo "  !! See the rest before committing:"
    echo "  !!   git diff --cached --no-color --no-ext-diff --no-textconv --unified=0 HEAD"
    PATCH_TRUNCATED=1
  else
    printf '%s\n' "$PATCH"
  fi

  echo
  echo "Name every '-' line above by class before proceeding. A deletion is a defect"
  echo "until named. This is a SURFACE, not a question: rerun the identical commit and"
  echo "it proceeds with no input. Change the candidate and it is surfaced again."

  # THE SENTINEL — the machine-readable half, emitted AFTER the patch so its presence
  # implies the whole surface above it was written. See THE FIRST-SIGHT SENTINEL in the
  # header for the matcher contract, the column-0 anchoring requirement and the consumer
  # list. Do not reword, reorder, or emit on the `passed` path without updating every
  # consumer.
  #
  # SUPPRESSED WHEN THE PATCH WAS TRUNCATED, and this is the guarantee, not an edge case.
  # The sentinel licenses a scripted caller to retry ONCE without human input. That is only
  # sound while the emitted surface IS the deletion set — and a truncated patch is by
  # definition not. Measured 2026-09-12 before this guard existed: at
  # DHX_DELETION_AUDIT_CAP=3 on a 59-deletion candidate, the retry fired, the commit LANDED,
  # and ZERO deletion lines reached the caller — only the `NOT a clean read` warning. The
  # audit had been fully automated past on exactly the sweeps it exists for. So: no complete
  # surface, no sentinel, no retry. The caller reports a failed commit, the warning above
  # says why, and a human reads the rest. Interactive callers are unaffected — the token is
  # still written below, so THEIR unchanged rerun proceeds as it always did.
  if [ "${PATCH_TRUNCATED:-0}" -eq 0 ]; then
    echo
    printf 'DHX-DELETION-AUDIT-FIRST-SIGHT parent=%s\n' "$HEAD_SHA"
  else
    echo
    echo "  !! NO first-sight sentinel emitted: the patch above is TRUNCATED, so a scripted"
    echo "  !! caller must NOT retry this candidate unattended. Read the full deletion set"
    echo "  !! with the command above, then rerun the identical commit by hand."
  fi
} >&2

# Write the token only AFTER the surface has actually been emitted. Writing it first
# would mean a crashed or truncated emission still green-lights the rerun — a commit
# that never saw its own deletion set, recorded as though it had.
: > "$TOKEN" 2>/dev/null || true
_dhx_record surfaced

exit 1
