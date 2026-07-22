#!/usr/bin/env bash
# dhx-read-dedup.sh — PreToolUse:Read hook (content-dedup measurement + Guard-2 short-TTL strict deny)
# Patterns: HP-003, HP-007, HP-036
#
# WHAT: the read-once restoration (brief 2026-05-24-read-once-content-dedup-restoration,
# option 2). The read-once content-dedup guard was retired 2026-04-26 (bc45a2e) bundled
# with the read-before-edit ownership rewrite, on a faulty premise. The cross-repo
# token-waste measurement + community web research (docs/research/2026-05-25-read-once-
# community-signal.md) resolved the build/no-build gate as BUILD, warn-mode-first.
#
# PHASE 1 (2026-05-25 → 2026-07-22): LOG-ONLY measurement. Records every Read's line-range
# per (session, agent), detects overlapping re-reads of UNCHANGED files, classifies them
# into the spike's bands (STRICT full->full / BROAD overlapping-partial / NEW no-overlap /
# CHANGED), and logs one event per re-read to a durable stats file.
#
# PHASE 2 / GUARD 2 (ENFORCING since 2026-07-22 — the Phase-2a check-in's precommitted
# SHIP verdict; decisions.md 2026-07-22 row): the SHORT-TTL STRICT DENY. A full->full
# re-read of an UNCHANGED file, < DHX_READ_DEDUP_DENY_GAP (120s) after a prior full read
# IN THE SAME AGENT CONTEXT, with no compaction marker in between, is DENIED via
# permissionDecision:"deny" — the content is still in active context; the deny reason IS
# the substitute (points at the earlier read; council 2026-06-25: additive advisories are
# net-negative, only block-and-substitute pays). Everything outside that gate passes
# through untouched and is logged exactly as Phase 1 did. Zero-blind-work by construction:
# no compaction plausibly lands inside 120s, and the marker check is belt-and-braces.
# The changed-file diff-substitute (Guard 1) was CLOSED on the same check-in data (25%
# gate rate vs >=40%; ~273K tok/mo vs >=1.5M) — do not add it back without new data.
#
# PER-AGENT KEYING (2026-07-22, operator-ratified): subagent tool calls fire this hook
# with the PARENT's session_id but their own agent_id (HP-003 propagation matrix). STATE
# is keyed per (session_id, agent): parent store stays <sid>.jsonl (continuity), subagents
# get <sid>.agent-<agent_id>.jsonl. A parent-then-subagent read pair is therefore NEVER a
# strict double-read (the subagent's context genuinely lacks the file — denying it would
# be the 2026-04-15-class blind-work FP); a double-read WITHIN one agent's context still
# denies. Compaction markers + content snapshots stay session-scoped (markers only ADD
# conservatism → allow; snapshots are Guard-1 telemetry, closed, cross-agent overwrite
# tolerated). Stats events carry an "agent" field ("main" or the agent_id) so post-ship
# telemetry sizes the real per-agent deny rate (the pre-ship 79/wk figure was
# agent-merged — an upper bound; no silent control arm, operator call 2026-07-22).
#
# BORROWED (Boucle tools/read-once + community): hit/changed event model, mtime+TTL
# compaction-awareness (READ_ONCE_TTL=1200 -> DHX_READ_DEDUP_TTL), offset/limit range
# tracking (Egor Fedorov "Context Optimizer" precedent). NOT borrowed: Boucle skips ALL
# partial reads (its hook.sh:53-57) so it only ever saw the STRICT band; capturing the
# BROAD overlapping-partial band (99% of the token mass per the spike) is the whole point.
#
# STATE  (ephemeral, TTL-windowed, session-scoped, pruned — fine to reap):
#   ~/.cache/dhx/read-dedup/<session_id>.jsonl
#   one record per Read: {"path","start","end","mtime","size","ts","seq"[,"lines"]}
#   "lines" (optional) caches the file's line count for THIS version (path+mtime+size) so a
#   hot re-read file is counted once per (session,version), not on every overlap event.
#   "seq" (Phase-2a) is the read's 1-based ordinal in this session (intervening-read proxy for
#   the compaction reconciliation — gap_reads on an event = cur_seq − prior_seq).
#   Two sibling subtrees under the same per-session cache root (Phase-2a, both reapable):
#     read-dedup/content/<session_id>/<path-sha1>     one size-capped content snapshot per
#       (session,path), overwritten each read → a later `changed` re-read diffs against the prior
#       version to size diff_tokens (DHX_READ_DEDUP_SNAPSHOT_MAX_BYTES cap; large thrash-class files skipped).
#     read-dedup/compaction/<session_id>.jsonl        per-session {ts,trigger} markers appended by the
#       companion PreCompact hook dhx-read-dedup-compact-marker.sh (the compaction_since_prior signal).
# STATS  (durable measurement dataset — the Phase-1 deliverable; lives OUTSIDE the cache dir):
#   ~/.local/share/dhx/read-dedup-stats.jsonl  (XDG_DATA_HOME — durable, NOT a reapable cache;
#   relocated 2026-06-09 after skills probe-dhx-sym-parity.sh unconditional-wiped ~/.cache/dhx — see decisions.md)
#   one event per detected re-read: {"ts","path","session","event","range":[s,e],
#       "overlap_lines","overlap_tokens","band",  (event in strict|broad|new|changed)
#       "gap_s","gap_reads","compaction_since_prior",  (Phase-2a, ALL events: gap to most-recent prior read in
#         seconds / in reads; whether a compaction marker fell between that prior read and now. gap_reads=-1 ⇒
#         prior record predates the seq field.)
#       ... and on `changed` events only (Phase-2a diff-substitute sizing — issue #1 of the 2026-06-25 council):
#       "full_tokens","diff_tokens","prior_full","prior_snapshot_available"}  (full re-read cost size/4;
#         real unified-diff cost of the prior→current version; was the prior read full [1,2001); was a content
#         snapshot of the prior version available to diff. diff_tokens=-1 ⇒ no snapshot, unsized.)
#   ADDITIVE schema: Phase-2a added fields only — existing fields (event/range/overlap_tokens/band) keep their
#   meaning (changed events still carry overlap_tokens:0 — zero UNCHANGED overlap is correct; the win lives in
#   the new full_tokens/diff_tokens pair), so the pre-enrichment window stays parseable alongside the new one.
# Token basis: overlap_lines * (file_size/total_lines) / 4 chars/token — the SAME flat
# chars/4 proxy the cross-repo spike used, so the live bands are directly comparable.
# NEVER touches Boucle's ~/.claude/read-once/stats.jsonl (the preserved BEFORE baseline).
#
# Config (env):
#   DHX_READ_DEDUP_TTL=1200       seconds a prior read counts as "still in context"
#                                 (compaction proxy; re-reads after this are not waste)
#   DHX_READ_DEDUP_DISABLED=1     disable entirely (measurement AND deny)
#   DHX_READ_DEDUP_DENY_DISABLED=1  kill-switch for the Guard-2 deny only (measurement
#                                 keeps logging; strict events log as "strict", not "deny")
#   DHX_READ_DEDUP_DENY_GAP=120   Guard-2 window: a full->full unchanged re-read within
#                                 this many seconds of the prior full read (same agent,
#                                 no compaction since) is denied
#   DHX_READ_DEDUP_STATE_DIR=...  override ephemeral cache root (probe/test injection, D-20 convention)
#   DHX_READ_DEDUP_DATA_DIR=...   override durable STATS data root (probe/test injection, D-20 convention)
#   DHX_READ_DEDUP_STATS_MAX_BYTES=5242880  size cap (bytes) for the durable stats log before it
#                                 rotates to a single `.jsonl.1` backup (default 5 MiB ≈ weeks)
#   DHX_READ_DEDUP_SNAPSHOT_MAX_BYTES=262144  Phase-2a: max file size (bytes) to content-snapshot for
#                                 changed-band diff sizing (default 256 KiB — captures the edit-verify
#                                 target population; excludes the gold.md/plan-phase thrash class).
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
  IFS= read -r AGENT_ID
} < <(
  printf '%s' "$INPUT" | jq -r '.tool_name // "", (.tool_input.offset // ""), (.tool_input.limit // ""), .session_id // "", .agent_id // ""' 2>/dev/null
)

