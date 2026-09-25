#!/bin/bash
# Probe: per-lane scoping of the SessionStart health cache (2026-09-15).
#
# THE DEFECT THIS PINS. `~/.cache/dhx/health.json` is $HOME-anchored and every CCS
# lane's SessionStart writes it, but `missing_symlinks` is computed against
# $CLAUDE_CONFIG_DIR. So the last lane to start a session won: a lane holding a real
# symlink fault wrote 1, the next SessionStart in ANY healthy lane overwrote it with
# 0, and the faulted lane's statusline then rendered a count computed for a different
# directory. Reproduced in a two-lane fixture before the fix; cases [1]-[3] below are
# that reproduction turned into an assertion.
#
# THE CONTRACT NOW:
#   health.json                  — machine-wide fields only, last-writer-wins (correct)
#   health-lane-<id>.json        — BOTH lane-sensitive fields, per lane
#   no sidecar for this lane     — renders `symlinks:?`, NEVER a clean line
#
# 2026-09-16: plugin_keys joined missing_symlinks in the sidecar. It is computed from
# $CLAUDE_CONFIG_DIR on both of its branches and so was always mechanically per-lane;
# what had kept it in the shared object was that its fast-path source (sym-health.json)
# carried no lane identity, and sharding a destination cannot fix an unstamped source.
# That source is stamped now. Cases [4b]-[4d] carry the new field set; the cross-lane
# isolation of the two plugin_keys VALUES is asserted in probe-sym-health-lane-stamp.sh,
# which owns that surface and has a fixture that can produce a genuine plugin-key fault
# (this file's make_lane faults a symlink, which drives missing_symlinks, not plugin_keys).
#
# THE INVARIANT THIS EXISTS FOR (case [7]): the lane id is derived TWICE, in bash by
# dhx-health-check.sh and in JS by statusline-wrapper.js::laneIdFor(). Nothing in
# either language can enforce that they agree, so this probe drives both
# implementations over the same inputs and compares. The sidecar's recorded
# config_dir is the runtime backstop (case [6]) — a drift renders unknown rather than
# serving one lane's reading to another — but the backstop degrades the signal, so
# the agreement is asserted here rather than left to it.
#
# plugin-keys lane-scoping row (which reverses the 2026-09-15 row's AC-3).
# Run: bash tests/probes/probe-health-lane-scoping.sh
#
# SAFE_FOR_LIVE: yes  (mktemp fake $HOME per case + HOME override; the hook's and the
#   wrapper's only writes land under that fake $HOME/.cache/dhx — the live cache is
#   never read or written. Same isolation pattern as probe-claude-md-link-check.sh.)
# LIVE_RUNTIME: no   (every path resolves under the fake $HOME; the hook's dhx-sym.sh
#   fork verifiers are absent there and take their default branch, so no
#   /dhx:sym gsd-update can flip this verdict with the repo unchanged)
# HERMETIC_TIER: yes (8 hook runs + 2 wrapper spawns; ~2s)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-health-check.sh"
WRAPPER="$REPO/dhx/statusline-wrapper.js"
RENDERER="$REPO/dhx/dhx-statusline.js"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; shift; for l in "$@"; do echo "     $l"; done; fail=$((fail+1)); }
chk() { # chk <name> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1 -> $2"; else bad "$1" "got:  $2" "want: $3"; fi
}

# --- fixture: one fake $HOME holding a canonical ~/.claude plus N CCS lanes ---------
# A lane is "faulted" when it is missing the dhx-tools link the hook's loop expects.
#
# RUN-SCOPED ROOT, deliberately. make_home() is called as `H="$(make_home)"`, and an
# `arr+=()` inside a command substitution is discarded when the subshell exits — a
# registry appended that way stays empty, so an EXIT trap iterating it removes nothing
# and the probe leaks a tree per run at a green exit. Allocating every fake home under
# one root and removing the root sidesteps the boundary entirely.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ITEMS=(gsd-core hooks gsd-file-manifest.json gsd-local-patches dhx-tools)

