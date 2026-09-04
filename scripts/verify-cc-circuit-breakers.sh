#!/usr/bin/env bash
# scripts/verify-cc-circuit-breakers.sh — set-drift monitor for Claude Code's permission
# circuit-breaker registry and the bypass-mode reducer that consults it.
#
# WHY THIS EXISTS. CC 2.1.259 added `deniedPathInsideDirectory:{bypassImmune:!0,...}` to the
# registry that decides which permission asks `bypassPermissions` cannot clear. Nothing local
# changed, a prompt storm followed, and it took two sessions to date the binary. 2.1.260
# removed the entry again. This script would have named the addition at the first session
# start on the new build. It replaces `dhx/dhx-cd-compound-read-allow.sh`, the command-mutating
# workaround that arc produced (retired 2026-09-04 — docs/decisions.md row of that date).
#
# WHAT IT CHECKS, per installed executable under ~/.local/share/claude/versions/:
#   1. REGISTRY — every `<key>:{bypassImmune:!X,classifierRouted:!Y}` entry of the registry
#      object, parsed to the object's STRUCTURAL TERMINATOR (brace walk), never a byte window:
#      new entries are precisely the event being monitored, and a window truncates the tail.
#      The full key -> flags map is compared, so a renamed key, a flipped flag, or a new key
#      all surface — a name-grep for one tag would miss the first and the third.
#   2. REDUCER — the ordered sequence of string literals and property names inside the
#      permission reducer from `checkPermissions(` to the bypass-mode
#      `return{behavior:"allow",updatedInput:` — the early-ask categories and their order.
#      A build could restore prompting with no registry change at all by inserting an
#      early-ask exception ahead of that return; this fingerprint is identifier-free, so
#      minifier churn cannot fake a drift and a real reorder cannot hide.
#   3. GENERIC BRANCH — the `bashMissKind:"cd-compound-read"` ask must stay `type:"other"`
#      with no `circuitBreaker`. ABSENT is reported, not failed: an upstream deletion of the
#      generic ask strengthens the retirement premise rather than weakening it.
#
# FAIL CLOSED. An empty extraction is exit 2, never a pass: the shape of this repo's `find`
# false-clean trap (docs/troubleshooting.md) is exactly an anchor that stops matching while the
# loop prints nothing and reads green. The anchors are stable literals (real flag names, real
# property names, the `bypassImmune:` token), never minified identifiers.
#
# WHERE IT RUNS. The local SessionStart path (dhx-plugin/plugins/dhx/hooks/session-start.sh),
# NOT CI: the GitHub-hosted runner has no ~/.local/share/claude/versions/ and would pass
# vacuously forever. Silent on the happy path; a drift or an extraction failure is a stderr
# advisory. Fail-open at the call site (the dispatcher appends `|| true`).
#
# CACHE. A clean verdict is cached per executable identity (name + size + mtime, with the
# sha256 recorded inside the cache file) so repeat session starts cost one `stat` per build.
# A drift is never cached — it re-reports every session until the baseline is updated.
#
# USAGE
#   bash scripts/verify-cc-circuit-breakers.sh                 # check every installed build
#   bash scripts/verify-cc-circuit-breakers.sh --print <exe>   # emit the snapshot for a build
#   bash scripts/verify-cc-circuit-breakers.sh --no-cache      # force re-extraction
# Baseline: config/cc-circuit-breakers.txt (regenerate with --print after a REVIEWED drift).
#
# Override seams (probes): CC_VERSIONS_DIR, CC_CB_BASELINE, CC_CB_CACHE_DIR.
#
# EXIT CODES
#   0  every installed build matches the baseline (or the verdict was cached clean)
#   1  at least one build DRIFTED from the baseline — read the diff on stderr
#   2  an extraction came back EMPTY on at least one build — the anchors need re-deriving
#   3  usage / baseline missing

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_DIR="${CC_VERSIONS_DIR:-$HOME/.local/share/claude/versions}"
BASELINE="${CC_CB_BASELINE:-$REPO/config/cc-circuit-breakers.txt}"
CACHE_DIR="${CC_CB_CACHE_DIR:-$HOME/.cache/dhx/cc-circuit-breakers}"
TAG="[cc-circuit-breakers]"

MODE=check; NO_CACHE=0; PRINT_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print) MODE=print; PRINT_TARGET="${2:-}"; shift ;;
    --no-cache) NO_CACHE=1 ;;
    -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
    *) echo "$TAG unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done

