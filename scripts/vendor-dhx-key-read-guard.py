#!/usr/bin/env python3
"""Build dhx/dhx-key-read-guard.js from GSD's gsd-secret-read-guard.js (1.14.0).

Re-sync after a GSD update: diff the new GSD guard against the vendored parser, then bump
EXPECT_SHA and re-run `python3 scripts/vendor-dhx-key-read-guard.py`; the probe
(tests/probes/probe-dhx-key-read-guard.js) must stay green. An anchor that no longer
matches exactly once aborts the build rather than guessing.

Every replacement must match EXACTLY once (asserted), so the delta against the
vendored source stays small and auditable.
"""
import hashlib, pathlib

SRC = pathlib.Path.home() / '.claude/hooks/gsd-secret-read-guard.js'
DST = pathlib.Path(__file__).resolve().parent.parent / 'dhx' / 'dhx-key-read-guard.js'
EXPECT_SHA = '486ca81ea2e44050'

src = SRC.read_text()
sha = hashlib.sha256(src.encode()).hexdigest()
assert sha.startswith(EXPECT_SHA), f'source changed: {sha[:16]}'

def once(text, old, new, label):
    n = text.count(old)
    assert n == 1, f'{label}: expected 1 match, got {n}'
    return text.replace(old, new)

HEADER = f"""#!/usr/bin/env node
// dhx-key-read-guard.js — PreToolUse (Read | Grep | Bash): block reads of SSH private keys
// and AWS credentials into the conversation.
// Patterns: HP-003, HP-009, HP-061
//
// WHY: CC 2.1.273 removed the `denyRulesUnjudged` circuit (hooks docs/decisions.md
// 2026-09-15): a Bash path built at runtime — `grep … "$(ls -d ~/.s?h)/config"` — now passes
// the Read() deny rules silently under bypass mode, while static paths and `cd` chains are
// still denied. This guard is the operator-chosen partial cover (2026-09-15 brief: vendor
// GSD's parser; protect id_<algo> + every IdentityFile target; deny rules narrowed to keys).
//
// PROVENANCE — VENDORED, DETACHED. The Bash operand parser (tokenize, substitutions,
// heredocs, eval / bash -c / xargs / source handling, Grep glob analysis) is copied from
// GSD's hooks/gsd-secret-read-guard.js (gsd-hook-version 1.14.0, sha256 {sha[:16]}…),
// with lib/hook-exit.js and lib/filename-classification.js inlined. /gsd:update does NOT
// touch this file: a GSD parser fix must be hand-synced here — rebuild with
// `python3 scripts/vendor-dhx-key-read-guard.py` (it asserts the source sha). GSD's own guard keeps running beside
// this one for .env / .secrets. Changed from GSD: the name predicate (key names,
// IdentityFile targets, .aws/credentials, whole .ssh / .aws directories) and fragment
// matching inside operands; exemptions for key USE (the -i / IdentityFile= value of
// ssh / scp / sftp / ssh-copy-id; ssh-add and ssh-keygen entirely), for grep-family
// PATTERN operands, and for cd / pushd / popd; a prefilter (id_ / .ssh / .aws) so unrelated
// commands are never parsed; a plain exit-2 deny (HP-009) instead of GSD's terminateNow.
// The Kimi normalizer below is carried unchanged; GSD's parity test does not bind this copy.
//
// RESIDUALS (stated, accepted): every rule here matches command TEXT, not the files a
// command opens — a symlink, a copy made earlier, or a fully encoded path
// (`$(printf '\\x2essh')`) defeats it, exactly as it defeats Claude Code's own parser. A
// custom IdentityFile name is protected only on a path that also shows `.ssh` (the
// prefilter). Fail-open on a hook-internal error, like the GSD original.
// Config: config/key-read-guard.json (DHX_KEY_GUARD_CONFIG=<path> overrides; probes use it).
// Probe: tests/probes/probe-dhx-key-read-guard.js.

"""

