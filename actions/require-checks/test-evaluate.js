'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseRequirements, parseAlternative, latestCompleted, evaluate } = require('./evaluate.js');

let nextId = 1;
function run(name, conclusion, completedAt, extra = {}) {
  return {
    id: extra.id || nextId++,
    name,
    status: extra.status || 'completed',
    conclusion,
    completed_at: completedAt,
    ...extra,
  };
}

test('parses groups and alternatives, ignoring blanks and comments', () => {
  const groups = parseRequirements(`
    # policy
    testing: run-tests | manual-test-evidence

    vulnerability: dependency-audit
  `);
  assert.deepEqual(groups, [
    { name: 'testing', alternatives: ['run-tests', 'manual-test-evidence'] },
    { name: 'vulnerability', alternatives: ['dependency-audit'] },
  ]);
});

test('rejects malformed requirements', () => {
  assert.throws(() => parseRequirements('run-tests'), /missing a "<group>:" prefix/);
  assert.throws(() => parseRequirements(': run-tests'), /empty group name/);
  assert.throws(() => parseRequirements('testing:'), /lists no checks/);
  assert.throws(() => parseRequirements(''), /requirements is empty/);
  assert.throws(() => parseRequirements('a: x\na: y'), /more than once/);
});

test('latestCompleted ignores in-flight runs', () => {
  const runs = [run('t', 'success', '2026-01-01T00:00:00Z'), run('t', null, null, { status: 'in_progress' })];
  assert.equal(latestCompleted(runs).conclusion, 'success');
});

test('latestCompleted breaks timestamp ties deterministically by id', () => {
  const older = run('t', 'failure', '2026-01-01T00:00:00Z', { id: 10 });
  const newer = run('t', 'success', '2026-01-01T00:00:00Z', { id: 11 });
  assert.equal(latestCompleted([older, newer]).id, 11);
  assert.equal(latestCompleted([newer, older]).id, 11);
});

test('a group is satisfied by its first passing alternative', () => {
  const res = evaluate({
    checkRuns: [run('run-tests', 'success', '2026-01-01T00:00:00Z')],
    requirements: 'testing: run-tests | manual-test-evidence',
  });
  assert.equal(res.satisfied, true);
  assert.equal(res.groups[0].state, 'satisfied');
  assert.equal(res.groups[0].satisfiedBy.alternative, 'run-tests');
});

test('any-of: a later alternative satisfies when the first failed', () => {
  const res = evaluate({
    checkRuns: [
      run('run-tests', 'failure', '2026-01-01T00:00:00Z'),
      run('manual-test-evidence', 'success', '2026-01-01T01:00:00Z'),
    ],
    requirements: 'testing: run-tests | manual-test-evidence',
  });
  assert.equal(res.satisfied, true);
  assert.equal(res.groups[0].satisfiedBy.alternative, 'manual-test-evidence');
  assert.deepEqual(res.waived, []);
});

test('a re-run supersedes an earlier failure for the same check name', () => {
  const res = evaluate({
    checkRuns: [
      run('run-tests', 'failure', '2026-01-01T00:00:00Z'),
      run('run-tests', 'success', '2026-01-01T00:05:00Z'),
    ],
    requirements: 'testing: run-tests',
  });
  assert.equal(res.satisfied, true);
});

test('a later failure supersedes an earlier success', () => {
  const res = evaluate({
    checkRuns: [
      run('run-tests', 'success', '2026-01-01T00:00:00Z'),
      run('run-tests', 'failure', '2026-01-01T00:05:00Z'),
    ],
    requirements: 'testing: run-tests',
  });
  assert.equal(res.satisfied, false);
  assert.equal(res.groups[0].state, 'unsatisfied');
});

test('an in-flight check blocks rather than passing or being ignored', () => {
  const res = evaluate({
    checkRuns: [run('run-tests', null, null, { status: 'in_progress' })],
    requirements: 'testing: run-tests',
  });
  assert.equal(res.satisfied, false);
  assert.equal(res.groups[0].state, 'pending');
  assert.deepEqual(res.groups[0].pending, ['run-tests']);
});

test('a pending alternative does not block when another already passed', () => {
  const res = evaluate({
    checkRuns: [
      run('run-tests', null, null, { status: 'queued' }),
      run('manual-test-evidence', 'success', '2026-01-01T00:00:00Z'),
    ],
    requirements: 'testing: run-tests | manual-test-evidence',
  });
  assert.equal(res.satisfied, true);
});

test('only success counts: neutral and skipped do not satisfy', () => {
  for (const conclusion of ['neutral', 'skipped', 'cancelled', 'timed_out', 'action_required']) {
    const res = evaluate({
      checkRuns: [run('run-tests', conclusion, '2026-01-01T00:00:00Z')],
      requirements: 'testing: run-tests',
    });
    assert.equal(res.satisfied, false, `${conclusion} must not satisfy a requirement`);
  }
});

