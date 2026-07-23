#!/usr/bin/env bash
# probe-vet-closures.sh — regression probe for the pending `/dhx:vet` closure surfacer.
#
# Invariants exercised:
#   1. THE ONE THING THAT MUST NOT GO WRONG — the surfaced action line is a RE-VET
#      (`› /dhx:vet <repo_root>/<prompt_relpath>`) and NEVER a `git mv` / `git -C` or any
#      other close command. Asserted POSITIVELY (real output is clean) and NEGATIVELY
#      (a deliberately sabotaged producer that DOES emit `git mv` makes the detector go
#      RED — proving the detector is not vacuous).
#   2. Fail silent, always — absent / empty / malformed ledger, absent jq-parseable rows,
#      and a held lock all exit 0 with EMPTY stdout.
#   3. Self-heal on read — rows whose prompt is gone, already under `done/`, or whose
#      `repo_root` no longer exists are dropped, never surfaced.
#   4. `state: "accepted-blocked"` renders DIFFERENTLY from an unanswered `offered` row.
#   5. Exact house output format (⚠ = U+26A0 U+FE0F, 4-space rows, 6-space `›` U+203A
#      action lines, ` · ` U+00B7 separators, exactly one trailing newline).
#   6. Shim contract — suppression var, absent-worker no-op, stdin drained.
#
# Backs: docs/decisions.md 2026-07-22 vet-closure SessionStart producer row.
# Run:   bash tests/probes/probe-vet-closures.sh
#
# SAFE_FOR_LIVE: yes
# RUNTIME: ~2s
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORKER="$REPO_ROOT/dhx/dhx-vet-closures-render.sh"
SHIM="$REPO_ROOT/dhx/dhx-vet-closures.sh"