HELPERS = """const fs = require('fs');
const os = require('os');
const path = require('path');

// Inlined from GSD hooks/lib/hook-exit.js — only what this guard uses. Deny = exit 2
// with the reason on stderr (HP-009: exit 2 blocks and CC hands stderr to the model);
// allow = silent exit 0.
const HOOK_ON_CRASH = Object.freeze({ ALLOW: 'allow', DENY: 'deny' });
function allow() { process.exit(0); }
function deny(reason) { process.stderr.write(String(reason) + '\\n'); process.exit(2); }
function crash(onCrash) {
  if (onCrash === HOOK_ON_CRASH.DENY) deny('Key read guard: internal error');
  allow();
}

// Inlined from GSD hooks/lib/filename-classification.js. Win32 strips trailing dots and
// spaces per path component, so `id_rsa.` resolves to `id_rsa` — normalize first.
function normalizeWindowsBasename(name) {
  if (typeof name !== 'string' || name === '') return '';
  let end = name.length;
  while (end > 0 && (name[end - 1] === '.' || name[end - 1] === ' ')) end--;
  return name.slice(0, end);
}
function lastSegment(tok) {
  const s = tok.replace(/[\\\\/]+$/, '');
  const i = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\\\'));
  return i === -1 ? s : s.slice(i + 1);
}
"""

KEY_CONSTS = """// Built-in private-key basenames: id_<algorithm>, optional _sk (FIDO), optional custom
// suffix (`id_ed25519_github`, `id_rsa.old`). Anchored on the algorithm on purpose — a bare
// `id_*` would fire on ordinary code files (`id_generator.py`, `id_map.csv`).
const KEY_BASENAME_RE = /^id_(?:rsa|dsa|ecdsa|ed25519)(?:_sk)?(?:[._-][a-z0-9._-]*)?$/;

// Prefilter: a command or path containing none of these cannot name a protected file, so it
// is never parsed — the per-call cost for ordinary commands stays near zero.
const KEY_PREFILTER_RE = /id_|\\.ssh|\\.aws/i;

// Commands that USE a key without printing it: all of their operands are exempt.
const KEY_USE_COMMANDS = new Set(['ssh-add', 'ssh-keygen']);

// Commands that take a key only as the value of `-i` / `-o IdentityFile=`: that value is
// exempt; every other operand (scp's files, ssh's remote command) is still checked, because
// copying a key off the box is the exfiltration step this guard exists for.
const IDENTITY_FLAG_COMMANDS = new Set(['ssh', 'scp', 'sftp', 'ssh-copy-id']);

// Commands whose first positional operand (or every -e / -f value) is a PATTERN, not a path:
// the operator's own `git diff --name-only | grep -iE '…|id_rsa|…'` secret scans must pass.
const PATTERN_FIRST_COMMANDS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack']);
"""

KEY_PROBES = """// Names a glob (Grep's `glob`, or a globbed Bash operand) is matched against. Configured
// IdentityFile basenames are appended at runtime (keyProbes()).
const KEY_PROBES = [
  'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'id_ecdsa_sk', 'id_ed25519_sk',
  'id_ed25519_github', 'id_rsa_work',
];
"""