test('a missing check is unsatisfied, not pending', () => {
  const res = evaluate({ checkRuns: [], requirements: 'testing: run-tests' });
  assert.equal(res.groups[0].state, 'unsatisfied');
});

test('a waiver satisfies the deploy but is reported as waived, not satisfied', () => {
  const res = evaluate({
    checkRuns: [
      run('dependency-audit', 'failure', '2026-01-01T00:00:00Z'),
      run('waiver-vulnerability', 'success', '2026-01-01T01:00:00Z'),
    ],
    requirements: 'vulnerability: dependency-audit | waiver-vulnerability',
  });
  assert.equal(res.satisfied, true);
  assert.equal(res.groups[0].state, 'waived');
  assert.deepEqual(res.waived, ['vulnerability']);
});

test('a waiver for one group does not satisfy another group', () => {
  const res = evaluate({
    checkRuns: [run('waiver-vulnerability', 'success', '2026-01-01T00:00:00Z')],
    requirements: 'testing: run-tests | waiver-testing\nvulnerability: dependency-audit | waiver-vulnerability',
  });
  assert.equal(res.satisfied, false);
  assert.equal(res.groups[0].state, 'unsatisfied');
  assert.equal(res.groups[1].state, 'waived');
});

test('a real pass is preferred over an available waiver', () => {
  const res = evaluate({
    checkRuns: [
      run('dependency-audit', 'success', '2026-01-01T00:00:00Z'),
      run('waiver-vulnerability', 'success', '2026-01-01T01:00:00Z'),
    ],
    requirements: 'vulnerability: dependency-audit | waiver-vulnerability',
  });
  assert.equal(res.groups[0].state, 'satisfied');
  assert.deepEqual(res.waived, []);
});

test('the waiver prefix is configurable', () => {
  const res = evaluate({
    checkRuns: [run('exception-testing', 'success', '2026-01-01T00:00:00Z')],
    requirements: 'testing: run-tests | exception-testing',
    waiverPrefix: 'exception-',
  });
  assert.equal(res.groups[0].state, 'waived');
});

test('null output and UUID external_id on job checks are tolerated', () => {
  // Implicit Actions job checks come back with output:null and a UUID
  // external_id; nothing in evaluation may assume otherwise.
  const res = evaluate({
    checkRuns: [
      run('run-tests', 'success', '2026-01-01T00:00:00Z', {
        output: null,
        external_id: '298944bb-6e13-515f-b29a-5a0bd118f3bf',
      }),
    ],
    requirements: 'testing: run-tests',
  });
  assert.equal(res.satisfied, true);
});

test('attempt history is collected for evidence', () => {
  const res = evaluate({
    checkRuns: [
      run('run-tests', 'failure', '2026-01-01T00:00:00Z'),
      run('run-tests', 'success', '2026-01-01T00:05:00Z'),
      run('unrelated', 'success', '2026-01-01T00:06:00Z'),
    ],
    requirements: 'testing: run-tests',
  });
  assert.equal(res.groups[0].attempts.length, 2);
});

test('parses an optional app id prefix on an alternative', () => {
  assert.deepEqual(parseAlternative('15368/run-tests'), { appId: 15368, name: 'run-tests' });
  assert.deepEqual(parseAlternative('run-tests'), { appId: null, name: 'run-tests' });
  assert.deepEqual(parseAlternative('CI / test'), { appId: null, name: 'CI / test' });
});

test('an app id prefix ignores a same-named check from another app', () => {
  const res = evaluate({
    checkRuns: [
      run('run-tests', 'success', '2026-01-01T00:00:00Z', { app: { id: 999 } }),
      run('run-tests', 'failure', '2026-01-01T00:00:00Z', { app: { id: 15368 } }),
    ],
    requirements: 'testing: 15368/run-tests',
  });
  assert.equal(res.satisfied, false);
  assert.equal(res.groups[0].attempts.length, 1);
});

test('an app id prefix is satisfied by that app, and an unprefixed name by any app', () => {
  const checkRuns = [run('visual', 'success', '2026-01-01T00:00:00Z', { app: { id: 39097 } })];
  assert.equal(evaluate({ checkRuns, requirements: 'testing: 39097/visual' }).satisfied, true);
  assert.equal(evaluate({ checkRuns, requirements: 'testing: visual' }).satisfied, true);
});

test('a prefixed waiver is still reported as waived', () => {
  const res = evaluate({
    checkRuns: [run('waiver-testing', 'success', '2026-01-01T00:00:00Z', { app: { id: 15368 } })],
    requirements: 'testing: run-tests | 15368/waiver-testing',
  });
  assert.equal(res.groups[0].state, 'waived');
});
