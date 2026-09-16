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
# hook_pk <home> <lane config dir, ANY spelling> -> that lane's recorded plugin_keys
#
# 2026-09-16: plugin_keys MOVED from the shared health.json into the per-lane sidecar,
# so this helper can no longer read one file -- it has to say WHICH lane it means. It
# selects by the recorded config_dir stamp rather than by deriving the sidecar's
# filename, which is deliberate: that is the exact selection the cross-repo reader
# (sym-gsd-update-report.md step 12.5 check 2) performs, so every assertion below now
# exercises the real consumer mechanism instead of a probe-local shortcut. Deriving the
# filename would need the lane-id allowlist from the head of dhx-health-check.sh, and
# putting that in a third language is what the stamp search exists to avoid.
#
# ABSENT when no sidecar carries that stamp -- distinct from a recorded value, and the
# callers below branch on it as a PROBE ERROR rather than treating it as an answer.
hook_pk() {
  local d; d="$(readlink -f "$2" 2>/dev/null || echo "$2")"
  jq -r --arg d "$d" 'select(.config_dir == $d) | .plugin_keys' "$1"/.cache/dhx/health-lane-*.json 2>/dev/null \
    | head -1 | grep . || echo ABSENT
}

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
chk "[1] the broken lane computes its own verdict" "$(hook_pk "$H" "$BROKEN")" "MISSING"

publish "$H" "$HEALTHY"
chk "[2] the healthy lane's publish lands in the shared file" "$(sym_field "$H" plugin_keys)" "ok"

run_hook "$H" "$BROKEN"
chk "[3] the broken lane's verdict SURVIVES a healthy lane's publish (the defect)" \
    "$(hook_pk "$H" "$BROKEN")" "MISSING"

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

# [5e] A caller that already TRIED to resolve and FAILED hands in null. Treating that as
# "resolve again" is how a second resolution crept back into the one function this arc spent
# four review rounds removing it from — and lint [13c] cannot see it, because the shape is
# semantic, not textual. An unresolvable config dir has no identity, so it matches no stamp.
got="$(HOME="$H" node -e '
  const w = require(process.argv[1]);
  console.log(String(w.symHealthIsForThisLane(process.argv[2], process.argv[3], null)));
' "$WRAPPER" "$(readlink -f "$HEALTHY")" "$HEALTHY" 2>/dev/null)"
chk "[5e] an explicit FAILED resolution refuses rather than resolving again" "$got" "false"

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
chk "[6a] a foreign fresh 'ok' does NOT mask this lane's real MISSING" "$(hook_pk "$H2" "$B2")" "MISSING"

# unstamped legacy file — unknown provenance, refused not trusted
printf '{"plugin_keys":"ok","checked_at":"%s"}' "$now_utc" > "$H2/.cache/dhx/sym-health.json"
run_hook "$H2" "$B2"
chk "[6b] an UNSTAMPED legacy file is refused, not trusted" "$(hook_pk "$H2" "$B2")" "MISSING"

# and the mirror direction: a foreign MISSING must not raise a false alarm
H3="$(make_home)"
G3="$(make_lane "$H3" healthy healthy)"
printf '{"plugin_keys":"MISSING","config_dir":"/nonexistent/other-lane","checked_at":"%s"}' "$now_utc" \
  > "$H3/.cache/dhx/sym-health.json"
run_hook "$H3" "$G3"
chk "[6c] a foreign fresh 'MISSING' does NOT raise a false alarm here" "$(hook_pk "$H3" "$G3")" "ok"

# the 60-second post-repair clear the 2026-04-16 row bought must SURVIVE for the lane
# the repair ran in — that is the UX this fix was not allowed to cost
printf '{"plugin_keys":"ok","config_dir":"%s","checked_at":"%s"}' "$(readlink -f "$B2")" "$now_utc" \
  > "$H2/.cache/dhx/sym-health.json"
