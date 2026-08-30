// markdown-progress-table.js — the ONE parser for a `.planning/ROADMAP.md`
// "## Progress" table.
//
// Extracted 2026-08-30 out of dhx/dhx-statusline.js so the statusline (which
// COUNTS the table) and dhx/dhx-roadmap-status-vocab.js (which VALIDATES its
// Status column) cannot drift apart on what a progress table even is. The
// validator exists to protect the statusline's `/^Complete$/i` numerator test;
// a validator reading rows the statusline never sees — or missing rows it does —
// would be protecting a different file.
//
// INVARIANT (cross-consumer): both consumers locate tables and split rows
// through THIS module. Do not re-implement either function in a consumer, and
// do not fork the row/column semantics per caller — differences in SCOPE belong
// in the caller (which tables, which rows), never in the parse. Enforced by
// tests/probes/probe-roadmap-status-vocab.js § 1, which drives one fixture
// through both consumers and asserts they see the same table.
//
// Behaviour is byte-preserved from the pre-extraction statusline: see the
// docs/decisions.md 2026-08-30 row and the five statusline probes, which were
// green before and after the move.

/**
 * Split a markdown table row into trimmed cells: `| a | b |` → ['a', 'b'].
 * The leading and trailing pipes are stripped first so the cell list carries
 * no phantom empties — that is what lets a name→index map built from the
 * header line index straight into every data row.
 */
function splitTableRow(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|')) s = s.slice(0, -1);
  return s.split('|').map((c) => c.trim());
}

/**
 * Locate EVERY progress table in `text`, in document order.
 *
 * Located by column NAME: any table row whose cells include both `Phase` and
 * `Status` (case-insensitive), followed by a matching delimiter row. The
 * delimiter requirement is what keeps a prose row that happens to mention both
 * words from being read as a header.
 *
 * Each entry is `{ columns, rows, ragged, line }`:
 *   columns  lowercased/trimmed header names
 *   rows     cell arrays indexed the same way (empty when ragged)
 *   ragged   true when a data row's cell count disagreed with the header — an
 *            unescaped pipe shifts every cell after it, so the honest answer
 *            for that table is "don't know". Both consumers WITHHOLD a ragged
 *            table rather than guess; they must not read `rows` on one.
 *   line     0-based index of the header line (for operator-facing reports)
 *
 * A whole-file scan, not first-match: the statusline wants only the active
 * milestone's table and takes [0] via findProgressTable() below, but the
 * vocabulary validator wants ALL of them — a malformed Status cell in an
 * archived-milestone table is exactly the four-month-unnoticed case it exists
 * to catch.
 */
function findProgressTables(text) {
  const isDelimiterCell = (c) => /^:?-{1,}:?$/.test(c);
  const lines = text.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (!t.startsWith('|') || t.indexOf('|', 1) === -1) continue;
    const columns = splitTableRow(lines[i]).map((c) => c.toLowerCase());
    if (columns.indexOf('phase') === -1 || columns.indexOf('status') === -1) continue;
    if (lines[i + 1] === undefined) continue;
    const delim = splitTableRow(lines[i + 1]);
    if (delim.length !== columns.length || !delim.every(isDelimiterCell)) continue;
    const rows = [];
    let ragged = false;
    let j = i + 2;
    for (; j < lines.length; j++) {
      if (!lines[j].trim().startsWith('|')) break;
      const cells = splitTableRow(lines[j]);
      if (cells.length !== columns.length) { ragged = true; break; }
      rows.push({ cells, line: j });
    }
    out.push({ columns, rows: ragged ? [] : rows, ragged, line: i });
    i = j - 1;   // resume after this table; its data rows are not headers
  }
  return out;
}

/**
 * The statusline's historical single-table accessor, preserved exactly:
 * the FIRST header-matching table, or null when there is none or when that
 * first table is ragged. `rows` is flattened back to bare cell arrays because
 * that is the shape parseRoadmapProgress consumes.
 */
function findProgressTable(text) {
  const first = findProgressTables(text)[0];
  if (!first || first.ragged) return null;
  return { columns: first.columns, rows: first.rows.map((r) => r.cells) };
}

module.exports = { splitTableRow, findProgressTables, findProgressTable };
