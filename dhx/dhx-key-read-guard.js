#!/usr/bin/env node
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
// GSD's hooks/gsd-secret-read-guard.js (gsd-hook-version 1.14.0, sha256 486ca81ea2e44050…),
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
// (`$(printf '\x2essh')`) defeats it, exactly as it defeats Claude Code's own parser. A
// custom IdentityFile name is protected only on a path that also shows `.ssh` (the
// prefilter). Fail-open on a hook-internal error, like the GSD original.
// Config: config/key-read-guard.json (DHX_KEY_GUARD_CONFIG=<path> overrides; probes use it).
// Probe: tests/probes/probe-dhx-key-read-guard.js.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// Inlined from GSD hooks/lib/hook-exit.js — only what this guard uses. Deny = exit 2
// with the reason on stderr (HP-009: exit 2 blocks and CC hands stderr to the model);
// allow = silent exit 0.
const HOOK_ON_CRASH = Object.freeze({ ALLOW: 'allow', DENY: 'deny' });
function allow() { process.exit(0); }
function deny(reason) { process.stderr.write(String(reason) + '\n'); process.exit(2); }
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
  const s = tok.replace(/[\\/]+$/, '');
  const i = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
  return i === -1 ? s : s.slice(i + 1);
}

// Fail open on a hook-internal error (see header). Declared ONCE so the
// outer catch states its policy explicitly (#3911).
const ON_CRASH = HOOK_ON_CRASH.ALLOW;

// Commands longer than this are denied rather than scanned (see header).
const MAX_COMMAND_LENGTH = 1024 * 1024;

// Recursion budget for `$( )` / backtick / `<( )` / nested-shell rescans.
const MAX_NESTING_DEPTH = 3;

// Brace-alternative budget for a Grep glob before it is denied as too complex.
const MAX_GLOB_ALTERNATIVES = 64;

// Built-in private-key basenames: id_<algorithm>, optional _sk (FIDO), optional custom
// suffix (`id_ed25519_github`, `id_rsa.old`). Anchored on the algorithm on purpose — a bare
// `id_*` would fire on ordinary code files (`id_generator.py`, `id_map.csv`).
const KEY_BASENAME_RE = /^id_(?:rsa|dsa|ecdsa|ed25519)(?:_sk)?(?:[._-][a-z0-9._-]*)?$/;

// Prefilter: a command or path containing none of these cannot name a protected file, so it
// is never parsed — the per-call cost for ordinary commands stays near zero.
const KEY_PREFILTER_RE = /id_|\.ssh|\.aws/i;

// Commands that USE a key without printing it: all of their operands are exempt.
const KEY_USE_COMMANDS = new Set(['ssh-add', 'ssh-keygen']);

// Commands that take a key only as the value of `-i` / `-o IdentityFile=`: that value is
// exempt; every other operand (scp's files, ssh's remote command) is still checked, because
// copying a key off the box is the exfiltration step this guard exists for.
const IDENTITY_FLAG_COMMANDS = new Set(['ssh', 'scp', 'sftp', 'ssh-copy-id']);

// Commands whose first positional operand (or every -e / -f value) is a PATTERN, not a path:
// the operator's own `git diff --name-only | grep -iE '…|id_rsa|…'` secret scans must pass.
const PATTERN_FIRST_COMMANDS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack']);

// Command-prefix wrappers to look through when locating the command word at
// the head of a segment (same set as hooks/gsd-windsurf-pre-command.js).
const CMD_PREFIXES = new Set(['sudo', 'env', 'command', 'nice', 'nohup', 'time', 'doas']);

// Commands whose ordinary operands are file NAMES, never file CONTENTS. A
// closed set on purpose: anything not listed is assumed to read.
const NON_READING_COMMANDS = new Set([
  'test', '[', '[[', 'ls', 'stat', 'touch', 'rm', 'chmod', 'chown', 'mkdir',
  'basename', 'dirname', 'realpath', 'file', 'echo', 'printf',
  'cd', 'pushd', 'popd',
]);

// Shell interpreters that run a script from `-c`, a file operand, or stdin
// (heredoc / here-string / piped `echo`|`printf`). `su` is here for its `-c`
// form (`su [user] -c 'cmd'`); a bare `su user` resolves to file mode, which
// only runs the ordinary operand check. `eval`, `source`/`.` and `xargs` are
// their own cases below; they are not in this set.
const SHELL_INTERPRETERS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh', 'su']);

// Shell flags whose VALUE is the next operand (`bash -o pipefail`,
// `bash --rcfile x <<EOF`): skipped when locating a script-file operand, so a
// flag value is not mistaken for the script and stdin mode still applies.
const SHELL_VALUE_FLAGS = new Set(['-o', '-O', '+o', '+O', '--rcfile', '--init-file']);

// Value-taking `xargs` flags (long `--flag=value` forms are single words).
// `-a`/`--arg-file` additionally replaces stdin, so it suppresses the pipeline
// inference below.
const XARGS_VALUE_FLAGS = new Set(['-n', '-I', '-i', '-L', '-l', '-P', '-s', '-d', '-E', '-a']);

