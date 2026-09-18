#!/usr/bin/env bash
# tests/probes/lib/resolve-cc-binary.sh
#
# ONE Claude Code binary, resolved ONCE, for probes that both MEASURE with a
# `claude` subprocess and LABEL a corpus cell with a release version.
#
# WHY THIS EXISTS — two defects, one cause (see docs/decisions.md 2026-09-18):
#
#   (1) Resolve-twice attribution. The supersession-watchdog probes under
#       tests/probes/.results/v1.3-multi-cc-ver/<version>/ write ONE fixed
#       filename per release directory, so the release label is the
#       observation's SLOT, not merely its name — a wrong label OVERWRITES a
#       different observation. Resolving `claude` from PATH for the measurement
#       and again for the label leaves a window (a 30s-timeout subprocess and
#       ~100 lines wide) in which the auto-updater can rewrite
#       ~/.local/bin/claude, so the cell names a release that did not produce
#       the observation. Same broken invariant as the effort-probe fix in
#       d39ba983 — the label must identify the actual PRODUCER — different
#       mechanism: that one broke across sessions, this one across time inside
#       a single process.
#
#   (2) `claude` on PATH is NOT the binary. Since 2026-08-07 it is
#       ~/.local/capbin/claude -> cross-repo health/scripts/claude-capped.sh,
#       which resolves the real binary via `readlink -f "$HOME/.local/bin/claude"`
#       and exits 127 when that fails. Probes that sandbox by swapping HOME
#       therefore ran NOTHING: measured at CC 2.1.275, all three
#       probe-installed-plugins-* cells recorded cell_outcome=setup_failure,
#       cell1_rc=127. Documented for probe-known-marketplaces-natural-heal.sh in
#       the 2026-09-15 decisions row and fixed there; the three siblings were the
#       unfixed remainder. Invoking the resolved path directly fixes this too.
#
# SELECTION — PATH-current, deliberately NOT $CLAUDE_CODE_EXECPATH.
# probe-known-marketplaces-natural-heal.sh prefers EXECPATH and is CORRECT to:
# dhx/dhx-km-acceptance.sh drives it once per installed CC version keyed on
# EXECPATH's version (2026-09-15 decisions row, F5). The installed-plugins
# probes have no such driver, and their cells are consumed by
# scripts/run-probes.sh, which hoists `active_cc` from its own PATH-derived
# `claude --version` and resolves per-probe outcome paths under it with NO
# freshness check. Pinning EXECPATH would let a session that outlived an update
# file under one release while the runner inspected another. PATH-current makes
# probe and consumer agree BY CONSTRUCTION. Consistency with the model probe is
# an argument; the model having a reason these three lack outweighs it.
#
# NO FALLBACK. An unresolvable or non-executable binary is a refusal, never a
# retry with bare `claude`: a version read from one binary is not evidence about
# an observation produced by another. Callers must refuse WITHOUT publishing a
# cell — publishing a non-observation into a one-slot-per-release corpus
# destroys whatever observation held the slot.
#
# CANONICALIZATION is load-bearing on --binary too. An accepted symlink is
# re-resolved by the kernel at exec, which recreates defect (1) in miniature
# between the version read and the launch. Every returned path is `readlink -f`'d.
#
# Function-only: no side effects, no traps, no `exit`, safe to source under
# `set -uo pipefail`. Convention follows lib/assert-stop-schema.sh.
#
# Pinned by tests/probes/probe-cc-binary-resolution.sh (hermetic, runs in the
# pre-commit tier — the live arms of the consuming probes are SAFE_FOR_LIVE: no
# and the tier can never execute them, which is the whole reason this is a lib
# and not three copies).

# resolve_cc_binary [explicit_path] -> canonical binary path on stdout
# rc 0 = resolved AND executable; rc 1 = unresolvable (stdout empty).
# With an explicit path, that path is canonicalized and used; a bad explicit
# path is an ERROR, never a silent fall-through to the default (asking for a
# specific binary and silently getting another is the attribution bug again).
#
# CC-STDERR-EXEMPT: resolves a path, classifies nothing. Measured 2026-09-18:
#   this file contains no `grep -q` and no `2>&1` capture, so it has no
#   classifier for a settings-lint line to reach.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

resolve_cc_binary() {
  local explicit="${1:-}" bin=""
  if [[ -n "$explicit" ]]; then
    bin=$(readlink -f -- "$explicit" 2>/dev/null || true)
  else
    bin=$(readlink -f -- "${HOME:-}/.local/bin/claude" 2>/dev/null || true)
  fi
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    return 1
  fi
  printf '%s' "$bin"
  return 0
}

# resolve_cc_version <binary_path> -> dotted triple on stdout
# rc 0 = resolved; rc 1 = no version (stdout empty).
# The installed layout names each version directory by its release
# (~/.local/share/claude/versions/2.1.276), so basename is the cheap path and
# costs no subprocess; it is accepted ONLY on an exact dotted-triple match, so a
# checkout, a renamed copy or a traversal segment falls through to asking the
# binary itself. Extraction is a bash regex, not `cmd | grep | head`: that shape
# takes SIGPIPE and fails open under `set -o pipefail` (HP-028).
resolve_cc_version() {
  local bin="${1:-}" base="" raw=""
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    return 1
  fi
  base=$(basename -- "$bin")
  if [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$base"
    return 0
  fi
  raw=$("$bin" --version 2>/dev/null || true)
  if [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# cc_version_is_sane <string> -> rc 0 when the string is a bare dotted triple.
# The version reaches a FILESYSTEM PATH (the corpus release directory), so it is
# validated at the point of use as well as at the point of resolution — the
# d39ba983 rule, kept now that a label can come from a binary's own output.
cc_version_is_sane() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
