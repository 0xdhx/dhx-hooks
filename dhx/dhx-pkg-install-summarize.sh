#!/usr/bin/env bash
#
# dhx-pkg-install-summarize.sh — the rc==0 compactor for dhx-pkg-install-filter.sh.
# Patterns: HP-040, HP-041
#
# Reads the merged stdout+stderr of a SUCCESSFUL package install on stdin and
# writes only the success summary: keep the authoritative summary lines, COLLAPSE
# the dominant repeating noise (npm `warn deprecated`, yarn `warning`) to a count,
# DROP progress/fetch/funding chatter.
#
# This runs ONLY on exit 0 — the filter's failure branch passes the raw output
# through with `cat`, so this compactor can never eat a failure cause (HP-040).
#
# Two invariants (mirrors ff-test-filter.sh's success/crash discipline):
#   1. POSITIVE SUCCESS SIGNAL — always print a `[pkg-install-filter] PASS:`
#      header + at least the summary, never ambiguous empty output.
#   2. UNRECOGNIZED OUTPUT IS NEVER SILENT — a success whose output matches no
#      known summary shape (an unmodeled tool) dumps the raw tail instead of
#      nothing.
#
# Exit code: always 0. The caller preserves the runner's real exit code.
#
set -uo pipefail

awk '
  { line[NR] = $0 }

  # --- COLLAPSE: the dominant large-install noise, counted not printed. ---
  /^npm (warn|WARN) deprecated /            { dep++;  next }
  /^warning /                                { ywarn++; next }   # yarn 1.x

  # --- KEEP: authoritative summary + advisory warnings worth surfacing. ---
  # npm / pnpm summary verbs + audit + vulnerability lines
  /^(added|removed|changed|up to date)/      { keep[++k] = $0; next }
  /audited [0-9]+ package/                   { keep[++k] = $0; next }
  /found [0-9]+ vulnerabilit/                { keep[++k] = $0; next }
  /^npm (warn|WARN) /                        { keep[++k] = $0; next }   # non-deprecated npm warnings
  # pip
  /^Successfully (installed|built|uninstalled)/ { keep[++k] = $0; next }
  /^WARNING:/                                { keep[++k] = $0; next }   # pip warnings (PEP-668, etc.)
  /^ERROR:/                                  { keep[++k] = $0; next }   # defensive: surfaced even on rc==0
  # pnpm / yarn terse summary
  /^Packages: /                              { keep[++k] = $0; next }
  /^Done([ .]|$)/                            { keep[++k] = $0; next }
  /^success /                                { keep[++k] = $0; next }   # yarn "success Saved N..."

  # everything else (Collecting / Downloading / Using cached / Requirement
  # already satisfied / Installing collected packages / funding / progress /
  # idealTree / [notice] / pnpm Progress / yarn [n/4]) falls through -> dropped.

  END {
    if (NR == 0) { print "[pkg-install-filter] PASS: install succeeded (no output)."; exit 0 }

    if (k > 0 || dep > 0 || ywarn > 0) {
      print "[pkg-install-filter] PASS: install succeeded; install-noise filtered (re-run raw for full output):"
      for (i = 1; i <= k; i++) print keep[i]
      if (dep   > 0) printf "  npm warn deprecated (x%d) — re-run raw to see them\n", dep
      if (ywarn > 0) printf "  yarn warning (x%d) — re-run raw to see them\n", ywarn
      exit 0
    }

    # Success, but no recognized summary shape (unmodeled tool). Never silent.
    print "[pkg-install-filter] PASS: install succeeded; no recognized summary line — raw tail:"
    print "----------------------------------------------------------------------"
    s = NR - 15; if (s < 1) s = 1
    for (i = s; i <= NR; i++) print line[i]
    exit 0
  }
'