run_hook "$H2" "$B2"
chk "[6d] an OWN-lane publish still overrides the local check (60s clear preserved)" \
    "$(hook_pk "$H2" "$B2")" "ok"

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
    # $cfg, NOT $stamp. They are the same path in `own` mode and DIFFERENT in `foreign`
    # mode -- $stamp is what the PUBLISHER recorded, and the foreign arm deliberately makes
    # that another lane's dir. Asking for the reading stamped with a foreign dir finds no
    # sidecar at all, which the guard below then reports as a dead harness rather than as a
    # refusal. The question this case asks is "what did the hook record FOR THIS LANE", so
    # the lane is the key. (Invisible before 2026-09-16: the reading lived in one shared
    # file that needed no key, so own-vs-foreign could not be confused here.)
    pk="$(hook_pk "$H4" "$cfg")"
    if [[ "$pk" == "ABSENT" ]]; then
      bad "[7/$mode] PROBE ERROR: the hook wrote no sidecar for '${cfg/#$H4/\$HOME}'" \
          "served-vs-refused cannot be read off an absent reading"
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

# ===================================================================================
# [9] ONE RESOLUTION, NOT TWO. Round 1 of this brief's close gate REFUTED it here: the
#     producer resolved the config dir for the stamp, then INDEPENDENTLY re-resolved
#     $CLAUDE_CONFIG_DIR/settings.json for the verdict. Two observations of a path that is
#     free to change between them, so the published object could name one lane and carry a
#     verdict computed from another -- an incoherent stamp, which is worse than no stamp,
#     because it is a wrong answer wearing provenance.
#
#     Asserted DETERMINISTICALLY, not by racing. A PATH-local `readlink` stub retargets the
#     lane symlink exactly once, immediately after the config-dir resolution returns, which
#     is precisely the window between the two reads. Racing it reproduced on the first
#     iteration before the fix and 0/400 after, but "did not happen in 400 tries" is absence
#     of evidence under one timing, and an assertion that cannot red on demand is decoration
#     (tests/probes/README.md § Liveness guards).
# ===================================================================================
H6="$(make_home)"
mkdir -p "$H6/good" "$H6/bad" "$SCRATCH/stubbin"
printf '%s' "$GOOD_SETTINGS" > "$H6/good/settings.json"
printf '{}'                  > "$H6/bad/settings.json"
ln -sfn "$H6/good" "$H6/lane"

REAL_READLINK="$(command -v readlink)"
cat > "$SCRATCH/stubbin/readlink" <<STUB
#!/bin/bash
out="\$("$REAL_READLINK" "\$@")"; rc=\$?
[[ -n "\$out" ]] && printf '%s\n' "\$out"
for a in "\$@"; do
  if [[ "\$a" == "$H6/lane" && ! -e "$SCRATCH/flipped" ]]; then
    : > "$SCRATCH/flipped"
    ln -sfn "$H6/bad" "$H6/lane"
  fi
done
exit \$rc
STUB
chmod +x "$SCRATCH/stubbin/readlink"

PATH="$SCRATCH/stubbin:$PATH" HOME="$H6" CLAUDE_CONFIG_DIR="$H6/lane" \
  bash "$PUBLISHER" health-export >/dev/null 2>&1

if [[ ! -e "$SCRATCH/flipped" ]]; then
  # the stub never fired, so the retarget never happened and the check below would pass
  # having exercised nothing -- the vacuity shape, reported as a probe error
  bad "[9] PROBE ERROR: the readlink stub never fired, so no retarget was injected" \
      "the assertion below would hold having tested nothing"
else
  stamp="$(sym_field "$H6" config_dir)"; verdict="$(sym_field "$H6" plugin_keys)"
  case "${stamp##*/}/$verdict" in
    good/ok|bad/MISSING)
      ok "[9] stamp and verdict survive a retarget between them (${stamp##*/}/$verdict)" ;;
    ABSENT/*|*/ABSENT)
      bad "[9] PROBE ERROR: the publisher wrote no object under the stub" ;;
    *)
      bad "[9] INCOHERENT: the stamp names a different dir than the verdict was computed for" \
          "stamp:   ${stamp##*/}" "verdict: $verdict" ;;
  esac
fi

