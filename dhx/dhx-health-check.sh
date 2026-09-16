#!/bin/bash
# Patterns: HP-009, HP-016
# DHX Health Check — SessionStart hook
# Runs fork verification and symlink checks, writes results to cache.
# Clears this session's drift snapshot so wrapper writes a fresh baseline on resume.
# Zero stdout on all paths — purely a cache writer.
# Cost: ~575ms measured 2026-09-15 (3 runs, live lane c), NOT the ~50ms this line used to
# claim — that figure predated the fork verifiers, the manifest walk and the prune sweeps,
# and its component list ("4 file reads + 2 greps + ls check") no longer matches the file.
# Dominant costs: the two dhx-sym.sh fork verifiers (68ms + 51ms measured separately), the
# jq walk over the plugin manifest, the /proc orphan sweep and three find sweeps. The
# destination check added below is ~10ms of that (two readlink forks per item); the
# one-fork batched form is refused because it costs the literal `for item in ...` line that
# probe-gsd-roots-resolve.sh pins against list staleness. SessionStart only — the repo rule
# "keep hooks fast" is about per-tool-call hooks and does not bind here.
# No network, no git, no node.

CACHE_DIR="$HOME/.cache/dhx"
CACHE_FILE="$CACHE_DIR/health.json"
DHX_SYM="$HOME/.claude/scripts/dhx-sym.sh"

mkdir -p "$CACHE_DIR"

# --- Lane identity (per-profile cache scoping, 2026-09-15) ---
# $CACHE_FILE is $HOME-anchored and every CCS lane's SessionStart writes it, so
# any field computed against $CLAUDE_CONFIG_DIR was last-writer-wins across lanes:
# a lane holding a real symlink fault wrote missing_symlinks:1 and the next
# SessionStart in ANY healthy lane overwrote it with 0, leaving the faulted lane's
# statusline rendering a count computed for a different directory. Reproduced in a
# two-lane fixture before the fix; see docs/decisions.md 2026-09-15 scoping row.
#
# Split by scope rather than sharding the whole object. Of the fields this script
# emits, exactly ONE is lane-sensitive: missing_symlinks (the loop below reads
# $config_dir). settings_chain, claude_md and hooks_wiring hardcode $HOME/.claude
# paths; worktree_patches and read_guard delegate to dhx-sym.sh, whose
# implementation (skills repo scripts/lib/forks.sh) references CLAUDE_CONFIG_DIR
# nowhere and anchors WORKFLOWS_DIR at "$HOME/.claude". Those six stay in
# $CACHE_FILE with its existing whole-file atomic write — which also keeps the
# skills-repo reader working (sym-gsd-update-report.md steps 12.45(c) and 12.5
# check 2 jq this file and hard-exit on .settings_chain / .read_guard /
# .plugin_keys / .hooks_wiring; that reader is why statusline-wrapper.js's old
# "sole runtime reader" claim was false and has been corrected).
#
# The lane-sensitive field goes to its own sidecar, $LANE_FILE, written with the
# same tmp+mv whole-file atomic write. A sidecar-per-lane needs no read-modify-write
# and therefore no lock: locking $CACHE_FILE itself would be worse than useless,
# since the atomic `mv` that makes the write safe detaches the lock from the inode
# every later writer would go on to take.
#
# ALLOWLIST, not sanitization. $CLAUDE_CONFIG_DIR is UNTRUSTED here — a sandboxed
# CC launched with CLAUDE_CONFIG_DIR=$(mktemp -d) has previously reached live cache
# files through a symlink chain (.planning/backlog/shipped/2026-04-27-heal-hook-
# config-dir-path-dependent-write-hardening.md, shipped 2026-05-19). Deriving a
# lane id from an arbitrary realpath would let any caller mint cache entries; a TTL
# would bound their AGE and not their CARDINALITY. So the id is accepted only from
# $HOME/.claude ("default") or a single-segment child of $HOME/.ccs/instances, and a
# config dir matching neither writes NO sidecar at all — its lane then reads as
# unknown, which is the honest answer. Same allowlist shape the SESSION_ID guard at
# the foot of this script uses (WR-01).
#
# INVARIANT: statusline-wrapper.js::laneIdFor() MUST derive the same id from the
# same config dir. The sidecar stores its own config_dir and the reader compares it,
# so a drift between the two implementations renders unknown rather than serving one
# lane's reading to another. Guarded by tests/probes/probe-health-lane-scoping.sh.
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
config_dir="${config_dir%/}"
config_dir_real="$(readlink -f "$config_dir" 2>/dev/null || echo "$config_dir")"
claude_home_real="$(readlink -f "$HOME/.claude" 2>/dev/null || echo "$HOME/.claude")"
instances_real="$(readlink -f "$HOME/.ccs/instances" 2>/dev/null || echo "$HOME/.ccs/instances")"

