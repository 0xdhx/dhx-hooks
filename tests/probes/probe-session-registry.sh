#!/usr/bin/env bash
# probe-session-registry.sh
#
# Regression probe for dhx/dhx-session-registry-start.sh (SessionStart) +
# dhx/dhx-session-registry-end.sh (SessionEnd) — the alive-session recovery
# registry producer.
#
# Invariants (per the ratified contract,
#   ~/repos/cross-repo/.planning/backlog/2026-06-08-alive-session-recovery-registry.md):
#   1. start hook appends a 9-field TSV row:
#        <iso_ts>\tstart\t<uuid>\t<instance>\t<slug>\t<repo>\t<tmux_session>\t<tmux_window>\t<pane_id>
#      with uuid<-session_id, instance<-CLAUDE_CONFIG_DIR .../instances/<x>/, slug<-cwd /->-,
#      repo<-cwd basename, tmux fields<-ONE combined display-message call.
#   2. uuid falls back to basename(transcript_path .jsonl) when session_id absent.
#   3. no $TMUX => tmux fields empty, row still 9 NF (not an error).
#   4. fail-open: unparseable JSON => exit 0, no row.
#   5. end hook appends a 3-field row: <iso_ts>\tend\t<uuid>.
#   6. concurrent appends are atomic (O_APPEND, rows < PIPE_BUF) — N parallel
#      starts => N intact 9-field rows, zero interleave/corruption.
#   7. registry path is literal $HOME/.claude/... (NOT $CLAUDE_CONFIG_DIR) so all
#      CCS instances share one file — asserted by driving the hook with a temp $HOME
#      and confirming the row lands under it.
#
# Backs: docs/decisions.md 2026-06-08 session-registry-producer row.
# Run:   bash tests/probes/probe-session-registry.sh
#
# SAFE_FOR_LIVE: yes
# Runner-safe: uses a temp $HOME (no live-registry mutation) and a PATH `tmux`
# stub (no live tmux server needed), so it is green under scripts/run-probes.sh
# regardless of whether the invoking context is inside tmux.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/dhx/dhx-session-registry-start.sh"
E="$ROOT/dhx/dhx-session-registry-end.sh"

