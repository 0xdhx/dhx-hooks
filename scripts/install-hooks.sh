#!/usr/bin/env bash
set -euo pipefail
# install-hooks.sh — idempotently install cross-repo's [XR] tracked git hooks.
#
# Ported verbatim from ~/repos/<skills-monorepo>/scripts/install-hooks.sh (D-10) with one
# documented self-heal-glob decision (see "Self-heal note" below).
#
# Installs:
#   .git/hooks/pre-commit            -> scripts/hooks/pre-commit            (symlink, worktree-safe)
#   .git/hooks/pre-merge-commit      -> scripts/hooks/pre-commit            (symlink, worktree-safe; clean-merge coverage)
#   .git/hooks/reference-transaction -> scripts/hooks/reference-transaction (symlink, worktree-safe; XR-29 Layer-1 guard —
#                                        ONLY when this repo carries the reftxn machinery; a FOREIGN tree that adopted just
#                                        the backlog-frontmatter gate via the scaffold installs the pre-commit gate alone)
#   .git/hooks/<name>                -> scripts/hooks/<name>                (generic sweep: every additional dot-free
#                                        regular file directly under scripts/hooks/ is wired as a self-contained hook —
#                                        e.g. acme-app's pre-push, relater's post-checkout — so adopter repos never
#                                        need to fork this installer to wire repo-own hooks)
#
# scripts/hooks/pre-commit is a run-parts dispatcher over scripts/hooks/
# pre-commit.d/. New checks are added there — this installer only wires the
# symlink, so it needs to run just once per clone or worktree.
#
# pre-merge-commit points at the SAME dispatcher: git runs pre-merge-commit (NOT
# the installed pre-commit) when it auto-creates a merge commit for a conflict-free
# merge, so a clean --no-ff merge that would otherwise bypass the pre-commit.d/
# gates is covered. git does NOT fire pre-merge-commit for fast-forwards (no commit
# is created), conflicted merges (the resolution `git commit` fires pre-commit
# instead — so no double-fire), or `--no-verify` merges. Inside the hook,
# `git diff --cached` is vs the first parent, so an index-feeding merge triggers the
# freshness leaf's delta-check and a stale union blocks.
#
# scripts/hooks/reference-transaction is the XR-29 Layer-1 shared-tree
# HEAD/base-ref guard (D-05 single guard script). After wiring, the installer
# regenerates its install-time predicate SNAPSHOT (scripts/hooks/reftxn-veto-snapshot.sh)
# from the skills canonical git-safe.sh (D-02/D-13) — the hook sources that
# snapshot, never the live working-tree symlink.
#
# Control flow (D-11): the per-hook wiring is an install_hook NAME TARGET helper
# that RETURNs (never exits) at the already-installed / wired points, so BOTH
# hooks wire AND the snapshot sync ALWAYS runs even on a repo where pre-commit is
# already installed (the old install-hooks.sh "exit 0 when already installed"
# clobber would have skipped the reftxn wiring + snapshot sync on most of the
# fleet). The pre-commit path keeps byte-identical observable behavior.
#
# Primary-only (D-06/D-17): this installer hard-fails UNCONDITIONALLY if run from
# a linked worktree (a worktree install dangles the shared .git/hooks symlink at
# an ephemeral path). That guard is an INLINED absolute-git-dir compare with NO
# dependency on git-safe.sh — a missing lib degrades only the snapshot sync, never
# the worktree guard.
#
# Behavior:
#   - Symlink already points at the dispatcher  -> return 0 (continue to next step).
#   - No hook present                           -> create the symlink.
#   - A foreign hook is present                 -> refuse + guidance, exit 1.
#   - Stale symlink into a removed worktree     -> self-heal (remove, reinstall).
#
# Worktree-safe: an ABSOLUTE symlink target ($GIT_TOPLEVEL/scripts/hooks/pre-commit)
# fires for the primary checkout AND every linked worktree. The install TARGET is the
# COMMON-dir hooks/ ($_cdir/hooks), resolved explicitly — NEVER `git rev-parse
# --git-path hooks`, which FOLLOWS core.hooksPath: on a fleet-enrolled repo
# (core.hooksPath -> the root-owned dispatcher) --git-path hooks resolves to the
# dispatcher dir, where install_hook refuse-to-clobbers at the FIRST hook, every run.
# (The 2026-07-13 fix superseded the earlier D-10 "--git-path hooks is worktree-safe"
# claim, which held only pre-fleet.) Installing into the common hooks/ is the correct
# fleet-composed model: the fixed _chain.sh delegates to exactly that dir.
#
# Self-heal note (Pitfall 3, Phase 06 provenance correction #2):
#   skills' self-heal below matches `*/.worktrees/*`. cross-repo's worktree
#   conventions are `.claude/worktrees/` (harness) and `../cross-repo-<branch>`
#   (sibling, per CLAUDE.md) — neither matches `*/.worktrees/*`. The verbatim
#   port is KEPT intentionally: an unrecognized stale symlink falls through to
#   the refuse-to-clobber branch, the correct conservative default under the
#   shared-tree invariant (better to refuse than to clobber a symlink that may
#   belong to a live concurrent session). Widening the glob is optional and
#   deferred — refuse-to-clobber is the safe fallthrough either way.
#
# NOTE (Phase 06 Plan 01 scope): this installer is PORTED here but is NOT run
# against cross-repo's own .git/hooks by this plan. Self-install (writing the
# shared .git/hooks/pre-commit symlink, which activates the gate for all
# concurrent sessions — D-14) is Plan 04's gated checkpoint (MVP-05).
#
# Safe to re-run. Escape hatch for the installed hook: `git commit --no-verify`.

