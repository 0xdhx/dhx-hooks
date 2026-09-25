#!/usr/bin/env bash
# probe-global-claude-md-write-ask.sh
#
# Regression probe for dhx/dhx-global-claude-md-write-ask.sh (PreToolUse:Bash).
#
# Invariant: a Bash command that WRITES to the global CLAUDE.md through any
# of its three spellings — canonical ~/repos/dotfiles/claude/CLAUDE.md, the
# ~/.claude/CLAUDE.md symlink, a ~/.ccs/instances/*/CLAUDE.md symlink — or the
# relative `claude/CLAUDE.md` form paired with a `dotfiles` mention, gets
# `permissionDecision:"ask"` on stdout at exit 0. A READ of the same paths,
# and any write to a PROJECT CLAUDE.md, produces exit 0 with NO stdout.
#
# Tooth: the assertion is on the emitted DECISION, not on the hook's
# vocabulary — an inverted predicate (ask-on-read) reds the silent arms and
# a deleted one reds the ask arms (README § "A guard has two layers").
#
#        (companion to the `permissions.ask` Edit(path) rules, hooks 29aacddb).
# Companion: probe-git-destructive-guard.sh (same harness shape; orthogonal
#        surface).
#
# Run: bash tests/probes/probe-global-claude-md-write-ask.sh
#
# Negative controls (measured 2026-09-19, via PROBE_HOOK_OVERRIDE=<mutant>):
#   inversion  `is_write || exit 0` → `is_write && exit 0`   26 red / 33
#              (every ASK arm + every global-path READ arm; tokens intact)
#   deletion   `is_global_path || exit 0` removed              3 red / 33
#              (exactly the three PROJECT-CLAUDE.md silent arms)
#   dead harness  hook replaced by `exit 0`                   15 red / 33
#              (every ASK arm — the silent arms alone would not see it)
#
# SAFE_FOR_LIVE: yes   (hook subshell with synthetic stdin; the hook never
#                       executes the command it inspects.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${PROBE_HOOK_OVERRIDE:-$REPO/dhx/dhx-global-claude-md-write-ask.sh}"

if [[ ! -x "$HOOK" ]]; then
  echo "FAIL hook not found or not executable: $HOOK"
  exit 1
fi

PASSED=0
FAILED=0

_run() {
  local cmd="$1" input
  input=$(jq -cn --arg x "$cmd" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$x}}')
  OUT=$(echo "$input" | bash "$HOOK" 2>&1)
  RC=$?
}

_assert_ask() {
  local name="$1"
  if [[ "$RC" == "0" ]] && jq -e '.hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$OUT" >/dev/null 2>&1; then
    echo "OK   ask    $name"; PASSED=$((PASSED + 1))
  else
    echo "FAIL ask    $name — expected exit 0 + permissionDecision:ask, got rc=$RC"
    echo "     output: $OUT"
    FAILED=$((FAILED + 1))
  fi
}

_assert_silent() {
  local name="$1"
  if [[ "$RC" == "0" ]] && [[ -z "$OUT" ]]; then
    echo "OK   silent $name"; PASSED=$((PASSED + 1))
  else
    echo "FAIL silent $name — expected exit 0 + no output, got rc=$RC"
    echo "     output: $OUT"
    FAILED=$((FAILED + 1))
  fi
}