# Matcher should scope to Read, but be defensive — only act on Read.
[ "${TOOL_NAME:-}" = "Read" ] || exit 0

# D-11: session_id is an untrusted filename component. Reject-and-disable (NOT sanitize)
# if empty / path-separator / `..` — never write outside the cache dir or collide IDs.
[ -z "${SESSION_ID:-}" ] && exit 0
case "$SESSION_ID" in
  */*|*'\'*|*..*) exit 0 ;;
esac

# Per-agent keying (HP-003): agent_id is populated on subagent tool calls, absent/empty on
# parent-level calls. Same D-11 discipline — it becomes a filename component, so an unsafe
# value disables the hook (reject, never sanitize). Parent store keeps the historical
# un-suffixed name (probe + live-store continuity); subagents get .agent-<id>.
AGENT_ID="${AGENT_ID:-}"
if [ -n "$AGENT_ID" ]; then
  case "$AGENT_ID" in
    */*|*'\'*|*..*) exit 0 ;;
  esac
  AGENT_SUFFIX=".agent-${AGENT_ID}"
  AGENT_LABEL="$AGENT_ID"
else
  AGENT_SUFFIX=""
  AGENT_LABEL="main"
fi

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
SNAP_MAX_BYTES="${DHX_READ_DEDUP_SNAPSHOT_MAX_BYTES:-262144}"  # 256 KiB; skip content snapshot above this
case "$SNAP_MAX_BYTES" in ''|*[!0-9]*) SNAP_MAX_BYTES=262144 ;; esac
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
# Best-effort: STATS append is already `|| true`-guarded, so a DATA_ROOT mkdir failure must NOT
# kill STATE recording (the hook's core function) — decouple it from the STATE_DIR `|| exit 0`.
mkdir -p "$DATA_ROOT" 2>/dev/null || true
STATE_FILE="${STATE_DIR}/${SESSION_ID}${AGENT_SUFFIX}.jsonl"