# ─── THE ROOT COMES FROM THIS SCRIPT, NOT FROM THE CALLER (XR-40 follow-up) ──
# The worktree guard below compares --absolute-git-dir against --git-common-dir. Those two AGREE
# under GIT_DIR/GIT_WORK_TREE, while GIT_TOPLEVEL — the value the symlink TARGETS are built from —
# was taken from `git rev-parse --show-toplevel` in the CALLER'S cwd and returned the lane. The
# guard and the thing it guarded read different inputs — the IDENTICAL defect fixed in
# install-dhx-tools.sh (XR-40 B-09, 601359200), and worse here: the targets land in the SHARED
# .git/hooks/, so a lane-pointing link dangles when the lane is removed and silently disables the
# pre-commit gate (the XR-29 reftxn guard included) for the primary and every worktree.
#
# REACHABILITY IS NOT THEORETICAL: git exports GIT_DIR into every hook it runs, and this script
# IS the hook-adjacent installer. Same two changes as the sibling, and both are needed: clear the
# environment before git is asked anything, and derive the root from this script's OWN location —
# the only tree whose paths it is entitled to wire into the shared hooks dir.
# Guard-shape parity with install-dhx-tools.sh is asserted by
# ~/repos/cross-repo/scripts/tests/probe-install-hooks-guard.sh (same unset list, same three legs).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CEILING_DIRECTORIES 2>/dev/null || true

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"   # scripts/ -> the repository root
cd "$SCRIPT_ROOT"

if ! GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "install-hooks: not in a git repository" >&2
  exit 1
fi
GIT_TOPLEVEL="$(cd -- "$GIT_TOPLEVEL" && pwd -P)"

# The third signal, and the one that makes the other two an actual guard rather than two
# readings of the same lie: git must AGREE with the script about which tree this is.
if [ "$GIT_TOPLEVEL" != "$SCRIPT_ROOT" ]; then
  echo "install-hooks: refusing — git and this script disagree about the repository root." >&2
  echo "  this script lives in: $SCRIPT_ROOT" >&2
  echo "  git reports:          $GIT_TOPLEVEL" >&2
  echo "  The hook symlink TARGETS are built from the root, so a disagreement means they would" >&2
  echo "  point into a tree this installer does not live in. Run it from the checkout it belongs" >&2
  echo "  to, with no GIT_DIR/GIT_WORK_TREE in the environment." >&2
  exit 1