make_home() {
  # mktemp, not a counter. A `_n=$((_n+1))` here is discarded with the subshell of
  # the `H="$(make_home)"` call site, so every "fresh" home would be the SAME
  # directory — and a second fixture inheriting the first one's sidecars turns a
  # lane-id disagreement into a pass. mktemp's uniqueness does not cross that boundary.
  local h; h="$(mktemp -d "$SCRATCH/home.XXXXXX")"
  mkdir -p "$h/.claude/hooks" "$h/.cache/dhx" "$h/repos/dotfiles/claude"
  echo canonical > "$h/repos/dotfiles/claude/CLAUDE.md"
  ln -s "$h/repos/dotfiles/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
  local i
  for i in "${ITEMS[@]}"; do mkdir -p "$h/.claude/$i"; done
  # the wrapper resolves $HOME/.claude/hooks/dhx-statusline.js at module load
  ln -s "$RENDERER" "$h/.claude/hooks/dhx-statusline.js"
  echo "$h"
}

make_lane() { # make_lane <home> <name> <fault|healthy>
  # NOT a single `local a=$1 b=$a` declaration: `local` is a builtin, so every word
  # is expanded BEFORE the builtin assigns anything, and a later operand referring to
  # an earlier one expands to nothing — under `set -u` that is an unbound-variable
  # abort inside a command substitution, which silently yields an EMPTY lane path.
  local h="$1"
  local mode="$3"
  local l="$h/.ccs/instances/$2"
  mkdir -p "$l"
  local i
  for i in "${ITEMS[@]}"; do
    [[ "$mode" == fault && "$i" == dhx-tools ]] && continue
    ln -s "$h/.claude/$i" "$l/$i"
  done
  echo "$l"
}

run_hook() { HOME="$1" CLAUDE_CONFIG_DIR="$2" bash "$HOOK" <<<'{"session_id":"probe-lane"}' >/dev/null 2>&1; }

render() { # render <home> <config_dir> -> statusline stdout; stderr kept for diagnosis
  HOME="$1" CLAUDE_CONFIG_DIR="$2" timeout 10 node "$WRAPPER" \
    <<<'{"session_id":"probe-lane","version":"2.1.112"}' 2>"$SCRATCH/render.err"
}

# LIVENESS GUARD for every render-based assertion below.
#
# An assertion that tests for the ABSENCE of a token is satisfied by a render that
# produced NOTHING -- the wrapper moved, the node spawn dying, $WRAPPER resolving
# outside the repo -- so on a broken harness it reports OK in exactly the situation
# where it can tell you least. That is the same failure [7] carries an rc guard for,
# and the same one that let [14a] pass its own negative control when it was first
# written. This proves the render RAN and emitted a line before any caller judges its
# content; callers branch on the rc and report a dead wrapper as a PROBE ERROR, never
# as a satisfied assertion.
render_live() { # render_live <home> <config_dir> -> stdout; rc 1 when nothing rendered
  local out rc
  out="$(render "$1" "$2")"; rc=$?
  (( rc == 0 )) || return 1
  [[ -n "${out//[[:space:]]/}" ]] || return 1
  printf '%s\n' "$out"
}
render_diag() { # one-line why-it-was-dead, for the bad() detail
  local e; e="$(head -2 "$SCRATCH/render.err" 2>/dev/null | tr '\n' ' ')"
  echo "wrapper: $WRAPPER | stderr: ${e:-<none>}"
}

lane_missing() { jq -r '.missing_symlinks // "ABSENT"' "$1/.cache/dhx/health-lane-$2.json" 2>/dev/null || echo ABSENT; }

# ===================================================================================
# [1]-[3] THE DEFECT, AS AN ASSERTION: a healthy lane's run must not erase a faulted
#         lane's reading, and each lane's reading must be its own.
# ===================================================================================
H="$(make_home)"
LANE_A="$(make_lane "$H" a fault)"
LANE_B="$(make_lane "$H" b healthy)"

run_hook "$H" "$LANE_A"
chk "[1] faulted lane a computes its own count" "$(lane_missing "$H" a)" "1"

run_hook "$H" "$LANE_B"
chk "[2] healthy lane b computes its own count" "$(lane_missing "$H" b)" "0"
chk "[3] lane a's reading SURVIVES lane b's SessionStart (the defect)" "$(lane_missing "$H" a)" "1"

