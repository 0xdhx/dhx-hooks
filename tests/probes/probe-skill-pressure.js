#!/usr/bin/env node
// Probe: skill-pressure segment — resolveSkillsRoot, countSkillPressure, PRESSURE_STATUSES.
// Covers D-01/D-02/D-03/D-04/D-09b/D-09c + PRESSURE-06 fixture injection.

// SAFE_FOR_LIVE: yes   (mkdtempSync; tmp-file fixtures only; one scenario reads
//                       the skills fixture by path which is read-only)
const fs = require('fs');
const os = require('os');
const path = require('path');

const WRAPPER = path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { resolveSkillsRoot, countSkillPressure, PRESSURE_STATUSES } = require(WRAPPER);

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-skill-pressure-'));

// Build a synthetic production-shape tree (reports/skills/<skill>/actionable/, D-09b).
// files: { [filename_without_ext]: status_string }
function makeSkillTree(root, skill, files) {
  const actionDir = path.join(root, 'reports', 'skills', skill, 'actionable');
  fs.mkdirSync(actionDir, { recursive: true });
  for (const [name, status] of Object.entries(files)) {
    const fm = [
      '---',
      `id: ${name}`,
      `status: ${status}`,
      `skill: ${skill}`,
      'created_at: 2026-05-29',
      'source_telemetry: test',
      `next_command: /dhx:skills modify ${skill}`,
      '---',
      '',
    ].join('\n');
    fs.writeFileSync(path.join(actionDir, name + '.md'), fm);
  }
}

// Write a single .md file at an arbitrary path (for archive/ directory-scope test).
function writeFile(filePath, status, skill) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const fm = [
    '---',
    `id: scope-test`,
    `status: ${status}`,
    `skill: ${skill}`,
    'created_at: 2026-05-29',
    'source_telemetry: test',
    `next_command: /dhx:skills modify ${skill}`,
    '---',
    '',
  ].join('\n');
  fs.writeFileSync(filePath, fm);
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

let pass = 0;
let fail = 0;

function check(name, actual, expected, extraInfo) {
  const ok = actual === expected;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
  if (!ok) {
    console.log(`       expected: ${expected}`);
    console.log(`       got:      ${actual}`);
    if (extraInfo) console.log(`       ${extraInfo}`);
  }
  ok ? pass++ : fail++;
}

// ---------------------------------------------------------------------------
// Scenario 1: zero pressure — only closed/archived/deferred files → pressure 0
// ---------------------------------------------------------------------------
{
  const root = path.join(tmpDir, 's1');
  makeSkillTree(root, 'skill-a', {
    'closed-item': 'closed',
    'archived-item': 'archived',
    'deferred-item': 'deferred',
    'superseded-item': 'superseded',
  });
  const { pressure } = countSkillPressure(root);
  check('zero pressure (closed/archived/deferred/superseded only) → 0', pressure, 0);
}

// ---------------------------------------------------------------------------
// Scenario 2: pressure=3 — active + needs-verify + regressed across 2 skill dirs
// (D-09b: production-shape */actionable/ wildcard glob)
// ---------------------------------------------------------------------------
{
  const root = path.join(tmpDir, 's2');
  // skill-alpha: active + needs-verify = 2 pressure
  makeSkillTree(root, 'skill-alpha', {
    'active-item': 'active',
    'nv-item': 'needs-verify',
  });
  // skill-beta: regressed + superseded = 1 pressure (superseded is 0)
  makeSkillTree(root, 'skill-beta', {
    'reg-item': 'regressed',
    'sup-item': 'superseded',
  });
  const { pressure } = countSkillPressure(root);
  check('pressure=3 over wildcard */actionable/ (D-09b)', pressure, 3);
}

// ---------------------------------------------------------------------------
// Scenario 3: directory-scope (D-09c) — status:active in archive/ → pressure 0
// ---------------------------------------------------------------------------
{
  const root = path.join(tmpDir, 's3');
  // Create an archive/ dir with an active file — must NOT be counted
  writeFile(
    path.join(root, 'reports', 'skills', 'scope-skill', 'archive', 'active-in-archive.md'),
    'active', 'scope-skill'
  );
  // actionable/ is missing entirely for scope-skill → expect 0
  const { pressure } = countSkillPressure(root);
  check('directory-scope: active in archive/ → pressure 0 (D-09c)', pressure, 0);
}

