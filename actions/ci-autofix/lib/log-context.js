// Pure helpers for the "Collect failure context" step in action.yml.
//
// Kept free of any GitHub API or filesystem access so test-log-context.js can
// exercise them against fixture text with nothing but Node. The step itself
// does the downloading and writing; everything here is string in, string out.

'use strict';

// ANSI SGR sequences, in both forms a job log can carry them: the raw ESC byte
// the Actions API returns, and the caret-escaped `^[[` form that appears once
// a log has been through a terminal or `cat -v`.
const ANSI_RE = /(?:\x1b|\^\[)\[[0-9;]*[A-Za-z]/g;

// The Actions API prefixes every line with an ISO-8601 timestamp, sometimes
// preceded by a UTF-8 BOM on the first line of a step.
const TIMESTAMP_RE = /^﻿?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/;

function stripAnsi(text) {
  return String(text).replace(ANSI_RE, '');
}

function stripTimestamp(line) {
  return line.replace(TIMESTAMP_RE, '');
}

// A filesystem-safe name for a job's log file. The index prefix keeps files in
// job order and stops two jobs whose names slug identically from colliding.
function jobLogFileName(index, jobName) {
  const slug = String(jobName || 'job')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60) || 'job';
  return `${String(index + 1).padStart(2, '0')}-${slug}.log`;
}

// Composer prints one line per package operation, for example:
//   - Locking drupal/core (11.4.7)
//   - Installing twig/twig (v3.30.0): Extracting archive
//   - Upgrading drupal/ai (1.4.9 => 1.5.0)
//   - Downgrading foo/bar (2.0.0 => 1.9.0)
//   - Removing foo/baz (1.0.0)
const OPERATION_RE = /^\s*-\s+(Locking|Installing|Upgrading|Downgrading|Removing)\s+(\S+\/\S+)\s+\(([^)]*)\)/;

// Composer's notice when `composer install` finds no lock file and resolves
// from scratch, which is what every Octane nightly does.
const FRESH_RESOLUTION_RE = /No composer\.lock file present/;

// Extract the package versions a log resolved to.
//
// Operations are applied in the order they appear, so a later `composer
// update` or `require` in the same log lands on top of an earlier resolution:
// `Upgrading` and `Downgrading` move a version, `Removing` drops the package.
//
// The result is FULL only when the log shows a from-scratch resolution. That
// resolution prints a `Locking` line for every package, so from that point the
// map is a complete inventory. Anything else is PARTIAL: with a lock file
// already present, Composer lists only what changed (a `Locking` line for a new
// package, `Upgrading` for a moved one) and says nothing about the rest, so a
// missing package is not evidence of anything.
function extractPackageVersions(text) {
  let packages = new Map();
  let fresh = false;
  let sawOperation = false;
  for (const rawLine of stripAnsi(text).split('\n')) {
    const line = stripTimestamp(rawLine);
    if (FRESH_RESOLUTION_RE.test(line)) {
      // Everything before this is superseded by the resolution that follows.
      packages = new Map();
      fresh = true;
      continue;
    }
    const m = OPERATION_RE.exec(line);
    if (!m) continue;
    sawOperation = true;
    const [, op, name, detail] = m;
    if (op === 'Removing') {
      packages.delete(name);
      continue;
    }
    // `1.4.9 => 1.5.0` becomes 1.5.0; a plain version passes through.
    packages.set(name, detail.split('=>').pop().trim());
  }
  const source = fresh && packages.size > 0 ? 'full' : (sawOperation ? 'partial' : 'none');
  return { source, packages };
}

// Extract one run's package versions from all of its job logs.
//
// `logs` is [{ name, text, downloadFailed }] in job order. The texts are read as
// one log, so an update in a later job lands on the resolution of an earlier
// one. If ANY job's log could not be downloaded, the result is `unreadable`:
// with no reliable way to tell which job ran Composer, a missing log could hold
// the resolution, and reporting a diff from the rest would assert changes from
// incomplete data.
function extractRunPackages(logs) {
  const unreadable = logs.filter(l => l.downloadFailed).map(l => l.name);
  if (unreadable.length > 0) {
    return { source: 'unreadable', packages: new Map(), unreadable };
  }
  return extractPackageVersions(logs.map(l => l.text).join('\n'));
}