# [4] the shared object no longer carries EITHER lane-sensitive field — a mirror
#     would be a second copy with different semantics, i.e. the stale trap the split
#     removes. The machine-wide fields must still be present and top-level, because the
#     skills-repo reader (sym-gsd-update-report.md steps 12.45(c) / 12.5 check 2) jq's
#     them straight out of this object and hard-exits on them.
#
#     LIVENESS GUARD (tests/probes/README.md § Liveness guards). [4a] and [4c] are
#     ABSENCE assertions, the shape satisfied by a harness that produced nothing. A
#     MISSING file is already caught — jq errors and the empty result fails the
#     comparison — but an EMPTY OBJECT is not: `{}` answers `has(...)` with a clean
#     `false` and would pass both vacuously. So each is anchored on a field the hook
#     always writes, and asserts presence-and-absence in ONE expression: the `false`
#     is unreachable unless the producer actually ran.
got="$(jq -r 'has("settings_chain") and (has("missing_symlinks")|not)' "$H/.cache/dhx/health.json" 2>/dev/null)"
chk "[4a] health.json does NOT carry missing_symlinks (and is live)" "$got" "true"
got="$(jq -r 'has("settings_chain") and (has("plugin_keys")|not)' "$H/.cache/dhx/health.json" 2>/dev/null)"
chk "[4c] health.json does NOT carry plugin_keys (and is live)" "$got" "true"
got="$(jq -r '[has("settings_chain"),has("read_guard"),has("hooks_wiring")] | all' "$H/.cache/dhx/health.json" 2>/dev/null)"
chk "[4b] health.json KEEPS the 3 machine-wide fields the skills-repo reader gates on" "$got" "true"
# [4d] the field did not evaporate: it MOVED. Asserting only its absence above would
#      pass equally against a hook that stopped computing it altogether, so the
#      destination is asserted too. MISSING, not ok, is the correct expectation here:
#      make_home() writes NO settings.json, so the predicate has nothing to resolve and
#      MISSING is this fixture's honest verdict. What discriminates is MISSING vs the
#      ABSENT fallback — present-and-lane-local versus not-written-at-all. The
#      cross-lane ISOLATION of the two values lives in probe-sym-health-lane-stamp.sh,
#      whose fixture can produce both because it builds a real settings.json per lane.
got="$(jq -r '.plugin_keys // "ABSENT"' "$H/.cache/dhx/health-lane-b.json" 2>/dev/null || echo ABSENT)"
chk "[4d] the lane sidecar carries plugin_keys instead" "$got" "MISSING"

# ===================================================================================
# [5] ALLOWLIST: $CLAUDE_CONFIG_DIR is untrusted. A config dir outside $HOME/.claude
#     and $HOME/.ccs/instances/<[A-Za-z0-9_-]+> must write NO sidecar, so no caller can
#     mint cache entries. Bounding cardinality, not merely age.
# ===================================================================================
SANDBOX="$SCRATCH/sandbox"; mkdir -p "$SANDBOX"
run_hook "$H" "$SANDBOX"
got="$(find "$H/.cache/dhx" -name 'health-lane-*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
chk "[5a] a sandbox config dir mints NO sidecar" "$got" "health-lane-a.json health-lane-b.json "
# a nested path under instances/ is also refused — only single-segment names pass
NESTED="$H/.ccs/instances/b/sub"; mkdir -p "$NESTED"
run_hook "$H" "$NESTED"
got="$(find "$H/.cache/dhx" -name 'health-lane-*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
chk "[5b] a nested path under instances/ mints NO sidecar" "$got" "health-lane-a.json health-lane-b.json "

# ===================================================================================
# [6] The runtime backstop: a sidecar recorded against a DIFFERENT config dir must not
#     be served. This is what makes a producer/consumer derivation drift degrade to
#     unknown instead of to another lane's reading.
# ===================================================================================
got="$(HOME="$H" CLAUDE_CONFIG_DIR="$LANE_A" node -e '
  const w = require(process.argv[1]);
  console.log(String(w.readLaneHealth(process.env.CLAUDE_CONFIG_DIR, process.env.HOME)));
' "$WRAPPER" 2>/dev/null)"
chk "[6a] lane a's own sidecar IS served to lane a" "$got" "1"

# rewrite lane a's sidecar to claim it was computed for lane b
jq --arg c "$LANE_B" '.config_dir = $c' "$H/.cache/dhx/health-lane-a.json" > "$H/.cache/dhx/health-lane-a.json.t" \
  && mv "$H/.cache/dhx/health-lane-a.json.t" "$H/.cache/dhx/health-lane-a.json"
got="$(HOME="$H" CLAUDE_CONFIG_DIR="$LANE_A" node -e '
  const w = require(process.argv[1]);
  console.log(String(w.readLaneHealth(process.env.CLAUDE_CONFIG_DIR, process.env.HOME)));
' "$WRAPPER" 2>/dev/null)"
chk "[6b] a sidecar stamped for another lane is REFUSED (undefined)" "$got" "undefined"