fi
cd "$GIT_TOPLEVEL"

# ── D-06/D-17: UNCONDITIONAL primary-only hard-fail ──────────────────────────
# Installing from a linked worktree dangles the shared .git/hooks symlink at an
# ephemeral path. Refuse from any worktree. This is an INLINED absolute-git-dir
# compare (the is_primary_checkout contract: resolved --absolute-git-dir ==
# realpath'd --git-common-dir ⇒ primary; they diverge for a linked worktree) with
# NO dependency on git-safe.sh — so a missing lib degrades only the snapshot sync
# below, NEVER this guard (correcting the prior skip-the-guard fallback).
_gdir=$(git rev-parse --absolute-git-dir 2>/dev/null || true)
_cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "$_gdir")
case "$_cdir" in /*) : ;; *) _cdir="$GIT_TOPLEVEL/$_cdir" ;; esac
_cdir=$(realpath "$_cdir" 2>/dev/null || echo "$_cdir")
if [ -z "$_gdir" ] || [ "$_gdir" != "$_cdir" ]; then
  echo "install-hooks: refusing to install from a linked worktree — the shared" >&2
  echo "  .git/hooks symlink would dangle at an ephemeral path; run from the" >&2
  echo "  primary checkout on main." >&2
  exit 1
fi

# ── CONTAINMENT: this installer writes ONLY inside this repository ────────────
# Filed 2026-08-24; brief now at ~/repos/cross-repo/.planning/backlog/shipped/
# 2026-08-24-install-hooks-writes-outside-the-repo-via-symlinked-git-hooks.md — after a close-gate
# reviewer demonstrated TWO paths out of the tree in disposable fixtures:
#
#   HOOKS_ESCAPE          rc=0  external_pre_commit=present  external_pre_merge=present
#   GENERIC_HOOK_SYMLINK  rc=0  external_mode_before=644  external_mode_after=755
#
#   (a) HOOKS_DIR was built as "$_cdir/hooks" and used with NO canonical check, so a .git/hooks
#       symlinked at an external directory RECEIVED the hook symlinks.
#   (b) the generic hook sweep below tests candidates with `[ -f "$_hook" ]`, which FOLLOWS
#       symlinks, and then chmod +x's them — changing the mode of a file outside the repository.
#
# EVERY PROSE POINTER AT A cross-repo ARTIFACT IN THIS FILE IS ABSOLUTE (~/repos/cross-repo/...),
# deliberately. This file is spliced VERBATIM into fourteen vendored copies, where a bare
# repo-relative pointer is false in thirteen of them — the same false-in-every-copy-but-one header
# WR-05 / d70afd0c removed from the validator. acme-app's 25-pointer-rot.sh is the only gate in
# the fleet that catches it, and it REFUSED this file on 2026-08-24 for exactly that. Runtime paths
# (scripts/hooks/..., resolved against the target at run time) stay relative — they are correct in
# every copy; only prose references to cross-repo's OWN artifacts get qualified.
#
# ONE BOUNDARY, APPLIED TO EVERY PATH. Deliberately the SAME SHAPE the scaffold's install.sh uses:
# canonicalise with `realpath -m`, then require a true prefix match on a `/`-TERMINATED boundary, so
# `/repo-evil` cannot pass as inside `/repo`. A second, divergent boundary would be worse than one
# boundary applied twice.
#
# CHECKED BEFORE THE FIRST MUTATION, deliberately. install.sh learned this across three review
# rounds: a containment check that runs after the first write leaves a PARTIAL install behind an
# error message claiming nothing was written. Every chmod, mkdir, ln and snapshot write in this file
# is downstream of this block.
#
# DECISION — a redirected .git/hooks is REFUSED, not followed-but-contained (the brief's open
# question, settled here). Refusing is the conservative default; the refusal is LOUD (exit 1 with
# guidance, never a silent skip); and the scaffold's install.sh treats a bundled-installer refusal as
# NON-FATAL (install.sh: "the dispatcher symlink was NOT wired ... The payload copy SUCCEEDED"), so
# an adopter deliberately sharing a hooks directory still gets the payload and is TOLD the symlink
# was not wired. Following-but-containing would mean writing this repo's ABSOLUTE hook targets into a
# directory shared with OTHER repositories — precisely the dangling-hook hazard the worktree guard
# above exists to refuse, with a wider blast radius.
#
# NARROWING, MEASURED 2026-08-24 and judged acceptable: rooting the boundary at the worktree TOPLEVEL
# also refuses any repo whose git common-dir lives outside it — a submodule, or a `.git` FILE
# pointing elsewhere. Across all 32 repos under ~/repos the only such trees are LINKED WORKTREES,
# which the unconditional worktree hard-fail above already refuses. This narrows nothing that
# reaches here today.
_root_abs="$(realpath -m -- "$GIT_TOPLEVEL" 2>/dev/null || true)"
if [ -z "$_root_abs" ]; then
  echo "install-hooks: cannot resolve the repository root — refusing" >&2
  exit 1
fi

# INVARIANT (fleet-composed worktree bypass, 2026-07-13): target the COMMON-dir
# hooks/ explicitly, NEVER `git rev-parse --git-path hooks` — the latter FOLLOWS
# core.hooksPath, so on a fleet-enrolled repo it resolves to the root-owned
# dispatcher dir → install_hook refuse-to-clobbers at the FIRST hook, every run.
# $_cdir was resolved + realpath'd absolute by the worktree guard above.
# Proof: ~/repos/cross-repo/scripts/fleet/tests/probe-chain-worktree-delegation.sh.
HOOKS_DIR="$_cdir/hooks"
if [ -z "$HOOKS_DIR" ]; then
  echo "install-hooks: could not resolve git hooks dir" >&2
  exit 1
fi

# The boundary itself. Takes a LABEL and a path; refuses the whole install if the path canonicalises
# anywhere other than strictly inside $_root_abs. `realpath -m` resolves every symlink component and
# does NOT require the path to exist, so a destination that does not exist yet (an uncreated
# .git/hooks) is checked at the location it WOULD be created.
_refuse_if_outside() {
  local _label="$1" _path="$2" _abs
  _abs="$(realpath -m -- "$_path" 2>/dev/null || true)"
  if [ -z "$_abs" ] || [ "${_abs#"$_root_abs"/}" = "$_abs" ]; then
    echo "install-hooks: $_label resolves OUTSIDE this repository — REFUSING." >&2
    echo "  path:       $_path" >&2
    echo "  resolves to: ${_abs:-<unresolvable>}" >&2
    echo "  repository:  $_root_abs" >&2
    echo "  A directory in that path is probably a symlink out of the repository (a shared or" >&2
    echo "  redirected .git/hooks, or a hook file symlinked elsewhere)." >&2
    echo "  NOTHING was created and NO file's mode was changed — this check runs before every" >&2
    echo "  write in this installer. Resolve the redirection, then re-run." >&2
    exit 1
  fi
}

# Destination (a): the git hooks directory every symlink below is created in.
_refuse_if_outside "the git hooks directory" "$HOOKS_DIR"

# Sources (b): scripts/hooks/ and EVERY entry directly under it. Checking every entry rather than
# re-deriving the sweep's own selection rule is deliberate — a containment check that duplicates the
# selection logic drifts away from it. This superset covers the dispatcher, reference-transaction,
# pre-commit.d/, the generated reftxn-veto-snapshot.sh, and every generic-sweep candidate at once.
_refuse_if_outside "the hook source directory" "scripts/hooks"
for _cand in scripts/hooks/*; do
  # A dangling symlink is neither chmod-able nor writable-through, and both the sweep's `[ -f ]` and
  # find's `-type f` skip it; an empty scripts/hooks/ yields the literal glob, which -e also rejects.
  [ -e "$_cand" ] || continue
  _refuse_if_outside "hook source '$_cand'" "$_cand"
done

DISPATCHER="scripts/hooks/pre-commit"
if [ ! -f "$DISPATCHER" ]; then
  echo "install-hooks: $DISPATCHER not found — refusing to install" >&2
  exit 1
fi
[ -x "$DISPATCHER" ] || chmod +x "$DISPATCHER"

# XR-29 reftxn machinery is cross-repo-specific. cross-repo ALWAYS carries it (tracked), so it is
# always wired here. A FOREIGN tree that adopts only the backlog-frontmatter gate via the scaffold
# (cross-repo:conventions/scaffolds/backlog-frontmatter-gate/, which ships a VERBATIM copy of this installer)
# has no reference-transaction hook — there the installer must wire the pre-commit gate WITHOUT the
# reftxn guard rather than refuse the whole install. Presence-gate so the ONE installer self-scopes:
# cross-repo gets the XR-29 guard + predicate snapshot; a foreign adopter gets the pre-commit gate.
# (The prior unconditional "refuse if absent" mis-fired on every foreign adopter — the copied payload
# installer refused in any tree lacking reftxn, which the loop-closure probe's fixture surfaces.)
REFTXN_HOOK="scripts/hooks/reference-transaction"
HAS_REFTXN=0
if [ -f "$REFTXN_HOOK" ]; then
  HAS_REFTXN=1
  # D-12: a symlinked hook only fires if the resolved target is executable.
  [ -x "$REFTXN_HOOK" ] || chmod +x "$REFTXN_HOOK"
fi

# run-parts requires the checks themselves to be executable.
if [ -d "scripts/hooks/pre-commit.d" ]; then
  find scripts/hooks/pre-commit.d -maxdepth 1 -type f ! -perm -u+x \
    -exec chmod +x {} +
fi

# HOOKS_DIR was resolved AND containment-checked in the boundary block above (it is the first
# destination this installer writes to, so it cannot be resolved any later than that check).
mkdir -p "$HOOKS_DIR"

# ── D-11: install_hook NAME TARGET_ABS — wires one hook, RETURNs (never exits) ─
# RETURNs 0 at the already-installed and successfully-wired points so the caller
# proceeds to the next hook + the snapshot sync. The foreign-hook-refuse path is
# a genuine error → exit 1 (intentional hard stop). Behavior for pre-commit is
# byte-identical to the pre-refactor inline block.
install_hook() {
  local name="$1" dispatcher_abs="$2"
  local target="$HOOKS_DIR/$name"

  if [ -L "$target" ]; then
    local current resolved
    current=$(readlink "$target")
    case "$current" in
      /*) resolved="$current" ;;
      *)  resolved="$HOOKS_DIR/$current" ;;
    esac
    if [ "$(readlink -f "$resolved" 2>/dev/null || true)" \
       = "$(readlink -f "$dispatcher_abs" 2>/dev/null || true)" ]; then
      return 0   # already installed and pointing at our dispatcher
    fi
    # Self-heal: symlink into a now-removed .worktrees/ checkout — safe to clobber.
    # (See "Self-heal note" in the header: this glob does not match cross-repo's
    # worktree conventions, so cross-repo stale symlinks fall through to the
    # refuse-to-clobber branch — the intended conservative default.)
    if [[ "$current" == *"/.worktrees/"* ]] && [ ! -e "$resolved" ]; then
      echo "install-hooks: removing stale worktree symlink (target: $current)"
      rm "$target"
    else
      echo "install-hooks: $target is a symlink pointing at '$current' (not our dispatcher)." >&2
      echo "  Refusing to clobber. Inspect and remove it manually, then re-run." >&2
      exit 1
    fi
  fi

  if [ -e "$target" ]; then
    echo "install-hooks: $target already exists and is not our dispatcher." >&2
    echo "  Refusing to clobber. Inspect and remove it manually, then re-run." >&2
    exit 1
  fi

  ln -s "$dispatcher_abs" "$target"
  echo "install-hooks: installed $target -> $dispatcher_abs"
  return 0
}

# Absolute paths are worktree-safe — a relative symlink would break from the
# deeper .git/worktrees/<name>/hooks/ directory.
DISPATCHER_ABS="$GIT_TOPLEVEL/scripts/hooks/pre-commit"
REFTXN_ABS="$GIT_TOPLEVEL/scripts/hooks/reference-transaction"

# Wire the hooks. Each call RETURNs (D-11), so the reftxn wiring + snapshot sync
# below are ALWAYS reached, even when pre-commit is already installed. pre-merge-commit
# reuses the pre-commit dispatcher (same target) so a conflict-free merge commit runs
# the same pre-commit.d/ gates — closing the clean-merge coverage hole.
install_hook "pre-commit" "$DISPATCHER_ABS"
install_hook "pre-merge-commit" "$DISPATCHER_ABS"

# ── Generic self-contained hook sweep (2026-07-23 fleet re-vendor arc) ────────
# Wire EVERY additional self-contained hook the repo tracks directly under
# scripts/hooks/ — the general case the reftxn presence-gate below is one
# instance of. Downstream adopters carry repo-own hooks here (acme-app:
# pre-push; relater: post-checkout); before this sweep their vendored installers
# needed local edits to wire them, which pinned those repos to forked
# pre-2026-07-13 installers (the drift the per-layout comparable set detects).
# Selection: regular files whose basename contains NO dot — git hook names never
# carry an extension, so helper artifacts (reftxn-veto-snapshot.sh) and dirs
# (pre-commit.d/, lib/) self-exclude. pre-commit is the dispatcher (wired
# above); reference-transaction keeps its dedicated block below (predicate
# snapshot sync + D-12 exec assert). Glob order keeps the wiring deterministic.
for _hook in scripts/hooks/*; do
  [ -f "$_hook" ] || continue
  _name=${_hook##*/}
  case "$_name" in
    pre-commit|reference-transaction|*.*) continue ;;
  esac
  [ -x "$_hook" ] || chmod +x "$_hook"
  install_hook "$_name" "$GIT_TOPLEVEL/scripts/hooks/$_name"
