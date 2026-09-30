'use strict';

/**
 * Pure evaluation of requirement groups against a commit's check runs.
 *
 * Deliberately free of network calls and of the Actions runtime, so the whole
 * decision can be unit tested against fixtures. action.yml fetches the check
 * runs and renders the result; everything that decides anything lives here.
 */

const DEFAULT_WAIVER_PREFIX = 'waiver-';

/**
 * Parse the `requirements` input.
 *
 *   testing: run-tests | manual-test-evidence | waiver-testing
 *   vulnerability: dependency-audit | waiver-vulnerability
 *
 * A group is satisfied when ANY of its alternatives passed, which is what lets
 * recorded manual testing stand in for an automated suite.
 *
 * An alternative may be prefixed with a numeric GitHub App id, as in
 * `15368/run-tests`, to accept that check only from that app. Unprefixed
 * names accept a check of that name from any app.
 */
function parseRequirements(raw) {
  const groups = [];
  const seen = new Set();

  for (const rawLine of String(raw == null ? '' : raw).split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;

    const sep = line.indexOf(':');
    if (sep === -1) {
      throw new Error(`requirements line is missing a "<group>:" prefix: "${line}"`);
    }

    const name = line.slice(0, sep).trim();
    if (!name) throw new Error(`requirements line has an empty group name: "${line}"`);
    if (seen.has(name)) throw new Error(`requirements declares group "${name}" more than once`);
    seen.add(name);

    const alternatives = line
      .slice(sep + 1)
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    if (alternatives.length === 0) {
      throw new Error(`requirements group "${name}" lists no checks`);
    }

    groups.push({ name, alternatives });
  }

  if (groups.length === 0) throw new Error('requirements is empty');
  return groups;
}

/**
 * Split an alternative into its optional app id and check name.
 */
function parseAlternative(alternative) {
  const m = /^(\d+)\/(.+)$/.exec(alternative);
  return m ? { appId: Number(m[1]), name: m[2] } : { appId: null, name: alternative };
}

/**
 * The most recently completed run for a check name.
 *
 * This cannot be delegated to the API. `filter=latest` selects the newest run
 * per check SUITE, and every workflow re-run creates a new suite, so a stale
 * failure and a fresh success both come back. Reducing by name here is what
 * makes a re-run actually supersede its predecessor.
 */
function latestCompleted(runs) {
  const completed = runs.filter((r) => r.status === 'completed');
  if (completed.length === 0) return null;

  return completed.slice().sort((a, b) => {
    const at = Date.parse(a.completed_at || '') || 0;
    const bt = Date.parse(b.completed_at || '') || 0;
    if (bt !== at) return bt - at;
    // Identical timestamps are possible; fall back to id so the winner is
    // deterministic rather than dependent on API ordering.
    return (b.id || 0) - (a.id || 0);
  })[0];
}

/**
 * @returns {{satisfied: boolean, groups: Array, waived: string[]}}
 */
function evaluate({ checkRuns, requirements, waiverPrefix = DEFAULT_WAIVER_PREFIX }) {
  const groups = parseRequirements(requirements);

  const byName = new Map();
  for (const run of checkRuns || []) {
    if (!byName.has(run.name)) byName.set(run.name, []);
    byName.get(run.name).push(run);
  }

  const results = groups.map((group) => {
    let satisfiedBy = null;
    const pending = [];

    const attempts = new Map();

    for (const alternative of group.alternatives) {
      const { appId, name } = parseAlternative(alternative);
      const runs = (byName.get(name) || []).filter((r) => appId === null || (r.app && r.app.id === appId));
      for (const r of runs) attempts.set(r.id, r);
      const latest = latestCompleted(runs);

      if (latest && latest.conclusion === 'success') {
        satisfiedBy = { alternative, run: latest };
        break;
      }
      // Only `success` counts. GitHub's own required-status-check rules also
      // accept `neutral` and `skipped`; for a deployment gate a skipped test is
      // not evidence that anything was tested.
      if (runs.some((r) => r.status !== 'completed')) pending.push(alternative);
    }

    const isWaiver = Boolean(satisfiedBy) && parseAlternative(satisfiedBy.alternative).name.startsWith(waiverPrefix);
    let state;
    if (satisfiedBy) state = isWaiver ? 'waived' : 'satisfied';
    else if (pending.length > 0) state = 'pending';
    else state = 'unsatisfied';

    return {
      name: group.name,
      alternatives: group.alternatives,
      state,
      satisfiedBy,
      pending,
      // Every attempt recorded against any alternative, for the audit trail.
      attempts: [...attempts.values()],
    };
  });

  return {
    satisfied: results.every((g) => g.state === 'satisfied' || g.state === 'waived'),
    groups: results,
    waived: results.filter((g) => g.state === 'waived').map((g) => g.name),
  };
}

module.exports = { parseRequirements, parseAlternative, latestCompleted, evaluate, DEFAULT_WAIVER_PREFIX };
