#!/bin/bash
# Probe: the lane stamp on ~/.cache/dhx/sym-health.json (2026-09-15).
#
# THE DEFECT THIS PINS. The skills-repo publisher (`/dhx:sym status|audit|repair`
# -> scripts/lib/doctor.sh::cmd_health_export) computes its `plugin_keys` verdict
# from a PER-LANE input, $CLAUDE_CONFIG_DIR/settings.json, and writes it to ONE
# $HOME-anchored file every CCS lane shares. Before the object carried
# `config_dir`, both hooks-repo consumers believed any FRESH verdict, so the last
# lane to run /dhx:sym won.
#
# The failure is a FALSE-CLEAN, which is the bad direction for a detector. Lanes
# normally link settings.json to the same ~/.ccs/shared/settings.json and agree, so
# the missing stamp costs nothing until the one case the detector exists for: a lane
# whose OWN link has broken, whose real MISSING is masked by a healthy lane's `ok`.
# The hooks-side symlink loop cannot cover that gap — settings.json is not one of
# the five items it walks. Cases [1]-[3] are that reproduction turned into an
# assertion.
#
# THE CONTRACT NOW:
#   published verdict, stamp == this lane   -> served (60s post-repair clear kept)
#   published verdict, stamp == other lane  -> refused, lane-local check instead
#   published verdict, NO stamp (pre-09-15) -> refused; unknown provenance
#   compare REALPATHS on both sides         -> a spelling cannot fake identity
#
# THE INVARIANT THIS EXISTS FOR (case [7]): the stamp is written in bash by one
# repo and tested in bash AND JavaScript by another. Nothing in either language can
# enforce that the three agree, so this probe drives all three over the same inputs.
#
# Backs ~/repos/skills/docs/decisions/2026-09-15-sym-health-lane-stamp.md and the
# hooks-side docs/decisions.md row of the same date.
# Run: bash tests/probes/probe-sym-health-lane-stamp.sh
#
# SAFE_FOR_LIVE: yes  (one run-scoped `mktemp -d` root holds every fake $HOME; the
#   publisher, the hook and the wrapper are all spawned with HOME + CLAUDE_CONFIG_DIR
#   pointed inside it, so every ~/.cache/dhx write lands there and the live cache is
#   never read or written)
# LIVE_RUNTIME: no   (every path resolves under the fake $HOME; the publisher's and
#   the hook's fork verifiers are absent there and take their default branch, so no
#   /dhx:sym gsd-update can flip this verdict with the repo unchanged)
# HERMETIC_TIER: yes (6 publisher runs + 6 hook runs + 5 node spawns; ~3s)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-health-check.sh"
WRAPPER="$REPO/dhx/statusline-wrapper.js"
RENDERER="$REPO/dhx/dhx-statusline.js"
PUBLISHER="$HOME/repos/skills/scripts/dhx-sym.sh"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; shift; for l in "$@"; do echo "     $l"; done; fail=$((fail+1)); }
chk() { if [[ "$2" == "$3" ]]; then ok "$1 -> $2"; else bad "$1" "got:  $2" "want: $3"; fi; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# --- fixture ------------------------------------------------------------------------
# A lane is "broken" when its OWN settings.json link dangles — the exact fault the
# publisher's verdict is computed from, and the one the symlink loop cannot see.
GOOD_SETTINGS='{"enabledPlugins":{"dhx@dhx-local":true},"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"/p"}}}}'

make_home() {
  local h; h="$(mktemp -d "$SCRATCH/home.XXXXXX")"
  mkdir -p "$h/.ccs/instances" "$h/.ccs/shared" "$h/.cache/dhx" "$h/.claude/hooks"
  # the wrapper resolves $HOME/.claude/hooks/dhx-statusline.js at MODULE LOAD, so
  # without this every `require()` below dies before the predicate is even reached —
  # which the liveness guards report as a probe error rather than as agreement
  ln -sf "$RENDERER" "$h/.claude/hooks/dhx-statusline.js"
  printf '%s' "$GOOD_SETTINGS" > "$h/.ccs/shared/settings.json"
  ln -sf "$h/.ccs/shared/settings.json" "$h/.claude/settings.json"
  echo "$h"
}

make_lane() { # make_lane <home> <name> healthy|broken -> lane path
  local h="$1"
  local n="$2"
  local kind="$3"
  local d="$h/.ccs/instances/$n"
  mkdir -p "$d"
  if [[ "$kind" == healthy ]]; then ln -sf "$h/.ccs/shared/settings.json" "$d/settings.json"
  else ln -sf "$h/.ccs/shared/DANGLING.json" "$d/settings.json"; fi
  echo "$d"
}

publish() { HOME="$1" CLAUDE_CONFIG_DIR="$2" bash "$PUBLISHER" health-export >/dev/null 2>&1; }
run_hook() { HOME="$1" CLAUDE_CONFIG_DIR="$2" bash "$HOOK" <<<'{"session_id":"probe-stamp"}' >/dev/null 2>&1; }

sym_field() { jq -r --arg f "$2" '.[$f] // "ABSENT"' "$1/.cache/dhx/sym-health.json" 2>/dev/null || echo ABSENT; }
hook_pk()   { jq -r '.plugin_keys // "ABSENT"' "$1/.cache/dhx/health.json" 2>/dev/null || echo ABSENT; }

# LIVENESS GUARD (tests/probes/README.md § Liveness guards). Several assertions below
# are equality checks whose helpers echo ABSENT for a missing file, and one is an
# absence check on a render. Both shapes are satisfied by a harness that produced
# NOTHING, so each is anchored on a value the fixture can legitimately produce, and
# the render is proved live before its content is judged.
render() { HOME="$1" CLAUDE_CONFIG_DIR="$2" timeout 10 node "$WRAPPER" \
    <<<'{"session_id":"probe-stamp","version":"2.1.112"}' 2>"$SCRATCH/render.err"; }
render_live() {
  local out rc
  out="$(render "$1" "$2")"; rc=$?
  (( rc == 0 )) || return 1
  [[ -n "${out//[[:space:]]/}" ]] || return 1
  printf '%s\n' "$out"
}

# The publisher lives in a SIBLING repo. If it is not checked out this probe cannot
# assert the cross-repo half at all — say so loudly and fail, rather than skipping
# quietly into a green run. A skip that reads as a pass is the failure mode the
# README rule names.
if [[ ! -f "$PUBLISHER" ]]; then
  bad "[0] PROBE ERROR: publisher not found at $PUBLISHER" \
      "the stamp is written by the skills repo; without it nothing below is meaningful"
  echo; echo "PASS: $pass  FAIL: $fail"; exit 1
fi
ok "[0] publisher present — the cross-repo half can be driven"

# ===================================================================================
# [1]-[3] THE DEFECT, AS AN ASSERTION: a healthy lane's publish must not erase a
#         broken lane's verdict.
# ===================================================================================
H="$(make_home)"
BROKEN="$(make_lane "$H" broken broken)"
HEALTHY="$(make_lane "$H" healthy healthy)"

publish "$H" "$BROKEN"
run_hook "$H" "$BROKEN"
chk "[1] the broken lane computes its own verdict" "$(hook_pk "$H")" "MISSING"

publish "$H" "$HEALTHY"
chk "[2] the healthy lane's publish lands in the shared file" "$(sym_field "$H" plugin_keys)" "ok"

run_hook "$H" "$BROKEN"
chk "[3] the broken lane's verdict SURVIVES a healthy lane's publish (the defect)" \
    "$(hook_pk "$H")" "MISSING"

# ===================================================================================
# [4] SCHEMA: the publisher stamps, and the stamp is the REALPATH — not whatever
#     spelling of the config dir it happened to be invoked with. A lexical stamp
#     would rebuild the bug one layer up: the parallel health.json arc was REFUTED
#     for exactly that, a lane symlinked to canonical comparing unequal to itself.
# ===================================================================================
chk "[4a] the published object carries config_dir" \
    "$(jq -r 'has("config_dir")' "$H/.cache/dhx/sym-health.json" 2>/dev/null)" "true"
chk "[4b] the stamp is this lane's realpath" "$(sym_field "$H" config_dir)" "$(readlink -f "$HEALTHY")"

# a config dir named with a trailing slash and an internal double slash must stamp
# the same value, or the consumer's realpath comparison will refuse a lane its own
# reading and render unknown forever
publish "$H" "$HEALTHY/"
chk "[4c] a trailing slash stamps the same realpath" "$(sym_field "$H" config_dir)" "$(readlink -f "$HEALTHY")"
publish "$H" "$H//.ccs/instances/healthy"
chk "[4d] an internal double slash stamps the same realpath" "$(sym_field "$H" config_dir)" "$(readlink -f "$HEALTHY")"

# ===================================================================================
# [5] THE CONSUMER GATE, driven against the REAL exported predicate — not a copy.
# ===================================================================================
js_gate() { # js_gate <home> <config_dir> <stamp>
  HOME="$1" node -e '
    const w = require(process.argv[1]);
    console.log(String(w.symHealthIsForThisLane(process.argv[3], process.argv[2])));
  ' "$WRAPPER" "$2" "$3" 2>"$SCRATCH/node.err"
}
chk "[5a] own stamp is accepted"            "$(js_gate "$H" "$HEALTHY" "$(readlink -f "$HEALTHY")")" "true"
chk "[5b] a foreign stamp is REFUSED"       "$(js_gate "$H" "$HEALTHY" "$(readlink -f "$BROKEN")")"  "false"
chk "[5c] an absent stamp is REFUSED"       "$(js_gate "$H" "$HEALTHY" "")"                          "false"
chk "[5d] a trailing-slash config dir still matches its realpath stamp" \
    "$(js_gate "$H" "$HEALTHY/" "$(readlink -f "$HEALTHY")")" "true"

# ===================================================================================
# [6] THE FALSE-CLEAN, END TO END through the real hook: a FRESH, well-formed,
#     entirely correct `ok` that belongs to another lane must not clear this lane.
# ===================================================================================
H2="$(make_home)"
B2="$(make_lane "$H2" broken broken)"
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"plugin_keys":"ok","config_dir":"/nonexistent/other-lane","checked_at":"%s"}' "$now_utc" \
  > "$H2/.cache/dhx/sym-health.json"