done

# Foreign-adopter path (HAS_REFTXN=0): the pre-commit + pre-merge-commit gates are wired; the XR-29
# reftxn guard and its predicate snapshot are cross-repo-specific, so stop here rather than refuse the
# install or emit cross-repo-internal machinery into a foreign tree. cross-repo (HAS_REFTXN=1) always
# falls through to the full reftxn wiring + snapshot sync below — behavior for cross-repo is unchanged.
if [ "$HAS_REFTXN" = 0 ]; then
  echo "install-hooks: reference-transaction machinery absent — pre-commit gate installed;"
  echo "  skipping the XR-29 reftxn guard + predicate snapshot (cross-repo-specific)."
  exit 0
fi

install_hook "reference-transaction" "$REFTXN_ABS"

# D-12: assert the wired reference-transaction target is executable — a non-exec
# hook never fires. Fix + warn if a clone dropped the bit.
if [ ! -x "$(readlink -f "$HOOKS_DIR/reference-transaction" 2>/dev/null || echo "$REFTXN_ABS")" ]; then
  echo "install-hooks: WARNING reference-transaction target not executable — chmod +x'ing $REFTXN_ABS" >&2
  chmod +x "$REFTXN_ABS"
fi

# ── D-02/D-13: atomic whole-file snapshot sync of the predicate ──────────────
# The hook sources scripts/hooks/reftxn-veto-snapshot.sh (NOT the live ~/.claude/
# dhx-shared symlink). Regenerate it as a WHOLE-FILE generated-from-source COPY
# of canonical git-safe.sh, resolved via the 3-tier lookup. Written ATOMICALLY
# (temp + mv) so a hook firing mid-sync reads either the old or the new whole
# file, never a partial (the fail-OPEN window). A provenance + content-checksum
# header lets the XR-34 parity-canary verify snapshot ≡ canonical by CHECKSUM.
#
# This sync degrades gracefully (keeps the existing stub) if git-safe.sh is
# unresolvable OR does not yet carry reftxn_should_veto (skills half not landed).
# The worktree hard-fail above already fired unconditionally — it does NOT depend
# on this lib resolving.
SNAPSHOT="$GIT_TOPLEVEL/scripts/hooks/reftxn-veto-snapshot.sh"
GIT_SAFE_SRC="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-shared/lib/git-safe.sh"
[ -f "$GIT_SAFE_SRC" ] || GIT_SAFE_SRC="$HOME/.claude/dhx-shared/lib/git-safe.sh"
[ -f "$GIT_SAFE_SRC" ] || GIT_SAFE_SRC="$HOME/repos/<skills-monorepo>/dhx-shared/lib/git-safe.sh"