# ===================================================================================
# [10] THE CONSUMER'S OWN SPLIT READ. Round 2 refuted this close here: the hook opened
#      sym-health.json THREE times -- stamp, then freshness, then verdict -- so a file
#      replaced between them let the stamp be checked against one object and the verdict
#      taken from another. The publisher writing atomically does not help: atomicity makes
#      each read see SOME whole file, never the same one.
#
#      Deterministic, like [9]. A PATH-local `jq` stub swaps the file exactly once, right
#      after the first read of that path returns. The fixture is built so the two objects
#      disagree: the ORIGINAL is this lane's own, fresh, and says MISSING; the REPLACEMENT
#      is fresh, foreign-stamped, and says ok. A consumer deciding from one read reports
#      MISSING; one that re-reads reports the foreign ok.
# ===================================================================================
H7="$(make_home)"
L7="$(make_lane "$H7" split healthy)"
mkdir -p "$SCRATCH/jqbin"
now7="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"plugin_keys":"MISSING","config_dir":"%s","checked_at":"%s"}' "$(readlink -f "$L7")" "$now7" \
  > "$H7/.cache/dhx/sym-health.json"
printf '{"plugin_keys":"ok","config_dir":"/nonexistent/other-lane","checked_at":"%s"}' "$now7" \
  > "$SCRATCH/swapin.json"

REAL_JQ="$(command -v jq)"
cat > "$SCRATCH/jqbin/jq" <<STUB
#!/bin/bash
"$REAL_JQ" "\$@"; rc=\$?
for a in "\$@"; do
  if [[ "\$a" == "$H7/.cache/dhx/sym-health.json" && ! -e "$SCRATCH/swapped" ]]; then
    : > "$SCRATCH/swapped"
    cp "$SCRATCH/swapin.json" "$SCRATCH/swapin.tmp"
    mv -f "$SCRATCH/swapin.tmp" "$H7/.cache/dhx/sym-health.json"
  fi
done
exit \$rc
STUB
chmod +x "$SCRATCH/jqbin/jq"

PATH="$SCRATCH/jqbin:$PATH" HOME="$H7" CLAUDE_CONFIG_DIR="$L7" \
  bash "$HOOK" <<<'{"session_id":"probe-split"}' >/dev/null 2>&1

if [[ ! -e "$SCRATCH/swapped" ]]; then
  bad "[10] PROBE ERROR: the jq stub never fired, so no swap was injected" \
      "the assertion below would hold having tested nothing"
else
  chk "[10] the hook decides from ONE read (a file swapped mid-read is not served)" \
      "$(hook_pk "$H7" "$L7")" "MISSING"
fi

# ===================================================================================
# [11] THE RENDER MUST NOT INHERIT A SHARED VERDICT. Round 2's second counterexample:
#      plugin_keys LIVED in health.json, which every lane's SessionStart overwrites, so a
#      healthy lane's run cleared a broken lane's rendered warning -- with no
#      sym-health.json present at all. The wrapper now computes this lane's verdict from
#      its own settings.json instead of inheriting that shared slot.
# ===================================================================================
H8="$(make_home)"
B8="$(make_lane "$H8" broken broken)"
rm -f "$H8/.cache/dhx/sym-health.json"
# a health.json written by some OTHER, healthy lane
cat > "$H8/.cache/dhx/health.json" <<'HJ'
{"worktree_patches":"patched","read_guard":"patched","claude_md":"ok","settings_chain":"ok","plugin_keys":"ok","hooks_wiring":"ok","checked":0}
HJ
if ! out="$(render_live "$H8" "$B8")"; then
  bad "[11] PROBE ERROR: the statusline wrapper could not be driven" \
      "wrapper: $WRAPPER | stderr: $(head -2 "$SCRATCH/render.err" | tr '\n' ' ')"
elif grep -q 'plugin-keys:MISSING' <<<"$out"; then
  ok "[11] a healthy lane's shared cache does not clear this lane's real fault"
else
  bad "[11] the render INHERITED another lane's verdict from health.json" \
      "line: $(tr -d '\033' <<<"$out" | tail -c 220)"
fi

