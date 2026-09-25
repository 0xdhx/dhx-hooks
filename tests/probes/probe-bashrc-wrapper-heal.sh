#!/bin/bash
# Probe: the dhx plugin-keys pre-launch heal has ONE home — dhx/dhx-plugin-keys-heal.sh, run by
# dhx/dhx-prelaunch.sh from the launch wrappers — and every site that checks those keys uses one
# jq predicate.
#
# The keys (enabledPlugins["dhx@dhx-local"], extraKnownMarketplaces["dhx-local"]) are
# load-gating (HP-017): when a stale-snapshot settings rewrite drops them, the dhx plugin
# silently fails to register, so the repair must run before Claude Code starts. From 2026-04-17
# it lived in the ~/.bashrc claude() wrapper, which returns early in non-interactive shells and
# which daemon-hosted sessions never pass; on 2026-09-15 it moved to the pre-launch seam
# (docs/decisions.md 2026-09-15 plugin-keys row). This probe keeps a second copy from growing
# back in .bashrc, keeps the wrapper's post-exit settings-symlink repair (which stayed), and
# asserts predicate parity so the heal and the warning fire at the same threshold.
#
# Asserts plugin-keys load-gating verified +
# bashrc auto-heal". Run: bash tests/probes/probe-bashrc-wrapper-heal.sh
# SAFE_FOR_LIVE: yes   (grep-only against live `~/.bashrc` and in-repo files; no writes)
set -uo pipefail

pass=0
fail=0

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    fail=$((fail+1))
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     got:  $got"
    echo "     want: $want"
    fail=$((fail+1))
  fi
}

# In-repo sites resolve relative to this probe, so a worktree checks its own copies.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASHRC="$HOME/.bashrc"
KEYS_HEAL="$REPO/dhx/dhx-plugin-keys-heal.sh"
PRELAUNCH="$REPO/dhx/dhx-prelaunch.sh"
HEALTH_CHECK="$REPO/dhx/dhx-health-check.sh"
PLUGIN_KEYS_PROBE="$REPO/tests/probes/probe-plugin-keys.sh"
INSTALL_PLUGIN="$REPO/scripts/install-plugin.sh"

# --- 1. The .bashrc wrapper keeps its post-exit half and routes through the capped launcher ---
assert "bashrc exists" "[[ -f '$BASHRC' ]]"
assert "claude() function defined" "grep -qE '^claude\(\) \{' '$BASHRC'"
assert "post-exit symlink repair preserved" "grep -qE 'ln -sf .\\\$canonical. .\\\$target.' '$BASHRC'"
assert "post-exit hold guard preserved" "grep -q 'settings-chain.hold' '$BASHRC'"
# `command claude` resolves through PATH to ~/.local/capbin/claude (claude-capped.sh), which runs
# dhx-prelaunch.sh — that is how an interactive launch still gets the heal.
assert "wrapper execs 'command claude \"\$@\"'" "grep -q 'command claude \"\$@\"' '$BASHRC'"

# --- 2. No second copy of the heal in .bashrc ---
assert "bashrc runs no 'claude plugin marketplace add'" "! grep -q 'plugin marketplace add' '$BASHRC'"
assert "bashrc runs no 'claude plugin enable'" "! grep -q 'plugin enable dhx@dhx-local' '$BASHRC'"
assert "bashrc carries no plugin-keys predicate" "! grep -q 'enabledPlugins\[\"dhx@dhx-local\"\]' '$BASHRC'"

# --- 3. The heal lives in the pre-launch seam and spawns no Claude Code process ---
assert "dhx-plugin-keys-heal.sh exists" "[[ -f '$KEYS_HEAL' ]]"
assert "dhx-prelaunch.sh runs dhx-plugin-keys-heal.sh" "grep -qE '^run_child dhx-plugin-keys-heal\.sh' '$PRELAUNCH'"
assert "keys heal invokes no 'claude' subcommand (comments aside)" \
  "! grep -qE '(^|[[:space:];|&(])claude[[:space:]]+plugin' < <(grep -vE '^[[:space:]]*#' '$KEYS_HEAL')"