# ── writes → ASK ──────────────────────────────────────────────────────────
_run 'sed -i "2d" ~/repos/dotfiles/claude/CLAUDE.md';                                  _assert_ask "sed -i on canonical (~)"
_run 'sed -i "2{/probe/d}" /home/dhx/repos/dotfiles/claude/CLAUDE.md';                 _assert_ask "sed -i on canonical (/home/<u>)"
_run 'cd ~/repos/dotfiles && sed -i "s/a/b/" claude/CLAUDE.md && git status';          _assert_ask "cd dotfiles + relative claude/CLAUDE.md"
_run $'cat >> ~/.claude/CLAUDE.md <<EOF\n- new rule\nEOF';                              _assert_ask "heredoc append onto ~/.claude symlink"
_run $'cat > "$HOME/.ccs/instances/a/CLAUDE.md" <<\'EOF\'\nx\nEOF';                     _assert_ask "heredoc overwrite onto \$HOME/.ccs instance symlink"
_run 'echo x | tee -a ~/.claude/CLAUDE.md';                                             _assert_ask "tee -a"
_run 'cp /tmp/x ~/repos/dotfiles/claude/CLAUDE.md';                                     _assert_ask "cp over canonical (dest)"
_run 'cd /tmp && mv x ~/.claude/CLAUDE.md';                                             _assert_ask "mv onto symlink (dest, 2nd segment)"
_run 'git -C ~/repos/dotfiles checkout -- claude/CLAUDE.md';                            _assert_ask "git -C checkout --"
_run 'cd ~/repos/dotfiles && git restore claude/CLAUDE.md';                             _assert_ask "git restore after cd"
_run $'python3 - ~/repos/dotfiles/claude/CLAUDE.md <<EOF\nopen(sys.argv[1],"w")\nEOF';  _assert_ask "python3 interpreter with path arg"
_run 'perl -pi -e "s/a/b/" ~/.claude/CLAUDE.md';                                        _assert_ask "perl -pi"
_run 'sed --in-place "s/a/b/" ~/repos/dotfiles/claude/CLAUDE.md';                       _assert_ask "sed --in-place"
_run 'f=~/repos/dotfiles/claude/CLAUDE.md; sed -i "1d" "$f"';                           _assert_ask "same-command variable indirection"
_run 'rm ~/.ccs/instances/b/CLAUDE.md';                                                 _assert_ask "rm of an instance symlink"

# ── reads and project files → SILENT ──────────────────────────────────────
_run 'cat ~/repos/dotfiles/claude/CLAUDE.md';                                           _assert_silent "cat canonical"
_run 'sed -n "1,60p" ~/repos/dotfiles/claude/CLAUDE.md';                                _assert_silent "sed -n (read) canonical"
_run 'grep -n Security ~/.claude/CLAUDE.md 2>/dev/null';                                _assert_silent "grep with 2>/dev/null"
_run 'head -3 ~/.ccs/instances/a/CLAUDE.md >/dev/null 2>&1';                            _assert_silent "head with >/dev/null 2>&1"
_run 'git -C ~/repos/dotfiles diff -- claude/CLAUDE.md';                                _assert_silent "git diff"
_run 'git -C ~/repos/dotfiles log -3 -- claude/CLAUDE.md';                              _assert_silent "git log"
_run 'readlink -f ~/.claude/CLAUDE.md';                                                 _assert_silent "readlink"
_run 'sed -i "s/a/b/" ./CLAUDE.md';                                                     _assert_silent "sed -i on PROJECT ./CLAUDE.md"
_run 'sed -i "s/a/b/" .claude/CLAUDE.md';                                               _assert_silent "sed -i on PROJECT .claude/CLAUDE.md (not home-anchored)"
_run $'cat > CLAUDE.md <<EOF\nproject\nEOF';                                            _assert_silent "heredoc onto PROJECT CLAUDE.md"
_run 'ls -la ~/.claude/CLAUDE.md';                                                      _assert_silent "ls -la"
_run 'cp ~/.claude/CLAUDE.md /tmp/bak';                                                 _assert_silent "cp FROM global (source, not dest)"
_run 'cp ~/repos/dotfiles/claude/CLAUDE.md ~/repos/dotfiles/claude/CLAUDE.md.bak';      _assert_silent "cp to a .bak sibling (dest is not CLAUDE.md)"
_run 'wc -l ~/repos/dotfiles/claude/CLAUDE.md';                                         _assert_silent "wc -l"
_run 'ls';                                                                              _assert_silent "unrelated command"

# ── stdin robustness → SILENT exit 0 ──────────────────────────────────────
OUT=$(printf '' | bash "$HOOK" 2>&1); RC=$?;                                            _assert_silent "empty stdin"
OUT=$(echo 'not json' | bash "$HOOK" 2>&1); RC=$?;                                      _assert_silent "non-JSON stdin"
OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/dhx/repos/dotfiles/claude/CLAUDE.md"}}' | bash "$HOOK" 2>&1); RC=$?
                                                                                        _assert_silent "non-Bash tool_name (fail open)"

echo ""
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
