#!/usr/bin/env node
// dhx-skill-desc-audit.cjs — skill-description delta auditor (worker).
// Patterns: HP-015
//
// SPEC: ~/repos/cross-repo/docs/prompts/2026-07-17-skill-description-token-contract-SPEC.md
// §4.5 (delta auditor) + §4.6 (cross-repo seam). Invoked by dhx-skill-desc-audit.sh from
// the SessionStart dispatcher chain. Consumes the skills-repo collector via the dhx-tools
// provisioning path; OBSERVES every skill source after the fact (the skills-repo probe is
// the author-time gate for the owned dhx set — this auditor is the tripwire for the rest).
//
// Contract:
//   - Clean path = EMPTY stdout (zero context tokens). Breach = one compact block.
//   - Warn decision per over-budget, non-shadowed subject (SPEC §4.5, verbatim):
//       warn iff digest != acked_for
//            AND (snooze_until null/expired)
//            AND (digest != last-warned digest OR last_warned older than 7d re-warn TTL)
//   - ack <slug> binds acceptance to the CURRENT digest — a later content change re-warns.
//   - snooze <slug> <Xh|Xd|perma> is a timed mute (snoozeUntilFor math reused verbatim from
//     cross-repo scripts/watch/dhx-watch-driver.cjs:438-453; expired snoozes cleared at
//     read time, idempotently — watch checker pattern).
//   - Exempt-content-change (SPEC §4.4/G6): registry-exempt skill whose desc_sha256 no
//     longer matches last_reviewed_sha256 → ONE-TIME "re-review" notice keyed by digest
//     (state.skills[key].rereview_noticed_for); the registry itself is NEVER written.
//   - Fail-open with visibility: collector missing / non-zero / unparseable / unknown
//     schema major → silent exit 0, consecutive_failures++, error appended to the .log
//     beside the state file; at >=3 one line surfaces so silent breakage can't persist.
//
// State: ~/.claude/dhx-tools/state/skill-desc-audit.json (schema_version 1; atomic
// temp+rename writes; entries GC'd when a skill leaves the finding/re-review set).
//
// CLI:  node dhx-skill-desc-audit.cjs [audit]            (default — the SessionStart path)
//       node dhx-skill-desc-audit.cjs ack <slug[,slug]>
//       node dhx-skill-desc-audit.cjs snooze <slug[,slug]> <Xh|Xd|perma>
//
// Probe seams (env; all default to live paths):
//   DHX_SKILL_DESC_COLLECTOR   collector script path
//   DHX_SKILL_DESC_STATE       state file path
//   DHX_SKILL_DESC_EXEMPTIONS  exemption registry path (also forwarded to the collector)
//   DHX_SKILL_DESC_NOW         ISO timestamp override for "now" (TTL/snooze determinism)
//
// Regression probe: tests/probes/probe-skill-desc-audit.sh

'use strict';
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const HOME = process.env.HOME || '';
const COLLECTOR = process.env.DHX_SKILL_DESC_COLLECTOR ||
  path.join(HOME, '.claude', 'dhx-tools', 'health-collectors', 'collect-skill-descriptions.cjs');
const STATE_FILE = process.env.DHX_SKILL_DESC_STATE ||
  path.join(HOME, '.claude', 'dhx-tools', 'state', 'skill-desc-audit.json');
const EXEMPTIONS_FILE = process.env.DHX_SKILL_DESC_EXEMPTIONS ||
  path.join(HOME, 'repos', 'hooks', 'config', 'skill-desc-exemptions.json');
const LOG_FILE = STATE_FILE.replace(/\.json$/, '') + '.log';

const SCHEMA_MAJOR = 1;          // accepted collector schema major (SPEC §4.6 handshake)
const STATE_SCHEMA = 1;
const REWARN_TTL_MS = 7 * 86400 * 1000;   // SPEC §4.5 anti-rot leg: unacked resurfaces weekly
const FAIL_SURFACE_AT = 3;
const EX_USAGE = 64;             // mirrors dhx-watch-driver EX_USAGE

