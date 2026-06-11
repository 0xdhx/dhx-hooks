#!/usr/bin/env bash
# dhx-read-dedup.sh — PreToolUse:Read hook (content-dedup re-read MEASUREMENT, log-only)
# Patterns: HP-003, HP-007, HP-036
#
# WHAT: the read-once restoration (brief 2026-05-24-read-once-content-dedup-restoration,
# option 2). The read-once content-dedup guard was retired 2026-04-26 (bc45a2e) bundled
# with the read-before-edit ownership rewrite, on a faulty premise. The cross-repo
# token-waste measurement + community web research (docs/research/2026-05-25-read-once-
# community-signal.md) resolved the build/no-build gate as BUILD, warn-mode-first.
#
# PHASE 1 (this file): LOG-ONLY. Records every Read's line-range per session, detects
# overlapping re-reads of UNCHANGED files, classifies them into the spike's bands
# (STRICT full->full / BROAD overlapping-partial / NEW no-overlap / CHANGED), and logs
# one event per re-read to a durable stats file. It emits NOTHING to Claude's context
# (always exit 0, no stdout) — for two reasons:
#   (1) "don't cost attention that doesn't pay its weight" — an advisory on every re-read
#       (~232/day broad-band) would make the hook the leak it measures;
#   (2) OBSERVER EFFECT — an advisory changes Claude's re-read behavior, tainting the very
#       measurement we are taking. Log-only is a clean observational study of natural
#       re-read behavior in the AFTER (unguarded) window.
# PHASE 2 (data-gated follow-up): selective warn + diff advisory for the high-value cases
# the Phase-1 data identifies (large full->full unchanged re-reads; diff-mode for edit-
# verify loops). PHASE 3 (if ever): narrow deny. See the brief §6/§7 + decisions.md.
#
# BORROWED (Boucle tools/read-once + community): hit/changed event model, mtime+TTL
# compaction-awareness (READ_ONCE_TTL=1200 -> DHX_READ_DEDUP_TTL), offset/limit range
# tracking (Egor Fedorov "Context Optimizer" precedent). NOT borrowed: Boucle skips ALL
# partial reads (its hook.sh:53-57) so it only ever saw the STRICT band; capturing the
# BROAD overlapping-partial band (99% of the token mass per the spike) is the whole point.
#
# STATE  (ephemeral, TTL-windowed, session-scoped, pruned — fine to reap):
#   ~/.cache/dhx/read-dedup/<session_id>.jsonl
#   one record per Read: {"path","start","end","mtime","size","ts"[,"lines"]}
#   "lines" (optional) caches the file's line count for THIS version (path+mtime+size) so a
#   hot re-read file is counted once per (session,version), not on every overlap event.
# STATS  (durable measurement dataset — the Phase-1 deliverable; lives OUTSIDE the cache dir):
#   ~/.local/share/dhx/read-dedup-stats.jsonl  (XDG_DATA_HOME — durable, NOT a reapable cache;
#   relocated 2026-06-09 after skills probe-dhx-sym-parity.sh unconditional-wiped ~/.cache/dhx — see decisions.md)
#   one event per detected re-read: {"ts","path","session","event","range":[s,e],
#       "overlap_lines","overlap_tokens","band"}  (event in strict|broad|new|changed)
# Token basis: overlap_lines * (file_size/total_lines) / 4 chars/token — the SAME flat
# chars/4 proxy the cross-repo spike used, so the live bands are directly comparable.
# NEVER touches Boucle's ~/.claude/read-once/stats.jsonl (the preserved BEFORE baseline).
#
# Config (env):
#   DHX_READ_DEDUP_TTL=1200       seconds a prior read counts as "still in context"
#                                 (compaction proxy; re-reads after this are not waste)
#   DHX_READ_DEDUP_DISABLED=1     disable entirely
#   DHX_READ_DEDUP_STATE_DIR=...  override ephemeral cache root (probe/test injection, D-20 convention)
#   DHX_READ_DEDUP_DATA_DIR=...   override durable STATS data root (probe/test injection, D-20 convention)
#   DHX_READ_DEDUP_STATS_MAX_BYTES=5242880  size cap (bytes) for the durable stats log before it
#                                 rotates to a single `.jsonl.1` backup (default 5 MiB ≈ weeks)
#
# Fires: PreToolUse on the Read tool. Action: state-write + stats-log only; no stdout,
# no blocking, never fails the tool call (set -uo, not -e — dhx convention).
#
# COST NOTE — "log-only" means zero CONTEXT cost, NOT free. Each Read forks ~6 procs
# (jq×2, realpath, stat×2, grep); a re-read adds a python3 proc. The full-file line count
# it needs is cached per (path,mtime,size) in the STATE record, so a hot re-read file is
# counted ONCE per (session,version) instead of on every overlap event (was a full-file
# read per re-read — the measurer doing its own re-reads; brief §0 Phase-2 cost item).
# State files are pruned (TTL + hourly stale-session sweep). The durable read-dedup-stats.jsonl
# is size-capped: when it exceeds DHX_READ_DEDUP_STATS_MAX_BYTES (default 5 MiB) the hourly
# housekeeping rotates it to a single `.jsonl.1` backup (bounded at ~2× cap ≈ several weeks of
# data; older events are dropped — raise the cap if a longer retention window is wanted).
# `timeout:5` (manifest) is a kill-switch, not a latency budget.
# (drain LOW-2, codex 2026-05-25 — Phase-2 cost follow-ups landed 2026-06-11; brief §0.)

