#!/usr/bin/env bash
# probe-skill-desc-audit.sh — regression probe for the skill-description delta auditor
# (dhx/dhx-skill-desc-audit.cjs + dhx/dhx-skill-desc-audit.sh).
# SAFE_FOR_LIVE: yes
#
# Invariants exercised (SPEC §4.4/§4.5/§4.6 — cross-repo
# docs/prompts/2026-07-17-skill-description-token-contract-SPEC.md; backs the
# docs/decisions.md 2026-07-17 skill-desc-delta-auditor row):
#   clean corpus → EMPTY stdout · new violation → warn block (source-aware remediation)
#   same digest → silent · digest change → re-warn · ack → silent · ack+change → re-warn
#   snooze active → silent · snooze expired → re-warn · perma → silent
#   7d TTL elapse (unacked) → re-warn · collector missing → fail-open + counter
#   3 consecutive failures → one-line surfacing · broken state file → no brick
#   exempt content change → ONE-TIME re-review notice · success resets failure counter
#   shadowed subjects never counted · chain script suppression env
#
# All paths env-seamed to a mktemp sandbox (DHX_SKILL_DESC_{COLLECTOR,STATE,EXEMPTIONS,NOW});
# never reads or writes live ~/.claude/dhx-tools or the live registry.
#
# Run: bash tests/probes/probe-skill-desc-audit.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/dhx/dhx-skill-desc-audit.cjs"
CHAIN="$REPO_ROOT/dhx/dhx-skill-desc-audit.sh"

T=$(mktemp -d /tmp/probe-skill-desc-audit.XXXXXX)
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()   { echo "OK   $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
check() { # check <desc> <expected-substring-or-EMPTY> <actual-output> [<rc> <expected-rc>]
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "EMPTY" ]; then
    [ -z "$got" ] && ok "$desc" || bad "$desc — expected empty stdout, got: $(printf '%s' "$got" | head -2)"
  else
    case "$got" in *"$want"*) ok "$desc" ;; *) bad "$desc — missing '$want' in: $(printf '%s' "$got" | head -3)" ;; esac
  fi
}

# ── fixture plumbing ───────────────────────────────────────────────────────────────
cat > "$T/stub-collector.cjs" <<'EOF'
// stub collector: echoes the fixture file named by STUB_OUT (args ignored).
process.stdout.write(require('fs').readFileSync(process.env.STUB_OUT, 'utf8'));
EOF

fixture() { # fixture <file> <subjects-json-array> [<extra-top-level-json>]
  local extra="${3:-}"
  printf '{"schema_version":1,"cc_version_observed":"2.1.212","verified_cc_version":"2.1.212","discovery_unverified":false%s,"subjects":%s,"totals":{}}\n' \
    "$extra" "$2" > "$1"
}

export DHX_SKILL_DESC_COLLECTOR="$T/stub-collector.cjs"
export DHX_SKILL_DESC_STATE="$T/state/audit.json"
export DHX_SKILL_DESC_EXEMPTIONS="$T/exempt.json"
export STUB_OUT="$T/fixture.json"
echo '{"exemptions":[]}' > "$T/exempt.json"

NOW0="2026-07-17T00:00:00Z"
export DHX_SKILL_DESC_NOW="$NOW0"

run() { node "$WORKER" "$@" 2>"$T/stderr"; }

SUBJ_CLEAN='[{"slug":"clean","source":"personal","path":"/y","chars":100,"cap":250,"exempt_via":null,"over":false,"desc_sha256":"c1","shadowed":false}]'
SUBJ_DHX_OVER='[{"slug":"newthing","source":"plugin:dhx@dhx-local","path":"/x","chars":312,"cap":250,"exempt_via":null,"over":true,"desc_sha256":"d1","shadowed":false}]'

# ── 1. clean corpus → empty stdout, rc 0 ───────────────────────────────────────────
fixture "$STUB_OUT" "$SUBJ_CLEAN"
OUT=$(run audit); RC=$?
check "clean corpus → empty stdout" EMPTY "$OUT"
[ "$RC" -eq 0 ] && ok "clean corpus → rc 0" || bad "clean corpus rc=$RC"

# ── 2. new violation → warn block, dhx remediation ─────────────────────────────────
fixture "$STUB_OUT" "$SUBJ_DHX_OVER"
OUT=$(run audit)
check "new violation → header" "1 new/changed violation" "$OUT"
check "new violation → chars/cap row" "dhx:newthing 312/250" "$OUT"
check "new violation → dhx source-aware remediation" "/dhx:skills modify newthing" "$OUT"

