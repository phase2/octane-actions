// Tests for lib/redact.js. Run with: node --test actions/ci-autofix/test-redact.js
//
// Every credential below is fabricated, built at runtime from pieces so no
// complete token-shaped string sits in the repository for a secret scanner to
// flag.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const R = require('./lib/redact.js');

const pem = [
  '-----BEGIN OPENSSH PRIVATE KEY-----',
  'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW',
  'QyNTUxOQAAACBmYWtla2V5ZmFrZWtleWZha2VrZXlmYWtla2V5ZmFrZQAAAJgAAAAA',
  '-----END OPENSSH PRIVATE KEY-----',
].join('\n');
const ghs = 'ghs' + '_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8';
const antKey = 'sk-' + 'ant-' + 'api03-' + 'x'.repeat(40);
const slack = 'xox' + 'b-' + '1234567890-abcdefghij';
const jwt = 'eyJ' + 'hbGciOiJIUzI1NiJ9' + '.' + 'eyJzdWIiOiIxMjM0NTY3ODkwIn0' + '.' + 'c2lnbmF0dXJlc2lnbmF0dXJl';

test('shape-based patterns catch unknown credentials', () => {
  for (const [secret, kind] of [[pem, 'private-key'], [ghs, 'github-token'], [antKey, 'anthropic-key'],
    [slack, 'slack-token'], ['AKIA' + 'ABCDEFGHIJKLMNOP', 'aws-key'], [jwt, 'jwt']]) {
    const r = R.redactText(`before ${secret} after`);
    assert.equal(r.text, `before [REDACTED:${kind}] after`, kind);
    assert.equal(r.count, 1, kind);
  }
});

test('an unterminated private key is redacted to the end', () => {
  const r = R.redactText('x\n' + pem.split('\n').slice(0, 2).join('\n'));
  assert.equal(r.text, 'x\n[REDACTED:private-key]');
});

test('URL credentials and auth headers keep their non-secret prefix', () => {
  assert.equal(R.redactText('https://x-access-token:s3cr3tvalue@github.com/o/r').text,
    'https://[REDACTED:url-credentials]github.com/o/r');
  assert.equal(R.redactText('Authorization: Bearer abc.def-123').text,
    'Authorization: Bearer [REDACTED:auth-header]');
});

test('known values are removed exactly, longest first, including each line of a multi-line one', () => {
  const known = R.knownValues(`opaque-value-1234\nopaque-value-1234-longer\n${pem}\nshort`);
  assert.ok(!known.includes('short'), 'values under the minimum length are ignored');
  const r = R.redactText('a opaque-value-1234-longer b opaque-value-1234 c', known);
  assert.equal(r.text, 'a [REDACTED:known-secret] b [REDACTED:known-secret] c');
  // A key's body line on its own, as a re-wrapped print of it would show it.
  const body = pem.split('\n')[1];
  assert.equal(R.redactText(`key line: ${body}`, known).text, 'key line: [REDACTED:known-secret]');
});

test('ordinary build output is left alone', () => {
  const text = [
    '  - Locking drupal/core (11.4.7)',
    'Behat\\Mink\\Exception\\ExpectationException: Current response status code is 500',
    'https://github.com/phase2/octane-ci/actions/runs/36220190181',
    'sha256:0123456789abcdef0123456789abcdef',
  ].join('\n');
  assert.deepEqual(R.redactText(text, R.knownValues('')), { text, count: 0 });
});

// The transcript case: a tool result that echoed a key file, inside the
// execution file's JSON. Serialised, the key's newlines are `\n` escapes.
test('redactDeep scrubs strings anywhere in a parsed transcript, keys included', () => {
  const transcript = [
    { type: 'user', message: { content: [{ type: 'tool_result', content: `cat key\n${pem}` }] } },
    { type: 'assistant', message: { content: [{ type: 'text', text: `token is ${ghs}` }] } },
    { [ghs]: 'odd but possible', n: 42, ok: true, none: null },
  ];
  const { value, count } = R.redactDeep(transcript, R.knownValues(pem));
  const out = JSON.stringify(value);
  assert.ok(!out.includes('PRIVATE KEY'), out);
  assert.ok(!out.includes(ghs), out);
  assert.ok(!out.includes(pem.split('\n')[1]), out);
  assert.equal(value[2].n, 42);
  assert.equal(value[2].none, null);
  assert.ok(count >= 3);
});