# ===================================================================================
# [7] THE TWO-LANGUAGE INVARIANT: bash producer and JS consumer derive the same id.
#     Driven over the real inputs, not a restatement of either implementation.
# ===================================================================================
H2="$(make_home)"
make_lane "$H2" zz healthy >/dev/null
agree=1
for cfg in "$H2/.claude" "$H2/.ccs/instances/zz" "$H2/.ccs/instances/zz/" "/tmp"; do
  # ABSOLUTE -newermt operand, not a relative one. `find` here is a bfs shim: a
  # relative `-newermt '5 seconds ago'` exits 1 with NO output and the 2>/dev/null
  # everyone adds for permission noise eats the `Invalid timestamp` — the sweep then
  # reads as "nothing was written", which in THIS probe would render an id
  # disagreement as agreement-on-nothing. Epoch form parses everywhere.
  since="@$(( $(date +%s) - 5 ))"
  run_hook "$H2" "$cfg"
  # producer's answer = which sidecar (if any) it just wrote
  bash_id="$(find "$H2/.cache/dhx" -name 'health-lane-*.json' -newermt "$since" -printf '%f\n' 2>/dev/null \
             | sed -nE 's/^health-lane-(.*)\.json$/\1/p' | head -1)"
  # rc captured, stderr NOT swallowed into the comparison. A node failure (wrapper
  # moved, export dropped, syntax error) yields an empty js_id, and an empty bash_id
  # is the legitimate answer for a refused config dir — so without this guard the one
  # case that MUST not pass silently, the invariant case, passes vacuously on a broken
  # harness. Observed: running this probe against a copy outside the repo resolved
  # $WRAPPER to a nonexistent path and all four rows reported agreement-on-nothing.
  js_id="$(HOME="$H2" node -e '
    const w = require(process.argv[1]);
    const r = w.laneIdFor(process.argv[2], process.env.HOME);
    console.log(r === null ? "" : r);
  ' "$WRAPPER" "$cfg" 2>"$SCRATCH/node.err")"
  js_rc=$?
  if (( js_rc != 0 )); then
    bad "[7] consumer laneIdFor() could not be driven for '${cfg/#$H2/\$HOME}'" \
        "node rc=$js_rc" "$(head -2 "$SCRATCH/node.err")"
    agree=0
  elif [[ "$bash_id" == "$js_id" ]]; then
    ok "[7] lane-id agreement for '${cfg/#$H2/\$HOME}' -> '${bash_id:-<none>}'"
  else
    bad "[7] lane-id DISAGREEMENT for '${cfg/#$H2/\$HOME}'" "bash: '$bash_id'" "js:   '$js_id'"
    agree=0
  fi
  rm -f "$H2/.cache/dhx"/health-lane-*.json
done

# ===================================================================================
# [8]-[9] RENDER: an absent reading must surface as `symlinks:?`, never as silence,
#         and a legacy top-level missing_symlinks must not leak into the line.
# ===================================================================================
H3="$(make_home)"
LANE_C="$(make_lane "$H3" c healthy)"
run_hook "$H3" "$LANE_C"
rm -f "$H3/.cache/dhx/health-lane-c.json"          # lane has never run under the new hook
if ! out="$(render_live "$H3" "$LANE_C")"; then
  bad "[8] PROBE ERROR: the statusline wrapper could not be driven" "$(render_diag)"
elif grep -q 'symlinks:?' <<<"$out"; then
  ok "[8] no sidecar for this lane renders 'symlinks:?' (not a clean line)"
else
  bad "[8] absent reading did not render as unknown" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
fi

# a pre-2026-09-15 cache still carrying the field must not be believed
jq '. + {missing_symlinks: 5}' "$H3/.cache/dhx/health.json" > "$H3/.cache/dhx/health.json.t" \
  && mv "$H3/.cache/dhx/health.json.t" "$H3/.cache/dhx/health.json"
if ! out="$(render_live "$H3" "$LANE_C")"; then
  bad "[9] PROBE ERROR: the statusline wrapper could not be driven" "$(render_diag)"
elif grep -q 'symlinks:5' <<<"$out"; then
  bad "[9] legacy top-level missing_symlinks LEAKED into the render" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
elif grep -q 'symlinks:?' <<<"$out"; then
  ok "[9] legacy top-level missing_symlinks is unreachable; still renders 'symlinks:?'"
else
  bad "[9] neither the legacy value nor the unknown token rendered" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
fi