PASS=0; FAIL=0
ok(){ printf 'OK   %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf 'FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
assert(){ if [ "$1" = "1" ]; then ok "$2"; else bad "$2"; fi; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ── Fixture scaffold: a fake repo with a live prompt + a retired one ──────────────
FAKEREPO="$TMP/skills"
mkdir -p "$FAKEREPO/docs/prompts/done"
printf '/dhx:skills modify vet\n' > "$FAKEREPO/docs/prompts/live-prompt.md"
printf '/dhx:skills modify vet\n' > "$FAKEREPO/docs/prompts/done/retired-prompt.md"

LEDGER="$TMP/vet-closures.jsonl"

iso(){ date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

row(){ # $1=repo_root $2=slug $3=prompt_relpath $4=verdict $5=state $6=last_offered
  printf '{"schema_version":1,"repo_root":"%s","corpus_dir":"docs/prompts","slug":"%s","prompt_relpath":"%s","verdict":"%s","state":"%s","last_offered":"%s","offer_count":1}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

run_worker(){ DHX_VET_CLOSURES_LEDGER="$LEDGER" bash "$WORKER" 2>/dev/null; }

# The detector under negative test. Returns 0 (clean) / 1 (forbidden command present).
detect_close_command(){
  local text="$1"
  if [[ "$text" == *"git mv"* ]] || [[ "$text" == *"git -C"* ]]; then return 1; fi
  return 0
}

# ── Fail-silent paths ────────────────────────────────────────────────────────────
rm -f "$LEDGER"
out=$(run_worker); rc=$?
assert "$([ -z "$out" ] && [ "$rc" = 0 ] && echo 1)" "absent ledger → empty stdout, exit 0"

: > "$LEDGER"
out=$(run_worker); rc=$?
assert "$([ -z "$out" ] && [ "$rc" = 0 ] && echo 1)" "empty ledger → empty stdout, exit 0"

printf 'not json at all\n{"broken":\n\n' > "$LEDGER"
out=$(run_worker); rc=$?
assert "$([ -z "$out" ] && [ "$rc" = 0 ] && echo 1)" "malformed ledger → empty stdout, exit 0 (fail silent)"

# ── Self-heal on read ────────────────────────────────────────────────────────────
row "$FAKEREPO" gone-prompt "docs/prompts/gone-prompt.md" SUPERSEDED offered "$(iso '2 hours ago')" > "$LEDGER"
out=$(run_worker)
assert "$([ -z "$out" ] && echo 1)" "self-heal: prompt file missing → row dropped"

row "$FAKEREPO" retired-prompt "docs/prompts/done/retired-prompt.md" ALREADY-DONE offered "$(iso '2 hours ago')" > "$LEDGER"
out=$(run_worker)
assert "$([ -z "$out" ] && echo 1)" "self-heal: prompt already under done/ → row dropped"

row "$TMP/no-such-repo" ghost "docs/prompts/ghost.md" SUPERSEDED offered "$(iso '2 hours ago')" > "$LEDGER"
out=$(run_worker)
assert "$([ -z "$out" ] && echo 1)" "self-heal: repo_root gone → row dropped"

# ── Happy path: one live row ─────────────────────────────────────────────────────
row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" SUPERSEDED offered "$(iso '3 days ago')" > "$LEDGER"
out=$(run_worker); rc=$?
assert "$([ "$rc" = 0 ] && [ -n "$out" ] && echo 1)" "live row → block rendered, exit 0"

hdr=$(printf '%s' "$out" | head -1)
assert "$([ "$hdr" = "⚠ Pending vet closures (1):" ] && echo 1)" "header exact: '⚠ Pending vet closures (1):'"

# Glyph PARITY with the sibling watch block, asserted byte-for-byte against the live
# producer rather than a hardcoded literal. The blocks concatenate in one SessionStart
# surface, so the only thing that matters is that they render identically — and a
# hardcoded expectation silently rots if the house glyph ever changes.
# NOTE: the house glyph is bare U+26A0 (e2 9a a0) + SPACE — there is NO U+FE0F
# variation selector in dhx-watch-digest.sh. The originating prompt claimed
# "U+26A0 + U+FE0F"; that claim is refuted by the live source this parity check reads.
WATCH_SRC="$REPO_ROOT/dhx/dhx-watch-digest.sh"
house_hex=$(grep -m1 -ao '⚠ ' "$WATCH_SRC" | head -1 | head -c 4 | od -An -tx1 | tr -d ' \n')
hdr_hex=$(printf '%s' "$hdr" | head -c 4 | od -An -tx1 | tr -d ' \n')
assert "$([ -n "$house_hex" ] && [ "$hdr_hex" = "$house_hex" ] && echo 1)" \
  "header glyph is byte-identical to dhx-watch-digest.sh's (house parity: $house_hex)"
assert "$([ "$hdr_hex" = "e29aa020" ] && echo 1)" "header glyph is U+26A0 + SPACE (no U+FE0F)"

RE_ROW='^ {4}[^ ]'
RE_ACT='^ {6}›'
rowline=$(printf '%s' "$out" | sed -n '2p')
assert "$([[ "$rowline" =~ $RE_ROW ]] && echo 1)" "row line has exactly 4 leading spaces"
assert "$([[ "$rowline" == *" · "* ]] && echo 1)" "row line uses ' · ' (U+00B7) separator"
assert "$([[ "$rowline" == *"skills"* ]] && [[ "$rowline" == *"live-prompt"* ]] && [[ "$rowline" == *"SUPERSEDED"* ]] && echo 1)" \
  "row line carries repo · slug · verdict"
assert "$([[ "$rowline" == *"offered 3d ago"* ]] && echo 1)" "freshness renders days for a 3-day-old offer"

actline=$(printf '%s' "$out" | sed -n '3p')
assert "$([[ "$actline" =~ $RE_ACT ]] && echo 1)" "action line has exactly 6 leading spaces + › (U+203A)"
assert "$([ "$actline" = "      › /dhx:vet $FAKEREPO/docs/prompts/live-prompt.md" ] && echo 1)" \
  "action line is a re-vet: '› /dhx:vet <repo_root>/<prompt_relpath>'"

# `$(...)` strips ALL trailing newlines, so the raw stream must be captured behind a
# sentinel — testing "${out: -1}" directly can never observe a newline and would be a
# permanently-vacuous assertion.
raw=$(run_worker; printf 'X'); raw=${raw%X}
assert "$([ "${raw: -1}" = $'\n' ] && [ "${raw: -2:1}" != $'\n' ] && echo 1)" "exactly one trailing newline"

# ── THE negative-tested property ─────────────────────────────────────────────────
if detect_close_command "$out"; then ok "output contains NO 'git mv' / 'git -C' (positive arm)"
else bad "output contains NO 'git mv' / 'git -C' (positive arm)"; fi

# Negative CONTROL: sabotage the producer so it emits a close command, and prove the
# detector goes RED. Without this arm, a detector that always returns 0 would "pass".
SABOTAGED="$TMP/sabotaged-render.sh"
python3 - "$WORKER" "$SABOTAGED" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
body = open(src).read()
needle = '"      › /dhx:vet $full"'
assert needle in body, "sabotage anchor not found — probe needs updating to match the worker"
open(dst, 'w').write(body.replace(needle, '"      › git mv $full done/"'))
PY
sab_rc=$?
assert "$([ "$sab_rc" = 0 ] && echo 1)" "sabotage anchor found in worker (control is wired to real code)"
sab_out=$(DHX_VET_CLOSURES_LEDGER="$LEDGER" bash "$SABOTAGED" 2>/dev/null)
assert "$([ -n "$sab_out" ] && echo 1)" "sabotaged producer still emits a block (control is live)"
if detect_close_command "$sab_out"; then bad "NEGATIVE CONTROL: detector must go RED on a 'git mv' producer"
else ok "NEGATIVE CONTROL: detector goes RED on a 'git mv' producer"; fi

# ── accepted-blocked renders differently ─────────────────────────────────────────
row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" SUPERSEDED accepted-blocked "$(iso '2 hours ago')" > "$LEDGER"
ab_out=$(run_worker)
ab_row=$(printf '%s' "$ab_out" | sed -n '2p')
assert "$([[ "$ab_row" == *"close blocked by gate"* ]] && echo 1)" "accepted-blocked row renders 'close blocked by gate'"
assert "$([ "$ab_row" != "$rowline" ] && echo 1)" "accepted-blocked row differs from an 'offered' row"
ab_act=$(printf '%s' "$ab_out" | sed -n '3p')
assert "$([ "$ab_act" = "      › /dhx:vet $FAKEREPO/docs/prompts/live-prompt.md" ] && echo 1)" \
  "accepted-blocked STILL surfaces a re-vet, not a close"
if detect_close_command "$ab_out"; then ok "accepted-blocked output carries no close command"
else bad "accepted-blocked output carries no close command"; fi

# ── Freshness bands ──────────────────────────────────────────────────────────────
row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" ALREADY-DONE offered "$(iso '20 minutes ago')" > "$LEDGER"
assert "$([[ "$(run_worker)" == *"offered 20m ago"* ]] && echo 1)" "freshness renders minutes under an hour"
row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" ALREADY-DONE offered "$(iso '5 hours ago')" > "$LEDGER"
assert "$([[ "$(run_worker)" == *"offered 5h ago"* ]] && echo 1)" "freshness renders hours under a day"
row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" ALREADY-DONE offered "garbage-timestamp" > "$LEDGER"
gt=$(run_worker)
assert "$([ -n "$gt" ] && [[ "$gt" == *"offered"* ]] && echo 1)" "unparseable timestamp → row kept, suffix omitted"

# ── Mixed corpus: only survivors counted ─────────────────────────────────────────
{ row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" SUPERSEDED offered "$(iso '1 hour ago')"
  row "$FAKEREPO" gone "docs/prompts/gone.md" SUPERSEDED offered "$(iso '1 hour ago')"
  printf 'garbage\n'
  row "$FAKEREPO" retired-prompt "docs/prompts/done/retired-prompt.md" ALREADY-DONE offered "$(iso '1 hour ago')"
} > "$LEDGER"
mix=$(run_worker)
assert "$([ "$(printf '%s' "$mix" | head -1)" = "⚠ Pending vet closures (1):" ] && echo 1)" \
  "mixed corpus → header counts only disk-verified survivors"
assert "$([ "$(printf '%s\n' "$mix" | grep -c '›')" = "1" ] && echo 1)" "mixed corpus → exactly one action line"

# ── Lock contention → silent no-op ───────────────────────────────────────────────
row "$FAKEREPO" live-prompt "docs/prompts/live-prompt.md" SUPERSEDED offered "$(iso '1 hour ago')" > "$LEDGER"
# Handshake, NOT a fixed sleep: the holder touches a marker only AFTER it owns the lock,
# and we poll for that marker. A bare `sleep 0.3` races — under load the holder may not
# have acquired the lock yet, the worker then reads freely, and the arm false-REDs.
HELD_MARKER="$TMP/lock-held"
( exec 9>"$LEDGER.lock"; flock 9; : > "$HELD_MARKER"; sleep 5 ) &
HOLDER=$!
for _ in $(seq 1 100); do [ -f "$HELD_MARKER" ] && break; sleep 0.05; done
if [ -f "$HELD_MARKER" ]; then
  lk_out=$(run_worker); lk_rc=$?
  assert "$([ -z "$lk_out" ] && [ "$lk_rc" = 0 ] && echo 1)" "held lock → silent exit 0 (no unserialized read)"
else
  bad "held lock → silent exit 0 (holder never acquired the lock; arm inconclusive)"
fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ── Shim contract ────────────────────────────────────────────────────────────────
shim_out=$(printf '{"hook_event_name":"SessionStart","source":"startup"}' \
  | DHX_SKIP_VET_CLOSURES=1 DHX_VET_CLOSURES_WORKER="$WORKER" bash "$SHIM" 2>/dev/null); shim_rc=$?
assert "$([ -z "$shim_out" ] && [ "$shim_rc" = 0 ] && echo 1)" "shim: DHX_SKIP_VET_CLOSURES=1 → empty, exit 0"

shim_out=$(printf '{"hook_event_name":"SessionStart"}' \
  | DHX_VET_CLOSURES_WORKER="$TMP/does-not-exist.sh" bash "$SHIM" 2>/dev/null); shim_rc=$?
assert "$([ -z "$shim_out" ] && [ "$shim_rc" = 0 ] && echo 1)" "shim: absent worker → graceful no-op, exit 0"

shim_out=$(printf '{"hook_event_name":"SessionStart"}' \
  | DHX_VET_CLOSURES_LEDGER="$LEDGER" DHX_VET_CLOSURES_WORKER="$WORKER" bash "$SHIM" 2>/dev/null); shim_rc=$?
assert "$([ "$shim_rc" = 0 ] && [[ "$shim_out" == *"Pending vet closures"* ]] && echo 1)" \
  "shim: delegates to worker and passes the block through"

big=$(head -c 200000 /dev/zero | tr '\0' 'x')
shim_out=$(printf '{"hook_event_name":"SessionStart","pad":"%s"}' "$big" \
  | DHX_VET_CLOSURES_WORKER="$TMP/does-not-exist.sh" bash "$SHIM" 2>/dev/null); shim_rc=$?
assert "$([ "$shim_rc" = 0 ] && echo 1)" "shim: drains oversized stdin without SIGPIPE (HP-015)"

# ── Header-comment invariant is present in the source ────────────────────────────
assert "$(grep -q 'INVARIANT: the action line is a RE-VET' "$WORKER" && echo 1)" \
  "worker carries the // INVARIANT: re-vet-not-close comment"
assert "$(grep -qE '^# Patterns: HP-' "$WORKER" && echo 1)" "worker declares a # Patterns: header"
assert "$(grep -qE '^# Patterns: HP-' "$SHIM" && echo 1)" "shim declares a # Patterns: header"

# Source-level guard: neither hook may contain a close command in ANY emitted string.
# Comment lines legitimately NAME the forbidden commands (the INVARIANT block explains
# why they are banned), so scope this to executable lines only.
code_has_close(){ grep -vE '^[[:space:]]*#' "$1" | grep -qE 'git (mv|-C)'; }
assert "$(code_has_close "$WORKER" || echo 1)" "worker EXECUTABLE lines contain no 'git mv' / 'git -C'"
assert "$(code_has_close "$SHIM"   || echo 1)" "shim EXECUTABLE lines contain no 'git mv' / 'git -C'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