# Guard-2 deny config (2026-07-22). DENY_ON=1 unless the kill-switch is set; window
# defaults to the check-in's 120s zero-FP slice. Non-numeric window → default.
DENY_ON=1
[ "${DHX_READ_DEDUP_DENY_DISABLED:-0}" = "1" ] && DENY_ON=0
DENY_GAP="${DHX_READ_DEDUP_DENY_GAP:-120}"
case "$DENY_GAP" in ''|*[!0-9]*) DENY_GAP=120 ;; esac

# Phase-2a sibling paths (both under the reapable per-session cache root, NOT the durable data root).
# COMPACT_FILE: per-session compaction-marker log written by the companion PreCompact hook
#   (dhx-read-dedup-compact-marker.sh). The python branch reads it for `compaction_since_prior`.
#   INVARIANT: marker + reader MUST agree on this path — both derive it from STATE_DIR/compaction/<sid>,
#   and both honor DHX_READ_DEDUP_STATE_DIR for fixture injection (probe-read-dedup.sh V-COMPACT-* assert it).
# SNAP_FILE: ONE content snapshot per (session,path), keyed on the canonical realpath via sha1 (avoids
#   path-separator filenames). Overwritten at the end of each read (size-capped) so a later `changed`
#   re-read can diff the prior version. Empty if no hasher is available → snapshot silently disabled.
COMPACT_DIR="${STATE_DIR}/compaction"
COMPACT_FILE="${COMPACT_DIR}/${SESSION_ID}.jsonl"
CONTENT_DIR="${STATE_DIR}/content/${SESSION_ID}"
SNAP_HASH=$(printf '%s' "$RESOLVED" | { sha1sum 2>/dev/null || md5sum 2>/dev/null; } | awk '{print $1}')
case "$SNAP_HASH" in ''|*[!0-9a-fA-F]*) SNAP_FILE="" ;; *) SNAP_FILE="${CONTENT_DIR}/${SNAP_HASH}.snap" ;; esac

# Once-per-hour housekeeping: drop stale session files (>1d) + size-cap the durable stats log.
CLEAN_MARKER="${STATE_DIR}/.last-cleanup"
LAST_CLEAN=$(cat "$CLEAN_MARKER" 2>/dev/null || echo 0); LAST_CLEAN=${LAST_CLEAN:-0}
case "$LAST_CLEAN" in *[!0-9]*) LAST_CLEAN=0 ;; esac
if [ $(( NOW - LAST_CLEAN )) -gt 3600 ]; then
  find "$STATE_DIR" -name '*.jsonl' -mtime +1 -delete 2>/dev/null || true
  # Phase-2a: reap stale content snapshots (not *.jsonl, so the line above misses them) + empty session
  # dirs. Compaction markers ARE *.jsonl under STATE_DIR → already reaped by the find above.
  find "$STATE_DIR/content" -type f -mtime +1 -delete 2>/dev/null || true
  find "$STATE_DIR/content" -type d -empty -delete 2>/dev/null || true
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