run_hook "$H2" "$B2"
chk "[6a] a foreign fresh 'ok' does NOT mask this lane's real MISSING" "$(hook_pk "$H2")" "MISSING"

# unstamped legacy file — unknown provenance, refused not trusted
printf '{"plugin_keys":"ok","checked_at":"%s"}' "$now_utc" > "$H2/.cache/dhx/sym-health.json"
run_hook "$H2" "$B2"
chk "[6b] an UNSTAMPED legacy file is refused, not trusted" "$(hook_pk "$H2")" "MISSING"

# and the mirror direction: a foreign MISSING must not raise a false alarm
H3="$(make_home)"
G3="$(make_lane "$H3" healthy healthy)"
printf '{"plugin_keys":"MISSING","config_dir":"/nonexistent/other-lane","checked_at":"%s"}' "$now_utc" \
  > "$H3/.cache/dhx/sym-health.json"
run_hook "$H3" "$G3"
chk "[6c] a foreign fresh 'MISSING' does NOT raise a false alarm here" "$(hook_pk "$H3")" "ok"

# the 60-second post-repair clear the 2026-04-16 row bought must SURVIVE for the lane
# the repair ran in — that is the UX this fix was not allowed to cost
printf '{"plugin_keys":"ok","config_dir":"%s","checked_at":"%s"}' "$(readlink -f "$B2")" "$now_utc" \
  > "$H2/.cache/dhx/sym-health.json"
