'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { renderEvidence, renderEvidenceLink } = require('./render.js');

const base = {
  actor: 'tekante',
  sha: 'abc123',
  statement: 'Manual regression suite v3 executed; all cases passed.',
  timestamp: '2026-09-04T19:00:00Z',
  checkName: 'manual-test-evidence',
};

test('records who asserted, when, and against which commit', () => {
  const { title, summary } = renderEvidence(base);
  assert.match(title, /@tekante/);
  assert.match(summary, /\| Asserted by \| @tekante \|/);
  assert.match(summary, /\| Recorded at \| 2026-09-04T19:00:00Z \|/);
  assert.match(summary, /`abc123`/);
  assert.match(summary, /> Manual regression suite v3 executed/);
});

test('requires the fields that carry the evidence', () => {
  for (const missing of ['actor', 'sha', 'statement']) {
    const fields = { ...base, [missing]: '' };
    assert.throws(() => renderEvidence(fields), new RegExp(`${missing} is required`));
  }
});

test('a whitespace-only statement is not a statement', () => {
  assert.throws(() => renderEvidence({ ...base, statement: '   \n  ' }), /statement is required/);
});

test('renders an http(s) evidence URL as a link', () => {
  const { summary } = renderEvidence({ ...base, evidenceUrl: 'https://example.com/run/42', evidenceLabel: 'TestRail run' });
  assert.match(summary, /\[TestRail run\]\(https:\/\/example\.com\/run\/42\)/);
});

test('says so plainly when no evidence URL was given', () => {
  const { summary } = renderEvidence(base);
  assert.match(summary, /_none provided_/);
});

test('refuses to render a non-http scheme as a clickable link', () => {
  assert.equal(renderEvidenceLink('javascript:alert(1)', 'x'), '`javascript:alert(1)` (unsupported scheme)');
  assert.equal(renderEvidenceLink('not a url', 'x'), '`not a url` (not a valid URL)');
});

test('a multi-line statement cannot break out of the evidence block', () => {
  const { summary } = renderEvidence({
    ...base,
    statement: 'line one\n| injected | table |\n## heading',
  });
  for (const line of ['> line one', '> | injected | table |', '> ## heading']) {
    assert.ok(summary.includes(line), `expected quoted line: ${line}`);
  }
});

test('external id is namespaced by check name', () => {
  assert.equal(renderEvidence(base).externalId, 'soc-evidence:manual-test-evidence');
});