PREDICATES = """// ---------------------------------------------------------------------------
// Key-name predicate
// ---------------------------------------------------------------------------

function expandHome(p) {
  return typeof p === 'string' && p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
}

let _config = null;
function guardConfig() {
  if (_config) return _config;
  const file = process.env.DHX_KEY_GUARD_CONFIG || path.join(__dirname, '..', 'config', 'key-read-guard.json');
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { cfg = {}; }
  const strings = (v) => (Array.isArray(v) ? v.filter((s) => typeof s === 'string') : []);
  _config = { sshConfigs: strings(cfg.ssh_configs), extra: strings(cfg.extra_key_basenames) };
  return _config;
}

// Basenames of every IdentityFile named in the configured ssh configs, plus the explicit
// extras. An unreadable config contributes nothing (fail-open, like the rest of the guard).
let _identities = null;
function identityBasenames() {
  if (_identities) return _identities;
  const out = new Set();
  const { sshConfigs, extra } = guardConfig();
  for (const e of extra) out.add(e.toLowerCase());
  for (const cfgPath of sshConfigs) {
    let text = '';
    try { text = fs.readFileSync(expandHome(cfgPath), 'utf8'); } catch { continue; }
    for (const line of text.split(/\\r?\\n/)) {
      const m = /^\\s*IdentityFile(?:\\s*=\\s*|\\s+)(.+?)\\s*$/i.exec(line);
      if (!m) continue;
      const base = normalizeWindowsBasename(lastSegment(m[1].replace(/^["']|["']$/g, ''))).toLowerCase();
      if (base && !base.endsWith('.pub')) out.add(base);
    }
  }
  _identities = out;
  return out;
}

function keyProbes() {
  return KEY_PROBES.concat([...identityBasenames()]);
}

function isKeyBasename(base) {
  if (!base || base.endsWith('.pub')) return false;
  return KEY_BASENAME_RE.test(base) || identityBasenames().has(base);
}

// One path-shaped fragment: a key name, a glob selecting one, `credentials` directly under
// `.aws`, or a whole `.ssh` / `.aws` directory (a recursive grep / tar / cp of the directory
// reads every key in it).
function fragmentNamesKey(frag) {
  const lower = frag.toLowerCase().replace(/[\\\\/]+$/, '');
  const base = normalizeWindowsBasename(lastSegment(lower));
  if (base === '') return false;
  if (base === '.ssh' || base === '.aws') return true;
  if (/[*?[]/.test(base)) {
    const alts = expandBraces(base) || [base];
    return alts.some((a) => globAltSelectsKey(a, lower));
  }
  if (isKeyBasename(base)) return true;
  return base === 'credentials' && /(^|[\\\\/])\\.aws[\\\\/]credentials$/.test(lower);
}

// True when any path-shaped fragment of the token names a protected file. Fragments split on
// whitespace, quotes, `$( )` / backtick punctuation and `=` `;` `,` `<` `>`, so a key path
// inside a substitution or a `--flag=value` is still seen; the part after a `:` is checked
// too (git `<ref>:<path>`, Windows drives).
function namesKey(tok) {
  if (typeof tok !== 'string' || tok === '' || !KEY_PREFILTER_RE.test(tok)) return false;
  for (const frag of tok.split(/[\\s"'`()=;,<>]+/)) {
    if (frag === '') continue;
    if (fragmentNamesKey(frag)) return true;
    const colon = frag.lastIndexOf(':');
    if (colon !== -1 && fragmentNamesKey(frag.slice(colon + 1))) return true;
  }
  return false;
}

// Operand positions that carry a PATTERN or a key being USED, not a file being read.
function exemptOperandIndexes(base, operands) {
  const skip = new Set();
  if (IDENTITY_FLAG_COMMANDS.has(base)) {
    for (let i = 0; i < operands.length; i++) {
      const t = operands[i].text;
      if (t === '-i') skip.add(i + 1);
      else if (t === '-o' && operands[i + 1] && /^identityfile[=\\s]/i.test(operands[i + 1].text)) skip.add(i + 1);
      else if (/^-i./.test(t) || /^-oidentityfile[=\\s]/i.test(t)) skip.add(i);
    }
  }
  if (PATTERN_FIRST_COMMANDS.has(base)) {
    let sawPatternFlag = false;
    for (let i = 0; i < operands.length; i++) {
      const t = operands[i].text;
      if (t === '-e' || t === '--regexp' || t === '-f' || t === '--file') { skip.add(i + 1); sawPatternFlag = true; }
      else if (/^(-e.|--regexp=)/.test(t)) { skip.add(i); sawPatternFlag = true; }
    }
    if (!sawPatternFlag) {
      for (let i = 0; i < operands.length; i++) {
        if (!operands[i].text.startsWith('-')) { skip.add(i); break; }
      }
    }
  }
  return skip;
}

"""

GLOB_FN = """// Does this single brace-free glob alternative select a protected key name? `full` is the
// whole lower-cased fragment: a pure wildcard counts only inside a `.ssh` directory.
function globAltSelectsKey(alt, full) {
  if (alt === '') return false;
  if (/^[*?]+$/.test(alt) && !/(^|[\\\\/])\\.ssh[\\\\/]/.test(full || '')) return false;
  let re;
  try {
    re = globAltToRegex(alt);
  } catch {
    return true; // an unparsable class — deny is the safe side
  }
  return keyProbes().some((probe) => re.test(probe));
}
"""

EMISSION = """const PATTERN_TEXT = 'SSH private keys (id_<algorithm>[_sk][suffix] and every IdentityFile in the ' +
  'configured ssh configs, never *.pub), ~/.aws/credentials, and whole .ssh / .aws directories';

function reasonFor(code, tool, target) {
  if (code === 'command-too-large') {
    return `Key read guard: this Bash command is over ${MAX_COMMAND_LENGTH} characters and ` +
      'cannot be checked for key-file reads. Split it into smaller commands.';
  }
  if (code === 'glob-too-complex') {
    return `Key read guard: the Grep glob '${target}' expands to more than ${MAX_GLOB_ALTERNATIVES} ` +
      'alternatives and cannot be checked for key-file matches. Use a narrower glob.';
  }
  return `Key read guard: ${tool} would read '${target}', which matches a protected credential ` +
    `(${PATTERN_TEXT}). Key material must not be read into the conversation. To USE a key, ` +
    'pass it with -i to ssh/scp or load it with ssh-add; for a fingerprint run ssh-keygen -lf on ' +
    'the .pub file. ssh config, known_hosts, authorized_keys and *.pub stay readable.';
}

function emitBlock(code, tool, target) {
  deny(reasonFor(code, tool, target));
}
"""