# --- byte helpers ----------------------------------------------------------------------------
# All reads are `tail -c +N | head -c M` seeks: a 216MB executable is grep-able with -a, but a
# `.{0,600}` context regex over it backtracks for minutes. Offsets come from `grep -aob`.
first_offset() { command grep -aob -- "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }
seek() {  # seek <file> <offset> <len>  (offset 0-based; nulls stripped)
  local o=$2; [ "$o" -lt 0 ] && o=0
  tail -c +$((o + 1)) "$1" 2>/dev/null | head -c "$3" | tr -d '\000'
}

# --- 1. registry -----------------------------------------------------------------------------
# Anchor on the first `bypassImmune:` token (a real property name), back up to the `{` that
# opens the enclosing object, then brace-walk forward to its terminator.
extract_registry() {
  local exe=$1 off chunk
  off=$(first_offset '{bypassImmune:!' "$exe")
  [ -n "$off" ] || return 1
  # Registry keys are short; 400 bytes before the first entry is ample to find the `={`.
  chunk=$(seek "$exe" $((off - 400)) 4400)
  printf '%s' "$chunk" | awk '
    { buf = buf $0 }
    END {
      # The registry object opens at the last "={" before the first bypassImmune token.
      t = index(buf, "{bypassImmune:!"); if (!t) exit 1
      head = substr(buf, 1, t - 1)
      start = 0
      while ((p = index(head, "={")) > 0) { start += p + 1; head = substr(head, p + 2) }
      if (!start) exit 1
      body = substr(buf, start)                  # begins at the opening brace of the literal
      depth = 0; end = 0
      for (i = 1; i <= length(body); i++) {
        c = substr(body, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { end = i; break } }
      }
      if (!end) exit 1
      obj = substr(body, 1, end)
      # One line per entry, in source order.
      while (match(obj, /[A-Za-z_$][A-Za-z0-9_$]*:\{bypassImmune:![01],classifierRouted:![01]\}/)) {
        e = substr(obj, RSTART, RLENGTH); obj = substr(obj, RSTART + RLENGTH)
        key = e; sub(/:.*/, "", key)
        bi = (e ~ /bypassImmune:!0/) ? 1 : 0
        cr = (e ~ /classifierRouted:!0/) ? 1 : 0
        printf "registry %s bypassImmune=%d classifierRouted=%d\n", key, bi, cr
      }
    }'
}

# --- 2. reducer fingerprint ------------------------------------------------------------------
# Anchor: the literal `reason:"requiresUserInteraction"` sits inside the reducer between the
# two bounds. Take a window around it, cut from `checkPermissions(` to the first bypass-mode
# allow return after it, and keep only quoted literals and multi-char property accesses —
# never bare identifiers, which the minifier renames per build.
extract_reducer() {
  local exe=$1 off chunk found=0
  # Every occurrence: the literal also appears in an inner helper that returns null before
  # any mode logic; only the outer reducer has the allow-return within reach of it.
  for off in $(command grep -aob -- 'reason:"requiresUserInteraction"' "$exe" 2>/dev/null | cut -d: -f1); do
    chunk=$(seek "$exe" $((off - 1200)) 2800)
    out=$(printf '%s' "$chunk" | awk '
      { buf = buf $0 }
      END {
        a = index(buf, "reason:\"requiresUserInteraction\""); if (!a) exit 1
        head = substr(buf, 1, a - 1); tail = substr(buf, a)
        s = 0; h = head
        while ((p = index(h, "checkPermissions(")) > 0) { s += p; h = substr(h, p + 1) }
        if (!s) exit 1
        e = index(tail, "return{behavior:\"allow\",updatedInput:"); if (!e) exit 1
        seg = substr(buf, s, (a - s) + e - 1)
        n = 0
        while (match(seg, /"[A-Za-z_-]+"|\.[A-Za-z][A-Za-z0-9]{3,}/)) {
          tok = substr(seg, RSTART, RLENGTH); seg = substr(seg, RSTART + RLENGTH)
          printf "reducer %s\n", tok; n++
        }
        if (n < 8) exit 1
      }') || continue
    [ -n "$out" ] || continue
    printf '%s\n' "$out"; found=1
  done
  [ "$found" -eq 1 ]
}

# --- 3. generic branch -----------------------------------------------------------------------
extract_generic() {
  local exe=$1 off chunk
  off=$(first_offset 'bashMissKind:"cd-compound-read"' "$exe")
  if [ -z "$off" ]; then echo "generic absent"; return 0; fi
  chunk=$(seek "$exe" $((off - 400)) 460)
  # The decisionReason object that carries the tag: text between the last `decisionReason:{`
  # before the tag and the tag itself.
  local reason; reason=$(printf '%s' "$chunk" | awk '{buf=buf $0} END{
      t=index(buf,"bashMissKind:\"cd-compound-read\""); h=substr(buf,1,t-1)
      p=0; while((q=index(h,"decisionReason:{"))>0){p+=q; h=substr(h,q+1)}
      if(!p){print "NO-DECISIONREASON"; exit}
      print substr(buf,p)}')
  case "$reason" in
    NO-DECISIONREASON) echo "generic unparsed" ;;
    *circuitBreaker:*) echo "generic circuit" ;;
    *'type:"other"'*)  echo "generic other" ;;
    *)                 echo "generic unknown-type" ;;
  esac
}