// Names a glob (Grep's `glob`, or a globbed Bash operand) is matched against. Configured
// IdentityFile basenames are appended at runtime (keyProbes()).
const KEY_PROBES = [
  'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'id_ecdsa_sk', 'id_ed25519_sk',
  'id_ed25519_github', 'id_rsa_work',
];

// ---------------------------------------------------------------------------
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
    for (const line of text.split(/\r?\n/)) {
      const m = /^\s*IdentityFile(?:\s*=\s*|\s+)(.+?)\s*$/i.exec(line);
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
  const lower = frag.toLowerCase().replace(/[\\/]+$/, '');
  const base = normalizeWindowsBasename(lastSegment(lower));
  if (base === '') return false;
  if (base === '.ssh' || base === '.aws') return true;
  if (/[*?[]/.test(base)) {
    const alts = expandBraces(base) || [base];
    return alts.some((a) => globAltSelectsKey(a, lower));
  }
  if (isKeyBasename(base)) return true;
  return base === 'credentials' && /(^|[\\/])\.aws[\\/]credentials$/.test(lower);
}

// True when any path-shaped fragment of the token names a protected file. Fragments split on
// whitespace, quotes, `$( )` / backtick punctuation and `=` `;` `,` `<` `>`, so a key path
// inside a substitution or a `--flag=value` is still seen; the part after a `:` is checked
// too (git `<ref>:<path>`, Windows drives).
function namesKey(tok) {
  if (typeof tok !== 'string' || tok === '' || !KEY_PREFILTER_RE.test(tok)) return false;
  for (const frag of tok.split(/[\s"'`()=;,<>]+/)) {
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
      else if (t === '-o' && operands[i + 1] && /^identityfile[=\s]/i.test(operands[i + 1].text)) skip.add(i + 1);
      else if (/^-i./.test(t) || /^-oidentityfile[=\s]/i.test(t)) skip.add(i);
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

// ---------------------------------------------------------------------------
// Grep glob analysis
// ---------------------------------------------------------------------------

// Expand `{a,b,…}` (nested allowed) into the list of alternatives, or null
// when the list would exceed MAX_GLOB_ALTERNATIVES. Malformed braces are
// treated literally.
function expandBraces(glob) {
  const open = glob.indexOf('{');
  if (open === -1) return [glob];
  let depth = 0;
  let close = -1;
  const commas = [];
  for (let i = open; i < glob.length; i++) {
    const ch = glob[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) { close = i; break; }
    } else if (ch === ',' && depth === 1) commas.push(i);
  }
  if (close === -1) return [glob];
  const pre = glob.slice(0, open);
  const post = glob.slice(close + 1);
  const inner = glob.slice(open + 1, close);
  const parts = [];
  let start = 0;
  for (const c of commas) {
    parts.push(inner.slice(start, c - open - 1));
    start = c - open;
  }
  parts.push(inner.slice(start));
  const out = [];
  for (const part of parts) {
    const expanded = expandBraces(pre + part + post);
    if (expanded === null) return null;
    for (const alt of expanded) {
      out.push(alt);
      if (out.length > MAX_GLOB_ALTERNATIVES) return null;
    }
  }
  return out;
}

// Anchored regex for one brace-free glob alternative (`*` → `[^/]*`,
// `?` → `[^/]`, `[…]` classes passed through with `[!` → `[^`).
function globAltToRegex(alt) {
  let out = '^';
  for (let i = 0; i < alt.length; i++) {
    const ch = alt[i];
    if (ch === '*') out += '[^/]*';
    else if (ch === '?') out += '[^/]';
    else if (ch === '[') {
      const j = alt.indexOf(']', i + 1);
      if (j === -1) out += '\\[';
      else {
        const body = alt.slice(i + 1, j);
        out += '[' + (body.startsWith('!') ? '^' + body.slice(1) : body).replace(/\\/g, '\\\\') + ']';
        i = j;
      }
    } else out += ch.replace(/[.+^${}()|\\]/g, '\\$&');
  }
  return new RegExp(out + '$');
}

// Does this single brace-free glob alternative select a protected key name? `full` is the
// whole lower-cased fragment: a pure wildcard counts only inside a `.ssh` directory.
function globAltSelectsKey(alt, full) {
  if (alt === '') return false;
  if (/^[*?]+$/.test(alt) && !/(^|[\\/])\.ssh[\\/]/.test(full || '')) return false;
  let re;
  try {
    re = globAltToRegex(alt);
  } catch {
    return true; // an unparsable class — deny is the safe side
  }
  return keyProbes().some((probe) => re.test(probe));
}

// Returns null (allowed), 'key-read', or 'glob-too-complex'.
function classifyGrepGlob(glob) {
  // Segment via the SAME `lastSegment` helper Read/Bash use (namesKey),
  // rather than a hand-rolled forward-slash-only split — the two used to
  // diverge on a backslash-bearing glob (`config\.env`), which `lastSegment`
  // reduces to `.env` but a `/`-only split left untouched, letting it escape
  // this arm's predicate while Read/Bash still blocked it.
  // Case-fold the last segment (KEY_PROBES are lower case) so `ID_RSA*` and
  // `*.ENV` select the secret namespace on case-insensitive filesystems.
  const segment = lastSegment(glob).toLowerCase();
  const alts = expandBraces(segment);
  if (alts === null) return 'glob-too-complex';
  return alts.some((a) => globAltSelectsKey(a, glob.toLowerCase())) ? 'key-read' : null;
}

// ---------------------------------------------------------------------------
// Bash command scan — pass 1: tokenizer
// ---------------------------------------------------------------------------

// Index of the `)` closing a `$(` / `<(` / `>(` opened just before `i`, or
// str.length when unterminated. Quote- and heredoc-aware so a `)` inside a
// quoted string or a heredoc body never closes the span early.
function findParenClose(str, i) {
  let depth = 1;
  let heredocTags = [];
  while (i < str.length) {
    const ch = str[i];
    if (ch === '\\') { i += 2; continue; }
    if (ch === "'") {
      const j = str.indexOf("'", i + 1);
      i = j === -1 ? str.length : j + 1;
      continue;
    }
    if (ch === '"') {
      i++;
      while (i < str.length && str[i] !== '"') {
        if (str[i] === '\\') { i += 2; continue; }
        if (str[i] === '$' && str[i + 1] === '(') { i = findParenClose(str, i + 2) + 1; continue; }
        if (str[i] === '`') {
          const j = str.indexOf('`', i + 1);
          i = j === -1 ? str.length : j + 1;
          continue;
        }
        i++;
      }
      i++;
      continue;
    }
    if (ch === '`') {
      const j = str.indexOf('`', i + 1);
      i = j === -1 ? str.length : j + 1;
      continue;
    }
    if (ch === '<' && str[i + 1] === '<' && str[i + 2] !== '<') {
      const tag = readHeredocTag(str, i + 2);
      heredocTags.push(tag);
      i = tag.end;
      continue;
    }
    if (ch === '\n' && heredocTags.length) {
      i = consumeHeredocBodies(str, i + 1, heredocTags).end;
      heredocTags = [];
      continue;
    }
    if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      if (depth === 0) return i;
    }
    i++;
  }
  return str.length;
}

// Reads the tag word after `<<` / `<<-` starting at `i`.
function readHeredocTag(str, i) {
  let stripTabs = false;
  if (str[i] === '-') { stripTabs = true; i++; }
  while (str[i] === ' ' || str[i] === '\t') i++;
  let quoted = false;
  let tag = '';
  if (str[i] === "'" || str[i] === '"') {
    const q = str[i];
    const j = str.indexOf(q, i + 1);
    tag = str.slice(i + 1, j === -1 ? str.length : j);
    quoted = true;
    i = j === -1 ? str.length : j + 1;
  } else {
    if (str[i] === '\\') { quoted = true; i++; }
    while (i < str.length && !/[\s;&|<>()]/.test(str[i])) tag += str[i++];
  }
  return { tag, quoted, stripTabs, end: i };
}

// From `i` (start of the line after the heredoc-opening line), consume one
// body per pending tag in order. Returns every body with its `quoted`/`seg`
// (the caller emits a token per body and recurses substitutions only for
// unquoted ones) and the index just past the last terminator line. An
// unterminated body consumes to end of input.
function consumeHeredocBodies(str, i, tags) {
  const bodies = [];
  for (const t of tags) {
    let body = '';
    let terminated = false;
    while (i < str.length) {
      const nl = str.indexOf('\n', i);
      const lineEnd = nl === -1 ? str.length : nl;
      const line = str.slice(i, lineEnd);
      i = nl === -1 ? str.length : nl + 1;
      const probe = t.stripTabs ? line.replace(/^\t+/, '') : line;
      if (probe === t.tag) { terminated = true; break; }
      body += line + '\n';
    }
    bodies.push({ body, quoted: t.quoted, seg: t.seg });
    if (!terminated) break;
  }
  return { bodies, end: i };
}

// `$( )` and backtick spans inside an unquoted heredoc body.
function collectSubstitutions(body, nested) {
  let i = 0;
  while (i < body.length) {
    if (body[i] === '$' && body[i + 1] === '(') {
      const e = findParenClose(body, i + 2);
      nested.push(body.slice(i + 2, e));
      i = e + 1;
      continue;
    }
    if (body[i] === '`') {
      const j = body.indexOf('`', i + 1);
      const e = j === -1 ? body.length : j;
      nested.push(body.slice(i + 1, e));
      i = e + 1;
      continue;
    }
    i++;
  }
}

// Tokens: { kind: 'word'|'op'|'sep', text, quoted: 'none'|'single'|'double', seg }.
// `op` tokens carry `read` (an input redirect) and `dup` (`>&N`, consumes no
// target). Nested command strings are collected separately.
function tokenize(str) {
  const tokens = [];
  const nested = [];
  let buf = '';
  let wordSubs = [];
  let quoted = 'none';
  let hasWord = false;
  let seg = 0;
  let heredocs = [];
  let expectTag = null;

  const flush = () => {
    if (!hasWord) return;
    if (expectTag) {
      // Record the current seg (still the `<<` segment — flush runs before the
      // newline sep increments it) so pass 2 can attach the body to the shell.
      heredocs.push({ tag: buf, quoted: quoted !== 'none', stripTabs: expectTag.stripTabs, seg });
      expectTag = null;
    } else {
      tokens.push({ kind: 'word', text: buf, quoted, seg, subs: wordSubs });
    }
    buf = '';
    wordSubs = [];
    quoted = 'none';
    hasWord = false;
  };
  // The operator text ends segment `seg`; pass 2 reads it to tell `a | bash`
  // (pipe inference) from `a || bash` and to skip grouping seps.
  const sep = (text) => {
    flush();
    tokens.push({ kind: 'sep', text, quoted: 'none', seg });
    seg++;
  };
  const op = (text, read, dup) => {
    tokens.push({ kind: 'op', text, quoted: 'none', seg, read, dup });
  };

  let i = 0;
  while (i < str.length) {
    const ch = str[i];

    if (ch === "'") {
      hasWord = true;
      if (quoted === 'none') quoted = 'single';
      const j = str.indexOf("'", i + 1);
      const end = j === -1 ? str.length : j;
      buf += str.slice(i + 1, end);
      i = end + 1;
      continue;
    }

    if (ch === '"') {
      hasWord = true;
      if (quoted === 'none') quoted = 'double';
      i++;
      while (i < str.length && str[i] !== '"') {
        const c = str[i];
        if (c === '\\' && i + 1 < str.length && '"\\$`\n'.includes(str[i + 1])) {
          if (str[i + 1] !== '\n') buf += str[i + 1];
          i += 2;
          continue;
        }
        if (c === '$' && str[i + 1] === '(') {
          const e = findParenClose(str, i + 2);
          { const sub = str.slice(i + 2, e); nested.push(sub); wordSubs.push(sub); }
          i = e + 1;
          continue;
        }
        if (c === '`') {
          const j = str.indexOf('`', i + 1);
          const e = j === -1 ? str.length : j;
          { const sub = str.slice(i + 1, e); nested.push(sub); wordSubs.push(sub); }
          i = e + 1;
          continue;
        }
        buf += c;
        i++;
      }
      i++;
      continue;
    }

    if (ch === '\\') {
      if (str[i + 1] === '\n') { i += 2; continue; } // line continuation
      hasWord = true;
      if (i + 1 < str.length) buf += str[i + 1];
      i += 2;
      continue;
    }

    if (ch === '$' && str[i + 1] === '(') {
      hasWord = true;
      const e = findParenClose(str, i + 2);
      { const sub = str.slice(i + 2, e); nested.push(sub); wordSubs.push(sub); }
      i = e + 1;
      continue;
    }

    if (ch === '$' && str[i + 1] === '{') {
      hasWord = true;
      const j = str.indexOf('}', i);
      const e = j === -1 ? str.length - 1 : j;
      buf += str.slice(i, e + 1);
      i = e + 1;
      continue;
    }

    if (ch === '`') {
      hasWord = true;
      const j = str.indexOf('`', i + 1);
      const e = j === -1 ? str.length : j;
      { const sub = str.slice(i + 1, e); nested.push(sub); wordSubs.push(sub); }
      i = e + 1;
      continue;
    }

    if ((ch === '<' || ch === '>') && str[i + 1] === '(') {
      flush();
      const e = findParenClose(str, i + 2);
      const inner = str.slice(i + 2, e);
      nested.push(inner);
      // Emit a word carrying the inner script so a shell / `source` operand
      // (`sh <(echo 'cat .env')`) can reconstruct it; the bare nested recursion
      // above only sees `echo …`, whose operands are not read.
      tokens.push({ kind: 'word', text: str.slice(i, e + 1), quoted: 'none', seg, procsub: inner });
      i = e + 1;
      continue;
    }

    if (ch === '\n') {
      sep('\n');
      i++;
      if (heredocs.length) {
        const r = consumeHeredocBodies(str, i, heredocs);
        for (const b of r.bodies) {
          // Emit a heredoc token per body (quoted included) — the body is the
          // stdin script only a shell interpreter runs. Kept out of `words`.
          tokens.push({ kind: 'heredoc', text: b.body, quoted: b.quoted, seg: b.seg });
          if (!b.quoted) collectSubstitutions(b.body, nested); // bash expands $( ) here
        }
        heredocs = [];
        i = r.end;
      }
      continue;
    }

    if (ch === ' ' || ch === '\t' || ch === '\r') {
      flush();
      i++;
      continue;
    }

    if (ch === '#' && !hasWord) {
      const j = str.indexOf('\n', i);
      i = j === -1 ? str.length : j;
      continue;
    }

    if (ch === '<' || ch === '>' || (ch === '&' && str[i + 1] === '>')) {
      let fd = '';
      if (hasWord && quoted === 'none' && /^\d+$/.test(buf)) {
        fd = buf;
        buf = '';
        hasWord = false;
      } else {
        flush();
      }
      let j = i;
      let text;
      if (str.startsWith('<<<', j)) { text = '<<<'; j += 3; }
      else if (str.startsWith('<<-', j)) { text = '<<-'; j += 3; }
      else if (str.startsWith('<<', j)) { text = '<<'; j += 2; }
      else if (str.startsWith('&>>', j)) { text = '&>>'; j += 3; }
      else if (str.startsWith('&>', j)) { text = '&>'; j += 2; }
      else if (str.startsWith('>>', j)) { text = '>>'; j += 2; }
      else if (str.startsWith('>|', j)) { text = '>|'; j += 2; }
      else { text = ch; j += 1; }
      if (text === '<<' || text === '<<-') {
        expectTag = { stripTabs: text === '<<-' };
        i = j;
        continue;
      }
      let dup = false;
      if ((text === '<' || text === '>') && str[j] === '&' && /[\d-]/.test(str[j + 1] || '')) {
        let k = j + 1;
        while (k < str.length && /[\d-]/.test(str[k])) k++;
        text += str.slice(j, k);
        j = k;
        dup = true;
      }
      op(fd + text, text[0] === '<' && text !== '<<<', dup);
      i = j;
      continue;
    }

    // Lookahead first, THEN record the full operator, so `a || bash` reports
    // `||` (no pipe inference) and `a | bash` reports `|` (pipe inference).
    if (ch === ';') {
      let text = ';';
      i++;
      if (str[i] === ';') { text = ';;'; i++; }
      sep(text);
      continue;
    }
    if (ch === '|') {
      let text = '|';
      i++;
      if (str[i] === '|') { text = '||'; i++; }
      else if (str[i] === '&') { text = '|&'; i++; }
      sep(text);
      continue;
    }
    if (ch === '&') {
      let text = '&';
      i++;
      if (str[i] === '&') { text = '&&'; i++; }
      sep(text);
      continue;
    }
    if (ch === '(' || ch === ')') {
      sep(ch);
      i++;
      continue;
    }
    if ((ch === '{' || ch === '}') && !hasWord && (i + 1 >= str.length || /[\s;&|)]/.test(str[i + 1]))) {
      sep(ch);
      i++;
      continue;
    }

    hasWord = true;
    buf += ch;
    i++;
  }
  flush();
  return { tokens, nested };
}

// ---------------------------------------------------------------------------
// Bash command scan — pass 2: per-segment evaluation
// ---------------------------------------------------------------------------

// `@file` (curl -d), `--flag=value`, `-Xvalue` → the operand that names the file.
function normalizeOperand(text) {
  let v = text;
  if (v.startsWith('@')) v = v.slice(1);
  if (v.startsWith('--')) {
    const eq = v.indexOf('=');
    if (eq !== -1) v = v.slice(eq + 1);
  } else if (/^-[A-Za-z]./.test(v)) {
    v = v.slice(2);
  }
  return v;
}

const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// `-c`, or a combined short flag ending in `c` (`-lc`, `-ec`, `-euc`): mode c.
const DASH_C_RE = /^-[A-Za-z]*c$/;

const GROUPING_SEPS = new Set(['(', ')', '{', '}']);

// Command base + operands after leading `VAR=val` assignments and prefix
// wrappers (`sudo`, `env VAR=x`, …), or null when nothing but prefixes remain.
function resolveCommand(words) {
  let idx = 0;
  while (idx < words.length && ASSIGNMENT_RE.test(words[idx].text)) idx++;
  while (idx < words.length) {
    const base = lastSegment(words[idx].text).toLowerCase();
    if (!CMD_PREFIXES.has(base)) break;
    idx++;
    if (base === 'env') {
      while (idx < words.length && ASSIGNMENT_RE.test(words[idx].text)) idx++;
    }
  }
  if (idx >= words.length) return null;
  return { base: lastSegment(words[idx].text).toLowerCase(), operands: words.slice(idx + 1) };
}

// The statically-knowable stdin a segment writes: `echo`/`printf` operands
// joined by a space (for `echo`, leading `-neE` flags dropped). Any other
// source (`cat gen.sh | bash`, `curl … | sh`) is not knowable → null.
function reconstructedScript(words) {
  const cmd = resolveCommand(words);
  if (!cmd) return null;
  if (cmd.base === 'echo') {
    let start = 0;
    while (start < cmd.operands.length && /^-[neE]+$/.test(cmd.operands[start].text)) start++;
    return cmd.operands.slice(start).map((w) => w.text).join(' ');
  }
  if (cmd.base === 'printf') return cmd.operands.map((w) => w.text).join(' ');
  return null;
}

// Same rule applied to a `<( … )` / `>( … )` inner script's first segment.
function reconstructedProcsub(inner) {
  const { tokens } = tokenize(inner);
  const words = [];
  for (const t of tokens) {
    if (t.kind === 'sep') break;
    if (t.kind === 'word') words.push(t);
  }
  return reconstructedScript(words);
}

// The operator connecting segment `s` to the nearest PRECEDING segment that has
// word tokens, skipping empty grouping segments (`(echo cat .env) | bash` has an
// empty segment between `)` and `|`). Returns { op, prevSeg }.
function precedingOp(s, bySeg, sepAfter) {
  let p = s - 1;
  while (p >= 0 && !(bySeg.get(p) || []).some((t) => t.kind === 'word')) p--;
  if (p < 0) return { op: undefined, prevSeg: -1 };
  let op;
  for (let q = p; q < s; q++) {
    const text = sepAfter.get(q);
    if (text !== undefined && !GROUPING_SEPS.has(text)) op = text; // last non-grouping wins
  }
  return { op, prevSeg: p };
}

// Names produced by a `$( )` / backtick substitution that feeds a READING command's operand
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

// Returns the offending token text, or null.
function findKeyRead(command, depth) {
  const { tokens, nested } = tokenize(command);

  for (const sub of nested) {
    if (depth < MAX_NESTING_DEPTH) {
      const hit = findKeyRead(sub, depth + 1);
      if (hit) return hit;
    }
  }

  // Group by seg, not separator order: heredoc tokens carry their `<<`
  // segment's seg and must reach the shell even though a data heredoc sits
  // between other separators. Heredocs are kept OUT of `words` so a data body
  // is never operand-checked (`cat <<EOF\n.env\nEOF` stays allowed).
  const bySeg = new Map();
  const heredocsBySeg = new Map();
  const sepAfter = new Map();
  let maxSeg = 0;
  for (const t of tokens) {
    if (t.seg > maxSeg) maxSeg = t.seg;
    if (t.kind === 'sep') {
      sepAfter.set(t.seg, t.text);
    } else if (t.kind === 'heredoc') {
      if (!heredocsBySeg.has(t.seg)) heredocsBySeg.set(t.seg, []);
      heredocsBySeg.get(t.seg).push(t);
    } else {
      if (!bySeg.has(t.seg)) bySeg.set(t.seg, []);
      bySeg.get(t.seg).push(t);
    }
  }

  for (let s = 0; s <= maxSeg; s++) {
    const segTokens = bySeg.get(s);
    if (!segTokens) continue;

    const words = [];
    const hereStrings = [];
    for (let k = 0; k < segTokens.length; k++) {
      const t = segTokens[k];
      if (t.kind === 'op') {
        if (t.dup) continue;
        const target = segTokens[k + 1];
        if (target && target.kind === 'word') {
          k++;
          if (t.text.endsWith('<<<')) hereStrings.push(target.text); // stdin data for a shell
          // Input redirects are reads regardless of the command's exemption.
          else if (t.read && namesKey(target.text)) return target.text;
        }
        continue;
      }
      words.push(t);
    }
    if (!words.length) continue;

    const cmd = resolveCommand(words);
    if (!cmd) continue;
    const { base, operands } = cmd;
    const heredocs = heredocsBySeg.get(s) || [];

    // eval concatenates ALL its operands and runs the result.
    if (base === 'eval') {
      if (depth < MAX_NESTING_DEPTH) {
        const hit = findKeyRead(operands.map((w) => w.text).join(' '), depth + 1);
        if (hit) return hit;
      }
      continue;
    }

    // `source` / `.` reads a file (or a process-substitution script).
    if (base === 'source' || base === '.') {
      for (const w of operands) {
        if (w.procsub !== undefined && depth < MAX_NESTING_DEPTH) {
          const src = reconstructedProcsub(w.procsub);
          if (src !== null) {
            const hit = findKeyRead(src, depth + 1);
            if (hit) return hit;
          }
        } else if (namesKey(normalizeOperand(w.text))) return w.text;
      }
      continue;
    }

    // xargs turns stdin file names into a sub-command's operands.
    if (base === 'xargs' && depth < MAX_NESTING_DEPTH) {
      const hit = scanXargsPipe(operands, s, bySeg, sepAfter, depth);
      if (hit) return hit;
      // `.env` given to xargs itself (`xargs -a .env cat`) is an ordinary
      // operand — fall through to the operand check below.
    }

    if (SHELL_INTERPRETERS.has(base) && depth < MAX_NESTING_DEPTH) {
      const hit = scanShellInterpreter(operands, heredocs, hereStrings, s, bySeg, sepAfter, depth);
      if (hit) return hit;
      // `bash .env` (file mode) is caught by the operand check below.
    }

    if (NON_READING_COMMANDS.has(base) || KEY_USE_COMMANDS.has(base)) continue;

    const skip = exemptOperandIndexes(base, operands);
    for (let i = 0; i < operands.length; i++) {
      if (skip.has(i)) continue;
      const w = operands[i];
      if (namesKey(normalizeOperand(w.text))) return w.text;
      const produced = producedKeyName(w.subs);
      if (produced) return produced;
    }
  }
  return null;
}

// A shell interpreter's script comes from `-c`, a file operand, or stdin.
function scanShellInterpreter(operands, heredocs, hereStrings, s, bySeg, sepAfter, depth) {
  const cIdx = operands.findIndex((w) => DASH_C_RE.test(w.text));
  if (cIdx !== -1) {
    // Mode c: the next operand is the script; stdin is DATA (not scanned).
    const script = operands[cIdx + 1];
    if (script) return findKeyRead(script.text, depth + 1);
    return null;
  }
  let fileTok;
  for (let m = 0; m < operands.length; m++) {
    if (SHELL_VALUE_FLAGS.has(operands[m].text)) { m++; continue; }
    if (!operands[m].text.startsWith('-')) { fileTok = operands[m]; break; }
  }
  if (fileTok) {
    // Mode file: `bash <(echo 'cat .env')`; a plain file is checked as an operand.
    if (fileTok.procsub !== undefined) {
      const src = reconstructedProcsub(fileTok.procsub);
      if (src !== null) return findKeyRead(src, depth + 1);
    }
    return null;
  }
  // Mode stdin: heredoc bodies, here-strings, and a piped echo/printf source.
  for (const h of heredocs) {
    const hit = findKeyRead(h.text, depth + 1);
    if (hit) return hit;
  }
  for (const hs of hereStrings) {
    const hit = findKeyRead(hs, depth + 1);
    if (hit) return hit;
  }
  const { op, prevSeg } = precedingOp(s, bySeg, sepAfter);
  if ((op === '|' || op === '|&') && prevSeg >= 0) {
    const src = reconstructedScript((bySeg.get(prevSeg) || []).filter((t) => t.kind === 'word'));
    if (src !== null) return findKeyRead(src, depth + 1);
  }
  return null;
}

// `find … | xargs cat`: the upstream segment's operands become file names the
// sub-command reads. Only inferred across a real pipe and when stdin is not
// redirected by `-a`/`--arg-file`. A sub-command that is itself a shell
// (`xargs -I{} sh -c 'cat .env'`) carries a literal script and is scanned in
// mode c whether or not a pipe feeds it.
function scanXargsPipe(operands, s, bySeg, sepAfter, depth) {
  let argFile = false;
  let subIdx = -1;
  for (let m = 0; m < operands.length; m++) {
    const t = operands[m].text;
    if (t === '-a' || t === '--arg-file') { argFile = true; m++; continue; }
    if (t.startsWith('--arg-file=')) { argFile = true; continue; }
    if (XARGS_VALUE_FLAGS.has(t)) { m++; continue; }
    if (t.startsWith('--') && t.includes('=')) continue;
    if (t.startsWith('-')) continue; // no-value flag (-0 -r -t -p) or long flag
    subIdx = m;
    break;
  }
  if (subIdx === -1) return null; // no sub-command: xargs defaults to echo

  const subBase = lastSegment(operands[subIdx].text).toLowerCase();
  if (SHELL_INTERPRETERS.has(subBase)) {
    // Heredocs/here-strings belong to xargs, not the sub-shell; pass none.
    const hit = scanShellInterpreter(operands.slice(subIdx + 1), [], [], s, bySeg, sepAfter, depth);
    if (hit) return hit;
  }
  if (argFile) return null; // stdin replaced by a file — no pipeline inference
  if (NON_READING_COMMANDS.has(subBase)) return null;

  const { op, prevSeg } = precedingOp(s, bySeg, sepAfter);
  if (op !== '|' && op !== '|&') return null;
  if (prevSeg < 0) return null;

  // Every upstream operand is a candidate file name — the NON_READING
  // exemption is bypassed for it, but the `*.pub` exemption in isKeyBasename
  // still holds.
  const prevCmd = resolveCommand((bySeg.get(prevSeg) || []).filter((t) => t.kind === 'word'));
  if (!prevCmd) return null;
  for (const w of prevCmd.operands) {
    if (namesKey(normalizeOperand(w.text))) return w.text;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------

const PATTERN_TEXT = 'SSH private keys (id_<algorithm>[_sk][suffix] and every IdentityFile in the ' +
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

// Strips a `module:` prefix so Kimi's `kimi_cli.tools.file:Grep` (not in the
// KIMI_TOOL_NAMES map — Grep has the same name on both buses) matches.
function bareToolName(raw) {
  return typeof raw === 'string' ? raw.slice(raw.lastIndexOf(':') + 1) : '';
}

// #2304: Kimi's native hook bus delivers Kimi's tool vocabulary in the
// payload (ReadFile / Shell) and `path` instead of `file_path`; the map and
// normalizer below are the byte-identical copy every guard carries (bound by
// tests/kimi-guard-normalization-parity.test.cjs — do not edit locally).
// Grep keeps its name on Kimi and is not in the map; bareToolName() above
// strips the module prefix for it.
const KIMI_TOOL_NAMES = new Map([['WriteFile', 'Write'], ['StrReplaceFile', 'Edit'], ['ReadFile', 'Read'], ['Shell', 'Bash']]);
function normalizeKimiPayload(data) {
  // #2595 (review nit): `JSON.parse('null')` is null, and null/primitive
  // payloads reached the `data.tool_name` read below and threw — falsifying
  // this function's own "total over the inputs JSON can express" claim, which
  // property (e) now tests directly. Harmless in practice (a null payload has
  // nothing to guard, and the throw landed in the same fail-open catch as the
  // exit-0 it now takes deliberately) but the claim should be true as stated.
  if (data === null || typeof data !== 'object') return data;
  const raw = data.tool_name;
  if (typeof raw !== 'string') return data;
  const mapped = KIMI_TOOL_NAMES.get(raw.slice(raw.lastIndexOf(':') + 1));
  if (!mapped) return data;
  data.tool_name = mapped;
  if (data.tool_response === undefined && data.tool_output !== undefined) {
    data.tool_response = data.tool_output;
  }
  const input = data.tool_input;
  if (input && typeof input === 'object') {
    // #2547 (review): Kimi's `path` is AUTHORITATIVE — it must win outright,
    // not merely fill in when `file_path` happens to be absent. kimi-cli's file
    // tools carry no `file_path` field at all (src/kimi_cli/tools/file/write.py,
    // replace.py, @ 4a550ef — the SHA #2547 pins), and soul/toolset.py hands the
    // model's raw json-parsed
    // arguments to PreToolUse verbatim, doing typed validation only later inside
    // tool.call() — after the hook has already decided. So a `file_path` in a
    // Kimi payload is ALWAYS model-supplied, and under the old `=== undefined`
    // condition it SHADOWED the field kimi-cli actually executes on. A payload
    // pairing a cross-root `path` with a spurious `file_path: ""` left every
    // guard reading an empty string and exiting 0, while the identical write
    // without the extra key blocked — a bypass needing no crash at all. The same
    // shadowing also preserved a NON-STRING `file_path` (`[]`), which threw
    // inside gsd-worktree-path-guard's path.isAbsolute() and reached its outer
    // `catch { process.exit(0) }`: the same crash-to-allow this fix closes
    // elsewhere, reached through the guard's own read rather than through
    // normalization. Overwriting can only ever narrow what a guard inspects to
    // the path that will actually be written, so it cannot under-block.
    if (typeof input.path === 'string') {
      input.file_path = input.path;
    }
    const edits = Array.isArray(input.edit) ? input.edit
      : (input.edit && typeof input.edit === 'object') ? [input.edit] : [];
    if (edits.length) {
      // #2547: `e?.old`, not `e.old` — `??` guards the value, not the
      // dereference, so a NULLISH entry (`edit: [null]`) threw a TypeError
      // here. normalizeKimiPayload runs before any tool dispatch, so that throw
      // reached each guard's outer `catch { process.exit(0) }` and silently
      // downgraded a should-BLOCK call into an allow. (A string/number entry
      // never threw — `('x').old` is a legal read yielding undefined.)
      //
      // The String() coercion is guarded for the same reason: `{"toString":
      // null}` is valid JSON that throws "Cannot convert object to primitive
      // value", which is the identical crash-to-allow with a different
      // trigger. Degrading only the non-coercible entry to '' keeps
      // stringification intact for every value that CAN coerce (numbers,
      // arrays, plain objects), so nothing downstream — including
      // gsd-prompt-guard's scan of new_string — loses content it saw before.
      const editText = (v) => { try { return String(v ?? ''); } catch { return ''; } };
      // #2595 (review Major 2): reconstruct UNCONDITIONALLY, mirroring the
      // `path` decision above rather than merely filling in when the field
      // happens to be absent. kimi-cli's StrReplaceFile schema is `path` +
      // `edit` only (src/kimi_cli/tools/file/replace.py @ 4a550ef) — it carries
      // no `old_string`/`new_string` at all, so either field appearing in a
      // Kimi payload is ALWAYS model-supplied, exactly like `file_path`. Under
      // the old `=== undefined` condition a model-supplied `new_string: ""`
      // SHADOWED the reconstruction, leaving gsd-prompt-guard's injection scan
      // reading '' and exiting at its `if (!content)` before it ever saw the
      // real `edit[].new` — a one-key bypass of the very scan this fix's
      // guarded coercion exists to keep fed. A `typeof` test would NOT close
      // it: a benign non-empty string shadows just as effectively as ''.
      input.old_string = edits.map((e) => editText(e?.old)).join('\n');
      input.new_string = edits.map((e) => editText(e?.new)).join('\n');
    }
  }
  return data;
}

let input = '';
const stdinTimeout = setTimeout(() => allow(undefined), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = normalizeKimiPayload(JSON.parse(input));

    // A null/primitive payload has nothing to guard — exit deliberately
    // rather than throwing into the fail-open catch below (#2595 class).
    if (data === null || typeof data !== 'object') {
      allow(undefined);
    }

    const tool = bareToolName(data.tool_name);
    if (tool !== 'Read' && tool !== 'Grep' && tool !== 'Bash') {
      allow(undefined);
    }
    if (!data.tool_input || typeof data.tool_input !== 'object') {
      allow(undefined);
    }

    // Every payload field is read TYPED in a single statement (#2547 class):
    // `[]`/`{}` are truthy and a non-string degrades to '' here.
    if (tool === 'Read') {
      const filePath = typeof data.tool_input.file_path === 'string' ? data.tool_input.file_path : '';
      if (namesKey(filePath)) emitBlock('key-read', tool, filePath);
      allow(undefined);
    }

    if (tool === 'Grep') {
      const grepPath = typeof data.tool_input.path === 'string' ? data.tool_input.path
        : (typeof data.tool_input.file_path === 'string' ? data.tool_input.file_path : '');
      if (namesKey(grepPath)) emitBlock('key-read', tool, grepPath);
      const glob = typeof data.tool_input.glob === 'string' ? data.tool_input.glob : '';
      if (glob !== '' && /\.ssh|\.aws/i.test(grepPath + ' ' + glob)) {
        const verdict = classifyGrepGlob(glob);
        if (verdict) emitBlock(verdict, tool, glob);
      }
      allow(undefined);
    }

    // Bash
    const command = typeof data.tool_input.command === 'string' ? data.tool_input.command : '';
    if (command === '' || !KEY_PREFILTER_RE.test(command)) allow(undefined);
    if (command.length > MAX_COMMAND_LENGTH) emitBlock('command-too-large', tool, '');
    const hit = findKeyRead(command, 0);
    if (hit !== null) emitBlock('key-read', tool, hit);
    allow(undefined);
  } catch {
    // Fail open — never block valid tool calls due to hook errors.
    // ON_CRASH is declared ALLOW at module top (#3911).
    crash(ON_CRASH, undefined);
  }
});