# [10] and a lane WITH a clean reading stays silent — 0 is not the same as unknown
run_hook "$H3" "$LANE_C"
# THE ABSENCE ASSERTION. Everything this case wants to catch shows up as a token that
# should not be there -- so an empty render satisfies it. Liveness first, content second.
if ! out="$(render_live "$H3" "$LANE_C")"; then
  bad "[10] PROBE ERROR: the statusline wrapper could not be driven, so the absence of" \
      "a symlink token proves nothing" "$(render_diag)"
elif grep -q 'symlinks:' <<<"$out"; then
  bad "[10] a checked-and-clean lane emitted a symlink token" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
else
  ok "[10] a checked-and-clean lane emits NO symlink token (render was live)"
fi

# ===================================================================================
# [11]-[14] SPELLING-INDEPENDENCE. Added 2026-09-15 after the close-gate reviewer
#   REFUTED the first round on exactly this gap: the lane identity was realpath-
#   normalized while the symlink loop's CCS-vs-canonical rule was still lexical, so a
#   config dir naming canonical by any other spelling ran the CCS rule over canonical's
#   real items, counted all five as faults, and — because the stamp the reader checks is
#   the realpath — SERVED that 5 to canonical. The cases below are the counterexamples
#   it constructed, kept as assertions. The probe's earlier agreement matrix at [7] tests
#   canonical, a normal lane, a trailing slash and /tmp; none of those is an ALIAS.
# ===================================================================================
H4="$(make_home)"
CANON_MISSING="$(run_hook "$H4" "$H4/.claude"; lane_missing "$H4" default)"
chk "[11] control — canonical by its own name" "$CANON_MISSING" "0"

# an instance path that is itself a symlink to canonical
ln -s "$H4/.claude" "$H4/.ccs/instances/alias" 2>/dev/null || { mkdir -p "$H4/.ccs/instances"; ln -s "$H4/.claude" "$H4/.ccs/instances/alias"; }
rm -f "$H4/.cache/dhx"/health-lane-*.json
run_hook "$H4" "$H4/.ccs/instances/alias"
chk "[12] a lane SYMLINKED to canonical counts like canonical, not like a CCS lane" \
    "$(lane_missing "$H4" default)" "0"

# the same directory named with an internal double slash
rm -f "$H4/.cache/dhx"/health-lane-*.json
run_hook "$H4" "$H4//.claude"
chk "[13] canonical named with a double slash counts like canonical" \
    "$(lane_missing "$H4" default)" "0"

# an instance literally named `default` must not write into canonical's sidecar
H5="$(make_home)"
# FAULTED deliberately: canonical is clean (0) and this instance is missing a link (1), so
# the two counts DIFFER. With both healthy the assertion below reads 0 either way and cannot
# red — it passed against the pre-remediation hook, which is the tell that it was testing
# nothing. An assertion that cannot fail is decoration.
make_lane "$H5" default fault >/dev/null
run_hook "$H5" "$H5/.claude"                       # canonical writes health-lane-default.json
CANON_BEFORE="$(lane_missing "$H5" default)"
run_hook "$H5" "$H5/.ccs/instances/default"        # the colliding instance must NOT overwrite it
# THE EQUALITY ASSERTION, and the same class of hole as [10]. lane_missing() echoes
# ABSENT when the sidecar is not there, so against a producer that writes NO sidecar at
# all the comparison below is ABSENT == ABSENT and passes having observed nothing.
# Anchor it on a real reading first: canonical is clean in this fixture, so 0 is the
# only before-value it can legitimately produce.
if [[ "$CANON_BEFORE" != "0" ]]; then
  bad "[14a] PROBE ERROR: canonical wrote no usable sidecar before the collision" \
      "got before: $CANON_BEFORE" \
      "want: 0 -- ABSENT here means the producer could not be driven, not that the test passed"
else
  chk "[14a] an instance named 'default' does not clobber canonical's sidecar" \
      "$(lane_missing "$H5" default)" "$CANON_BEFORE"
fi
got="$(HOME="$H5" node -e '
  const w = require(process.argv[1]);
  const r = w.laneIdFor(process.argv[2], process.env.HOME);
  console.log(r === null ? "<none>" : r);
' "$WRAPPER" "$H5/.ccs/instances/default" 2>/dev/null)"
chk "[14b] the consumer refuses the reserved name too (producer/consumer agreement)" "$got" "<none>"

echo
echo "PASS: $pass  FAIL: $fail"
exit $(( fail > 0 ? 1 : 0 ))