# Phase-2a: this read's 1-based session ordinal = (prior reads of ALL paths) + 1. Recorded in the state
# record (`seq`) so a future event can log gap_reads = cur_seq − prior_seq (intervening-read proxy).
SEQ=0
[ -f "$STATE_FILE" ] && SEQ=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
SEQ=${SEQ:-0}
case "$SEQ" in *[!0-9]*) SEQ=0 ;; esac
SEQ=$(( SEQ + 1 ))

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
      "$RESOLVED" "$SESSION_ID" "$START" "$END" "$CUR_MTIME" "$CUR_SIZE" "$NOW" "$TTL" \
      "$SNAP_FILE" "$COMPACT_FILE" "$SEQ" "$DENY_ON" "$DENY_GAP" "$AGENT_LABEL" <<'PY' 2>/dev/null || true
import sys, os, json, difflib
path, session = sys.argv[1], sys.argv[2]
cs, ce = int(sys.argv[3]), int(sys.argv[4])
cmtime, csize = sys.argv[5], sys.argv[6]
now, ttl = int(sys.argv[7]), int(sys.argv[8])
# Phase-2a argv: snapshot path (may be ""), compaction-marker path, this read's session ordinal.
snap_file = sys.argv[9] if len(sys.argv) > 9 else ""
compact_file = sys.argv[10] if len(sys.argv) > 10 else ""
try:
    cur_seq = int(sys.argv[11])
except (IndexError, ValueError):
    cur_seq = -1
# Guard-2 argv (2026-07-22): deny enabled flag, deny window seconds, agent label.
# Defaults fail toward NOT denying (a malformed argv must never block a Read).
try:
    deny_on = sys.argv[12] == "1"
except IndexError:
    deny_on = False
try:
    deny_gap = int(sys.argv[13])
except (IndexError, ValueError):
    deny_gap = 120
agent = sys.argv[14] if len(sys.argv) > 14 else "main"

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

# --- Phase-2a universal fields (every re-read event carries these) ---
prior_ts = int(most_recent.get("ts", 0))
gap_s = now - prior_ts   # seconds since the most-recent prior read of this path (Guard-1 <120s slice)

# gap_reads: intervening reads since that prior (the proxy compaction signal). -1 if the prior record
# predates the seq field (pre-enrichment window) or this read's seq is unknown.
ms_seq = most_recent.get("seq")
try:
    gap_reads = cur_seq - int(ms_seq) if (cur_seq >= 0 and ms_seq is not None) else -1
except (TypeError, ValueError):
    gap_reads = -1

# compaction_since_prior: did a PreCompact marker land between the prior read and now? The companion
# hook appends {ts,trigger} per session; here we only need the boolean (the gate is "no-compaction-since").
compaction_since_prior = False
if compact_file:
    try:
        with open(compact_file) as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    m = json.loads(ln)
                except Exception:
                    continue
                mts = int(m.get("ts", 0))
                if prior_ts < mts <= now:
                    compaction_since_prior = True
                    break
    except Exception:
        pass

def emit(event, overlap_lines, overlap_tokens, band, extra=None):
    rec = {
        "ts": now, "path": path, "session": session, "event": event,
        "range": [cs, ce], "overlap_lines": overlap_lines,
        "overlap_tokens": overlap_tokens, "band": band,
        "gap_s": gap_s, "gap_reads": gap_reads,
        "compaction_since_prior": compaction_since_prior,
        "agent": agent,
    }
    if extra:
        rec.update(extra)
    print(json.dumps(rec, separators=(",", ":")))

if changed:
    # Re-read of a genuinely CHANGED file. Not unchanged-overlap waste — but the diff-substitute target
    # (the 2026-06-25 council's Guard 2). Size it: full_tokens = full re-read cost (size/4, spike-basis);
    # diff_tokens = real unified-diff cost prior→current IF a snapshot of the prior version was cached.
    # overlap_tokens stays 0 (zero UNCHANGED overlap is correct; the win is full−diff). The check-in reads
    # the fraction clearing predicted-full ≥~1500 / diff ≤~700 / prior-full-cached / no-compaction-since.
    full_tokens = int(round(int(csize) / 4)) if csize else 0
    # prior_full: was a FULL read [1,2001) of the prior version cached (so a diff would reconstruct it)?
    old_ver = [r for r in priors
               if str(r.get("mtime")) == str(most_recent.get("mtime"))
               and str(r.get("size")) == str(most_recent.get("size"))]
    prior_full = any(int(r.get("start", 0)) == 1 and int(r.get("end", 0)) == 2001 for r in old_ver)
    diff_tokens = -1            # sentinel: not sized (no usable prior snapshot)
    snapshot_available = False
    if snap_file and os.path.exists(snap_file):
        try:
            with open(snap_file, "r", errors="replace") as fh:
                old_lines = fh.readlines()
            with open(path, "r", errors="replace") as fh:
                new_lines = fh.readlines()
            diff_bytes = sum(len(x) for x in difflib.unified_diff(old_lines, new_lines, n=3))
            diff_tokens = int(round(diff_bytes / 4))
            snapshot_available = True
        except Exception:
            pass
    emit("changed", 0, 0, "none", extra={
        "full_tokens": full_tokens, "diff_tokens": diff_tokens,
        "prior_full": prior_full, "prior_snapshot_available": snapshot_available,
    })
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