function nowMs() {
  const o = process.env.DHX_SKILL_DESC_NOW;
  if (o) { const t = Date.parse(o); if (!isNaN(t)) return t; }
  return Date.now();
}

function log(msg) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    fs.appendFileSync(LOG_FILE, `[${new Date(nowMs()).toISOString()}] ${msg}\n`);
  } catch (_) { /* logging must never break the auditor */ }
}

// ── state (broken/absent file must NEVER brick session start — fall back to fresh) ─────────
function freshState() { return { schema_version: STATE_SCHEMA, consecutive_failures: 0, skills: {} }; }

function loadState() {
  let raw;
  try { raw = fs.readFileSync(STATE_FILE, 'utf8'); } catch { return freshState(); }
  try {
    const s = JSON.parse(raw);
    if (!s || typeof s !== 'object' || typeof s.skills !== 'object' || s.skills === null) throw new Error('bad shape');
    if (typeof s.consecutive_failures !== 'number') s.consecutive_failures = 0;
    return s;
  } catch (e) {
    log(`state file unreadable (${e.message}) — resetting to fresh state (acks/snoozes lost)`);
    return freshState();
  }
}

function saveState(state, before) {
  const out = JSON.stringify(state, null, 2) + '\n';
  if (before !== undefined && out === before) return;   // no churn on identical state
  const dir = path.dirname(STATE_FILE);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(STATE_FILE)}.tmp.${process.pid}`);
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, STATE_FILE);
}

// ── snooze math — reused VERBATIM from cross-repo scripts/watch/dhx-watch-driver.cjs:438-453
// (WR-01 range check included; fail() adapted to this script's usage-error contract).
function fail(msg, code) { process.stderr.write(`dhx-skill-desc-audit: ${msg}\n`); process.exit(code); }

function snoozeUntilFor(duration, nowMsArg) {
  if (duration === 'perma') return 'perma';
  const m = /^(\d+)(h|d)$/.exec(duration);
  const n = parseInt(m[1], 10);
  const ms = m[2] === 'h' ? n * 3600 * 1000 : n * 86400 * 1000;
  const t = nowMsArg + ms;
  const d = new Date(t);
  if (isNaN(d.getTime())) fail(`snooze duration too large: ${duration} (exceeds representable date range)`, EX_USAGE);
  return d.toISOString();
}

// Read-time expiry GC (watch checker pattern): expired ISO snoozes cleared idempotently.
function gcSnoozes(state, now) {
  for (const k of Object.keys(state.skills)) {
    const su = state.skills[k].snooze_until;
    if (su && su !== 'perma') {
      const t = Date.parse(su);
      if (isNaN(t) || t <= now) state.skills[k].snooze_until = null;
    }
  }
}

function snoozeActive(entry, now) {
  if (!entry || !entry.snooze_until) return false;
  if (entry.snooze_until === 'perma') return true;
  const t = Date.parse(entry.snooze_until);
  return !isNaN(t) && t > now;
}

// ── naming + source-aware remediation (SPEC §4.5 — never point /dhx:skills at cache files) ──
function displayName(s) {
  return s.source.startsWith('plugin:dhx@') ? `dhx:${s.slug}` : s.slug;
}

function remediation(s) {
  if (s.source.startsWith('plugin:dhx@')) return `/dhx:skills modify ${s.slug}`;
  if (s.source === 'personal') return `edit ~/.claude/skills/${s.slug} — gsd-vendored? file upstream or /gsd-surface`;
  if (s.source === 'project' || s.source.startsWith('tree:')) return `edit the skill source (${s.path})`;
  const plugin = s.source.replace(/^plugin:/, '').split('@')[0];
  return `(${plugin} plugin) exempt: ~/repos/hooks/config/skill-desc-exemptions.json — or disable`;
}

// ── collector invocation (SPEC §4.6 seam: dhx-tools symlink; schema handshake) ──────────────
function runCollector() {
  if (!fs.existsSync(COLLECTOR)) throw new Error(`collector not provisioned: ${COLLECTOR} (run skills-repo scripts/install-dhx-tools.sh)`);
  const args = [COLLECTOR];
  // Forward the registry so collector cap-resolution and our re-review pass read ONE file.
  if (fs.existsSync(EXEMPTIONS_FILE)) args.push('--exemptions', EXEMPTIONS_FILE);
  const r = cp.spawnSync(process.execPath, args, { encoding: 'utf8', timeout: 30000 });
  if (r.error) throw new Error(`collector spawn failed: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`collector exit ${r.status}: ${(r.stderr || '').slice(0, 300)}`);
  let out;
  try { out = JSON.parse(r.stdout); } catch (e) { throw new Error(`collector output unparseable: ${e.message}`); }
  const major = Math.trunc(Number(out.schema_version));
  if (major !== SCHEMA_MAJOR) throw new Error(`unknown collector schema major ${out.schema_version} (accept ${SCHEMA_MAJOR}) — fail-open`);
  return out;
}

