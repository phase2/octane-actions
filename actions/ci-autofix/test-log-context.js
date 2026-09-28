// Tests for lib/log-context.js, the dependency comparison the triage prompt
// carries. Run with: node --test actions/ci-autofix/test-log-context.js
//
// The fixtures are trimmed from real Build Nightly logs (runs 36097810273 and
// 36220190181, 2026-09-25/26), including the timestamp prefix and the ANSI
// colour codes the Actions API returns. That pair is the case this exists
// for: the agent called the 2026-09-26 failure "no package change" while
// twig/twig and drupal/ai had both moved.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const L = require('./lib/log-context.js');

const E = '\x1b';
const ts = '2026-09-26T05:16:56.3938431Z ';
const lock = (name, version) => `${ts}  - Locking ${E}[32m${name}${E}[39m (${E}[33m${version}${E}[39m)`;

const fresh = `${ts}${E}[30;43mNo composer.lock file present. Updating dependencies to latest instead of installing from lock file.${E}[39;49m`;

const baselineLog = [
  fresh,
  `${ts}${E}[32mLock file operations: 3 installs, 0 updates, 0 removals${E}[39m`,
  lock('drupal/core', '11.4.7'),
  lock('twig/twig', 'v3.29.0'),
  lock('drupal/ai', '1.4.9'),
  `${ts}${E}[32mWriting lock file${E}[39m`,
].join('\n');

const failedLog = [
  fresh,
  lock('drupal/core', '11.4.7'),
  lock('twig/twig', 'v3.30.0'),
  lock('drupal/ai', '1.5.0'),
  lock('drupal/ai_logging', '1.3.3'),
  `${ts}  - Installing ${E}[32mtwig/twig${E}[39m (${E}[33mv3.30.0${E}[39m): Extracting archive`,
].join('\n');

const baselineRun = {
  id: 36097810273,
  created_at: '2026-09-25T05:15:36Z',
  html_url: 'https://github.com/phase2/octane-ci/actions/runs/36097810273',
};

test('strips ANSI in both the raw and caret-escaped forms', () => {
  assert.equal(L.stripAnsi(`${E}[32mok${E}[39m`), 'ok');
  assert.equal(L.stripAnsi('^[[33m[INFO] ^[[0mdone'), '[INFO] done');
});

test('strips the Actions timestamp prefix, including a leading BOM', () => {
  assert.equal(L.stripTimestamp('2026-09-26T05:16:56.3938431Z hello'), 'hello');
  assert.equal(L.stripTimestamp('﻿2026-09-26T05:16:56.1Z hello'), 'hello');
  assert.equal(L.stripTimestamp('no timestamp'), 'no timestamp');
});

test('a from-scratch resolution is full', () => {
  const r = L.extractPackageVersions(failedLog);
  assert.equal(r.source, 'full');
  assert.equal(r.packages.get('twig/twig'), 'v3.30.0');
  assert.equal(r.packages.size, 4);
});

test('Locking lines without a from-scratch resolution are partial', () => {
  // A lock file was present: Composer locks only the new package.
  assert.equal(L.extractPackageVersions(lock('drupal/new', '1.0.0')).source, 'partial');
});

// The case the first version got wrong: once any Locking line appeared, the
// Upgrading lines were dropped and the result was still labelled complete.
test('a later update in the same log is applied on top of the resolution', () => {
  const r = L.extractPackageVersions([
    baselineLog,
    `${ts}Lock file operations: 1 install, 1 update, 1 removal`,
    lock('drupal/new', '1.0.0'),
    `${ts}  - Upgrading ${E}[32mtwig/twig${E}[39m (${E}[33mv3.29.0${E}[39m => ${E}[33mv3.30.0${E}[39m)`,
    `${ts}  - Removing drupal/ai (1.4.9)`,
  ].join('\n'));
  assert.equal(r.source, 'full');
  assert.equal(r.packages.get('twig/twig'), 'v3.30.0');
  assert.equal(r.packages.get('drupal/new'), '1.0.0');
  assert.equal(r.packages.has('drupal/ai'), false);
});

test('a from-scratch resolution supersedes anything before it', () => {
  const r = L.extractPackageVersions([`${ts}  - Installing stale/pkg (0.1.0)`, baselineLog].join('\n'));
  assert.equal(r.source, 'full');
  assert.equal(r.packages.has('stale/pkg'), false);
});

test('install operations alone are partial, applied in order', () => {
  const r = L.extractPackageVersions([
    `${ts}  - Installing foo/a (1.0.0): Extracting archive`,
    `${ts}  - Upgrading foo/b (1.0.0 => 1.1.0)`,
    `${ts}  - Downgrading foo/c (2.0.0 => 1.9.0)`,
    `${ts}  - Installing foo/d (1.0.0)`,
    `${ts}  - Removing foo/d (1.0.0)`,
  ].join('\n'));
  assert.equal(r.source, 'partial');
  assert.deepEqual(Object.fromEntries(r.packages), { 'foo/a': '1.0.0', 'foo/b': '1.1.0', 'foo/c': '1.9.0' });
});

test('the last mention of a package wins when Composer ran twice', () => {
  const r = L.extractPackageVersions([lock('foo/a', '1.0.0'), lock('foo/a', '2.0.0')].join('\n'));
  assert.equal(r.packages.get('foo/a'), '2.0.0');
});

test('a log with no Composer output reports none, not an empty resolution', () => {
  assert.equal(L.extractPackageVersions('PHPUnit 11.5.56\nOK (9 tests)').source, 'none');
});