# ===================================================================================
# [12] THE STAMP GATE AND THE FALLBACK MUST MEAN THE SAME LANE. Round 3 refuted the close
#      here: the hook snapshots $CLAUDE_CONFIG_DIR once at the head (that snapshot decides
#      the lane id and the sidecar it writes), compares the published stamp against it --
#      and then, on refusal, RE-RESOLVED $CLAUDE_CONFIG_DIR/settings.json. One invocation
#      could therefore classify itself as lane `good`, write good's sidecar, and take its
#      supposedly lane-local verdict from `bad`.
#
#      Reading the env var twice is harmless; RESOLVING it twice is not, because each
#      realpath walks a symlink chain that can be retargeted in between. Deterministic, via
#      the same stub technique as [9]: retarget immediately after the head resolution.
# ===================================================================================
H9="$(make_home)"
# good/ and bad/ live UNDER .ccs/instances/ (they were $H9/good and $H9/bad until
# 2026-09-16). Not cosmetic: plugin_keys now lands in the per-lane sidecar, which is
# written only for a config dir the allowlist at the head of dhx-health-check.sh admits
# -- $HOME/.claude or a single-segment child of $HOME/.ccs/instances. Resolving to
# $H9/good satisfied neither, so the hook wrote NO sidecar and this case had no reading
# to assert against. Relocating them keeps the case testing what it was written to test
# (which resolution the fallback uses) instead of incidentally re-testing the allowlist,
# which [5a]/[5b] of probe-health-lane-scoping.sh already own.
mkdir -p "$H9/.ccs/instances/good" "$H9/.ccs/instances/bad" "$SCRATCH/stubbin12"
printf '%s' "$GOOD_SETTINGS" > "$H9/.ccs/instances/good/settings.json"
printf '{}'                  > "$H9/.ccs/instances/bad/settings.json"
ln -sfn "$H9/.ccs/instances/good" "$H9/.ccs/instances/swing"
now9="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# a FOREIGN stamp forces the refusal branch, which is where the second resolution lived
printf '{"plugin_keys":"ok","config_dir":"/nonexistent/other-lane","checked_at":"%s"}' "$now9" \
  > "$H9/.cache/dhx/sym-health.json"

REAL_READLINK12="$(command -v readlink)"
cat > "$SCRATCH/stubbin12/readlink" <<STUB
#!/bin/bash
out="\$("$REAL_READLINK12" "\$@")"; rc=\$?
[[ -n "\$out" ]] && printf '%s\n' "\$out"
for a in "\$@"; do
  if [[ "\$a" == "$H9/.ccs/instances/swing" && ! -e "$SCRATCH/swung" ]]; then
    : > "$SCRATCH/swung"
    ln -sfn "$H9/.ccs/instances/bad" "$H9/.ccs/instances/swing"
  fi
done
exit \$rc
STUB
chmod +x "$SCRATCH/stubbin12/readlink"

PATH="$SCRATCH/stubbin12:$PATH" HOME="$H9" CLAUDE_CONFIG_DIR="$H9/.ccs/instances/swing" \
  bash "$HOOK" <<<'{"session_id":"probe-swing"}' >/dev/null 2>&1

if [[ ! -e "$SCRATCH/swung" ]]; then
  bad "[12] PROBE ERROR: the readlink stub never fired, so no retarget was injected" \
      "the assertion below would hold having tested nothing"
else
  # the run classified itself against `good` (the head resolution), so its fallback verdict
  # must be good's `ok` -- a MISSING here means the fallback resolved through `bad`.
  # Since 2026-09-16 this reads the sidecar keyed to good, so it now asserts something
  # strictly stronger than it did against the shared file: not merely that the VERDICT is
  # good's, but that the run filed it under good's identity. An ABSENT would mean the run
  # classified itself as neither.
  chk "[12] the fallback resolves the lane the run classified itself as" \
      "$(hook_pk "$H9" "$H9/.ccs/instances/good")" "ok"
fi