function loadRegistry() {
  try {
    const data = JSON.parse(fs.readFileSync(EXEMPTIONS_FILE, 'utf8'));
    return Array.isArray(data.exemptions) ? data.exemptions : [];
  } catch { return []; }
}

// ── audit (the SessionStart path — exit 0 ALWAYS) ───────────────────────────────────────────
function audit() {
  const state = loadState();
  const before = JSON.stringify(state, null, 2) + '\n';
  const now = nowMs();

  let collected;
  try {
    collected = runCollector();
  } catch (e) {
    state.consecutive_failures = (state.consecutive_failures || 0) + 1;
    log(`audit failure #${state.consecutive_failures}: ${e.message}`);
    try { saveState(state, before); } catch (we) { log(`state write failed: ${we.message}`); }
    if (state.consecutive_failures >= FAIL_SURFACE_AT) {
      process.stdout.write(`⚠ skill-desc auditor failing (${state.consecutive_failures} sessions) — see ${LOG_FILE}\n`);
    }
    process.exit(0);
  }
  state.consecutive_failures = 0;
  gcSnoozes(state, now);

  const subjects = (collected.subjects || []).filter((s) => !s.parse_error && !s.shadowed);
  const registry = loadRegistry();

  // Findings: over-budget vs the collector-resolved cap (exemption caps included — a skill
  // exceeding even its exempted max_chars is a real finding).
  const findings = subjects.filter((s) => s.over);

  const warnRows = [];
  const keepKeys = new Set();
  for (const s of findings) {
    const key = displayName(s);
    keepKeys.add(key);
    const entry = state.skills[key] || {};
    const digest = s.desc_sha256;
    const lastWarnedMs = entry.last_warned ? Date.parse(entry.last_warned) : NaN;
    // SPEC §4.5 warn boolean, verbatim:
    const warn = digest !== (entry.acked_for || null)
      && !snoozeActive(entry, now)
      && (digest !== entry.digest || isNaN(lastWarnedMs) || (now - lastWarnedMs) > REWARN_TTL_MS);
    if (warn) {
      warnRows.push(`  ${key} ${s.chars}/${s.cap} › ${remediation(s)}`);
      state.skills[key] = {
        digest,
        last_warned: new Date(now).toISOString(),
        acked_for: entry.acked_for || null,
        snooze_until: entry.snooze_until || null,
        ...(entry.rereview_noticed_for ? { rereview_noticed_for: entry.rereview_noticed_for } : {}),
      };
    } else if (!state.skills[key]) {
      // Over-budget but silent (fresh perma-case can't happen; defensive) — still track digest.
      state.skills[key] = { digest, last_warned: null, acked_for: null, snooze_until: null };
    }
  }

  // Exempt-content-change (G6): one-time re-review notice keyed by digest; registry untouched.
  const noticeRows = [];
  for (const s of subjects) {
    if (s.exempt_via !== 'registry') continue;
    const hit = registry.find((e) => e.slug === s.slug && (!e.source || s.source.includes(e.source)));
    if (!hit || !hit.last_reviewed_sha256) continue;
    if (hit.last_reviewed_sha256 === s.desc_sha256) continue;
    const key = displayName(s);
    keepKeys.add(key);
    const entry = state.skills[key] || {};
    if (entry.rereview_noticed_for !== s.desc_sha256) {
      noticeRows.push(`  ${key} exempted content changed — re-review: refresh last_reviewed_sha256, or tighten/remove the exemption`);
      state.skills[key] = { ...entry, rereview_noticed_for: s.desc_sha256 };
    }
  }

  // GC entries no longer backed by a current finding or a tracked exempt skill.
  for (const k of Object.keys(state.skills)) if (!keepKeys.has(k)) delete state.skills[k];

  try { saveState(state, before); } catch (we) { log(`state write failed: ${we.message}`); }

  if (warnRows.length || noticeRows.length) {
    const unverified = collected.discovery_unverified
      ? ` [unverified: CC ${collected.cc_version_observed} ≠ verified ${collected.verified_cc_version}]` : '';
    const lines = [];
    if (warnRows.length) {
      lines.push(`⚠ skill desc budget: ${warnRows.length} new/changed violation(s)${unverified}`);
      lines.push(...warnRows);
    }
    if (noticeRows.length) {
      if (!warnRows.length) lines.push(`⚠ skill desc: exempted content changed (${noticeRows.length})${unverified}`);
      lines.push(...noticeRows);
    }
    lines.push(`  › node ~/.claude/hooks/dhx-skill-desc-audit.cjs ack <slug> · snooze <slug> 8h|7d|perma · exempt: ~/repos/hooks/config/skill-desc-exemptions.json`);
    process.stdout.write(lines.join('\n') + '\n');
  }
  process.exit(0);
}