lane_id=""
if [[ "$config_dir_real" == "$claude_home_real" ]]; then
  lane_id="default"
elif [[ "$config_dir_real" == "$instances_real"/* ]]; then
  candidate="${config_dir_real#"$instances_real"/}"
  # `default` is RESERVED for canonical $HOME/.claude, so an instance literally named
  # `default` would share its sidecar filename. The reader's config_dir stamp still stops
  # one being SERVED the other's reading, but they would clobber each other and whichever
  # wrote second would leave the other rendering `symlinks:?` — a silent loss of signal for
  # a name collision nothing else announces. Refusing writes no sidecar, so that lane reads
  # as unknown always, which is at least the honest and STABLE answer. Surfaced by the
  # close-gate reviewer, 2026-09-15; probe case [14].
  [[ "$candidate" =~ ^[A-Za-z0-9_-]+$ && "$candidate" != "default" ]] && lane_id="$candidate"
fi

LANE_FILE=""
[[ -n "$lane_id" ]] && LANE_FILE="$CACHE_DIR/health-lane-$lane_id.json"

# Read stdin — session_id available since CC added it to SessionStart events
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# --- Worktree patches ---
wt_state="patched"
if [[ -x "$DHX_SYM" ]]; then
  "$DHX_SYM" verify-worktree-patches >/dev/null 2>&1
  case $? in
    0) wt_state="patched" ;;
    1) wt_state="REGRESSED" ;;
    2) wt_state="REVIEW" ;;
    3) wt_state="DRIFT" ;;
  esac
fi

# --- Read-guard fork ---
rg_state="patched"
if [[ -x "$DHX_SYM" ]]; then
  "$DHX_SYM" verify-read-guard-fork >/dev/null 2>&1
  case $? in
    0) rg_state="patched" ;;
    1) rg_state="REGRESSED" ;;
    2) rg_state="REVIEW" ;;
    3) rg_state="DRIFT" ;;
  esac
fi

# --- Symlink health (active profile only) ---
# In a CCS profile, items must be symlinks to ~/.claude. In ~/.claude itself,
# they're the real thing. A real dir where a symlink belongs means invisible
# drift — e.g., a botched GSD install writing into the profile instead of
# following the symlink to ~/.claude.
#
# THE one lane-sensitive field in this script. It is written to $LANE_FILE, not
# to $CACHE_FILE — see the lane-identity block at the head of the file.
# $config_dir is derived there.
missing=0
# INVARIANT: the gsd runtime item below MUST track the live gsd install dir name.
# 2026-06-05 `@opengsd/gsd-core@1.3.1` renamed `get-shit-done/` -> `gsd-core/`; the
# stale `get-shit-done` entry counted a permanently-missing dir and surfaced a false
# `patches:DRIFT 1 broken symlink` token. A future rename does the same silently —
# guarded by tests/probes/probe-gsd-roots-resolve.sh. See docs/decisions.md
# 2026-06-05 gsd-core rename row.
# 2026-08-08: `package.json` dropped from the list — gsd-core 1.10.0 (#2544)
# removed the config-root package.json outright (CommonJS marker moved to
# hooks/package.json + plugin dirs, which ride the `hooks` item above), so the
# old entry was another permanently-missing false `1 broken symlink` token —
# the same failure mode as the 2026-06-05 rename row above.
# 2026-09-15: `dhx-tools` ADDED — it is in symlinks.yaml `ccs-profiles.links` (so
# `/dhx:sym setup|repair` creates it) but was absent here, and the dashboard's
# parity check cannot see it either: dhx-dashboard.cjs `readSymlinks()` diffs every
# instance against the DEFAULT profile and skips that profile itself (`e.name !==
# ref`), so a `dhx-tools` lost from the reference lane was invisible to both. This
# item is a BACKSTOP, not a break detector: consumers are $HOME-anchored per
# install-dhx-tools.sh, so a missing lane link no longer breaks them (the skills-side
# `/dhx:upstream` call sites were repointed 2026-09-15); ~/repos/cross-repo
# scripts/upstream/* still lane-anchor MARKER_DIR/WATCH_DRIVER and would break.
# REALPATH, not the lexical spelling — both operands, both tests. The lane identity
# above is realpath-normalized, so a lexical comparison here decided the CCS-vs-canonical
# RULE on a different basis than the one that picked the sidecar to write it into, and the
# two disagree whenever $CLAUDE_CONFIG_DIR names canonical by any spelling other than
# "$HOME/.claude" exactly. Two measured spellings, both reported missing_symlinks:5 where
# canonical reports 0 — a lane symlinked at $HOME/.ccs/instances/<n> -> $HOME/.claude, and
# a plain internal double slash ($HOME//.claude). In both the reading was then SERVED to
# canonical, because the stamp the reader checks is the realpath and it matched. Found by
# the close-gate reviewer, 2026-09-15; probe cases [11]-[13].
# 2026-09-15 (second edit, same day): the loop read a link's EXISTENCE and TYPE but never
# its DESTINATION, so a link that exists, is a symlink, and resolves to a decoy — a stale
# instance dir, an old `get-shit-done` path, another lane — was indistinguishable from a
# healthy one. That is the quiet fault of the three: a missing item means something never
# ran and a real dir means an install wrote to the wrong place, both loud, while a
# wrong-target link resolves cleanly and silently serves a different tree. Reproduced in a
# fixture lane before the fix: `dhx-tools` repointed at an existing decoy reported
# missing_symlinks:0, and repointed at a nonexistent path reported 1 — so `-e` already
# covered dangling and only "resolves elsewhere" was blind.
#
# The expected target is DERIVED, never tabulated: every item here links to
# ~/.claude/<same basename>, verified across all 25 live lane links plus symlinks.yaml
# `ccs-profiles.links`, so this is one comparison rather than a per-item map that becomes
# the next thing to go stale. The membership of this list has already gone stale twice for
# exactly that reason.
#
# ULTIMATE REFERENT, not the immediate target — and this is forced, not preferred. The
# repair primitive (skills scripts/lib/sym-core.sh cmd_link) decides "already correct" by
# comparing `readlink -f` on both operands, so a hook comparing one-level targets would
# count links that repair calls correct and refuses to touch: a permanent false count, the
# same cry-wolf failure the 2026-06-05 rename and the 2026-08-08 package.json removal each
# produced. Realpath on BOTH operands for the same reason the CCS-vs-canonical test above
# uses it, with a live proof: canonical's own `gsd-local-patches` is itself a symlink into
# ~/repos/dotfiles, so a lexical compare against "$HOME/.claude/$item" flags a healthy lane.
#
# BRANCH ORDER IS LOAD-BEARING. `-e` must stay first: two paths resolve EQUAL when both
# name the same NONEXISTENT final component, so a lane link pointing at an absent canonical
# item passes the target comparison and is caught only by the existence test. The `! -L`
# branch stays too — subsuming it into the comparison (a real dir resolves to itself, so it
# would be counted either way) would collapse "real dir standing in" and "link to the wrong
# place" into one indistinguishable state, and the diagnose snippet names them separately.
#
# KNOWN GAP, filed not fixed: `/dhx:sym repair` cannot currently fix what this branch
# counts. Its per-path audit (cmd_check) prints `symlink` for a decoy-pointing link, so
# repair never collects the item — though cmd_link repoints one correctly when asked.
# Brief: ~/repos/skills/.planning/backlog/2026-09-15-sym-audit-check-is-destination-blind.md
for item in gsd-core hooks gsd-file-manifest.json gsd-local-patches dhx-tools; do
  p="$config_dir_real/$item"
  expected_real="$(readlink -f "$claude_home_real/$item" 2>/dev/null || echo "$claude_home_real/$item")"
  if [[ ! -e "$p" ]]; then
    missing=$((missing + 1))
  elif [[ "$config_dir_real" != "$claude_home_real" && ! -L "$p" ]]; then
    missing=$((missing + 1))
  elif [[ "$(readlink -f "$p" 2>/dev/null || echo "")" != "$expected_real" ]]; then
    missing=$((missing + 1))
  fi
done

# --- Settings chain integrity ---
# Canonical: ~/.claude/settings.json -> ~/.ccs/shared/settings.json (real file).
# The .bashrc claude() wrapper enforces this on session exit, but can be
# bypassed (subshells, repair scripts using `mv tmp target` on the symlink).
# When the chain breaks, ~/.claude/settings.json silently stops tracking CCS
# changes — no user-visible error, just drift.
settings_chain="ok"
claude_settings="$HOME/.claude/settings.json"
shared_settings="$HOME/.ccs/shared/settings.json"
if [[ ! -f "$shared_settings" ]] || [[ -L "$shared_settings" ]]; then
  settings_chain="SHARED_MISSING"
elif [[ ! -L "$claude_settings" ]]; then
  settings_chain="REAL_FILE"
elif [[ "$(readlink -f "$claude_settings")" != "$(readlink -f "$shared_settings")" ]]; then
  settings_chain="WRONG_TARGET"
fi

# --- CLAUDE.md symlink integrity ---
# install.sh (lines 31-34: `for file in CLAUDE.md settings.json … ln -sf`) links
# $HOME/.claude/CLAUDE.md -> the dotfiles canonical. On 2026-06-15 it was found
# to be a REGULAR FILE: the symlink had silently broken and live edits piled up
# in the orphaned file while the versioned dotfiles backup stayed ~8 weeks stale
# (canonical last touched 2026-04-21). CC reads the regular file fine, so the
# session still works — this is an ADVISORY drift signal, not a wiring break
# (tier set in scripts/lib/tiers.json). Fixed-target check mirrors settings_chain
# above; hardcodes the canonical the way settings_chain hardcodes ~/.ccs/shared.
# $HOME/.claude (not CLAUDE_CONFIG_DIR) because install.sh links that exact path.
# Recovery: /dhx:sym repair restores the symlink (skills 5547627c; a diverged
# regular file is backed up + operator-gated). States: ok | MISSING | REAL_FILE | WRONG_TARGET.
claude_md_state="ok"
claude_md="$HOME/.claude/CLAUDE.md"
claude_md_canonical="$HOME/repos/dotfiles/claude/CLAUDE.md"
if [[ ! -e "$claude_md" ]]; then
  claude_md_state="MISSING"
elif [[ ! -L "$claude_md" ]]; then
  claude_md_state="REAL_FILE"
elif [[ "$(readlink -f "$claude_md")" != "$(readlink -f "$claude_md_canonical")" ]]; then
  claude_md_state="WRONG_TARGET"
fi

# --- Plugin keys (HP-017 residual risk) ---
# enabledPlugins["dhx@dhx-local"] + extraKnownMarketplaces["dhx-local"] live in
# settings.json and are clobber-vulnerable per the 2026-04-16 rewriter
# investigation. Missing either → plugin hooks stop firing and /dhx:sym repair
# is the recovery path.
#
# Two-source resolution: the skills-repo `/dhx:sym` publisher writes
# ~/.cache/dhx/sym-health.json on every status/audit/repair invocation. That
# file is the authoritative signal (single source of truth — same process that
# runs `claude plugin enable` publishes the result). If fresh (<1h via
# checked_at) AND STAMPED FOR THIS LANE, prefer its plugin_keys field. Otherwise
# fall back to the direct jq check below — defense-in-depth when the cache goes
# stale, the skills repo moves, or the publisher breaks. Resolution of
# settings.json via CLAUDE_CONFIG_DIR + realpath matches
# statusline-wrapper.js::hashWarnSettings().
#
# THE LANE STAMP, and why the freshness gate alone was not enough (2026-09-15).
# The publisher computes its verdict from a PER-LANE input —
# $CLAUDE_CONFIG_DIR/settings.json — but writes it to one $HOME-anchored file
# every CCS lane shares. Before it carried `config_dir`, a fresh verdict was
# simply believed, so the last lane to run /dhx:sym won and this hook served a
# foreign answer. The failure is a FALSE-CLEAN, the bad direction: all lanes
# normally link settings.json to the same ~/.ccs/shared/settings.json and agree,
# so the gap costs nothing until the one case the detector exists for — a lane
# whose OWN link has broken, whose real MISSING is then masked by a healthy
# lane's `ok`. The symlink loop below cannot cover it either: settings.json is
# not one of the five items it walks.
#
# Compared as REALPATHS on both sides. $config_dir_real is the same normalised
# value the lane-identity block derives, and the publisher stamps
# `readlink -f`. That is the round-1 lesson from the health.json arc, where a
# lexical-vs-realpath split let a lane symlinked to canonical compare unequal to
# itself. An UNSTAMPED file is refused, not trusted — written before this
# change, unknown provenance, and unknown provenance is what the stamp ends.
# Refusal costs nothing: it falls through to the lane-local jq check below.
# Producer + schema: ~/repos/skills/docs/decisions/2026-09-15-sym-health-lane-stamp.md
plugin_keys=""
sym_health="$CACHE_DIR/sym-health.json"
if [[ -f "$sym_health" ]]; then
  # ONE read of the file; all three fields parsed from the SAME bytes.
  #
  # This block used to run three separate `jq` invocations — stamp, then freshness, then
  # verdict — and a close-gate reviewer refuted the close on it: each `jq` opens the
  # pathname again, so an atomic replacement landing between them let the stamp be checked
  # against one object and the verdict taken from another. The publisher writing atomically
  # does not help; atomicity makes each read see SOME whole file, never the same one.
  # Demonstrated by swapping in a fresh, foreign-stamped `ok` immediately after the stamp
  # read, in a lane whose own settings require MISSING: the accepted verdict was `ok`.
  #
  # Checking a value and then re-reading it is the same defect the publisher was refuted
  # for one round earlier (two resolutions of one thing, free to disagree). The rule that
  # covers the class, rather than these three lines: decide from one read.
  sym_fields=$(jq -r '[.config_dir // "", .checked_at // "", .plugin_keys // ""] | @tsv' "$sym_health" 2>/dev/null)
  IFS=$'\t' read -r sym_config_dir checked_at sym_plugin_keys <<<"$sym_fields"
  if [[ -n "${sym_config_dir:-}" && "$sym_config_dir" == "$config_dir_real" ]]; then
    if [[ -n "${checked_at:-}" ]]; then
      checked_epoch=$(date -u -d "$checked_at" +%s 2>/dev/null || echo 0)
      age_sec=$(( $(date +%s) - checked_epoch ))
      if (( checked_epoch > 0 && age_sec >= 0 && age_sec < 3600 )); then
        plugin_keys="${sym_plugin_keys:-}"
      fi
    fi
  fi
fi
if [[ -z "$plugin_keys" ]]; then
  plugin_keys="ok"
  settings_real=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)
  if [[ ! -f "$settings_real" ]] || \
     ! jq -e '.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""' "$settings_real" >/dev/null 2>&1; then
    plugin_keys="MISSING"
  fi
fi

# --- Hooks-json wiring canary (HP-017 residual class — manifest→symlink drift) ---
# HP-017 made plugin-manifest hook entries rewriter-safe (they live outside
# settings.json), but the manifest still references scripts via paths under
# $HOME/.claude/hooks/<basename> — and those are symlinks back to dhx/<basename>.
# A missing or wrong-target symlink means the hook silently fails to fire even
# though the manifest entry is intact. plugin_keys catches the settings-side
# clobber; this canary catches the symlink-side drift.
#
# For each command line in the manifest:
#   1. Strip interpreter (bash|node) and quotes; expand $HOME and ${CLAUDE_PLUGIN_ROOT}.
#   2. Verify the target path exists on disk (script-missing → broken).
#   3. If readlink-resolved path is under the dhx repo root, verify the
#      basename is symlinked under ~/.claude/hooks/ AND the symlink resolves
#      back to that same dhx path. Else (non-dhx path: dispatcher under
#      dhx-plugin/, gsd scripts) → script-presence check is enough.
#
# Three env-var indirections enable fixture isolation in
# tests/probes/probe-hooks-wiring.sh — same overridable-default pattern as
# isGsdDriftFromForkSync(snapshot, liveRoot, forkRoot) in statusline-wrapper.js.
#
# INVARIANT: Manifest absent or unparseable → hooks_wiring="ok". Don't false-
# positive a fresh-clone state where the manifest hasn't been generated yet;
# the SessionStart-only execution cadence means a single noisy "broken" reading
# would persist across the entire session.
hooks_wiring="ok"
manifest_default="/home/dhx/repos/hooks/dhx-plugin/plugins/dhx/hooks/hooks.json"
manifest="${DHX_HOOKS_MANIFEST:-$manifest_default}"
dhx_repo_root="${DHX_HOOKS_REPO_ROOT:-/home/dhx/repos/hooks/dhx}"
hooks_dir="${DHX_HOOKS_INSTALL_DIR:-$HOME/.claude/hooks}"

if [[ -f "$manifest" ]]; then
  # ${CLAUDE_PLUGIN_ROOT} resolves to the directory containing .claude-plugin/
  # — i.e., the plugin dir two levels up from hooks/hooks.json. Default uses
  # the canonical path; tests can override DHX_HOOKS_MANIFEST without touching
  # this variable since fixture manifests don't reference ${CLAUDE_PLUGIN_ROOT}.
  plugin_root_default="$(dirname "$(dirname "$manifest_default")")"
  broken=0
  # Walk every command across all event blocks. `.. | objects | select(.command)`
  # is more flexible than the canonical `.hooks | to_entries[] | .value[] | .hooks[]?`
  # path because it tolerates schema variation (no-matcher blocks vs matcher blocks).
  while IFS= read -r cmdline; do
    [[ -z "$cmdline" ]] && continue
    # Strip leading interpreter + space (`bash ` or `node `).
    path="${cmdline#bash }"
    path="${path#node }"
    # Strip surrounding double-quotes.
    path="${path#\"}"
    path="${path%\"}"
    # Expand env vars. Use sed for ${CLAUDE_PLUGIN_ROOT} because bash's `//`
    # substitution misinterprets the literal `${...}` as a nested expansion;
    # ${HOME} is fine since `$HOME` (no braces) escapes cleanly.
    path="${path//\$HOME/$HOME}"
    path=$(printf '%s' "$path" | sed "s|\${CLAUDE_PLUGIN_ROOT}|$plugin_root_default|g")

    if [[ ! -e "$path" ]]; then
      broken=$((broken + 1))
      continue
    fi

    real=$(readlink -f "$path" 2>/dev/null || echo "")
    if [[ -z "$real" ]]; then
      broken=$((broken + 1))
      continue
    fi

    # Symlink contract applies when EITHER:
    #   (a) the declared path lives under the dhx hooks install dir (a dhx
    #       script the manifest references via $HOME/.claude/hooks/<basename>),
    #       OR
    #   (b) the resolved path is under the dhx repo root (catches future
    #       manifest formats that reference dhx scripts directly).
    # Non-dhx scripts (e.g. dispatcher under dhx-plugin/, gsd-owned paths) are
    # caught by neither branch — script-presence is the only check for them.
    declared_in_hooks_dir=0
    [[ "$path" == "$hooks_dir/"* ]] && declared_in_hooks_dir=1
    real_in_dhx_repo=0
    [[ "$real" == "$dhx_repo_root/"* ]] && real_in_dhx_repo=1

    if (( declared_in_hooks_dir || real_in_dhx_repo )); then
      basename=$(basename "$path")
      link="$hooks_dir/$basename"
      if [[ ! -L "$link" ]]; then
        broken=$((broken + 1))
        continue
      fi
      link_real=$(readlink -f "$link" 2>/dev/null || echo "")
      # Symlink must resolve back to a file UNDER the dhx repo root. Any other
      # target (decoy path, accidental relink to a moved location) counts as
      # drift even if the file at the link target exists.
      if [[ -z "$link_real" || "$link_real" != "$dhx_repo_root/"* ]]; then
        broken=$((broken + 1))
        continue
      fi
    fi
  done < <(jq -r '.. | objects | select(.command) | .command' "$manifest" 2>/dev/null)

  if (( broken > 0 )); then
    hooks_wiring="BROKEN:$broken"
  fi
fi

# --- Write MACHINE-WIDE health cache (atomic via temp + mv) ---
# Every field here is computed against a hardcoded $HOME path, so whichever lane
# wrote last, the reading is valid for all of them — last-writer-wins is CORRECT
# for this object and the existing whole-file write is kept unchanged.
# missing_symlinks deliberately absent: it moved to $LANE_FILE below. Do NOT
# reinstate it here as a mirror — a second copy with different semantics is the
# stale trap this split removes, and statusline-wrapper.js now overwrites any
# legacy value it finds so an old cache can never leak one.
#
# plugin_keys STAYS here despite its fallback branch resolving
# ${CLAUDE_CONFIG_DIR}/settings.json, i.e. despite being mechanically per-lane.
# Sharding it would not fix it: its fast-path takes a verdict from
# sym-health.json, which the skills-repo /dhx:sym writes from whatever lane the
# operator was in and which carries NO lane identity of its own — so a per-lane
# slot would still be stamped with a foreign lane's answer. Sharding the
# destination cannot fix an unstamped source, and that source is another repo's.
# Filed: .planning/backlog/2026-09-15-sym-health-json-carries-no-lane-identity.md.
tmp="$CACHE_FILE.tmp.$$"
cat > "$tmp" <<EOF
{"worktree_patches":"$wt_state","read_guard":"$rg_state","claude_md":"$claude_md_state","settings_chain":"$settings_chain","plugin_keys":"$plugin_keys","hooks_wiring":"$hooks_wiring","checked":$(date +%s)}
EOF
mv -f "$tmp" "$CACHE_FILE"

# --- Write PER-LANE health sidecar (atomic via temp + mv) ---
# Empty $LANE_FILE means the config dir failed the allowlist at the head of this
# script (a sandbox tmpdir, an unexpected root). Writing nothing is deliberate:
# the reader then finds no reading for that lane and renders `symlinks:?` rather
# than a count, which is the honest answer and keeps the key space bounded.
# config_dir_real is safe to interpolate into JSON unquoted-escaping because the
# allowlist above admits only $HOME/.claude or $HOME/.ccs/instances/<[A-Za-z0-9_-]+>.
if [[ -n "$LANE_FILE" ]]; then
  ltmp="$LANE_FILE.tmp.$$"
  cat > "$ltmp" <<EOF
{"config_dir":"$config_dir_real","missing_symlinks":$missing,"checked":$(date +%s)}
EOF
  mv -f "$ltmp" "$LANE_FILE"
fi

# --- Clear THIS session's drift snapshots (scoped, not global) ---
# Wrapper now keys snapshots by (session_id, process_start_ticks), so /resume
# into a new process gets a fresh file without needing this hook to run. Hook
# still earns its keep for /clear and /compact events where process identity is
# unchanged but the user wants a fresh drift baseline. Glob matches both the
# process-stamped format (`-p<ticks>.json`) and the legacy session-id-only
# format (for macOS fallback + migration). Other sessions' snapshots intact.
# WR-01 (Phase 20 code-review follow-up): SESSION_ID is untrusted (read from
# stdin JSON). The second rm arg interpolates it UNQUOTED into a glob, so a
# session_id of `*` would expand to `drift-snapshot-*-*.json` and delete EVERY
# session's snapshots — the same untrusted-input-as-filename class the read-guard
# hardened against (D-11). Allowlist the UUID shape (hex + hyphens + underscore)
# before the rm; a non-conforming id skips the targeted prune (the -mtime +30
# catchall below still reclaims it). Allowlist, not denylist: one check rejects
# /, \, .. and every glob metachar (*, ?, [), while the intentional trailing `-*`
# glob stays outside the variable.
if [[ -n "$SESSION_ID" && "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  rm -f "$CACHE_DIR/drift-snapshot-${SESSION_ID}.json" "$CACHE_DIR"/drift-snapshot-${SESSION_ID}-*.json
fi

# --- Prune orphan drift snapshots (Linux: live-tick cross-check) ---
# Fast path: a snapshot filename carries `-p<ticks>` (HP-016 field 22) and any
# ticks value not present in a live CC process is an orphan. 1h mtime grace
# handles newly-started CC processes whose hook just fired (this session or a
# sibling coming up in the same minute). Non-Linux (no /proc) skips this block
# and relies on the 30d sweep below.
#
# Keeps the cache scannable during debugging — `ls ~/.cache/dhx/` stays a
# handful of files instead of hundreds. Not a correctness fix; hygiene only.
# Each live session still keys on its own (session_id, ticks), so no probe
# cares which dead sessions' snapshots survived.
if [[ -d /proc ]]; then
  live_ticks=$(for pid in $(pgrep -f 'bin/claude' 2>/dev/null); do
    awk '{print $22}' /proc/"$pid"/stat 2>/dev/null
  done | sort -u)
  now=$(date +%s)
  for f in "$CACHE_DIR"/drift-snapshot-*-p*.json; do
    [[ -f "$f" ]] || continue
    ticks=$(basename "$f" | sed -nE 's/^drift-snapshot-.*-p([0-9]+)\.json$/\1/p')
    [[ -z "$ticks" ]] && continue
    mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    (( now - mtime < 3600 )) && continue
    if ! grep -Fxq "$ticks" <<<"$live_ticks"; then
      rm -f "$f"
    fi
  done
fi

# --- Prune stale drift cache files (>30 days) ---
# Catchall for non-Linux (no /proc orphan sweep above) and for legacy files
# without `-p<ticks>` suffix (macOS fallback path from HP-016, pre-2026-04-16
# snapshots). Defense-in-depth: any file the orphan sweep missed, the 30d TTL
# eventually collects. session-start-*.json and session-version-*.txt were
# prior drift designs obsoleted by the snapshot-comparison scheme; nothing
# writes them anymore — one-time purge happened 2026-04-16 under the drift-fix
# orchestration.
find "$CACHE_DIR" -name 'drift-snapshot-*.json' -mtime +30 -delete 2>/dev/null

# --- Prune stale PARTIAL-READ NOTE seen-sets (CAL-POLISH-02, D-05) ---
# Per-session seen-set JSONLs keyed on (session_id, CC-process-start-ticks) gate
# the dhx-read-guard.js PARTIAL-READ NOTE to once-per-(session,file). They are
# ephemeral — a /resume rotates the ticks suffix and abandons the old file — so a
# 1-day TTL is intentional (much tighter than the 30d drift-snapshot catchall).
find "$CACHE_DIR" -name 'partial-read-seen-*.jsonl' -mtime +1 -delete 2>/dev/null

# --- Prune sidecars for lanes that stopped starting sessions (>30 days) ---
# Cardinality is already bounded by the allowlist (one entry per CCS instance
# plus `default`), so this is hygiene, not a safety bound — it collects the
# sidecar of an instance that was deleted, matching the 30d catchall two blocks
# up and the file's own "keep the cache scannable during debugging" discipline.
# Deleting a dormant lane's reading is CORRECT, not lossy: the reader then
# renders `symlinks:?` for that lane, which is true — nothing has checked it for
# a month. 30d (not 1d) because a lane legitimately goes weeks between sessions.
find "$CACHE_DIR" -name 'health-lane-*.json' -mtime +30 -delete 2>/dev/null

exit 0
