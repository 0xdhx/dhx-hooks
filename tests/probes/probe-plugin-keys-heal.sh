#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (every cell runs dhx/dhx-plugin-keys-heal.sh under a mktemp HOME, a mktemp
#   CLAUDE_CONFIG_DIR and a mktemp DHX_HOOKS_CACHE_DIR; the only live read is the in-repo
#   dhx-plugin marketplace manifest in the default-directory cell)
#
# Guards dhx/dhx-plugin-keys-heal.sh (docs/decisions.md 2026-09-15 plugin-keys row): the pre-launch
# repair of enabledPlugins["dhx@dhx-local"] and extraKnownMarketplaces["dhx-local"].
#   P1  healthy: exit 0, silent, file not rewritten, no log
#   P2  enabledPlugins missing → set; declared source untouched; other keys preserved
#   P3  extraKnownMarketplaces missing → source written; enabledPlugins untouched
#   P4  clobber shape (both missing) → both restored; stderr names both
#   P5  explicit false → true;  P6 empty path → written
#   P7  a declared non-empty path is never replaced
#   P8  symlinked settings: the link survives and the real file is repaired; mode preserved
#   P9  second run after a repair is silent and rewrites nothing
#   P10 unparseable settings → exit 1, bytes unchanged, REFUSE printed once, repeat silent
#   P11 non-object settings → refused unchanged
#   P12 identity guard: a manifest not naming dhx-local refuses when the source must be written,
#       and is irrelevant when only enabledPlugins is missing
#   P13 no settings file → exit 0, nothing created
#   P14 a healthy run re-arms the refusal marker
#   P15 fresh lock held → exit 0 unchanged, CONTENTION logged;  P16 stale lock → taken over
#   P17 default marketplace dir = dhx-plugin/ beside the script's dhx/ directory
# Run: bash tests/probes/probe-plugin-keys-heal.sh
set -u

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo /home/dhx/repos/hooks)
HEAL="$REPO/dhx/dhx-plugin-keys-heal.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
check() {  # name status
  if [[ "$2" == "0" ]]; then printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

PRED='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'

# mkcell NAME SETTINGS_JSON → root with cfg/settings.json (real file), cache/, mp/ (valid manifest)
mkcell() {
  local r="$TMPROOT/$1"
  mkdir -p "$r/home" "$r/cfg" "$r/cache" "$r/mp/.claude-plugin"
  printf '{"name":"dhx-local","owner":{"name":"probe"},"plugins":[{"name":"dhx","source":"./plugins/dhx"}]}' \
    > "$r/mp/.claude-plugin/marketplace.json"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$r/cfg/settings.json"
  printf '%s' "$r"
}
# run ROOT → runs the heal; sets RC, ERR
run() {
  local r=$1
  ERR=$(env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" DHX_HOOKS_CACHE_DIR="$r/cache" \
    DHX_PLUGIN_KEYS_MARKETPLACE_DIR="${MPDIR:-$r/mp}" bash "$HEAL" </dev/null 2>&1 >/dev/null)
  RC=$?
}
fp() { stat -c '%i %Y %s' "$1" 2>/dev/null; }
strip() { jq -cS 'del(.enabledPlugins["dhx@dhx-local"], .extraKnownMarketplaces["dhx-local"]) | if .enabledPlugins == {} then del(.enabledPlugins) else . end | if .extraKnownMarketplaces == {} then del(.extraKnownMarketplaces) else . end' "$1"; }

SRC='{"source":"directory","path":"/elsewhere/dhx-plugin"}'
OTHER='"permissions":{"deny":["Bash(git reset --hard*)"]},"enabledPlugins":{"other@m":true},"extraKnownMarketplaces":{"m":{"source":{"source":"directory","path":"/m"}}},"model":"x"'

echo "=== dhx-plugin-keys-heal — P1-P17 ==="

# ---- P1 healthy ----
r=$(mkcell p1 "{$OTHER,\"x\":1}")
jq --argjson s "$SRC" '.enabledPlugins["dhx@dhx-local"] = true | .extraKnownMarketplaces["dhx-local"].source = $s' \
  "$r/cfg/settings.json" > "$r/s.tmp" && mv "$r/s.tmp" "$r/cfg/settings.json"
before=$(fp "$r/cfg/settings.json"); sleep 1.1
run "$r"
[[ $RC == 0 && -z "$ERR" && "$(fp "$r/cfg/settings.json")" == "$before" && ! -e "$r/cache/plugin-keys-heal.log" ]]
check "P1 healthy: rc 0, silent, not rewritten, no log" $?

# ---- P2 enabledPlugins missing ----
r=$(mkcell p2 "{$OTHER}")
jq --argjson s "$SRC" '.extraKnownMarketplaces["dhx-local"].source = $s' "$r/cfg/settings.json" > "$r/s.tmp" && mv "$r/s.tmp" "$r/cfg/settings.json"
orig=$(strip "$r/cfg/settings.json")
run "$r"
[[ $RC == 0 ]] && jq -e "$PRED" "$r/cfg/settings.json" >/dev/null \
  && [[ "$(jq -r '.extraKnownMarketplaces["dhx-local"].source.path' "$r/cfg/settings.json")" == "/elsewhere/dhx-plugin" ]] \
  && [[ "$(strip "$r/cfg/settings.json")" == "$orig" ]] \
  && [[ "$ERR" == *"restored dhx plugin keys (enabledPlugins)"* ]] \
  && grep -q $'\tREPAIRED\tmissing=enabledPlugins' "$r/cache/plugin-keys-heal.log"
check "P2 enabledPlugins missing: set, source untouched, other keys preserved, one stderr line, logged" $?

# ---- P3 extraKnownMarketplaces missing ----
r=$(mkcell p3 "{$OTHER}")
jq '.enabledPlugins["dhx@dhx-local"] = true' "$r/cfg/settings.json" > "$r/s.tmp" && mv "$r/s.tmp" "$r/cfg/settings.json"
orig=$(strip "$r/cfg/settings.json")
run "$r"
[[ $RC == 0 ]] && jq -e --arg p "$r/mp" '.extraKnownMarketplaces["dhx-local"].source == {source: "directory", path: $p}' "$r/cfg/settings.json" >/dev/null \
  && [[ "$(strip "$r/cfg/settings.json")" == "$orig" ]]
check "P3 marketplace missing: source {directory, <mp dir>} written, other keys preserved" $?

# ---- P4 clobber shape ----
r=$(mkcell p4 '{"permissions":{"allow":[]}}')
run "$r"
[[ $RC == 0 ]] && jq -e "$PRED" "$r/cfg/settings.json" >/dev/null \
  && jq -e '.permissions == {allow: []}' "$r/cfg/settings.json" >/dev/null \
  && [[ "$ERR" == *"(enabledPlugins+extraKnownMarketplaces)"* ]]
check "P4 both keys missing: both restored, stderr names both" $?

# ---- P5 explicit false / P6 empty path ----
r=$(mkcell p5 "{\"enabledPlugins\":{\"dhx@dhx-local\":false},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":$SRC}}}")
run "$r"
[[ $RC == 0 ]] && jq -e '.enabledPlugins["dhx@dhx-local"] == true' "$r/cfg/settings.json" >/dev/null
check "P5 enabledPlugins false → true" $?
r=$(mkcell p6 '{"enabledPlugins":{"dhx@dhx-local":true},"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":""}}}}')
run "$r"
[[ $RC == 0 ]] && jq -e --arg p "$r/mp" '.extraKnownMarketplaces["dhx-local"].source.path == $p' "$r/cfg/settings.json" >/dev/null
check "P6 empty source path → written" $?