# ── 3. same digest, same session-cadence → silent ──────────────────────────────────
OUT=$(run audit)
check "same digest re-run → silent (warn-once-per-digest)" EMPTY "$OUT"

# ── 4. digest change → re-warn ─────────────────────────────────────────────────────
fixture "$STUB_OUT" '[{"slug":"newthing","source":"plugin:dhx@dhx-local","path":"/x","chars":320,"cap":250,"exempt_via":null,"over":true,"desc_sha256":"d2","shadowed":false}]'
OUT=$(run audit)
check "digest change → re-warn" "dhx:newthing 320/250" "$OUT"

# ── 5. ack → silent ────────────────────────────────────────────────────────────────
OUT=$(run ack dhx:newthing)
check "ack confirmation" "acked: dhx:newthing" "$OUT"
OUT=$(run audit)
check "acked digest → silent" EMPTY "$OUT"

# ── 6. ack + content change → re-warn (ack is digest-bound) ────────────────────────
fixture "$STUB_OUT" '[{"slug":"newthing","source":"plugin:dhx@dhx-local","path":"/x","chars":330,"cap":250,"exempt_via":null,"over":true,"desc_sha256":"d3","shadowed":false}]'
OUT=$(run audit)
check "ack + content change → re-warn" "dhx:newthing 330/250" "$OUT"

# ── 7. snooze semantics (SPEC §4.5 boolean verbatim): active mutes even past the TTL;
#       expiry past the TTL re-warns; perma mutes forever ───────────────────────────
OUT=$(run snooze dhx:newthing 30d)
check "snooze confirmation" "snoozed until" "$OUT"
OUT=$(run audit)
check "snooze active → silent" EMPTY "$OUT"
export DHX_SKILL_DESC_NOW="2026-07-25T00:00:00Z"   # +8d: TTL elapsed but still snoozed
OUT=$(run audit)
check "snooze overrides TTL re-warn while active" EMPTY "$OUT"
export DHX_SKILL_DESC_NOW="2026-08-17T00:00:00Z"   # +31d: snooze expired + TTL elapsed
OUT=$(run audit)
check "snooze expired (past TTL) → re-warn" "dhx:newthing 330/250" "$OUT"
export DHX_SKILL_DESC_NOW="2026-08-17T01:00:00Z"
OUT=$(run snooze dhx:newthing perma)
OUT=$(run audit)
check "perma snooze → silent" EMPTY "$OUT"
export DHX_SKILL_DESC_NOW="2027-07-17T00:00:00Z"
OUT=$(run audit)
check "perma snooze → silent a year on" EMPTY "$OUT"

# ── 8. 7d TTL elapse (unacked, un-snoozed, same digest) → re-warn ──────────────────
rm -f "$DHX_SKILL_DESC_STATE"
export DHX_SKILL_DESC_NOW="$NOW0"
fixture "$STUB_OUT" "$SUBJ_DHX_OVER"
OUT=$(run audit)   # first warn at NOW0
export DHX_SKILL_DESC_NOW="2026-07-20T00:00:00Z"   # +3d: inside TTL → silent
OUT=$(run audit)
check "same digest +3d (inside 7d TTL) → silent" EMPTY "$OUT"
export DHX_SKILL_DESC_NOW="2026-07-25T00:00:01Z"   # +8d: TTL elapsed → re-warn
OUT=$(run audit)
check "same digest +8d (TTL elapsed) → re-warn" "dhx:newthing 312/250" "$OUT"

# ── 9. non-dhx remediation is source-aware ─────────────────────────────────────────
fixture "$STUB_OUT" '[
  {"slug":"gsd-foo","source":"personal","path":"/g","chars":412,"cap":250,"exempt_via":null,"over":true,"desc_sha256":"g1","shadowed":false},
  {"slug":"lcp","source":"plugin:chrome-devtools-mcp@chrome-devtools-plugins","path":"/p","chars":439,"cap":250,"exempt_via":null,"over":true,"desc_sha256":"p1","shadowed":false}]'
rm -f "$DHX_SKILL_DESC_STATE"
OUT=$(run audit)
check "personal remediation → gsd-aware" "file upstream or /gsd-surface" "$OUT"
check "plugin remediation → exempt-or-disable" "exempt: ~/repos/hooks/config/skill-desc-exemptions.json" "$OUT"