# --- Guard-2 short-TTL strict deny (2026-07-22 check-in SHIP verdict) ---
# Gate, ALL required: strict band (full->full, unchanged version — the same_ver filter
# above already pinned mtime+size) AND within the deny window AND no compaction marker
# since the prior read AND deny enabled. Everything else logs and allows, as Phase 1 did.
# The event is logged as "deny" (band stays "strict") so post-ship telemetry separates
# enforced from observed; the schema stays additive — analyzers keying on the Phase-1
# event set simply don't see denies.
if band == "strict" and deny_on and gap_s < deny_gap and not compaction_since_prior:
    emit("deny", overlap, overlap_tokens, band)
    sys.exit(0)

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

  # --- Guard-2 deny emission (2026-07-22) ---
  # python only emits event:"deny" when the full gate held (strict + <window + no
  # compaction + enabled). Emit the structured deny and exit WITHOUT recording this read:
  # the content was NOT re-injected, and recording the denied attempt would refresh the
  # prior-read timestamp — extending the deny window past actual context residency.
  # INVARIANT: fail toward ALLOW — if the jq emit fails for any reason, fall through to
  # normal recording and the Read proceeds (a broken deny must never block work).
  if [ -n "${EVENT_JSON:-}" ] && printf '%s' "$EVENT_JSON" | jq -e '.event == "deny"' >/dev/null 2>&1; then
    DENY_GAP_S=$(printf '%s' "$EVENT_JSON" | jq -r '.gap_s // "?"' 2>/dev/null)
    BASE_NAME="${RESOLVED##*/}"
    REASON="READ-DEDUP DENY: \"${BASE_NAME}\" was fully read ${DENY_GAP_S}s ago in this same context and is unchanged on disk (mtime+size match) — its full content is already in your context; use that instead of re-reading. A ranged Read (offset/limit) is not blocked if you need specific lines. Full re-reads are allowed again after ${DENY_GAP}s, after the file changes, or after a compaction."
    MSG="read-dedup: denied full re-read of ${BASE_NAME} (unchanged, read ${DENY_GAP_S}s ago; ~saved $(printf '%s' "$EVENT_JSON" | jq -r '.overlap_tokens // 0' 2>/dev/null) tok)"
    if DENY_JSON=$(jq -cn --arg r "$REASON" --arg m "$MSG" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r},systemMessage:$m}' 2>/dev/null); then
      printf '%s\n' "$DENY_JSON"
      exit 0
    fi
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
         --argjson seq "$SEQ" --argjson lines "$LINES_HINT" \
         '{path:$path,start:$start,end:$end,mtime:$mtime,size:$size,ts:$ts,seq:$seq,lines:$lines}' \
         >> "$STATE_FILE" 2>/dev/null || true
else
  jq -cn --arg path "$RESOLVED" --argjson start "$START" --argjson end "$END" \
         --arg mtime "$CUR_MTIME" --arg size "$CUR_SIZE" --argjson ts "$NOW" \
         --argjson seq "$SEQ" \
         '{path:$path,start:$start,end:$end,mtime:$mtime,size:$size,ts:$ts,seq:$seq}' \
         >> "$STATE_FILE" 2>/dev/null || true
fi

# Phase-2a: snapshot current content for changed-band diff sizing. One file per (session,path),
# overwritten each read so a later `changed` re-read diffs against THIS (the now-prior) version. Size-
# capped (the edit-verify target is small; the thrash-class large files are skipped, logged downstream as
# prior_snapshot_available:false). INVARIANT: SNAP_FILE keys on the same RESOLVED realpath as the records.
if [ -n "${SNAP_FILE:-}" ] && [ "${CUR_SIZE:-0}" -le "$SNAP_MAX_BYTES" ]; then
  mkdir -p "$CONTENT_DIR" 2>/dev/null && cp -f "$RESOLVED" "$SNAP_FILE" 2>/dev/null || true
fi

exit 0
