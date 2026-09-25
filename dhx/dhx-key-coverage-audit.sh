#!/usr/bin/env bash
# dhx-key-coverage-audit.sh — SessionStart: warn when an SSH private key on this
# machine is not covered by BOTH key-protection layers.
# Patterns: HP-009, HP-015
# (HP-009: exit 2 blocks / exit 1 does not — this hook exits 0 on EVERY path, so it can
#  neither block a session nor trip the dispatcher's child-failure surface. HP-015:
#  SessionStart fires on startup|resume|clear|compact, which is the audit cadence.
#  Plain stdout reaching model context is the session-start.sh dispatcher's own stated
#  contract — see its "children emit PLAIN stdout" note — not an HP claim.)
#
# WHY: the 2026-09-15 key arc replaced the `Read(~/.ssh/id_*)` deny glob with exact
# names, because the glob also swallowed `id_ed25519.pub` and CC's matcher offers no
# carve-out (extglob unsupported, negated class unsupported, an explicit allow loses
# to the deny — all measured; docs/decisions.md 2026-09-15 row). Exact names cost a
# residual: a key minted LATER is covered by no rule until someone adds one. That is
# a residual guarded by human memory, which is not a guard. This hook is the detector
# that replaces the memory: it enumerates the private keys that actually exist and
# names any whose protection is incomplete, with the line to paste.
#
# THE TWO LAYERS, and why both are checked:
#   1. CC deny rule  — `Read(<path>)` in the live settings. Survives a hook crash.
#   2. dhx-key-read-guard.js — text-matches command operands. Covers names no rule
#      lists, but FAILS OPEN on a hook-internal error (its own stated residual).
# Neither subsumes the other, so a key missing either layer is reported.
#
# NEVER READS KEY MATERIAL. Private keys are located by inference only — a `*.pub`
# whose sibling exists, or an `IdentityFile` target — never by opening a file to look
# for a PEM header. The file contents of a private key are never read by this script.
#
# Silent on the happy path (hooks convention: stdout becomes model context).
# Fail-open on every error path: a broken check must never block session start.
# Exit 0 ALWAYS — a non-zero exit is the dispatcher's child-failure surface, which is
# for a broken child, not for a finding.
#
# Config: reads config/key-read-guard.json (the guard's own config — single source of
# truth for ssh_configs + extra_key_basenames). Overrides, used by the probe:
#   DHX_KEY_GUARD_CONFIG=<path>       guard config
#   DHX_KEY_COVERAGE_SETTINGS=<path>  settings.json to audit
# Probe: tests/probes/probe-dhx-key-coverage-audit.sh

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

GUARD_CONFIG="${DHX_KEY_GUARD_CONFIG:-/home/dhx/repos/hooks/config/key-read-guard.json}"
SETTINGS="${DHX_KEY_COVERAGE_SETTINGS:-}"
if [[ -z "$SETTINGS" ]]; then
  SETTINGS=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null) || exit 0
fi
[[ -r "$GUARD_CONFIG" && -r "$SETTINGS" ]] || exit 0

# --- guard config ---------------------------------------------------------------
mapfile -t SSH_CONFIGS < <(jq -r '.ssh_configs[]? // empty' "$GUARD_CONFIG" 2>/dev/null) || exit 0
mapfile -t EXTRA_NAMES < <(jq -r '.extra_key_basenames[]? // empty' "$GUARD_CONFIG" 2>/dev/null) || exit 0

# ~ expansion for config-declared paths (the guard accepts a leading ~/).
expand_tilde() { case "$1" in "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

# --- deny patterns, normalized to absolute glob patterns -------------------------
# `Read(~/x)` -> $HOME/x. `Read(//abs)` -> /abs (CC's absolute-path prefix: a single
# leading / is relative to the settings file, so // is how an absolute rule is spelled).
# Anything still not absolute cannot match a key path and is dropped.
DENY_PATTERNS=()
while IFS= read -r rule; do
  [[ "$rule" == Read\(*\) ]] || continue
  pat="${rule#Read(}"; pat="${pat%)}"
  case "$pat" in
    "~/"*) pat="$HOME/${pat#\~/}" ;;
    "//"*) pat="${pat#/}" ;;
    "/"*)  : ;;
    *)     continue ;;
  esac
  DENY_PATTERNS+=("$pat")
done < <(jq -r '.permissions.deny[]? // empty' "$SETTINGS" 2>/dev/null)

# --- candidate private keys ------------------------------------------------------
# Located WITHOUT reading any file's contents:
#   (a) every `<name>.pub` whose sibling `<name>` exists — the universal keypair shape
#   (b) every IdentityFile target named by a configured ssh config
# A `~/.ssh/<name>` IdentityFile resolves against THAT config's own directory: in the
# Windows-side config `~` is the Windows home, which from WSL is the config's own dir.
CANDIDATES=()
IDENTITY_TARGETS=()
add_candidate() { local p=$1; local c; for c in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do [[ "$c" == "$p" ]] && return 0; done; CANDIDATES+=("$p"); }