out = src
# A: header (everything before 'use strict')
head_end = out.index("'use strict';\n")
out = HEADER + out[head_end:]
# B: requires -> inlined helpers
out = once(out, "const { HOOK_ON_CRASH, allow, deny, crash } = require('./lib/hook-exit.js');\n"
                "const { finalExtension, normalizeWindowsBasename, lastSegment } = require('./lib/filename-classification.js');\n",
           HELPERS, 'requires')
# C: .env constants -> key constants
out = once(out, "// `.env.<suffix>` names that are templates, not secrets (case-insensitive).\n"
                "const NON_SECRET_ENV_SUFFIXES = new Set(['example', 'sample', 'template', 'dist']);\n",
           KEY_CONSTS, 'env-consts')
# cd / pushd / popd join the non-reading set
out = once(out, "  'basename', 'dirname', 'realpath', 'file', 'echo', 'printf',\n]);",
           "  'basename', 'dirname', 'realpath', 'file', 'echo', 'printf',\n  'cd', 'pushd', 'popd',\n]);",
           'non-reading')
# D: GLOB_PROBES -> KEY_PROBES
g0 = out.index("// Probe names a Grep glob alternative is matched against.")
g1 = out.index("  '.env.zzq',\n];\n") + len("  '.env.zzq',\n];\n")
out = out[:g0] + KEY_PROBES + out[g1:]
# E: secret-name predicate section -> key predicates
p0 = out.index("// ---------------------------------------------------------------------------\n// Secret-name predicate\n")
p1 = out.index("// ---------------------------------------------------------------------------\n// Grep glob analysis\n")
out = out[:p0] + PREDICATES + out[p1:]
# F: globAltSelectsSecret -> globAltSelectsKey
f0 = out.index("// Does this single alternative select any secret name? (See header.)\n")
f1 = out.index("  return GLOB_PROBES.some((probe) => re.test(probe));\n}\n") + len("  return GLOB_PROBES.some((probe) => re.test(probe));\n}\n")
out = out[:f0] + GLOB_FN + out[f1:]
# G: classifyGrepGlob
out = once(out, "  return alts.some(globAltSelectsSecret) ? 'secret-read' : null;",
           "  return alts.some((a) => globAltSelectsKey(a, glob.toLowerCase())) ? 'key-read' : null;", 'classify')
# H: operand loop with exemptions
out = once(out, "    if (NON_READING_COMMANDS.has(base)) continue;\n\n    for (const w of operands) {\n"
                "      if (namesSecret(normalizeOperand(w.text))) return w.text;\n    }\n",
           "    if (NON_READING_COMMANDS.has(base) || KEY_USE_COMMANDS.has(base)) continue;\n\n"
           "    const skip = exemptOperandIndexes(base, operands);\n"
           "    for (let i = 0; i < operands.length; i++) {\n"
           "      if (skip.has(i)) continue;\n"
           "      const w = operands[i];\n"
           "      if (namesKey(normalizeOperand(w.text))) return w.text;\n    }\n", 'operand-loop')
# I: emission
e0 = out.index("const PATTERN_TEXT = ")
e1 = out.index("  deny({ decision: 'block', code, tool, path: target, reason }, reason);\n}\n") + \
     len("  deny({ decision: 'block', code, tool, path: target, reason }, reason);\n}\n")
out = out[:e0] + EMISSION + out[e1:]
# K: Bash prefilter; Grep glob only when the search is aimed at .ssh / .aws
out = once(out, "    if (command === '') allow(undefined);\n",
           "    if (command === '' || !KEY_PREFILTER_RE.test(command)) allow(undefined);\n", 'bash-prefilter')
out = once(out, "      if (glob !== '') {\n        const verdict = classifyGrepGlob(glob);",
           "      if (glob !== '' && /\\.ssh|\\.aws/i.test(grepPath + ' ' + glob)) {\n        const verdict = classifyGrepGlob(glob);",
           'grep-glob-gate')