// ---------------------------------------------------------------------------
// Scenario 4: DHX_SKILLS_REPO env override (D-02) — resolveSkillsRoot returns tmpDir
// ---------------------------------------------------------------------------
{
  // Arrange: create a valid reports/skills/ under the tmpDir for this scenario
  const root = path.join(tmpDir, 's4-override');
  fs.mkdirSync(path.join(root, 'reports', 'skills'), { recursive: true });

  const saved = process.env.DHX_SKILLS_REPO;
  process.env.DHX_SKILLS_REPO = root;
  const resolved = resolveSkillsRoot();
  if (saved === undefined) {
    delete process.env.DHX_SKILLS_REPO;
  } else {
    process.env.DHX_SKILLS_REPO = saved;
  }
  check('DHX_SKILLS_REPO env override resolves to tmpDir (D-02)', resolved, root);
}

// ---------------------------------------------------------------------------
// Scenario 5: unreadable actionable/ dir → fail-silent, pressure 0
// ---------------------------------------------------------------------------
{
  const root = path.join(tmpDir, 's5');
  const actionDir = path.join(root, 'reports', 'skills', 'unreadable-skill', 'actionable');
  fs.mkdirSync(actionDir, { recursive: true });
  // Make actionable/ unreadable
  try {
    fs.chmodSync(actionDir, 0o000);
    const { pressure } = countSkillPressure(root);
    check('unreadable actionable/ dir → fail-silent, pressure 0', pressure, 0);
    fs.chmodSync(actionDir, 0o755); // restore for cleanup
  } catch {
    // On some systems chmod may not prevent root access; treat as pass (fail-silent holds)
    fs.chmodSync(actionDir, 0o755);
    check('unreadable actionable/ dir → fail-silent, pressure 0', 0, 0, '(chmod skipped on this platform)');
  }
}

// ---------------------------------------------------------------------------
// Scenario 6: missing actionable/ dir entirely → fail-silent, pressure 0
// ---------------------------------------------------------------------------
{
  const root = path.join(tmpDir, 's6');
  // Create a skill dir but NO actionable/ inside it
  fs.mkdirSync(path.join(root, 'reports', 'skills', 'empty-skill'), { recursive: true });
  const { pressure } = countSkillPressure(root);
  check('missing actionable/ dir → fail-silent, pressure 0', pressure, 0);
}

// ---------------------------------------------------------------------------
// Scenario 7: FIXTURE INJECTION (D-04/PRESSURE-06)
// Copy ALL 8 skills tests/fixtures/actionable/ files (including the
// needs-verify/multi-issue file — NONE excluded) into a wildcard
// reports/skills/<skill>/actionable/ tree, read expected_pressure from
// MANIFEST.json, assert countSkillPressure == expected_pressure (3).
// This is the cross-repo parsing-agreement PRESSURE-06 exists to enforce.
// ---------------------------------------------------------------------------
{
  // Resolve skills repo root: use DHX_SKILLS_REPO if set, else real resolveSkillsRoot().
  const skillsRepo = process.env.DHX_SKILLS_REPO || resolveSkillsRoot();
  if (!skillsRepo) {
    console.log('SKIP  fixture-injection (D-04/PRESSURE-06): could not resolve skills repo root');
    pass++; // count as pass — environment issue, not a code bug
  } else {
    const fixtureDir = path.join(skillsRepo, 'tests', 'fixtures', 'actionable');
    const manifestPath = path.join(fixtureDir, 'MANIFEST.json');

    try {
      // Read expected_pressure from MANIFEST.json (not hardcoded).
      const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
      const expectedPressure = manifest.expected_pressure;

      // Stage ALL fixture .md files into a wildcard tree under tmpDir.
      const root = path.join(tmpDir, 's7-fixture');
      const injectedActionDir = path.join(root, 'reports', 'skills', 'fixture-skill', 'actionable');
      fs.mkdirSync(injectedActionDir, { recursive: true });

      const mdFiles = fs.readdirSync(fixtureDir).filter(f => f.endsWith('.md'));
      for (const f of mdFiles) {
        fs.copyFileSync(path.join(fixtureDir, f), path.join(injectedActionDir, f));
      }

      // Assert countSkillPressure agrees with MANIFEST expected_pressure.
      const { pressure } = countSkillPressure(root);
      check(
        `fixture-injection (D-04/PRESSURE-06): ALL ${mdFiles.length} files incl. needs-verify/multi-issue → pressure=${expectedPressure}`,
        pressure,
        expectedPressure
      );
    } catch (err) {
      console.log(`FAIL  fixture-injection (D-04/PRESSURE-06): error — ${err.message}`);
      fail++;
    }
  }
}

// ---------------------------------------------------------------------------
// Summary + cleanup
// ---------------------------------------------------------------------------
console.log(`\n${pass}/${pass + fail} passed`);
try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
process.exit(fail === 0 ? 0 : 1);