pass=0; fail=0
chk(){ if eval "$2"; then echo "OK   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude" "$T/bin"
REG="$T/.claude/dhx-session-registry.tsv"

# tmux stub: deterministic combined-format output, no live server needed.
cat > "$T/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# Echo a fixed session\twindow\tpane triple for `display-message -p ... <fmt>`.
printf 'stubsess\t7\t%%99\n'
STUB
chmod +x "$T/bin/tmux"

CCDIR=/home/dhx/.ccs/instances/c   # drives instance<-c resolution

# --- 1. full start row (tmux present via stub) ---
: > "$REG"
echo '{"session_id":"uuid-AAA","transcript_path":"/x/uuid-AAA.jsonl","cwd":"/home/dhx/repos/hooks"}' \
  | env -i HOME="$T" CLAUDE_CONFIG_DIR="$CCDIR" TMUX=fake TMUX_PANE=%99 PATH="$T/bin:/usr/bin:/bin" bash "$S"
row=$(cat "$REG")
chk "start row has 9 fields"          '[ "$(awk -F"\t" "{print NF}" <<<"$row")" = 9 ]'
chk "field2 = start"                  '[ "$(cut -f2 <<<"$row")" = start ]'
chk "field3 = uuid (session_id)"      '[ "$(cut -f3 <<<"$row")" = uuid-AAA ]'
chk "field4 = instance c"             '[ "$(cut -f4 <<<"$row")" = c ]'
chk "field5 = slug (/->-)"            '[ "$(cut -f5 <<<"$row")" = -home-dhx-repos-hooks ]'
chk "field6 = repo basename"          '[ "$(cut -f6 <<<"$row")" = hooks ]'
chk "field7 = tmux session (stub)"    '[ "$(cut -f7 <<<"$row")" = stubsess ]'
chk "field8 = tmux window (stub)"     '[ "$(cut -f8 <<<"$row")" = 7 ]'
chk "field9 = pane id (stub)"         '[ "$(cut -f9 <<<"$row")" = "%99" ]'

# --- 2. uuid fallback to transcript basename ---
: > "$REG"
echo '{"transcript_path":"/p/uuid-BBB.jsonl","cwd":"/home/dhx/repos/hooks"}' \
  | env -i HOME="$T" CLAUDE_CONFIG_DIR="$CCDIR" PATH="/usr/bin:/bin" bash "$S"
chk "uuid <- basename(transcript)"    '[ "$(cut -f3 "$REG")" = uuid-BBB ]'

# --- 3. no $TMUX => empty tmux fields, still 9 NF ---
: > "$REG"
echo '{"session_id":"uuid-CCC","cwd":"/tmp/foo"}' \
  | env -i HOME="$T" CLAUDE_CONFIG_DIR="$CCDIR" PATH="/usr/bin:/bin" bash "$S"
row=$(cat "$REG")
chk "no-tmux row still 9 fields"      '[ "$(awk -F"\t" "{print NF}" <<<"$row")" = 9 ]'
chk "no-tmux tmux session empty"      '[ -z "$(cut -f7 <<<"$row")" ]'
chk "no-tmux pane empty"              '[ -z "$(cut -f9 <<<"$row")" ]'

# --- 4. instance falls back to raw when CLAUDE_CONFIG_DIR not an instance dir ---
: > "$REG"
echo '{"session_id":"uuid-DDD","cwd":"/tmp/foo"}' \
  | env -i HOME="$T" CLAUDE_CONFIG_DIR="/home/dhx/.claude" PATH="/usr/bin:/bin" bash "$S"
chk "instance = raw (non-CCS dir)"    '[ "$(cut -f4 "$REG")" = raw ]'

# --- 5. fail-open: bad JSON => exit 0, no row ---
: > "$REG"
echo 'not-json{' | env -i HOME="$T" CLAUDE_CONFIG_DIR="$CCDIR" PATH="/usr/bin:/bin" bash "$S"; rc=$?
chk "start exit 0 on bad JSON"        '[ "$rc" = 0 ]'
chk "start writes no row on bad JSON" '[ ! -s "$REG" ]'

# --- 6. end row = 3 fields ---
: > "$REG"
echo '{"session_id":"uuid-AAA","reason":"prompt_input_exit"}' \
  | env -i HOME="$T" PATH="/usr/bin:/bin" bash "$E"
row=$(cat "$REG")
chk "end row has 3 fields"            '[ "$(awk -F"\t" "{print NF}" <<<"$row")" = 3 ]'
chk "end field2 = end"                '[ "$(cut -f2 <<<"$row")" = end ]'
chk "end field3 = uuid"               '[ "$(cut -f3 <<<"$row")" = uuid-AAA ]'

# --- 7. end fail-open: empty stdin => exit 0, no row ---
: > "$REG"
printf '' | env -i HOME="$T" PATH="/usr/bin:/bin" bash "$E"; rc=$?
chk "end exit 0 on empty stdin"       '[ "$rc" = 0 ]'
chk "end writes no row on empty"      '[ ! -s "$REG" ]'

# --- 8. concurrent atomic appends: 30 parallel starts => 30 intact 9-NF rows ---
: > "$REG"
for i in $(seq 1 30); do
  echo "{\"session_id\":\"uuid-$i\",\"cwd\":\"/home/dhx/repos/hooks\"}" \
    | env -i HOME="$T" CLAUDE_CONFIG_DIR="$CCDIR" PATH="/usr/bin:/bin" bash "$S" &
done
wait
chk "30 concurrent rows present"      '[ "$(wc -l < "$REG")" = 30 ]'
chk "0 malformed (NF!=9) rows"        '[ "$(awk -F"\t" "NF!=9" "$REG" | wc -l)" = 0 ]'
chk "30 distinct uuids intact"        '[ "$(cut -f3 "$REG" | sort -u | wc -l)" = 30 ]'

echo "${pass} passed, ${fail} failed"
[ "$fail" = 0 ]
