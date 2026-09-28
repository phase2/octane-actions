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

// Extract the package versions a log resolved to.
//
// `Locking` lines are a FULL resolution: Composer prints one for every package
// when it computes a lock file, which is what happens on every run of a
// lock-free build like Octane's nightly. Install-side lines are PARTIAL: they
// list only what changed relative to whatever vendor/ already held. So when a
// log has any Locking lines, only those are used and the result is marked
// complete; otherwise the install operations are used and it is marked
// partial, and a caller must not read a missing package as "not installed".
//
// If Composer ran more than once in the log, the last mention of a package
// wins, since that is the state the build finished with.
function extractPackageVersions(text) {
  const locked = new Map();
  const operated = new Map();
  for (const rawLine of stripAnsi(text).split('\n')) {
    const m = OPERATION_RE.exec(stripTimestamp(rawLine));
    if (!m) continue;
    const [, op, name, detail] = m;
    // `1.4.9 => 1.5.0` becomes 1.5.0; a plain version passes through.
    const version = detail.split('=>').pop().trim();
    if (op === 'Locking') {
      locked.set(name, version);
    } else if (op === 'Removing') {
      operated.set(name, null);
    } else {
      operated.set(name, version);
    }
  }
  if (locked.size > 0) {
    return { source: 'lock', packages: locked };
  }
  // A Removing line records an absence, not a version.
  for (const [name, version] of operated) {
    if (version === null) operated.delete(name);
  }
  return { source: operated.size > 0 ? 'install' : 'none', packages: operated };
}

// Merge per-job extraction results into one per-run result. A full (lock)
// resolution from any job beats partial install operations from another.
function mergePackageVersions(results) {
  const lock = results.filter(r => r.source === 'lock');
  const chosen = lock.length > 0 ? lock : results.filter(r => r.source === 'install');
  const packages = new Map();
  for (const r of chosen) {
    for (const [name, version] of r.packages) packages.set(name, version);
  }
  const source = lock.length > 0 ? 'lock' : (packages.size > 0 ? 'install' : 'none');
  return { source, packages };
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

  if (failed.source === 'none' || baseline.source === 'none') {
    const which = failed.source === 'none' && baseline.source === 'none'
      ? 'either run'
      : (failed.source === 'none' ? 'the failed run' : 'the baseline run');
    lines.push(`No Composer package operations were found in ${which}'s logs, so`);
    lines.push('dependency changes are UNKNOWN, not absent. Search the saved logs before');
    lines.push('drawing any conclusion about dependencies.');
    return lines.join('\n');
  }

  if (failed.source !== 'lock' || baseline.source !== 'lock') {
    lines.push('PARTIAL: at least one run shows only install operations, not a full');
    lines.push('resolution, so packages absent from this list may still differ.');
    lines.push('');
  }

  const diff = diffPackageVersions(baseline.packages, failed.packages);
  const total = diff.changed.length + diff.added.length + diff.removed.length;
  if (total === 0) {
    lines.push(`No resolved package versions differ (${failed.packages.size} packages compared).`);
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
  mergePackageVersions,
  diffPackageVersions,
  formatDependencyDiff,
};