if [ ! -f "$GIT_SAFE_SRC" ]; then
  echo "install-hooks: NOTICE git-safe.sh canonical not resolvable — keeping the existing" >&2
  echo "  predicate snapshot stub ($SNAPSHOT). Re-run after provisioning to sync." >&2
elif ! grep -q 'reftxn_should_veto' "$GIT_SAFE_SRC"; then
  echo "install-hooks: NOTICE canonical git-safe.sh lacks reftxn_should_veto (skills half not" >&2
  echo "  landed via the KD #10 prompt) — keeping the existing snapshot stub; the sync" >&2
  echo "  completes once the predicate lands." >&2
else
  _src_sum=$(sha256sum "$GIT_SAFE_SRC" | awk '{print $1}')
  _tmp=$(mktemp "$(dirname "$SNAPSHOT")/.reftxn-veto-snapshot.XXXXXX")
  {
    echo "#!/usr/bin/env bash"
    echo "# scripts/hooks/reftxn-veto-snapshot.sh — GENERATED-FROM-SOURCE snapshot (D-02/D-13)."
    echo "# DO NOT EDIT BY HAND. Regenerated by scripts/install-hooks.sh from the skills"
    echo "# canonical git-safe.sh at install time; the XR-34 parity-canary verifies this"
    echo "# snapshot ≡ canonical by the content checksum below."
    echo "#"
    # XR-34 D-02 brain/skull provenance block — STATIC prose, independent of the
    # canonical sha (it documents the dev-vs-root-owned copy split, not the content).
    # Committed by hand in 560f1887; reproduced verbatim here so a live install is a
    # no-op on a clean tree instead of silently reverting the block every run. The
    # quoted heredoc keeps the backticked `layer3-unlock-helper` inert.
    cat <<'REFTXN_D02_HEADER'
# ── XR-34 brain/skull split (D-02): this is the DEV copy ──────────────────────
# As of XR-34 the LIVE guard reads the ROOT-OWNED predicate copy installed INSIDE
# the dispatcher dir (default /usr/local/libexec/fleet-machinery/dispatcher/reftxn-veto-snapshot.sh
# — the subhook resolves it as $SELF_DIR/reftxn-veto-snapshot.sh; a TOP-LEVEL copy at
# /usr/local/libexec/fleet-machinery/ is read by NOTHING and is a false-negative decoy),
# regenerated via the privileged `layer3-unlock-helper regen-predicate` mode — the
# agent UID cannot edit that copy (closes the SC-4 self-disable-via-edit residual).
# THIS tracked working-tree file is the AGENT-WRITABLE DEV/iteration copy ONLY: it
# is what in-lane dispatcher testing runs against, and the source the root-owned
# copy is generated to match (the D-06 dev->live parity canary asserts hash-= AND a
# real veto fires through the promoted root-owned snapshot). Editing this file does
# NOT change the LIVE boundary — that requires the privileged regen-predicate path.
REFTXN_D02_HEADER
    echo "#"
    echo "# generated-from-source: $GIT_SAFE_SRC"
    echo "# canonical-sha256: $_src_sum"
    echo "#"
    cat "$GIT_SAFE_SRC"
  } > "$_tmp"
  chmod +x "$_tmp"
  mv -f "$_tmp" "$SNAPSHOT"
  echo "install-hooks: synced predicate snapshot $SNAPSHOT (canonical sha256 $_src_sum)"
fi

exit 0
