// run_cage.test.mjs — the cage's env-forwarding plan (cage-match #121, Carnot).
//
// forwardedCageEnv must be PURE: it computes which secrets ride into the docker
// child KEY-ONLY (passValues) and which NAMEs go in the argv (passNames), WITHOUT
// mutating the long-lived parent env. The prior version did `process.env.X = tok`,
// which would leave a stale inference token in the process across calls — Carnot's
// NEW HIGH. These tests lock the non-mutation + the key-only routing without Docker
// (the live proof remains cage/escape-probe.sh's token-forward/not-leaked cases).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { forwardedCageEnv } from '../cage/run-cage.mjs';

test('forwardedCageEnv: does NOT mutate the passed env (no stale token residue)', () => {
  const env = { CAGE_GH_TOKEN: 'gh-xyz', CAGE_CLAUDE_TOKEN: 'sk-ant-oat-xyz' };
  const before = { ...env };
  forwardedCageEnv(env);
  // the env it was handed is unchanged — the secret VALUES come back in passValues,
  // they are NOT written back as GH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN on the parent env.
  assert.deepEqual(env, before);
  assert.equal(env.GH_TOKEN, undefined);
  assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
});

test('forwardedCageEnv: GH token rides key-only (passValues + passNames), never value-carrying setEnv', () => {
  const { setEnv, passNames, passValues } = forwardedCageEnv({ CAGE_GH_TOKEN: 'gh-xyz' });
  assert.deepEqual(passValues, { GH_TOKEN: 'gh-xyz', GITHUB_TOKEN: 'gh-xyz' });
  assert.ok(passNames.includes('GH_TOKEN') && passNames.includes('GITHUB_TOKEN'));
  assert.equal(setEnv.GH_TOKEN, undefined); // never in the value-carrying (argv) env
  assert.equal(setEnv.HOME, '/work');
});

test('forwardedCageEnv: inference token rides key-only as CLAUDE_CODE_OAUTH_TOKEN', () => {
  const { passNames, passValues, setEnv } = forwardedCageEnv({ CAGE_CLAUDE_TOKEN: 'sk-ant-oat-xyz' });
  assert.equal(passValues.CLAUDE_CODE_OAUTH_TOKEN, 'sk-ant-oat-xyz');
  assert.ok(passNames.includes('CLAUDE_CODE_OAUTH_TOKEN'));
  assert.equal(setEnv.HOME, '/work');
});

test('forwardedCageEnv: neither token set → no secret crosses (fail-closed, matches token-not-leaked probe)', () => {
  // Even with an AMBIENT CLAUDE_CODE_OAUTH_TOKEN present, without CAGE_CLAUDE_TOKEN
  // nothing is forwarded — the explicit-indirection-only rule the probe asserts live.
  const { passNames, passValues } = forwardedCageEnv({ CLAUDE_CODE_OAUTH_TOKEN: 'ambient-should-not-cross' });
  assert.deepEqual(passValues, {});
  assert.deepEqual(passNames, []);
});

test('forwardedCageEnv: CAGE_AGENT_* is value-carrying context, NOT a key-only secret', () => {
  const { setEnv, passValues } = forwardedCageEnv({ CAGE_AGENT_REPO: 'o/r', CAGE_AGENT_FP: 'abc123' });
  assert.equal(setEnv.CAGE_AGENT_REPO, 'o/r');
  assert.equal(setEnv.CAGE_AGENT_FP, 'abc123');
  assert.deepEqual(passValues, {}); // task context is non-secret → -e k=v, not key-only
});
