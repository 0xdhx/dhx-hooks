#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes
# probe-dhx-key-coverage-audit.sh — assertions for dhx/dhx-key-coverage-audit.sh.
#
# WHAT IT GUARDS: the 2026-09-15 key arc traded the `Read(~/.ssh/id_*)` deny glob for
# exact names (the glob also swallowed `id_ed25519.pub`, and CC's matcher has no
# carve-out — measured). Exact names leave a residual: a key minted later is covered
# by no rule until someone adds one. The audit hook IS that residual's guard, so the
# thing to assert is that it FIRES — a detector that silently finds nothing is
# indistinguishable from a covered machine, which is the failure this whole arc is
# about.
#
# READ-ONLY against live state: every case runs the hook against a fixture tree via
# DHX_KEY_GUARD_CONFIG + DHX_KEY_COVERAGE_SETTINGS. No live settings, no live ~/.ssh,
# no key material anywhere — fixture "private keys" are the string "not-a-key".
#
# Companion INVARIANT: the guard-predicate regex in the hook mirrors KEY_BASENAME_RE
# in dhx/dhx-key-read-guard.js. Case 4 is what reds if they drift apart on the
# algorithm-anchored shape.

set -uo pipefail

HOOK="${HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/dhx/dhx-key-coverage-audit.sh}"
PASS=0; FAIL=0
ok()   { printf 'OK   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe-key-coverage.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- fixture builders -------------------------------------------------------------
# mkfixture <name> — an .ssh-shaped dir with a config; caller adds keys.
mkfixture() {
  local d="$WORK/$1/ssh"
  mkdir -p "$d"
  : > "$d/config"
  printf '%s' "$d"
}
# addkey <dir> <name> [pub]  — a "private key" plus, unless pub=nopub, its .pub sibling.
addkey() {
  local d=$1 n=$2 pub=${3:-pub}
  printf 'not-a-key\n' > "$d/$n"
  [[ "$pub" == nopub ]] || printf 'ssh-ed25519 AAAA fixture\n' > "$d/$n.pub"
}
# guardcfg <dir> <extra-json-array> — the guard config naming this fixture's config.
guardcfg() {
  local d=$1 extras=${2:-[]} f="$WORK/guard-$RANDOM.json"
  printf '{"ssh_configs":["%s/config"],"extra_key_basenames":%s}\n' "$d" "$extras" > "$f"
  printf '%s' "$f"
}
# settings <deny-json-array>
settings() {
  local f="$WORK/settings-$RANDOM.json"
  printf '{"permissions":{"deny":%s}}\n' "$1" > "$f"
  printf '%s' "$f"
}
run() { DHX_KEY_GUARD_CONFIG="$1" DHX_KEY_COVERAGE_SETTINGS="$2" bash "$HOOK" 2>&1; }

# --- 1. fully covered → silent ----------------------------------------------------
d=$(mkfixture c1); addkey "$d" id_ed25519
out=$(run "$(guardcfg "$d")" "$(settings "[\"Read(/$d/id_ed25519)\"]")")
[[ -z "$out" ]] && ok "covered key → silent" || bad "covered key → silent" "got: $out"

# --- 2. missing deny rule, guard-covered name → fires, names the rule -------------
d=$(mkfixture c2); addkey "$d" id_ed25519
out=$(run "$(guardcfg "$d")" "$(settings '[]')")
if [[ "$out" == *"key-coverage"* && "$out" == *"deny rule: MISSING"* \
      && "$out" == *"read-guard: covered"* && "$out" == *"permissions.deny += \"Read(/$d/id_ed25519)\""* ]]; then
  ok "rule gap on a guard-covered key → fires with the paste-able rule"
else bad "rule gap on a guard-covered key" "got: $out"; fi

# --- 3. neither layer → both remediation lines ------------------------------------
d=$(mkfixture c3); addkey "$d" backup_key
out=$(run "$(guardcfg "$d")" "$(settings '[]')")
if [[ "$out" == *"deny rule: MISSING · read-guard: MISSING"* \
      && "$out" == *"permissions.deny += "* && "$out" == *'extra_key_basenames += "backup_key"'* ]]; then
  ok "no layer covers → both remediation lines"
else bad "no layer covers → both remediation lines" "got: $out"; fi

# --- 4. algorithm-anchored predicate (mirrors KEY_BASENAME_RE) --------------------
# id_ed25519_work is guard-covered (suffix arm); id_generator.py is NOT a key name at
# all and must not be claimed as guard-covered. Both assert the regex shape.
d=$(mkfixture c4); addkey "$d" id_ed25519_work; addkey "$d" id_generator.py
out=$(run "$(guardcfg "$d")" "$(settings '[]')")
work_line=$(printf '%s' "$out" | grep -A1 "id_ed25519_work$" | tail -1)
gen_line=$(printf '%s' "$out" | grep -A1 "id_generator.py$" | tail -1)
[[ "$work_line" == *"read-guard: covered"* ]] \
  && ok "suffixed id_<algo> name → guard-covered (KEY_BASENAME_RE suffix arm)" \
  || bad "suffixed id_<algo> name → guard-covered" "got: $work_line"
[[ "$gen_line" == *"read-guard: MISSING"* ]] \
  && ok "id_generator.py → NOT guard-covered (algorithm anchor holds)" \
  || bad "id_generator.py → NOT guard-covered" "got: $gen_line"

# --- 5. extra_key_basenames covers the guard layer --------------------------------
d=$(mkfixture c5); addkey "$d" oddly_named
out=$(run "$(guardcfg "$d" '["oddly_named"]')" "$(settings '[]')")
[[ "$out" == *"read-guard: covered"* ]] \
  && ok "extra_key_basenames entry → guard-covered" || bad "extra_key_basenames entry" "got: $out"

# --- 6. IdentityFile target with NO .pub is still discovered ----------------------
d=$(mkfixture c6); addkey "$d" deploy_key nopub
printf '  IdentityFile %s/deploy_key\n' "$d" > "$d/config"
out=$(run "$(guardcfg "$d")" "$(settings '[]')")
[[ "$out" == *"deploy_key"* && "$out" == *"read-guard: covered"* ]] \
  && ok "IdentityFile target without a .pub → discovered, guard-covered" \
  || bad "IdentityFile target without a .pub" "got: $out"

# --- 7. a .pub with NO private sibling is not a candidate (no false positive) -----
d=$(mkfixture c7); printf 'ssh-ed25519 AAAA orphan\n' > "$d/orphan.pub"
out=$(run "$(guardcfg "$d")" "$(settings '[]')")
[[ -z "$out" ]] && ok "orphan .pub → not a candidate" || bad "orphan .pub → not a candidate" "got: $out"

# --- 8. a glob deny rule covers (matching spans /) --------------------------------
d=$(mkfixture c8); addkey "$d" id_ed25519
out=$(run "$(guardcfg "$d")" "$(settings "[\"Read(/$WORK/**)\"]")")
[[ -z "$out" ]] && ok "glob deny rule → covered (pattern match spans /)" \
  || bad "glob deny rule → covered" "got: $out"

# --- 9. a relative deny rule must NOT be credited as covering an absolute key -----
d=$(mkfixture c9); addkey "$d" id_ed25519
out=$(run "$(guardcfg "$d")" "$(settings '["Read(./.env*)","Read(.secrets)"]')")
[[ "$out" == *"deny rule: MISSING"* ]] \
  && ok "relative deny rules → not credited for an absolute key path" \
  || bad "relative deny rules → not credited" "got: $out"

# --- 10. unreadable private key still enumerated (proves no content read) --------
d=$(mkfixture c10); addkey "$d" id_ed25519; chmod 000 "$d/id_ed25519"
out=$(run "$(guardcfg "$d")" "$(settings '[]')")
chmod 644 "$d/id_ed25519"
[[ "$out" == *"id_ed25519"* ]] \
  && ok "mode-000 key still enumerated → the audit never reads key contents" \
  || bad "mode-000 key still enumerated" "got: $out"

# --- 11. fail-open: unreadable guard config → silent, rc 0 -----------------------
out=$(DHX_KEY_GUARD_CONFIG="$WORK/nope.json" DHX_KEY_COVERAGE_SETTINGS="$(settings '[]')" bash "$HOOK" 2>&1); rc=$?
[[ -z "$out" && "$rc" -eq 0 ]] && ok "missing guard config → fail-open silent, rc 0" \
  || bad "missing guard config → fail-open" "rc=$rc out=$out"

# --- 12. a finding still exits 0 (rc != 0 is the dispatcher's child-failure surface)
d=$(mkfixture c12); addkey "$d" id_ed25519
DHX_KEY_GUARD_CONFIG="$(guardcfg "$d")" DHX_KEY_COVERAGE_SETTINGS="$(settings '[]')" bash "$HOOK" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "a finding exits 0 (never the child-failure surface)" || bad "a finding exits 0" "rc=$?"

# --- 13. emission stays within the 76-char content width -------------------------
# HOME is pointed at the fixture root so the key sits at ~/ssh/backup_key — a
# realistic home-relative length AND the path the `~` display abbreviation produces.
# Measuring against an mktemp path instead would assert the width of the tmpdir name,
# not of the emission (it measured 101 and the emission was never the reason).
d=$(mkfixture c13); addkey "$d" backup_key
home13="$WORK/c13"
longest=$(HOME="$home13" DHX_KEY_GUARD_CONFIG="$(guardcfg "$d")" \
  DHX_KEY_COVERAGE_SETTINGS="$(settings '[]')" bash "$HOOK" 2>&1 \
  | awk '{ print length }' | sort -rn | head -1)
[[ "${longest:-0}" -le 76 ]] && ok "emission within 76-char content width (longest=$longest)" \
  || bad "emission within 76-char width" "longest=$longest"

# --- 14. $HOME paths display as ~ (the spelling the pasted rule uses) -------------
d=$(mkfixture c14); addkey "$d" id_ed25519
out=$(HOME="$WORK/c14" DHX_KEY_GUARD_CONFIG="$(guardcfg "$d")" \
  DHX_KEY_COVERAGE_SETTINGS="$(settings '[]')" bash "$HOOK" 2>&1)
[[ "$out" == *"~/ssh/id_ed25519"* && "$out" == *'"Read(~/ssh/id_ed25519)"'* ]] \
  && ok "\$HOME path → ~ in both the listing and the deny rule" \
  || bad "\$HOME path → ~ abbreviation" "got: $out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