# Tokenizer: record each word's `$( )` / backtick substitutions (text is still pushed to
# `nested` exactly as GSD does) so the reading command can check names a substitution
# PRODUCES — `cat "$(ls ~/.ssh/id_*)"` — in its own context (producedKeyName).
out = once(out, "  let buf = '';\n  let quoted = 'none';\n  let hasWord = false;\n",
           "  let buf = '';\n  let wordSubs = [];\n  let quoted = 'none';\n  let hasWord = false;\n", 'wordsubs-decl')
out = once(out, "      tokens.push({ kind: 'word', text: buf, quoted, seg });\n    }\n    buf = '';\n",
           "      tokens.push({ kind: 'word', text: buf, quoted, seg, subs: wordSubs });\n    }\n    buf = '';\n    wordSubs = [];\n",
           'wordsubs-flush')
for frag, label in (("nested.push(str.slice(i + 2, e));", 'dollar-paren'), ("nested.push(str.slice(i + 1, e));", 'backtick')):
    n = out.count(frag)
    assert n == 2, f'{label}: expected 2 in-word substitution sites, got {n}'
    out = out.replace(frag, "{ const sub = " + frag[len('nested.push('):-2] + "; nested.push(sub); wordSubs.push(sub); }")
out = once(out,
           "      const w = operands[i];\n      if (namesKey(normalizeOperand(w.text))) return w.text;\n    }\n",
           "      const w = operands[i];\n      if (namesKey(normalizeOperand(w.text))) return w.text;\n"
           "      const produced = producedKeyName(w.subs);\n      if (produced) return produced;\n    }\n",
           'produced-check')
PRODUCED = """// Names produced by a `$( )` / backtick substitution that feeds a READING command's operand
// (`cat "$(ls ~/.ssh/id_*)"`). The producer (ls, find, echo, …) reads nothing, so the nested
// scan exempts it; here, in the reading command's own context, its operands are the file
// names about to be read. A non-reading or key-using outer command (`chmod`, `ssh-add`)
// never reaches this check, so `ssh-add $(ls ~/.ssh/id_* | grep -v pub)` still passes.
const NAME_PRODUCERS = new Set(['ls', 'find', 'echo', 'printf', 'realpath', 'readlink', 'basename', 'dirname']);
function producedKeyName(subs) {
  if (!Array.isArray(subs)) return null;
  for (const sub of subs) {
    if (!KEY_PREFILTER_RE.test(sub)) continue;
    const words = [];
    for (const t of tokenize(sub).tokens) {
      if (t.kind === 'sep') break;
      if (t.kind === 'word') words.push(t);
    }
    const cmd = resolveCommand(words);
    if (!cmd || !NAME_PRODUCERS.has(cmd.base)) continue;
    for (const w of cmd.operands) {
      if (!w.text.startsWith('-') && namesKey(w.text)) return w.text;
    }
  }
  return null;
}

"""
out = once(out, "// Returns the offending token text, or null.\nfunction findSecretRead(",
           PRODUCED + "// Returns the offending token text, or null.\nfunction findSecretRead(", 'produced-fn')
# comments that name removed GSD symbols — rewrite to the key vocabulary
out = once(out, "  // Case-fold the last segment (GLOB_PROBES are lower case) so `.ENV*` and",
           "  // Case-fold the last segment (KEY_PROBES are lower case) so `ID_RSA*` and", 'comment-probes')
out = once(out, "  // exemption is bypassed for it, but the `.env.example|…` suffix exemption in\n  // isSecretBasename still holds.",
           "  // exemption is bypassed for it, but the `*.pub` exemption in isKeyBasename\n  // still holds.", 'comment-xargs')
# J: renames
out = out.replace('findSecretRead', 'findKeyRead').replace('namesSecret', 'namesKey').replace("'secret-read'", "'key-read'")
out = out.replace("// Returns null (allowed), 'key-read', or 'glob-too-complex'.", "// Returns null (allowed), 'key-read', or 'glob-too-complex'.")

# leftovers that must not survive
for bad in ['isSecretBasename', 'GLOB_PROBES', 'NON_SECRET_ENV_SUFFIXES', 'finalExtension(', 'globAltSelectsSecret',
            "require('./lib/"]:
    assert bad not in out, f'leftover: {bad}'

DST.write_text(out)
print(f'wrote {DST} ({len(out.splitlines())} lines) from {SRC.name} sha {sha[:16]}')