# ===================================================================================
# [14] CROSS-LANE ISOLATION OF THE VALUE AT REST (2026-09-16). Cases [6] and [11] cover
#      the two routes that were closed first -- the PUBLISHER (a foreign sym-health.json
#      must not be believed) and the RENDER (the statusline computes this lane's verdict
#      rather than inheriting a shared slot). This case covers the third: the value the
#      hook STORES. Until plugin_keys moved to the per-lane sidecar it went into the
#      $HOME-anchored health.json, so whichever lane started a session last owned it --
#      and the cross-repo reader (sym-gsd-update-report.md step 12.5 check 2) jq's that
#      value and hard-exits on it. A foreign MISSING aborted a healthy gsd-update; a
#      foreign `ok` let one proceed past a real plugin-key fault, which is the false-clean
#      direction and the one that costs something.
#
#      Reproduced against the pre-fix hook before the fix landed: lane broken wrote
#      MISSING, lane healthy's SessionStart replaced it with ok, and a check running in
#      lane broken then read ok. That reproduction is this assertion.
#
#      LIVENESS: [14b] is an equality assertion and hook_pk() answers ABSENT for a lane
#      with no sidecar, so ABSENT == ABSENT would pass having observed nothing. [14a]
#      anchors it on a value only a live producer can emit, and gates the rest.
# ===================================================================================
H10="$(make_home)"
B10="$(make_lane "$H10" broken broken)"
G10="$(make_lane "$H10" healthy healthy)"
rm -f "$H10/.cache/dhx/sym-health.json"       # no publisher: the lane-local check decides

run_hook "$H10" "$B10"
PK10_BEFORE="$(hook_pk "$H10" "$B10")"
if [[ "$PK10_BEFORE" != "MISSING" ]]; then
  bad "[14a] PROBE ERROR: the broken lane recorded no usable verdict" \
      "got: $PK10_BEFORE" \
      "want: MISSING -- ABSENT here means the hook could not be driven, not that it passed"
else
  ok "[14a] the broken lane records its own MISSING"
  run_hook "$H10" "$G10"                      # the OTHER lane starts a session
  chk "[14b] a healthy lane's SessionStart does NOT overwrite it" \
      "$(hook_pk "$H10" "$B10")" "MISSING"
  chk "[14c] and the healthy lane reads its own ok, not the broken lane's verdict" \
      "$(hook_pk "$H10" "$G10")" "ok"
fi

# ===================================================================================
# [13] THE CLASS, LINTED. Three review rounds found four members of one class -- a decision
#      made from more than one RESOLUTION of the same path -- and two of them were found
#      AFTER the class was declared swept by hand. A claim that keeps being wrong is not a
#      claim to repeat; this greps for the shape so the next one reds instead of shipping.
#
#      The rule: a consumer resolves this lane's config dir ONCE per decision and passes the
#      result down. Re-reading the variable is fine; re-resolving the path is not.
# ===================================================================================
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` yields "0\n0" and poisons the
# arithmetic below. `|| true` keeps the single printed count.
count() { grep -cE "$2" "$1" 2>/dev/null || true; }

# the hook's ONE authoritative resolution goes through $config_dir, so no `readlink -f`
# operand should name the env var at all
chk "[13a] no hook readlink resolves \$CLAUDE_CONFIG_DIR directly" \
    "$(count "$HOOK" '^[^#]*readlink -f[^#]*CLAUDE_CONFIG_DIR')" "0"
chk "[13b] the hook binds \$CLAUDE_CONFIG_DIR to config_dir exactly once" \
    "$(count "$HOOK" '^[^#]*config_dir="\$\{CLAUDE_CONFIG_DIR')" "1"

# NEWLINE-SQUASHED, deliberately. `grep -E` is line-based and the call this lint exists to
# catch was written across two lines, so the first draft of [13c] passed its own negative
# control -- it could not see the very shape it names. Squash first, then match.
squashed="$SCRATCH/wrapper.squashed"
tr '\n' ' ' < "$WRAPPER" > "$squashed"
fresh_reads=0
for pat in 'pluginKeysForThisLane\( *process\.env' 'readLaneHealth\( *process\.env' 'symHealthIsForThisLane\([^,]*, *process\.env'; do
  n="$(grep -oE "$pat" "$squashed" 2>/dev/null | wc -l)"
  fresh_reads=$(( fresh_reads + ${n:-0} ))
done
chk "[13c] no wrapper decision site takes a fresh env read instead of the pass's resolution" \
    "$fresh_reads" "0"

echo
echo "PASS: $pass  FAIL: $fail"
exit $(( fail > 0 ? 1 : 0 ))