snapshot() {
  local exe=$1 r g
  r=$(extract_registry "$exe") || return 2
  [ -n "$r" ] || return 2
  printf '%s\n' "$r"
  r=$(extract_reducer "$exe") || return 2
  [ -n "$r" ] || return 2
  printf '%s\n' "$r"
  g=$(extract_generic "$exe")
  printf '%s\n' "$g"
}

if [ "$MODE" = print ]; then
  [ -f "$PRINT_TARGET" ] || { echo "$TAG --print needs an executable path" >&2; exit 3; }
  printf '# baseline-build: %s\n' "$(basename "$PRINT_TARGET")"
  snapshot "$PRINT_TARGET"; rc=$?
  [ $rc -eq 0 ] || echo "$TAG EMPTY EXTRACTION from $PRINT_TARGET — anchors need re-deriving" >&2
  exit $rc
fi

[ -r "$BASELINE" ] || { echo "$TAG baseline missing: $BASELINE" >&2; exit 3; }
[ -d "$VERSIONS_DIR" ] || { echo "$TAG no versions dir at $VERSIONS_DIR — nothing to inspect (not a pass)" >&2; exit 2; }

# The generic-branch line is compared separately: `absent` is allowed to differ from the
# baseline (premise strengthened), `circuit` is a drift, anything else is a drift too.
baseline_core=$(command grep -v '^generic \|^#' "$BASELINE")
baseline_generic=$(command grep '^generic ' "$BASELINE" | head -1)
# Builds OLDER than the one the baseline was taken from are history, not drift: 2.1.259 is
# still installed beside 2.1.261 and its extra registry key is the known, documented arc.
# Re-reporting it every session would teach the reader to ignore the advisory. Newer builds
# are always checked; an older build is skipped silently.
baseline_build=$(sed -n 's/^# baseline-build: *//p' "$BASELINE" | head -1)
[ -n "$baseline_core" ] || { echo "$TAG baseline has no registry/reducer lines: $BASELINE" >&2; exit 3; }

DRIFT=0; EMPTY=0; SEEN=0
shopt -s nullglob
for exe in "$VERSIONS_DIR"/*; do
  [ -f "$exe" ] || continue
  SEEN=$((SEEN + 1))
  ver=$(basename "$exe")
  if [ -n "$baseline_build" ] && [ "$ver" != "$baseline_build" ] && \
     [ "$(printf '%s\n%s\n' "$ver" "$baseline_build" | sort -V | head -1)" = "$ver" ]; then
    continue   # older than the baseline build
  fi
  ident="$ver.$(stat -c '%s.%Y' "$exe" 2>/dev/null || echo 0)"
  cache="$CACHE_DIR/$ident.ok"
  if [ "$NO_CACHE" -eq 0 ] && [ -f "$cache" ] && [ "$cache" -nt "$BASELINE" ]; then continue; fi

  snap=$(snapshot "$exe"); rc=$?
  if [ $rc -ne 0 ]; then
    echo "$TAG EMPTY EXTRACTION on $ver — an anchor stopped matching; this is NOT a clean result" >&2
    EMPTY=1; continue
  fi
  core=$(printf '%s\n' "$snap" | command grep -v '^generic ')
  generic=$(printf '%s\n' "$snap" | command grep '^generic ' | head -1)

  ok=1
  if [ "$core" != "$baseline_core" ]; then
    ok=0
    echo "$TAG DRIFT on $ver — registry/reducer differs from $BASELINE:" >&2
    diff <(printf '%s\n' "$baseline_core") <(printf '%s\n' "$core") | sed 's/^/    /' >&2
  fi
  if [ "$generic" != "$baseline_generic" ]; then
    case "$generic" in
      "generic absent") echo "$TAG note: $ver no longer carries the generic cd-compound-read ask (premise strengthened, not a drift)" >&2 ;;
      *) ok=0; echo "$TAG DRIFT on $ver — generic cd-compound-read ask is now '$generic' (baseline '$baseline_generic')" >&2 ;;
    esac
  fi

  if [ $ok -eq 1 ]; then
    mkdir -p "$CACHE_DIR" 2>/dev/null && printf 'sha256=%s\nchecked=%s\n' \
      "$(sha256sum "$exe" 2>/dev/null | cut -c1-64)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$cache" 2>/dev/null
  else
    DRIFT=1
    echo "$TAG    if reviewed and accepted: bash scripts/verify-cc-circuit-breakers.sh --print $exe > config/cc-circuit-breakers.txt" >&2
  fi
done

if [ "$SEEN" -eq 0 ]; then
  echo "$TAG no executables under $VERSIONS_DIR — nothing was inspected (not a pass)" >&2; exit 2
fi
[ "$EMPTY" -eq 1 ] && exit 2
[ "$DRIFT" -eq 1 ] && exit 1
exit 0