# ---- P7 declared non-empty path never replaced ----
r=$(mkcell p7 "{\"enabledPlugins\":{},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":$SRC,\"autoUpdate\":false}}}")
run "$r"
[[ $RC == 0 ]] && jq -e --argjson s "$SRC" '.extraKnownMarketplaces["dhx-local"] == {source: $s, autoUpdate: false}' "$r/cfg/settings.json" >/dev/null
check "P7 declared non-empty path and sibling fields left alone" $?

# ---- P8 symlink chain + mode ----
r=$(mkcell p8 "")
mkdir -p "$r/shared"
printf '{"model":"y"}\n' > "$r/shared/settings.json"
# 640, not 600: mktemp creates 0600, so a 600 fixture could not tell a kept mode from a lost one.
chmod 640 "$r/shared/settings.json"
ln -s "$r/shared/settings.json" "$r/cfg/settings.json"
run "$r"
[[ $RC == 0 && -L "$r/cfg/settings.json" && "$(readlink -f "$r/cfg/settings.json")" == "$r/shared/settings.json" ]] \
  && jq -e "$PRED" "$r/shared/settings.json" >/dev/null \
  && [[ "$(stat -c %a "$r/shared/settings.json")" == "640" ]] \
  && [[ -z "$(find "$r/shared" -name '.settings.dhx-keys-heal.*')" ]]
check "P8 symlinked settings: link intact, real file repaired, mode 640 kept, no temp left" $?

# ---- P9 idempotent ----
before=$(fp "$r/shared/settings.json"); sleep 1.1
run "$r"
[[ $RC == 0 && -z "$ERR" && "$(fp "$r/shared/settings.json")" == "$before" ]]
check "P9 second run after repair: silent, not rewritten" $?