// ── ack / snooze entry points (watch-driver grammar: <slug[,slug]> [+ duration]) ────────────
function requireEntries(state, targetsArg) {
  const targets = String(targetsArg).split(',').map((t) => t.trim()).filter(Boolean);
  if (!targets.length) fail('no target slug given', EX_USAGE);
  for (const t of targets) {
    if (!state.skills[t] || !state.skills[t].digest) {
      fail(`no recorded finding for '${t}' — targets are the names shown in the audit block (state: ${STATE_FILE})`, EX_USAGE);
    }
  }
  return targets;
}

function ack(targetsArg) {
  const state = loadState();
  const before = JSON.stringify(state, null, 2) + '\n';
  const targets = requireEntries(state, targetsArg);
  for (const t of targets) state.skills[t].acked_for = state.skills[t].digest;
  saveState(state, before);
  process.stdout.write(`acked: ${targets.join(', ')} (digest-bound — a content change re-warns)\n`);
}

function snooze(targetsArg, duration) {
  if (!duration) fail('snooze requires <slug[,slug]> <Xh|Xd|perma>', EX_USAGE);
  if (!/^(\d+)(h|d)$/.test(duration) && duration !== 'perma') {
    fail(`snooze duration must be <N>h | <N>d | perma; got: ${duration}`, EX_USAGE);
  }
  const state = loadState();
  const before = JSON.stringify(state, null, 2) + '\n';
  const targets = requireEntries(state, targetsArg);
  const until = snoozeUntilFor(duration, nowMs());
  for (const t of targets) state.skills[t].snooze_until = until;
  saveState(state, before);
  process.stdout.write(`snoozed until ${until}: ${targets.join(', ')}\n`);
}

// ── dispatch ────────────────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const sub = argv[0] || 'audit';
if (sub === 'audit') audit();
else if (sub === 'ack') ack(argv[1] || '');
else if (sub === 'snooze') snooze(argv[1] || '', argv[2]);
else fail(`unknown subcommand: ${sub} (audit | ack <slug> | snooze <slug> <Xh|Xd|perma>)`, EX_USAGE);
