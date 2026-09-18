#!/usr/bin/env bash
# tests/probes/lib/cc-cell-stderr.sh
#
# Separate a sandboxed Claude Code cell's OUTCOME from the advisories it emits
# about the CONFIGURATION it was handed.
#
# WHY THIS EXISTS (2026-09-18, found while verifying the single-binary fix).
# The probe-installed-plugins-*-natural-heal.sh cells classify a run by grepping
# its stderr for failure signatures:
#
#     rc == 124 || stderr =~ /timeout|deadline/        -> timeout_124
#     stderr =~ /401|403|...|authentication|.../       -> auth_failure
#     stderr =~ /network|connection|ECONNREFUSED|.../  -> network_failure
#
# Those probes deliberately copy the operator's LIVE settings.json into the
# sandbox for fidelity. Claude Code then validates that file and prints an
# advisory PER QUESTIONABLE RULE — and the advisory quotes the rule verbatim.
# This host's settings carry `Bash(timeout * gh *)`, so every cell's stderr
# contains the word "timeout" and every cell was classified `timeout_124` with
# rc=0. Measured 2026-09-18: all three probes, 3/3, immediately after the
# single-binary fix revived their live arms — post_size observations were good
# and were discarded anyway.
#
# It had never fired before because the cells had been exiting 127 at the
# wrapper since 2026-08-07 (see resolve-cc-binary.sh), and that message is short
# and contains none of these words. Fixing the binary is what exposed it.
#
# The exposure is NOT limited to timeouts and is not hypothetical-only: a rule
# naming `Authorization`, `--connect-timeout`, or a host called `connection`
# forges `auth_failure` or `network_failure` just as easily. The direction is
# fail-SAFE — every misfire lands in the ambiguous family, never a false
# `v1_2_work_warranted` — so no committed cell ever claimed a verdict it had not
# earned. But a watchdog that can only ever say "ambiguous" is not watching.
#
# WHAT IS STRIPPED — only lines that describe the INPUT CONFIG or the sandbox's
# own missing files, never lines describing the request:
#
#   1. `Permission allow rule (<file>): ...` / `Permission deny rule (<file>): ...`
#      Claude Code's settings-lint. Speaks about a rule, not about this request.
#   2. `<Event> hook [<cmd>] failed: ...`
#      The probes point HOME at a mktemp dir, so every hook registered under
#      $HOME/.claude/hooks is missing BY CONSTRUCTION and fails on every cell.
#      That is an artifact of the probe's own isolation, not an observation.
#
# The D-22 false-PASS guard is NOT weakened: a real auth, network or timeout
# failure is reported on its own line and survives the filter. This removes only
# text that was never evidence about the cell.
#
# No pipes: a `printf | grep` filter takes SIGPIPE under `set -o pipefail` and
# fails open exactly when the payload is large (HP-028). This reads a herestring
# in a pure-bash loop instead.
#
# Pinned by tests/probes/probe-cc-binary-resolution.sh.

# strip_cc_config_advisories <stderr> -> stderr with config advisories removed
#
# CC-STDERR-EXEMPT: this file IS the filter. It classifies nothing and spawns
#   no child; the `claude -p` and `timeout|deadline` strings in the header above
#   are prose describing the regression it defends against.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

strip_cc_config_advisories() {
  local line out=""
  while IFS= read -r line; do
    case "$line" in
      "Permission allow rule ("*) continue ;;
      "Permission deny rule ("*)  continue ;;
    esac
    # `SessionEnd hook [...] failed:`, `PreToolUse hook [...] failed:`, ...
    if [[ "$line" =~ ^[A-Za-z]+\ hook\ \[.*\]\ failed: ]]; then
      continue
    fi
    out+="$line"$'\n'
  done <<< "${1:-}"
  printf '%s' "$out"
}

# count_cc_config_advisories <stderr> -> how many lines the filter would drop.
# Surfaced on the probe's stdout at classification time so a reader can tell a
# genuinely clean cell from a noisy one that was cleaned, without re-running.
count_cc_config_advisories() {
  local raw="${1:-}" kept="" n_raw=0 n_kept=0
  kept=$(strip_cc_config_advisories "$raw")
  [[ -n "$raw" ]]  && n_raw=$(grep -c '' <<< "$raw")
  [[ -n "$kept" ]] && n_kept=$(grep -c '' <<< "$kept")
  printf '%s' "$(( n_raw - n_kept ))"
}