run_hook "$H2" "$B2"
chk "[6d] an OWN-lane publish still overrides the local check (60s clear preserved)" \
    "$(hook_pk "$H2")" "ok"

# ===================================================================================
# [7] THE THREE-WAY INVARIANT: publisher (bash, skills repo), hook gate (bash, hooks
#     repo) and wrapper predicate (JS, hooks repo) must agree on identity over the
#     same inputs. Driven, not restated.
# ===================================================================================
H4="$(make_home)"
L4="$(make_lane "$H4" zz healthy)"
ln -sfn "$L4" "$H4/.ccs/instances/aliased" 2>/dev/null
# TWO OUTCOMES, deliberately. A matrix where every row agrees on `true` cannot tell
# agreement from two implementations that both just say yes — the decoration shape
# tests/probes/README.md names. Each spelling is therefore driven twice: once with the
# publisher's own stamp (must be SERVED) and once with that stamp rewritten to another
# lane (must be REFUSED), so the pair has to track a value that actually changes.
for mode in own foreign; do
  for cfg in "$L4" "$L4/" "$H4//.ccs/instances/zz" "$H4/.ccs/instances/aliased" "$H4/.claude"; do
    rm -f "$H4/.cache/dhx/sym-health.json" "$H4/.cache/dhx/health.json"
    publish "$H4" "$cfg"
    # plant a verdict that DIFFERS from what the lane-local check would produce, so
    # serve-vs-refuse is observable from the resulting health.json at all: lane zz is
    # healthy, so a served publish reads MISSING and a refused one reads ok
    jq --arg m "$mode" \
       '.plugin_keys = "MISSING" | (if $m == "foreign" then .config_dir = "/nonexistent/other-lane" else . end)' \
       "$H4/.cache/dhx/sym-health.json" > "$H4/.cache/dhx/s.t" \
      && mv "$H4/.cache/dhx/s.t" "$H4/.cache/dhx/sym-health.json"

    stamp="$(sym_field "$H4" config_dir)"
    if [[ "$stamp" == "ABSENT" ]]; then
      bad "[7/$mode] PROBE ERROR: no stamp on disk for '${cfg/#$H4/\$HOME}'" \
          "an ABSENT stamp would make the comparison below vacuous"
      continue
    fi
    js="$(js_gate "$H4" "$cfg" "$stamp")"; js_rc=$?
    if (( js_rc != 0 )); then
      bad "[7/$mode] PROBE ERROR: the JS predicate could not be driven for '${cfg/#$H4/\$HOME}'" \
          "node rc=$js_rc" "$(head -2 "$SCRATCH/node.err")"
      continue
    fi
    run_hook "$H4" "$cfg"
    pk="$(hook_pk "$H4")"
    if [[ "$pk" == "ABSENT" ]]; then
      bad "[7/$mode] PROBE ERROR: the hook wrote no health.json for '${cfg/#$H4/\$HOME}'" \
          "served-vs-refused cannot be read off an absent file"
      continue
    fi
    bash_served="$([[ "$pk" == "MISSING" ]] && echo true || echo false)"
    want="$([[ "$mode" == "own" ]] && echo true || echo false)"
    if [[ "$bash_served" == "$js" && "$bash_served" == "$want" ]]; then
      ok "[7/$mode] publisher/hook/wrapper agree for '${cfg/#$H4/\$HOME}' -> served=$js"
    else
      bad "[7/$mode] DISAGREEMENT for '${cfg/#$H4/\$HOME}'" \
          "hook served: $bash_served" "js predicate: $js" "expected: $want"
    fi
  done
done

# ===================================================================================
# [8] RENDER: the statusline must not show another lane's verdict either. The
#     wrapper applies the override a SECOND time, after the hook already resolved it.
# ===================================================================================
H5="$(make_home)"
B5="$(make_lane "$H5" broken broken)"
run_hook "$H5" "$B5"                                     # health.json = MISSING (true)
printf '{"plugin_keys":"ok","config_dir":"/nonexistent/other-lane","checked_at":"%s"}' "$now_utc" \
  > "$H5/.cache/dhx/sym-health.json"                     # a foreign 'ok' arrives
if ! out="$(render_live "$H5" "$B5")"; then
  bad "[8] PROBE ERROR: the statusline wrapper could not be driven" \
      "wrapper: $WRAPPER | stderr: $(head -2 "$SCRATCH/render.err" | tr '\n' ' ')"
elif grep -q 'plugin-keys:MISSING' <<<"$out"; then
  ok "[8] a foreign fresh 'ok' does not clear the rendered warning"
else
  bad "[8] the render CLEARED on another lane's verdict" \
      "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
fi

echo
echo "PASS: $pass  FAIL: $fail"
exit $(( fail > 0 ? 1 : 0 ))