test('a run is read across its jobs in order', () => {
  const r = L.extractRunPackages([
    { name: 'Build', text: baselineLog, downloadFailed: false },
    { name: 'Update', text: `${ts}  - Upgrading twig/twig (v3.29.0 => v3.30.0)`, downloadFailed: false },
  ]);
  assert.equal(r.source, 'full');
  assert.equal(r.packages.get('twig/twig'), 'v3.30.0');
});

test('any undownloadable job log makes the run unreadable, naming the job', () => {
  const r = L.extractRunPackages([
    { name: 'Build and Update environment', text: '(log download failed: 404)', downloadFailed: true },
    { name: 'Test', text: baselineLog, downloadFailed: false },
  ]);
  assert.equal(r.source, 'unreadable');
  assert.deepEqual(r.unreadable, ['Build and Update environment']);
});

test('diff reports changed, added and removed packages, sorted', () => {
  const d = L.diffPackageVersions(
    new Map([['b/b', '1'], ['a/a', '1'], ['gone/x', '1']]),
    new Map([['b/b', '2'], ['a/a', '2'], ['new/y', '1']]),
  );
  assert.deepEqual(d.changed.map(p => p.name), ['a/a', 'b/b']);
  assert.deepEqual(d.added, [{ name: 'new/y', version: '1' }]);
  assert.deepEqual(d.removed, [{ name: 'gone/x', version: '1' }]);
});

test('the 2026-09-26 regression: the moved packages appear in the prompt text', () => {
  const out = L.formatDependencyDiff({
    failed: L.extractPackageVersions(failedLog),
    baseline: L.extractPackageVersions(baselineLog),
    baselineRun,
  });
  assert.match(out, /twig\/twig v3\.29\.0 -> v3\.30\.0/);
  assert.match(out, /drupal\/ai 1\.4\.9 -> 1\.5\.0/);
  assert.match(out, /Added \(1\):\n  drupal\/ai_logging 1\.3\.3/);
  assert.match(out, /runs\/36097810273/);
  assert.doesNotMatch(out, /drupal\/core/);
});

test('identical resolutions say so, with the package count', () => {
  const r = L.extractPackageVersions(baselineLog);
  const out = L.formatDependencyDiff({ failed: r, baseline: r, baselineRun });
  assert.match(out, /No resolved package versions differ \(3 packages compared\)/);
});

// The three branches below are the ones where an agent could otherwise read
// silence as "unchanged". Each must say UNKNOWN or PARTIAL in so many words.
test('no baseline run says dependency changes are unknown', () => {
  const r = L.extractPackageVersions(failedLog);
  assert.match(L.formatDependencyDiff({ failed: r, baseline: r, baselineRun: null }), /UNKNOWN/);
});

test('no Composer output in a run says unknown, and names which run', () => {
  const none = L.extractPackageVersions('no composer here');
  const out = L.formatDependencyDiff({ failed: none, baseline: L.extractPackageVersions(baselineLog), baselineRun });
  assert.match(out, /UNKNOWN, not absent/);
  assert.match(out, /the failed run's logs/);
});

test('a partial comparison is flagged, and lists only shared version changes', () => {
  const partial = L.extractPackageVersions([
    `${ts}  - Installing twig/twig (v3.30.0)`,
    `${ts}  - Installing only/here (1.0.0)`,
  ].join('\n'));
  const out = L.formatDependencyDiff({ failed: partial, baseline: L.extractPackageVersions(baselineLog), baselineRun });
  assert.match(out, /^PARTIAL:/m);
  assert.match(out, /twig\/twig v3\.29\.0 -> v3\.30\.0/);
  assert.doesNotMatch(out, /Added|Removed|only\/here|drupal\/core/);
});

test('a partial comparison with no shared changes counts only shared packages', () => {
  const partial = L.extractPackageVersions(`${ts}  - Installing twig/twig (v3.29.0)`);
  const out = L.formatDependencyDiff({ failed: partial, baseline: L.extractPackageVersions(baselineLog), baselineRun });
  assert.match(out, /No resolved package versions differ \(1 packages compared\)/);
});

test('an unreadable run says unknown and names the job, on either side', () => {
  const ok = L.extractPackageVersions(baselineLog);
  const bad = { source: 'unreadable', packages: new Map(), unreadable: ['Build and Update environment'] };
  const out1 = L.formatDependencyDiff({ failed: bad, baseline: ok, baselineRun });
  assert.match(out1, /Build and Update environment in the failed run could not be downloaded/);
  assert.match(out1, /UNKNOWN/);
  const out2 = L.formatDependencyDiff({ failed: ok, baseline: bad, baselineRun });
  assert.match(out2, /in the baseline run could not be downloaded/);
});

test('a long diff is truncated on a line boundary within the budget, and says so', () => {
  const many = new Map();
  for (let i = 0; i < 500; i++) many.set(`vendor/pkg${String(i).padStart(3, '0')}`, '1.0.0');
  const out = L.formatDependencyDiff({
    failed: { source: 'full', packages: many },
    baseline: { source: 'full', packages: new Map() },
    baselineRun,
    maxChars: 1000,
  });
  assert.ok(out.length <= 1000, `length ${out.length} exceeds budget`);
  assert.match(out, /list truncated/);
  assert.match(out.split('\n').at(-2), /^  vendor\/pkg\d{3} 1\.0\.0$/);
});

test('job log file names are ordered, safe and distinct', () => {
  assert.equal(L.jobLogFileName(0, 'Build and Update environment'), '01-build-and-update-environment.log');
  assert.equal(L.jobLogFileName(11, '../../etc/passwd'), '12-etc-passwd.log');
  assert.equal(L.jobLogFileName(2, '!!!'), '03-job.log');
  assert.notEqual(L.jobLogFileName(0, 'Test'), L.jobLogFileName(1, 'test'));
});
