// Unit tests for the self-healer's pure functions. Zero-dep: Node's built-in
// test runner (`node --test`). These pin exactly the failure modes the
// cage-match (PR #100) surfaced — fail-OPEN verdicts, brace-fragile parsing,
// sentinel collisions, and shell-injection-shaped names.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { normalizeTier, tierExitCode, maxTier, TIERS } from '../src/tiers.mjs';
import { extractVerdict, validateVerdict } from '../src/diagnose.mjs';
import { collapseRepeats, assertValidContainerName } from '../src/sensor.mjs';

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