for cfg in "${SSH_CONFIGS[@]+"${SSH_CONFIGS[@]}"}"; do
  cfg=$(expand_tilde "$cfg")
  dir=$(dirname "$cfg")
  [[ -d "$dir" ]] || continue
  for pub in "$dir"/*.pub; do
    [[ -e "$pub" ]] || continue
    priv="${pub%.pub}"
    [[ -f "$priv" ]] && add_candidate "$priv"
  done
  [[ -r "$cfg" ]] || continue
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in
      "~/.ssh/"*) target="$dir/${target#\~/.ssh/}" ;;
      "~/"*)      target="$HOME/${target#\~/}" ;;
    esac
    IDENTITY_TARGETS+=("$target")
    [[ -f "$target" ]] && add_candidate "$target"
  done < <(awk 'tolower($1)=="identityfile" {print $2}' "$cfg" 2>/dev/null)
done

[[ "${#CANDIDATES[@]}" -gt 0 ]] || exit 0

# --- coverage tests --------------------------------------------------------------
# Layer 1: any deny pattern glob-matching the path. Unquoted RHS = glob match, and in
# [[ ]] pattern matching `*` spans `/`, so `~/.ssh/**` matches a key path as CC intends.
covered_by_rule() {
  local path=$1 pat
  for pat in "${DENY_PATTERNS[@]+"${DENY_PATTERNS[@]}"}"; do
    # shellcheck disable=SC2053
    [[ "$path" == $pat ]] && return 0
  done
  return 1
}

# Layer 2: the guard's own predicate — algorithm-anchored basename, an IdentityFile
# target in a configured config, or an extra_key_basenames entry. Mirrors
# KEY_BASENAME_RE in dhx/dhx-key-read-guard.js.
# INVARIANT: this regex tracks KEY_BASENAME_RE in dhx/dhx-key-read-guard.js. If that
# predicate changes, this one must change with it or the audit reports the wrong layer.
covered_by_guard() {
  local path=$1 base name t
  base=$(basename "$path")
  [[ "$base" =~ ^id_(rsa|dsa|ecdsa|ed25519)(_sk)?([._-][a-z0-9._-]*)?$ ]] && return 0
  for name in "${EXTRA_NAMES[@]+"${EXTRA_NAMES[@]}"}"; do
    [[ "$base" == "$name" ]] && return 0
  done
  for t in "${IDENTITY_TARGETS[@]+"${IDENTITY_TARGETS[@]}"}"; do
    [[ "$t" == "$path" ]] && return 0
  done
  return 1
}

# Display spelling: ~ for $HOME. Shorter (the 76-char content width is a hard ceiling
# and a wrapped line loses its indent, inverting the hierarchy) and it matches how the
# deny rule itself is written, so the line reads as the thing you are about to paste.
display_path() {
  case "$1" in "$HOME/"*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

# The deny-rule spelling for a path: ~/ inside $HOME, else CC's // absolute form.
rule_for() {
  local path=$1
  case "$path" in
    "$HOME/"*) printf 'Read(~/%s)' "${path#"$HOME"/}" ;;
    *)         printf 'Read(/%s)' "$path" ;;
  esac
}

# --- report ----------------------------------------------------------------------
# Parallel arrays, NOT tab-joined rows split by `IFS=$'\t' read`: TAB is IFS whitespace, so
# `read` collapses an empty field and shifts the rest left (docs/decisions.md 2026-09-25 row).
# Three arrays need no delimiter at all.
GAPS=() GAP_RULE=() GAP_GUARD=()
for key in "${CANDIDATES[@]}"; do
  rule_ok=no; guard_ok=no
  covered_by_rule "$key" && rule_ok=yes
  covered_by_guard "$key" && guard_ok=yes
  [[ "$rule_ok" == yes && "$guard_ok" == yes ]] && continue
  GAPS+=("$key"); GAP_RULE+=("$rule_ok"); GAP_GUARD+=("$guard_ok")
done

[[ "${#GAPS[@]}" -gt 0 ]] || exit 0

n=${#GAPS[@]}
noun="key"; [[ "$n" -gt 1 ]] && noun="keys"
printf '⚠ key-coverage: %d SSH private %s not fully protected\n' "$n" "$noun"
for i in "${!GAPS[@]}"; do
  key=${GAPS[$i]} rule_ok=${GAP_RULE[$i]} guard_ok=${GAP_GUARD[$i]}
  printf '    %s\n' "$(display_path "$key")"
  printf '      deny rule: %s · read-guard: %s\n' \
    "$([[ "$rule_ok" == yes ]] && echo covered || echo MISSING)" \
    "$([[ "$guard_ok" == yes ]] && echo covered || echo MISSING)"
  [[ "$rule_ok" == no ]] && printf '      permissions.deny += "%s"\n' "$(rule_for "$key")"
  [[ "$guard_ok" == no ]] && printf '      extra_key_basenames += "%s"\n' "$(basename "$key")"
done
printf '  › deny edits land in BOTH ~/.ccs/shared/settings.json and hooks\n'
printf '    config/settings.json, same commit (drift-monitor sync)\n'

exit 0