set -uo pipefail   # NOT -e; a hook error must never fail the user's Read.

[ "${DHX_READ_DEDUP_DISABLED:-0}" = "1" ] && exit 0

INPUT=$(cat)

# --- parse (2 jq forks: file_path alone since it can hold spaces; rest as TSV) ---
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# One field per line (NOT @tsv): tab is IFS-whitespace, so `read` collapses the empty
# offset/limit fields of a full read and mis-assigns session_id. Line-per-field with
# `IFS= read` keeps empty fields as empty lines. (offset/limit/session_id/tool_name
# never contain newlines; file_path — which could — is extracted separately above.)
{
  IFS= read -r TOOL_NAME
  IFS= read -r OFFSET
  IFS= read -r LIMIT
  IFS= read -r SESSION_ID
} < <(
  printf '%s' "$INPUT" | jq -r '.tool_name // "", (.tool_input.offset // ""), (.tool_input.limit // ""), .session_id // ""' 2>/dev/null
)

# Matcher should scope to Read, but be defensive — only act on Read.
[ "${TOOL_NAME:-}" = "Read" ] || exit 0

# D-11: session_id is an untrusted filename component. Reject-and-disable (NOT sanitize)
# if empty / path-separator / `..` — never write outside the cache dir or collide IDs.
[ -z "${SESSION_ID:-}" ] && exit 0
case "$SESSION_ID" in
  */*|*'\'*|*..*) exit 0 ;;
esac

# IN-02: realpath so overlap keys on the canonical inode path.
RESOLVED=$(realpath "$FILE_PATH" 2>/dev/null || printf '%s' "$FILE_PATH")
# File must exist to stat it; if not, let Read surface the error.
[ -f "$RESOLVED" ] || exit 0

CUR_MTIME=$(stat -c '%Y' "$RESOLVED" 2>/dev/null || printf '')
CUR_SIZE=$(stat -c '%s' "$RESOLVED" 2>/dev/null || printf '')
[ -z "$CUR_MTIME" ] && exit 0
[ -z "$CUR_SIZE" ] && exit 0

# --- read range (CC page size = 2000 lines; full read modelled as [1,2001) like the spike) ---
# offset = 1-based start line; limit = line count. Defaults: offset->1, limit->2000.
RS="${OFFSET:-}"; RL="${LIMIT:-}"
[ -z "$RS" ] && RS=1
if [ -z "$RL" ]; then
  END=$(( RS + 2000 ))
else
  END=$(( RS + RL ))
fi
START="$RS"
# Guard against pathological non-numeric (jq already coerced; belt-and-suspenders).
case "$START$END" in *[!0-9]*) exit 0 ;; esac

NOW=$(date +%s)
TTL="${DHX_READ_DEDUP_TTL:-1200}"

# Two roots, two lifetimes. STATE is per-session ephemeral and STAYS in the cache dir (fine to
# reap). STATS is the durable Phase-1 measurement and must NOT live in an XDG *cache* dir —
# that's semantically reapable (skills probe-dhx-sym-parity.sh unconditional-wiped ~/.cache/dhx
# 05-25→06-08; cleanupPeriodDays-style sweeps would too). It lives under XDG_DATA_HOME instead.
# INVARIANT: STATS_FILE's root must differ from the cache/STATE root, so a cache reap cannot take
# the durable dataset. probe-read-dedup.sh V-DURABLE-SPLIT asserts this (wipes cache, confirms
# STATS survives). Each root carries its own D-20 fixture-injection override.
CACHE_ROOT="${DHX_READ_DEDUP_STATE_DIR:-${HOME}/.cache/dhx}"
DATA_ROOT="${DHX_READ_DEDUP_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/dhx}"
STATE_DIR="${CACHE_ROOT}/read-dedup"
STATS_FILE="${DATA_ROOT}/read-dedup-stats.jsonl"
STATS_MAX_BYTES="${DHX_READ_DEDUP_STATS_MAX_BYTES:-5242880}"   # 5 MiB; rotate to .1 above this
case "$STATS_MAX_BYTES" in ''|*[!0-9]*) STATS_MAX_BYTES=5242880 ;; esac
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
# Best-effort: STATS append is already `|| true`-guarded, so a DATA_ROOT mkdir failure must NOT
# kill STATE recording (the hook's core function) — decouple it from the STATE_DIR `|| exit 0`.
mkdir -p "$DATA_ROOT" 2>/dev/null || true
STATE_FILE="${STATE_DIR}/${SESSION_ID}.jsonl"

# Once-per-hour housekeeping: drop stale session files (>1d) + size-cap the durable stats log.
CLEAN_MARKER="${STATE_DIR}/.last-cleanup"
LAST_CLEAN=$(cat "$CLEAN_MARKER" 2>/dev/null || echo 0); LAST_CLEAN=${LAST_CLEAN:-0}
case "$LAST_CLEAN" in *[!0-9]*) LAST_CLEAN=0 ;; esac
if [ $(( NOW - LAST_CLEAN )) -gt 3600 ]; then
  find "$STATE_DIR" -name '*.jsonl' -mtime +1 -delete 2>/dev/null || true
  # Size-cap the durable, append-only stats log. STATE is pruned by the find above, but STATS
  # lives under XDG_DATA_HOME (durable by design) so it can't be TTL-reaped — bound it here.
  # Single-backup rotation: over the cap, the current log becomes the .1 backup (overwriting
  # any prior .1) and a fresh log starts → bounded at ~2× cap; older events drop.
  SSIZE=$(stat -c '%s' "$STATS_FILE" 2>/dev/null || echo 0)
  case "$SSIZE" in ''|*[!0-9]*) SSIZE=0 ;; esac
  if [ "$SSIZE" -gt "$STATS_MAX_BYTES" ]; then
    mv -f "$STATS_FILE" "${STATS_FILE}.1" 2>/dev/null || true
  fi
  printf '%s' "$NOW" > "$CLEAN_MARKER" 2>/dev/null || true
fi

# --- detect re-read: prior records for THIS path in THIS session ---
# Fast path: no prior record for the path -> first read -> just record it, no stats event.
PRIORS=""
LINES_HINT=""   # set by the re-read branch when python resolves a line count to cache
if [ -f "$STATE_FILE" ]; then
  PRIORS=$(grep -F "\"path\":\"${RESOLVED}\"" "$STATE_FILE" 2>/dev/null || true)
fi

if [ -n "$PRIORS" ] && command -v python3 >/dev/null 2>&1; then
  # python3 owns the interval-union overlap + band classification + token estimate.
  # Script comes via the heredoc (stdin); prior records via $PRIORS_DATA env (so the
  # heredoc and the data don't both contend for stdin); scalars via argv.
  PY_OUT=$(PRIORS_DATA="$PRIORS" python3 - \
      "$RESOLVED" "$SESSION_ID" "$START" "$END" "$CUR_MTIME" "$CUR_SIZE" "$NOW" "$TTL" <<'PY' 2>/dev/null || true
import sys, os, json
path, session = sys.argv[1], sys.argv[2]
cs, ce = int(sys.argv[3]), int(sys.argv[4])
cmtime, csize = sys.argv[5], sys.argv[6]
now, ttl = int(sys.argv[7]), int(sys.argv[8])

priors = []
for line in os.environ.get("PRIORS_DATA", "").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    # TTL window: a read at/older than TTL is treated as scrolled-out / post-compaction,
    # i.e. no longer "in context" -> not counted toward overlap. `>=` matches Boucle's
    # expire-at-TTL semantics exactly (hook.sh ENTRY_AGE >= TTL).
    if now - int(r.get("ts", 0)) >= ttl:
        continue
    priors.append(r)

if not priors:
    # all prior reads aged out of the TTL window -> treat as fresh, no waste event.
    sys.exit(0)

most_recent = max(priors, key=lambda r: int(r.get("ts", 0)))
changed = (str(most_recent.get("mtime")) != str(cmtime)) or (str(most_recent.get("size")) != str(csize))

def emit(event, overlap_lines, overlap_tokens, band):
    print(json.dumps({
        "ts": now, "path": path, "session": session, "event": event,
        "range": [cs, ce], "overlap_lines": overlap_lines,
        "overlap_tokens": overlap_tokens, "band": band,
    }, separators=(",", ":")))

if changed:
    # Re-read of a genuinely changed file = legitimate (new content). Not waste.
    # (Phase 2 may diff-serve these; Phase 1 just records the class.)
    emit("changed", 0, 0, "none")
    sys.exit(0)

# Unchanged file: union the ranges of prior reads of THIS version (same mtime+size).
same_ver = [r for r in priors
            if str(r.get("mtime")) == str(cmtime) and str(r.get("size")) == str(csize)]
intervals = sorted((int(r["start"]), int(r["end"])) for r in same_ver
                   if "start" in r and "end" in r)
# Merge prior intervals.
merged = []
for s, e in intervals:
    if merged and s <= merged[-1][1]:
        merged[-1] = (merged[-1][0], max(merged[-1][1], e))
    else:
        merged.append((s, e))

# Compute the file's real line extent FIRST — overlap must not count lines that don't
# exist. A "full read" models [1,2001) regardless of file length, and a partial read can
# extend past EOF (offset+limit > file lines), so clamp every interval to [1, file_end)
# BEFORE counting. (drain catch #MED-1, codex 2026-05-25: the prior post-hoc
# min(overlap, total_lines) only caught full->full; an EOF-crossing partial like [250,450)
# on a 300-line file reported 200 overlap lines when ~51 exist, inflating the BROAD band.)
# The line count is a property of the file VERSION (path+mtime+size). Reuse it from a prior
# same-version read record that already cached it, so a hot re-read file is counted once per
# (session,version) — not on every overlap event. (brief §0 Phase-2 cost item: stop the
# read-waste measurer from doing its own full-file read on each re-read.)
total_lines = None
for r in same_ver:
    cl = r.get("lines")
    if cl is not None:
        try:
            cl = int(cl)
        except (TypeError, ValueError):
            cl = None
        if cl and cl > 0:
            total_lines = cl
            break
if total_lines is None:
    try:
        with open(path, "rb") as fh:
            total_lines = sum(1 for _ in fh) or 1
    except Exception:
        total_lines = max(int(csize) // 50, 1)  # ~50 B/line fallback
# Hand the resolved count back to the shell (first stdout line, stripped before the stats
# append) so it lands in THIS read's state record and future same-version re-reads hit the
# cache above instead of re-counting.
print("#L%d" % total_lines)
file_end = total_lines + 1   # exclusive upper bound of lines that actually exist

# Lines of the current [cs,ce) already covered by the prior union — every interval
# clamped to the real file extent so past-EOF range never counts.
overlap = 0
for s, e in merged:
    lo = max(s, cs, 1)
    hi = min(e, ce, file_end)
    if hi > lo:
        overlap += hi - lo
if overlap <= 0:
    emit("new", 0, 0, "none")   # non-overlapping (or wholly-past-EOF) region: new content.
    sys.exit(0)

# Token estimate: overlapping REAL lines * avg bytes/line / 4 — the spike's flat chars/4 proxy.
avg_line_bytes = int(csize) / total_lines if total_lines else 0
overlap_tokens = int(round(overlap * avg_line_bytes / 4))

# Band uses the UNCLAMPED full-read model — band is about read INTENT, not file length.
cur_full = (cs == 1 and ce == 2001)
prior_full = any(s == 1 and e == 2001 for s, e in merged)
band = "strict" if (cur_full and prior_full) else "broad"
emit(band, overlap, overlap_tokens, band)
PY
  )
  # python may prepend a `#L<n>` line-count hint as the first stdout line (so bash can cache
  # it into this read's state record). Split it off; the remainder is the stats event JSON.
  EVENT_JSON="$PY_OUT"
  case "$PY_OUT" in
    '#L'*)
      first="${PY_OUT%%$'\n'*}"
      LINES_HINT="${first#\#L}"
      if [ "$first" = "$PY_OUT" ]; then
        EVENT_JSON=""                    # hint only, no event line followed
      else
        EVENT_JSON="${PY_OUT#*$'\n'}"    # everything after the first newline
      fi
      ;;
  esac
  case "$LINES_HINT" in ''|*[!0-9]*) LINES_HINT="" ;; esac
  if [ -n "${EVENT_JSON:-}" ]; then
    # WR-01: the JSON is already escaped by python's json.dumps; atomic O_APPEND write.
    printf '%s\n' "$EVENT_JSON" >> "$STATS_FILE" 2>/dev/null || true
  fi
fi

# --- always record this read so future reads can detect overlap against it ---
# WR-01: jq escapes the path (quotes/backslashes) so the JSONL never corrupts; the
# prefilter grep above keys on the same `"path":"<realpath>"` shape jq emits.
# REQ READ-06: bash `>>` is one atomic open(O_APPEND)+write() (< PIPE_BUF); no lock needed
# (single logical writer per session; concurrent subagent appends stay line-atomic).
# Carry the cached line count (LINES_HINT, set on a re-read) into the record so the next
# same-version re-read reuses it instead of re-counting the whole file. First reads have no
# hint → no `lines` field (the first re-read computes + caches it).
if [ -n "${LINES_HINT:-}" ]; then
  jq -cn --arg path "$RESOLVED" --argjson start "$START" --argjson end "$END" \
         --arg mtime "$CUR_MTIME" --arg size "$CUR_SIZE" --argjson ts "$NOW" \
         --argjson lines "$LINES_HINT" \
         '{path:$path,start:$start,end:$end,mtime:$mtime,size:$size,ts:$ts,lines:$lines}' \
         >> "$STATE_FILE" 2>/dev/null || true
else
  jq -cn --arg path "$RESOLVED" --argjson start "$START" --argjson end "$END" \
         --arg mtime "$CUR_MTIME" --arg size "$CUR_SIZE" --argjson ts "$NOW" \
         '{path:$path,start:$start,end:$end,mtime:$mtime,size:$size,ts:$ts}' \
         >> "$STATE_FILE" 2>/dev/null || true
fi

exit 0