# ---- P10 unparseable ----
r=$(mkcell p10 'not json {{{')
sum=$(sha256sum < "$r/cfg/settings.json")
run "$r"; rc1=$RC; err1=$ERR
run "$r"
[[ $rc1 == 1 && "$err1" == *"REFUSE: settings is not a parseable JSON object"* && $RC == 1 && -z "$ERR" ]] \
  && [[ "$(sha256sum < "$r/cfg/settings.json")" == "$sum" ]] \
  && [[ "$(grep -c $'\tREFUSE\t' "$r/cache/plugin-keys-heal.log")" == 2 ]]
check "P10 unparseable: rc 1, bytes unchanged, REFUSE printed once then silent, both logged" $?

# ---- P11 non-object ----
r=$(mkcell p11 '[1,2]')
sum=$(sha256sum < "$r/cfg/settings.json")
run "$r"
[[ $RC == 1 && "$(sha256sum < "$r/cfg/settings.json")" == "$sum" ]]
check "P11 non-object settings: refused, unchanged" $?

# ---- P12 identity guard ----
r=$(mkcell p12 '{"enabledPlugins":{"dhx@dhx-local":true}}')
printf '{"name":"not-dhx","plugins":[{"name":"dhx"}]}' > "$r/mp/.claude-plugin/marketplace.json"
sum=$(sha256sum < "$r/cfg/settings.json")
run "$r"
guard_rc=$RC; guard_err=$ERR; guard_sum=$(sha256sum < "$r/cfg/settings.json")
r2=$(mkcell p12b "{\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":$SRC}}}")
printf '{"name":"not-dhx"}' > "$r2/mp/.claude-plugin/marketplace.json"
run "$r2"
[[ $guard_rc == 1 && "$guard_err" == *"no dhx-local marketplace manifest"* && "$guard_sum" == "$sum" ]] \
  && [[ $RC == 0 ]] && jq -e "$PRED" "$r2/cfg/settings.json" >/dev/null
check "P12 identity guard refuses a wrong manifest only when the source must be written" $?

# ---- P13 no settings ----
r=$(mkcell p13 "")
run "$r"
[[ $RC == 0 && -z "$ERR" && ! -e "$r/cfg/settings.json" ]]
check "P13 no settings file: rc 0, nothing created" $?

# ---- P14 healthy re-arms the refusal marker ----
r=$(mkcell p14 'broken')
run "$r"; e1=$ERR
printf '{"enabledPlugins":{"dhx@dhx-local":true},"extraKnownMarketplaces":{"dhx-local":{"source":%s}}}\n' "$SRC" > "$r/cfg/settings.json"
run "$r"
printf 'broken\n' > "$r/cfg/settings.json"
run "$r"
[[ -n "$e1" && "$ERR" == *"REFUSE"* ]]
check "P14 a healthy run re-arms: the same refusal prints again after recovery" $?

# ---- P15 fresh lock / P16 stale lock ----
r=$(mkcell p15 '{"permissions":{}}')
real=$(readlink -f "$r/cfg/settings.json")
mkdir -p "$r/cache/plugin-keys-heal.$(printf '%s' "$real" | sha256sum | cut -c1-16).lock"
sum=$(sha256sum < "$r/cfg/settings.json")
run "$r"
[[ $RC == 0 && "$(sha256sum < "$r/cfg/settings.json")" == "$sum" ]] && grep -q $'\tCONTENTION\t' "$r/cache/plugin-keys-heal.log"
check "P15 lock held: rc 0, unchanged, CONTENTION logged" $?
r=$(mkcell p16 '{"permissions":{}}')
real=$(readlink -f "$r/cfg/settings.json")
lock="$r/cache/plugin-keys-heal.$(printf '%s' "$real" | sha256sum | cut -c1-16).lock"
mkdir -p "$lock"; touch -d '1 minute ago' "$lock"
run "$r"
[[ $RC == 0 && ! -e "$lock" ]] && jq -e "$PRED" "$r/cfg/settings.json" >/dev/null
check "P16 stale lock: taken over, repaired, released" $?

# ---- P17 default marketplace dir ----
r=$(mkcell p17 '{}')
ERR=$(env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" DHX_HOOKS_CACHE_DIR="$r/cache" \
  bash "$HEAL" </dev/null 2>&1 >/dev/null); RC=$?
[[ $RC == 0 ]] && jq -e --arg p "$(readlink -f "$REPO/dhx-plugin")" '.extraKnownMarketplaces["dhx-local"].source.path == $p' "$r/cfg/settings.json" >/dev/null
check "P17 default marketplace dir resolves to this checkout's dhx-plugin/" $?

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
