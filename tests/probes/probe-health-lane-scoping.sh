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
#   health-lane-<id>.json        — the one lane-sensitive field, per lane
#   no sidecar for this lane     — renders `symlinks:?`, NEVER a clean line
#
# THE INVARIANT THIS EXISTS FOR (case [7]): the lane id is derived TWICE, in bash by
# dhx-health-check.sh and in JS by statusline-wrapper.js::laneIdFor(). Nothing in
# either language can enforce that they agree, so this probe drives both
# implementations over the same inputs and compares. The sidecar's recorded
# config_dir is the runtime backstop (case [6]) — a drift renders unknown rather than
# serving one lane's reading to another — but the backstop degrades the signal, so
# the agreement is asserted here rather than left to it.
#
# Backs docs/decisions.md 2026-09-15 health-cache lane-scoping row.
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

render() { # render <home> <config_dir> -> statusline stdout
  HOME="$1" CLAUDE_CONFIG_DIR="$2" timeout 10 node "$WRAPPER" \
    <<<'{"session_id":"probe-lane","version":"2.1.112"}' 2>/dev/null
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

# [4] the shared object no longer carries the lane-sensitive field at all — a mirror
#     would be a second copy with different semantics, i.e. the stale trap the split
#     removes. Machine-wide fields must still be present and top-level, because the
#     skills-repo reader (sym-gsd-update-report.md steps 12.45(c) / 12.5 check 2) jq's
#     them straight out of this object and hard-exits on them.
got="$(jq -r 'has("missing_symlinks")' "$H/.cache/dhx/health.json" 2>/dev/null)"
chk "[4a] health.json does NOT carry missing_symlinks" "$got" "false"
got="$(jq -r '[has("settings_chain"),has("read_guard"),has("plugin_keys"),has("hooks_wiring")] | all' "$H/.cache/dhx/health.json" 2>/dev/null)"
chk "[4b] health.json KEEPS the 4 fields the skills-repo reader gates on" "$got" "true"

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
out="$(render "$H3" "$LANE_C")"
if grep -q 'symlinks:?' <<<"$out"; then
  ok "[8] no sidecar for this lane renders 'symlinks:?' (not a clean line)"
else
  bad "[8] absent reading did not render as unknown" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
fi

# a pre-2026-09-15 cache still carrying the field must not be believed
jq '. + {missing_symlinks: 5}' "$H3/.cache/dhx/health.json" > "$H3/.cache/dhx/health.json.t" \
  && mv "$H3/.cache/dhx/health.json.t" "$H3/.cache/dhx/health.json"
out="$(render "$H3" "$LANE_C")"
if grep -q '5 broken symlinks' <<<"$out"; then
  bad "[9] legacy top-level missing_symlinks LEAKED into the render" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
elif grep -q 'symlinks:?' <<<"$out"; then
  ok "[9] legacy top-level missing_symlinks is unreachable; still renders 'symlinks:?'"
else
  bad "[9] neither the legacy value nor the unknown token rendered" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
fi

# [10] and a lane WITH a clean reading stays silent — 0 is not the same as unknown
run_hook "$H3" "$LANE_C"
out="$(render "$H3" "$LANE_C")"
if grep -q 'symlinks:?\|broken symlink' <<<"$out"; then
  bad "[10] a checked-and-clean lane emitted a symlink token" "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
else
  ok "[10] a checked-and-clean lane emits NO symlink token"
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
chk "[14a] an instance named 'default' does not clobber canonical's sidecar" \
    "$(lane_missing "$H5" default)" "$CANON_BEFORE"
got="$(HOME="$H5" node -e '
  const w = require(process.argv[1]);
  const r = w.laneIdFor(process.argv[2], process.env.HOME);
  console.log(r === null ? "<none>" : r);
' "$WRAPPER" "$H5/.ccs/instances/default" 2>/dev/null)"
chk "[14b] the consumer refuses the reserved name too (producer/consumer agreement)" "$got" "<none>"

echo
echo "PASS: $pass  FAIL: $fail"
exit $(( fail > 0 ? 1 : 0 ))
