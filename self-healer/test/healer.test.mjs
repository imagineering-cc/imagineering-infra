// Unit tests for the self-healer's pure functions. Zero-dep: Node's built-in
// test runner (`node --test`). These pin exactly the failure modes the
// cage-match (PR #100) surfaced — fail-OPEN verdicts, brace-fragile parsing,
// sentinel collisions, and shell-injection-shaped names.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { normalizeTier, tierExitCode, maxTier, TIERS } from '../src/tiers.mjs';
import { extractVerdict, validateVerdict } from '../src/diagnose.mjs';
import { collapseRepeats, assertValidContainerName } from '../src/sensor.mjs';
import { scrubSecrets, formatVerdict, pingIfNoteworthy } from '../src/notify.mjs';

test('scrubSecrets: redacts known token shapes', () => {
  assert.match(scrubSecrets('token sk-ant-oat01-abc123DEF_xyz here'), /<redacted:anthropic-key>/);
  assert.match(scrubSecrets('ghs_AAAABBBBCCCCDDDD1111'), /<redacted:github-token>/);
  assert.match(scrubSecrets('Authorization: Bearer abcdef1234567890'), /Bearer <redacted>/);
  assert.equal(scrubSecrets('nothing secret here'), 'nothing secret here');
});

test('formatVerdict: HTML-escapes dynamic text and scrubs secrets', () => {
  const msg = formatVerdict({
    overallTier: 'amber',
    summary: 'shim leaked sk-ant-oat01-SECRETvalue_here in <logs>',
    findings: [{ container: 'c<1>', signature: 'sig & stuff', tier: 'amber', proposedAction: 'fix it' }],
  });
  assert.doesNotMatch(msg, /sk-ant-oat01-SECRETvalue/); // secret scrubbed
  assert.match(msg, /&lt;logs&gt;/);                    // angle brackets escaped
  assert.match(msg, /c&lt;1&gt;/);                       // finding container escaped
  assert.match(msg, /sig &amp; stuff/);                  // ampersand escaped
});

test('pingIfNoteworthy: green is a silent no-op (no network)', async () => {
  const r = await pingIfNoteworthy({ overallTier: 'green', findings: [] });
  assert.equal(r.pinged, false);
});

test('pingIfNoteworthy: amber without a key is a no-op (no network)', async () => {
  const saved = process.env.NOTIFY_API_KEY;
  delete process.env.NOTIFY_API_KEY;
  try {
    const r = await pingIfNoteworthy({ overallTier: 'amber', summary: 'x', findings: [] });
    assert.equal(r.pinged, false);
    assert.match(r.reason, /NOTIFY_API_KEY/);
  } finally {
    if (saved !== undefined) process.env.NOTIFY_API_KEY = saved;
  }
});

test('normalizeTier: trims + lowercases into the closed set', () => {
  assert.equal(normalizeTier('red'), 'red');
  assert.equal(normalizeTier('RED'), 'red');
  assert.equal(normalizeTier('  Amber '), 'amber');
});

test('normalizeTier: rejects anything off the set (fail closed)', () => {
  assert.equal(normalizeTier('greenish'), null);
  assert.equal(normalizeTier(''), null);
  assert.equal(normalizeTier(undefined), null);
  assert.equal(normalizeTier(2), null);
});

test('tierExitCode: green=0 amber=1 red=2', () => {
  assert.equal(tierExitCode(TIERS.GREEN), 0);
  assert.equal(tierExitCode(TIERS.AMBER), 1);
  assert.equal(tierExitCode(TIERS.RED), 2);
});

test('maxTier: returns the worse tier', () => {
  assert.equal(maxTier('green', 'red'), 'red');
  assert.equal(maxTier('amber', 'green'), 'amber');
  assert.equal(maxTier('green', 'green'), 'green');
});

test('extractVerdict: pulls a balanced object out of surrounding prose', () => {
  const v = extractVerdict('Here is the verdict: {"overallTier":"green","findings":[]} done.');
  assert.deepEqual(v, { overallTier: 'green', findings: [] });
});

test('extractVerdict: survives brace-heavy pino log echoes inside strings', () => {
  // The model echoes a pino log line containing braces inside a string value.
  const text = '{"summary":"saw {\\"level\\":50} reconnect","overallTier":"green","findings":[]}';
  const v = extractVerdict(text);
  assert.equal(v.overallTier, 'green');
  assert.match(v.summary, /level/);
});

test('extractVerdict: throws on no/unbalanced JSON rather than guessing', () => {
  assert.throws(() => extractVerdict('no json here'));
  assert.throws(() => extractVerdict('{"a":1'));
});

test('validateVerdict: derives overallTier from findings, ignoring a lying top-level tier', () => {
  // Prompt-injection attempt: top-level says green, but a finding is red.
  const v = validateVerdict({
    summary: 'x',
    overallTier: 'green',
    findings: [{ container: 'c', tier: 'red' }],
  });
  assert.equal(v.overallTier, 'red'); // derived from findings, not trusted
});

test('validateVerdict: empty findings ⇒ green', () => {
  assert.equal(validateVerdict({ summary: 'ok', overallTier: 'green', findings: [] }).overallTier, 'green');
});

test('validateVerdict: fails CLOSED on an off-set finding tier', () => {
  assert.throws(() => validateVerdict({ findings: [{ tier: 'GREENISH' }] }));
});

test('validateVerdict: fails CLOSED when findings is not an array', () => {
  assert.throws(() => validateVerdict({ findings: 'nope' }));
});

test('validateVerdict: throws on a present-but-invalid overallTier (fail closed on bad contract)', () => {
  assert.throws(() => validateVerdict({ overallTier: 'redish', findings: [] }));
});

test('validateVerdict: tolerates an ABSENT overallTier by deriving it', () => {
  assert.equal(validateVerdict({ findings: [] }).overallTier, 'green');
  assert.equal(validateVerdict({ findings: [{ tier: 'amber' }] }).overallTier, 'amber');
});

test('validateVerdict: coerces malformed finding fields to safe defaults', () => {
  const v = validateVerdict({ findings: [{ tier: 'green', selfRecovered: 'yes', diagnosis: 42 }] });
  const f = v.findings[0];
  assert.equal(f.container, '(unknown)');
  assert.equal(f.proposedAction, 'none');
  assert.equal(f.selfRecovered, false); // 'yes' (string) is not the boolean true
  assert.equal(f.diagnosis, ''); // non-string coerced
});

test('collapseRepeats: folds identical runs into ×N, leaves singletons alone', () => {
  assert.equal(collapseRepeats('a\na\na\nb'), 'a  (×3)\nb');
  assert.equal(collapseRepeats('x\ny\nz'), 'x\ny\nz');
});

test('assertValidContainerName: accepts docker-legal names, rejects shell metachars', () => {
  assert.equal(assertValidContainerName('tw-clawd'), 'tw-clawd');
  assert.equal(assertValidContainerName('embodied-dreamfinder'), 'embodied-dreamfinder');
  assert.throws(() => assertValidContainerName('a; rm -rf /'));
  assert.throws(() => assertValidContainerName('$(whoami)'));
  assert.throws(() => assertValidContainerName('has space'));
  assert.throws(() => assertValidContainerName(''));
});
