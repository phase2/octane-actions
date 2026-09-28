// Deterministic credential redaction for everything this action shows the
// agent or prints to the run log.
//
// Two sites use it. Every job log is scrubbed before it is written to disk for
// the agent or cut into the prompt excerpt, and the agent transcript is
// scrubbed before it is printed. The transcript matters most: the agent holds
// Bash in a job where the checkout's deploy key sits on disk (create-pull-
// request pushes over that SSH remote, so it cannot simply be removed), and an
// unscrubbed transcript would carry anything the agent read straight into the
// run log.
//
// GitHub's own masking is not relied on. It covers registered secrets only,
// and multi-line values such as a private key are masked on a best-effort
// basis. So this removes two things: the exact values the caller passes in,
// and anything that has the shape of a credential whether or not it is known.

'use strict';

// Shape-based patterns, most specific first. Each replacement keeps any
// non-secret prefix (a URL scheme, a header name) so the redacted text still
// reads sensibly.
const PATTERNS = [
  // PEM private keys of any flavour. An unterminated block (a truncated log)
  // is redacted to the end of the text rather than left half-exposed.
  ['private-key', /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)/g],
  ['github-token', /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b/g],
  ['anthropic-key', /\bsk-ant-[A-Za-z0-9_-]{20,}/g],
  ['slack-token', /\bxox[abeoprs]-[A-Za-z0-9-]{10,}/g],
  ['aws-key', /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g],
  ['jwt', /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g],
];

// Patterns whose first capture group is a prefix to keep.
const PREFIXED_PATTERNS = [
  // user:password@ in any URL.
  ['url-credentials', /(\b[a-z][a-z0-9+.-]*:\/\/)[^\s:@/]+:[^\s@/]+@/gi],
  ['auth-header', /(\bauthorization:\s*(?:bearer|token|basic)\s+)[^\s"'\\]+/gi],
];

// Known values shorter than this are not redacted: a short value such as
// "true" or a common word would shred unrelated text, and no real credential
// is that short.
const MIN_KNOWN_LENGTH = 8;

// Parse the caller's known secret values. `raw` is newline-separated; a
// multi-line secret (a private key) is also split so each of its lines is
// redacted on its own, which catches a key printed with different line
// breaks or quoted into JSON.
function knownValues(raw) {
  const out = new Set();
  for (const line of String(raw || '').split(/\r?\n/)) {
    const v = line.trim();
    if (v.length >= MIN_KNOWN_LENGTH) out.add(v);
  }
  // Longest first, so a value containing another is removed whole.
  return [...out].sort((a, b) => b.length - a.length);
}

// Redact one string. Returns { text, count }.
function redactText(input, known = []) {
  let text = String(input);
  let count = 0;
  for (const value of known) {
    const parts = text.split(value);
    if (parts.length > 1) {
      count += parts.length - 1;
      text = parts.join('[REDACTED:known-secret]');
    }
  }
  for (const [kind, re] of PATTERNS) {
    text = text.replace(re, () => {
      count++;
      return `[REDACTED:${kind}]`;
    });
  }
  for (const [kind, re] of PREFIXED_PATTERNS) {
    text = text.replace(re, (_, prefix) => {
      count++;
      return `${prefix}[REDACTED:${kind}]`;
    });
  }
  return { text, count };
}

// Redact every string inside a parsed JSON value, keys included. Working on
// parsed values rather than serialised text means escaping cannot hide a
// secret: serialised, a value with a newline, quote or backslash appears
// escaped and an exact-match search for it would miss.
function redactDeep(value, known = []) {
  let count = 0;
  const walk = v => {
    if (typeof v === 'string') {
      const r = redactText(v, known);
      count += r.count;
      return r.text;
    }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === 'object') {
      const out = {};
      for (const [k, val] of Object.entries(v)) out[walk(k)] = walk(val);
      return out;
    }
    return v;
  };
  return { value: walk(value), count };
}

module.exports = { knownValues, redactText, redactDeep, MIN_KNOWN_LENGTH };