# ── 10. shadowed subjects never counted ────────────────────────────────────────────
fixture "$STUB_OUT" '[{"slug":"dup","source":"plugin:llm-wiki@llm-wiki","path":"/s","chars":900,"cap":250,"exempt_via":null,"over":true,"desc_sha256":"s1","shadowed":true}]'
rm -f "$DHX_SKILL_DESC_STATE"
OUT=$(run audit)
check "shadowed over-budget subject → silent (never double-count)" EMPTY "$OUT"

# ── 11. collector missing → fail-open + counter; ≥3 → one-line surfacing ───────────
rm -f "$DHX_SKILL_DESC_STATE"
export DHX_SKILL_DESC_COLLECTOR="$T/absent.cjs"
OUT=$(run audit); RC=$?
[ "$RC" -eq 0 ] && ok "collector missing → rc 0 (fail-open)" || bad "collector missing rc=$RC"
check "collector missing → silent (failure #1)" EMPTY "$OUT"
CF=$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.DHX_SKILL_DESC_STATE,"utf8")).consecutive_failures))')
[ "$CF" = "1" ] && ok "consecutive_failures incremented to 1" || bad "consecutive_failures=$CF, expected 1"
OUT=$(run audit)
check "failure #2 → still silent" EMPTY "$OUT"
OUT=$(run audit)
check "failure #3 → one-line surfacing" "skill-desc auditor failing (3 sessions)" "$OUT"

# ── 12. success resets the failure counter ─────────────────────────────────────────
export DHX_SKILL_DESC_COLLECTOR="$T/stub-collector.cjs"
fixture "$STUB_OUT" "$SUBJ_CLEAN"
OUT=$(run audit)
CF=$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.DHX_SKILL_DESC_STATE,"utf8")).consecutive_failures))')
[ "$CF" = "0" ] && ok "success resets consecutive_failures to 0" || bad "consecutive_failures=$CF after success, expected 0"

# ── 13. unknown schema major → fail-open ───────────────────────────────────────────
fixture "$STUB_OUT" "$SUBJ_DHX_OVER"
node -e 'const f=process.env.STUB_OUT,j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.schema_version=2;require("fs").writeFileSync(f,JSON.stringify(j))'
OUT=$(run audit); RC=$?
[ "$RC" -eq 0 ] && check "unknown schema major → fail-open, silent" EMPTY "$OUT" || bad "schema-major rc=$RC"

# ── 14. broken state file → no brick (negative control) ────────────────────────────
printf 'NOT JSON {{{' > "$DHX_SKILL_DESC_STATE"
fixture "$STUB_OUT" "$SUBJ_DHX_OVER"
OUT=$(run audit); RC=$?
[ "$RC" -eq 0 ] && ok "broken state file → rc 0 (no brick)" || bad "broken state rc=$RC"
check "broken state file → auditor still functions (warns)" "dhx:newthing 312/250" "$OUT"

# ── 15. exempt content change → one-time re-review notice; registry never written ──
echo '{"exemptions":[{"slug":"llm-wiki","source":"llm-wiki","max_chars":1000,"last_reviewed_sha256":"OLDHASH","approved":"2026-07-17","reason":"probe fixture"}]}' > "$T/exempt.json"
REG_BEFORE=$(cat "$T/exempt.json")
fixture "$STUB_OUT" '[{"slug":"llm-wiki","source":"plugin:llm-wiki@llm-wiki","path":"/w","chars":980,"cap":1000,"exempt_via":"registry","over":false,"desc_sha256":"NEWHASH","shadowed":false}]'
rm -f "$DHX_SKILL_DESC_STATE"
OUT=$(run audit)
check "exempt content change → re-review notice" "exempted content changed — re-review" "$OUT"
OUT=$(run audit)
check "re-review notice is one-time (same digest → silent)" EMPTY "$OUT"
[ "$(cat "$T/exempt.json")" = "$REG_BEFORE" ] && ok "registry never written by auditor" || bad "registry mutated"

# ── 16. chain script: suppression env + missing-worker no-op ───────────────────────
OUT=$(echo '{"session_id":"probe","source":"startup"}' | DHX_SKIP_SKILL_DESC_AUDIT=1 bash "$CHAIN"); RC=$?
[ "$RC" -eq 0 ] && check "chain script suppression env → silent rc 0" EMPTY "$OUT" || bad "suppression rc=$RC"
OUT=$(echo '{}' | DHX_SKILL_DESC_WORKER="$T/no-such-worker.cjs" bash "$CHAIN"); RC=$?
[ "$RC" -eq 0 ] && check "chain script missing worker → silent no-op" EMPTY "$OUT" || bad "missing-worker rc=$RC"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
