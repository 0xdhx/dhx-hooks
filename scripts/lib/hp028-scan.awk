# scripts/lib/hp028-scan.awk — the ONE HP-028 shape detector.
#
# Consumers (both must use this file; neither may carry its own pattern):
#   tests/probes/probe-sigpipe-pipefail-shapes.sh   at rest, over worktree files
#   scripts/verify-hook-patterns.sh check #5         at commit, over STAGED blobs, run from
#                                                    this file's own STAGED copy (fail closed)
#
# Flags a line holding a pipeline stage whose reader exits before draining its input:
# grep / egrep / fgrep / rg carrying -q, -m, --quiet, --silent or --max-count. Under
# `set -o pipefail` the producer then takes SIGPIPE, the pipeline exits 141 and an `if`
# reads "no match" — or, in `! p | grep -q X`, the passing arm (docs/hook-patterns.md HP-028).
# Reader set measured 2026-09-25 (`timeout 3 bash -c 'yes | R'`, 141 = quits early,
# 124 = reads everything): grep -q/-m1, rg -q/-m1/--quiet quit early; grep -l,
# --files-with-matches, -c, -L read everything and are NOT flagged.
#
# Why a scanner and not one regex (2026-09-25 row): the regex required `grep -[qm]` right
# after the pipe, so `grep -Eq`, `grep -E -q`, `command grep -q` and a shebang-only file
# were invisible while it printed "invariant holds" over 10 sites. GNU grep PERMUTES its
# arguments, so `grep -e PAT -q` and `grep -E 'a|b' -q` are live readers no left-to-right
# regex sees. This walks each line tracking quotes, splits stages on single `|` / `|&`
# (never `||`), skips `command`/`env`/`exec`/`builtin` prefixes and path, backslash and
# quoted spellings of the reader, then checks EVERY option token up to `--`.
#
# Carry-over between lines: a line ending in an unquoted `|` makes the next line a pipe
# stage; a line ending in an unquoted `\` continues the current stage. Quote state is NOT
# carried — heredoc bodies with a lone apostrophe would otherwise blind every later line.
#
# Exempt: whole-line comments, trailing comments, and any line containing the literal
# HP-028 (the visible exemption for fixtures that construct the broken form on purpose).
#
# Stated residuals: a pipeline inside a multi-line quoted string, behind eval or a
# variable holding the command, or a reader reached through xargs/a function.
#
# Output: <label>:<line>:<text>, label = -v label=... when given, else FILENAME.
# Portable across gawk and mawk (both measured).

function flush_word() { if (word != "") { words[++nw] = word; word = "" } }

function reset_stage() { split("", words); nw = 0; word = "" }

function judge(   k, cmd, j, o) {
  flush_word()
  if (stage_after_pipe && nw > 0) {
    k = 1
    while (k <= nw && (words[k] == "command" || words[k] == "env" || words[k] == "exec" || words[k] == "builtin" || words[k] == "{" || words[k] == "!" || words[k] ~ /^-/)) k++
    cmd = words[k]; sub(/^\\/, "", cmd); sub(/.*\//, "", cmd)
    if (cmd == "grep" || cmd == "egrep" || cmd == "fgrep" || cmd == "rg") {
      for (j = k + 1; j <= nw; j++) {
        o = words[j]
        if (o == "--") break
        if (o ~ /^--(quiet|silent|max-count)($|=)/) { hit = 1; break }
        if (o ~ /^-[A-Za-z0-9]/ && o ~ /^-[A-Za-z0-9]*[qm]/) { hit = 1; break }
      }
    }
  }
  reset_stage()
}

FNR == 1 { carry_pipe = 0; carry_cont = 0; reset_stage() }

{
  line = $0; t = line; sub(/^[ \t]+/, "", t)
  if (t ~ /^#/ || line ~ /HP-028/) { carry_pipe = 0; carry_cont = 0; reset_stage(); next }

  hit = 0; q = ""; sp = 0; depth = 0
  if (carry_cont) { carry_cont = 0 }                 # keep words + stage_after_pipe
  else if (carry_pipe) { reset_stage(); stage_after_pipe = 1; carry_pipe = 0 }
  else { reset_stage(); stage_after_pipe = 0 }

  n = length(line); last_sig = ""
  for (i = 1; i <= n; i++) {
    ch = substr(line, i, 1)
    if (q != "") {
      if (ch == q) q = ""
      else if (ch == "\\" && q == "\"") { word = word substr(line, i + 1, 1); i++ }
      else if (q == "\"" && ch == "$" && substr(line, i + 1, 1) == "(") {
        # command substitution inside double quotes is a real pipeline context
        judge(); stage_after_pipe = 0; sp++; qstk[sp] = q; dstk[sp] = depth; depth = 0; q = ""; i++
      }
      else word = word ch
      continue
    }
    if (ch == "\\") {
      if (i == n) { last_sig = "\\"; break }         # line continuation
      word = word ch substr(line, i + 1, 1); i++; last_sig = "w"; continue
    }
    if (ch == "'" || ch == "\"") { q = ch; last_sig = "w"; continue }
    if (ch == "#" && word == "") break                 # trailing comment
    if (ch == "|") {
      nx = substr(line, i + 1, 1)
      if (nx == "|") { judge(); stage_after_pipe = 0; i++; last_sig = "op"; continue }
      judge(); stage_after_pipe = 1; if (nx == "&") i++; last_sig = "|"; continue
    }
    if (ch == "(") { judge(); stage_after_pipe = 0; depth++; last_sig = "op"; continue }
    if (ch == ")") {
      judge(); stage_after_pipe = 0; last_sig = "op"
      if (depth > 0) depth--
      else if (sp > 0) { q = qstk[sp]; depth = dstk[sp]; sp-- }   # back inside the "..."
      continue
    }
    if (ch == ";" || ch == "&" || ch == "`") { judge(); stage_after_pipe = 0; last_sig = "op"; continue }
    if (ch == " " || ch == "\t") { flush_word(); continue }
    word = word ch; last_sig = "w"
  }

  if (q == "" && last_sig == "\\") { flush_word(); carry_cont = 1 }
  else if (q == "" && last_sig == "|") { carry_pipe = 1; reset_stage() }
  else judge()

  if (hit) print (label != "" ? label : FILENAME) ":" FNR ":" line
}

END { if (carry_cont) judge() }
