'use strict';

/**
 * Renders the evidence block recorded on an attestation or waiver check run.
 *
 * This exists as an action rather than as markdown assembled in each repo's
 * workflow YAML because the schema IS the control: a check run carries no
 * creator field of its own, so who asserted what, when, and against which
 * commit only survives if something writes it into `output`. Centralising it
 * means an adopting repo cannot quietly omit a field an auditor expects.
 */

const REQUIRED = ['actor', 'sha', 'statement'];

/** Only http(s) links are rendered as links; anything else is shown verbatim. */
function renderEvidenceLink(url, label) {
  if (!url) return '_none provided_';
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return `\`${url}\` (not a valid URL)`;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return `\`${url}\` (unsupported scheme)`;
  }
  return `[${label || 'Evidence'}](${parsed.href})`;
}

function renderEvidence(fields) {
  for (const key of REQUIRED) {
    if (!fields[key] || !String(fields[key]).trim()) {
      throw new Error(`${key} is required to record an attestation`);
    }
  }

  const {
    actor, sha, statement, evidenceUrl, evidenceLabel,
    runUrl, eventName, timestamp, checkName,
  } = fields;

  const rows = [
    ['Asserted by', `@${actor}`],
    ['Recorded at', timestamp],
    ['Commit', `\`${sha}\``],
    ['Evidence', renderEvidenceLink(evidenceUrl, evidenceLabel)],
  ];
  if (eventName) rows.push(['Triggered by', `\`${eventName}\``]);
  if (runUrl) rows.push(['Recorded in', `[workflow run](${runUrl})`]);

  const summary = [
    '| field | value |',
    '| --- | --- |',
    ...rows.map(([k, v]) => `| ${k} | ${v} |`),
    '',
    '**Statement**',
    '',
    // Block quote so a multi-line statement cannot break the table above, and
    // so leading markdown in the statement cannot restructure the document.
    ...String(statement).trim().split('\n').map((l) => `> ${l}`),
  ].join('\n');

  return {
    title: `Asserted by @${actor}`,
    summary,
    externalId: `soc-evidence:${checkName || ''}`,
  };
}

module.exports = { renderEvidence, renderEvidenceLink };