function diffPackageVersions(baseline, failed) {
  const changed = [];
  const added = [];
  const removed = [];
  for (const [name, version] of failed) {
    if (!baseline.has(name)) {
      added.push({ name, version });
    } else if (baseline.get(name) !== version) {
      changed.push({ name, from: baseline.get(name), to: version });
    }
  }
  for (const [name, version] of baseline) {
    if (!failed.has(name)) removed.push({ name, version });
  }
  const byName = (a, b) => a.name.localeCompare(b.name);
  return {
    changed: changed.sort(byName),
    added: added.sort(byName),
    removed: removed.sort(byName),
  };
}

// Render the comparison for the prompt, bounded to maxChars.
//
// Every branch states what it could and could not establish, in words the
// agent cannot mistake for "nothing changed": the 2026-09-26 misdiagnosis was
// exactly an agent asserting unchanged dependencies it had never seen.
function formatDependencyDiff({ failed, baseline, baselineRun, maxChars = 6000 }) {
  const lines = [];
  if (!baselineRun) {
    lines.push('No earlier successful run of this workflow on this branch was found, so');
    lines.push('there is no baseline to compare against. Dependency changes are UNKNOWN.');
    return lines.join('\n');
  }
  lines.push(`Baseline: run ${baselineRun.id} (${baselineRun.created_at}), the most recent`);
  lines.push(`successful run of this workflow on this branch: ${baselineRun.html_url}`);
  lines.push('');

  for (const [label, r] of [['the failed run', failed], ['the baseline run', baseline]]) {
    if (r.source === 'unreadable') {
      lines.push(`The log(s) of ${r.unreadable.join(', ')} in ${label} could not be downloaded,`);
      lines.push('so dependency changes are UNKNOWN. Check the saved logs for what did load.');
      return lines.join('\n');
    }
  }

  if (failed.source === 'none' || baseline.source === 'none') {
    const which = failed.source === 'none' && baseline.source === 'none'
      ? 'either run'
      : (failed.source === 'none' ? 'the failed run' : 'the baseline run');
    lines.push(`No Composer package operations were found in ${which}'s logs, so`);
    lines.push('dependency changes are UNKNOWN, not absent. Search the saved logs before');
    lines.push('drawing any conclusion about dependencies.');
    return lines.join('\n');
  }

  // Added and Removed are only meaningful between two complete inventories. In
  // a partial map a package is absent because Composer did not touch it, so
  // only version changes to packages seen on both sides are reported.
  const complete = failed.source === 'full' && baseline.source === 'full';
  if (!complete) {
    lines.push('PARTIAL: at least one run shows only incremental Composer operations, not a');
    lines.push('from-scratch resolution. Only version changes to packages seen in both runs');
    lines.push('are listed; packages absent from this list may still differ.');
    lines.push('');
  }

  const diff = diffPackageVersions(baseline.packages, failed.packages);
  if (!complete) {
    diff.added = [];
    diff.removed = [];
  }
  const total = diff.changed.length + diff.added.length + diff.removed.length;
  if (total === 0) {
    const compared = complete
      ? failed.packages.size
      : [...failed.packages.keys()].filter(name => baseline.packages.has(name)).length;
    lines.push(`No resolved package versions differ (${compared} packages compared).`);
    return lines.join('\n');
  }

  lines.push(`${total} package difference(s), baseline -> failed:`);
  const body = [];
  if (diff.changed.length) {
    body.push(`Changed (${diff.changed.length}):`);
    for (const p of diff.changed) body.push(`  ${p.name} ${p.from} -> ${p.to}`);
  }
  if (diff.added.length) {
    body.push(`Added (${diff.added.length}):`);
    for (const p of diff.added) body.push(`  ${p.name} ${p.version}`);
  }
  if (diff.removed.length) {
    body.push(`Removed (${diff.removed.length}):`);
    for (const p of diff.removed) body.push(`  ${p.name} ${p.version}`);
  }

  // Truncate on a line boundary and say so, rather than cutting mid-entry.
  const truncNote = '(list truncated; compare the saved logs for the rest)';
  let out = lines.join('\n');
  for (const line of body) {
    if (out.length + 1 + line.length + 1 + truncNote.length > maxChars) {
      return `${out}\n${truncNote}`;
    }
    out += `\n${line}`;
  }
  return out;
}

module.exports = {
  stripAnsi,
  stripTimestamp,
  jobLogFileName,
  extractPackageVersions,
  extractRunPackages,
  diffPackageVersions,
  formatDependencyDiff,
};