# --- 4. jq predicate parity across every site that checks the keys ---
canonical_pred='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'
PRED_ERE="\.enabledPlugins\[\"dhx@dhx-local\"\] == true and \(\.extraKnownMarketplaces\[\"dhx-local\"\]\.source\.path // empty\) != \"\""
for site in "$KEYS_HEAL" "$HEALTH_CHECK" "$PLUGIN_KEYS_PROBE" "$INSTALL_PLUGIN"; do
  got=$(grep -oE "$PRED_ERE" "$site" 2>/dev/null | head -1)
  assert_eq "$(basename "$site") jq predicate matches canonical" "$got" "$canonical_pred"
done

# --- 5. BEHAVIOURAL parity with the JavaScript copy (2026-09-15) ---
# The path-zero / path-false / path-null / path-object fixtures are here because the first
# nine did NOT cover a non-string `source.path`, and a close-gate reviewer drove exactly that
# gap: jq's `(… // empty) != ""` fires its alternative only on null and false, so the hook
# calls a path of 0 `ok`, while the JS copy's `typeof mk === 'string'` called it MISSING.
# Whether strict typing would be better is a separate question from whether the copies agree.
# Since the statusline wrapper computes this lane's plugin-keys verdict itself, there is a
# FIFTH copy of the predicate and the first one not written in jq — so section 4's textual
# match cannot reach it. A grep cannot compare across languages; driving both over the same
# inputs can. Same shape as the two-language lane-id agreement in
# probe-sym-health-lane-scoping: the invariant is unenforceable by either language, so it is
# asserted by running them.
WRAPPER_JS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/dhx/statusline-wrapper.js"
PARITY_TMP="$(mktemp -d)"
trap 'rm -rf "$PARITY_TMP"' EXIT

# bash side: the hook's own resolution — an unreadable settings.json is MISSING, not an error
bash_verdict() { # bash_verdict <config_dir>
  local real; real="$(readlink -f "$1/settings.json" 2>/dev/null)"
  if [[ ! -f "$real" ]] || ! jq -e "$canonical_pred" "$real" >/dev/null 2>&1; then
    echo MISSING
  else
    echo ok
  fi
}

js_verdict() { # js_verdict <config_dir>
  node -e '
    const w = require(process.argv[1]);
    process.stdout.write(String(w.pluginKeysForThisLane(process.argv[2])));
  ' "$WRAPPER_JS" "$1" 2>/dev/null
}

GOOD='{"enabledPlugins":{"dhx@dhx-local":true},"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"/p"}}}}'
mk_fixture() { # mk_fixture <name> <content|SPECIAL>
  local d="$PARITY_TMP/$1"; mkdir -p "$d"
  case "$2" in
    ABSENT)   ;;                                              # no settings.json at all
    DANGLING) ln -sf "$d/nowhere.json" "$d/settings.json" ;;   # broken link, the live lane-zz shape
    *)        printf '%s' "$2" > "$d/settings.json" ;;
  esac
  echo "$d"
}

for fx in \
  "healthy|$GOOD" \
  "enabled-false|{\"enabledPlugins\":{\"dhx@dhx-local\":false},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":\"/p\"}}}}" \
  "enabled-absent|{\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":\"/p\"}}}}" \
  "marketplace-absent|{\"enabledPlugins\":{\"dhx@dhx-local\":true}}" \
  "marketplace-empty|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":\"\"}}}}" \
  "path-zero|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":0}}}}" \
  "path-false|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":false}}}}" \
  "path-null|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":null}}}}" \
  "path-object|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"path\":{}}}}}" \
  "malformed|not json {{{" \
  "empty-object|{}" \
  "absent|ABSENT" \
  "dangling|DANGLING" \
; do
  name="${fx%%|*}"; body="${fx#*|}"
  d="$(mk_fixture "$name" "$body")"
  b="$(bash_verdict "$d")"; j="$(js_verdict "$d")"
  if [[ -z "$j" ]]; then
    assert_eq "plugin-keys parity [$name] — JS predicate could not be driven" "driven" "not-driven"
  else
    assert_eq "plugin-keys parity [$name] (bash=$b js=$j)" "$j" "$b"
  fi
done

echo
echo "$pass passed, $fail failed"
exit $fail
