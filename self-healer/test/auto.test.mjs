// auto.test.mjs — green-auto orchestrator gating + spawn-shape.
//
// green-auto is the first stage that runs a codegen agent, so the SECURITY-
// relevant surface is the gates: it must spawn NOTHING unless the feature flag,
// on-box, a DISTINCT repo-scoped token, the cage substrate, and an agent command
// are ALL present — and when it does spawn, the bounded token (never the broad
// host token) must ride into the cage and the route must go through run-cage.mjs.
//
// The pure decision/builder functions are the testable surface (the live cage
// proof is cage/escape-probe.sh on the box, exactly as cage.mjs's real proof is).
// Every test isolates env so a real HEALER_* in the shell can't leak in.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  boundedAuthority,
  cageSubstrate,
  buildRunCageSpawn,
  autoFixIfActionable,
  RUN_CAGE_PATH,
} from '../src/auto.mjs';

/** Run `fn` with a fully-cleared green-auto/cage env, restoring after. */
function withEnv(overrides, fn) {
  const keys = [
    'HEALER_GREEN_AUTO', 'HEALER_GREEN_AUTO_TOKEN', 'HEALER_HOST',
    'HEALER_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN',
    'HEALER_CAGE_IMAGE', 'HEALER_CAGE_NETWORK', 'HEALER_CAGE_PROXY_URL', 'HEALER_CAGE_AGENT_CMD',
  ];
  const saved = {};
  for (const k of keys) { saved[k] = process.env[k]; delete process.env[k]; }
  Object.assign(process.env, overrides);
  try { return fn(); }
  finally {
    for (const k of keys) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  }
}

const greenFinding = (over = {}) => ({
  container: 'embodied-dreamfinder', // mapped in repos.mjs
  tier: 'green',
  confidence: 'high',
  signature: 'null deref on empty transcript',
  diagnosis: 'guard the empty case',
  proposedAction: 'add a null-guard before indexing',
  ...over,
});

// ── Gate 3: bounded authority ────────────────────────────────────────────────

test('boundedAuthority: refuses when no repo-scoped token is set', () => {
  const r = boundedAuthority({});
  assert.equal(r.ok, false);
  assert.match(r.reason, /HEALER_GREEN_AUTO_TOKEN/);
});

test('boundedAuthority: accepts a token distinct from the broad host token', () => {
  const r = boundedAuthority({ HEALER_GREEN_AUTO_TOKEN: 'repo-scoped-xyz', HEALER_GH_TOKEN: 'broad-abc' });
  assert.equal(r.ok, true);
  assert.equal(r.token, 'repo-scoped-xyz');
});

test('boundedAuthority: REFUSES when the bound token equals the broad host token', () => {
  // The whole point: never hand the agent the healer’s org-wide token.
  for (const broadKey of ['HEALER_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN']) {
    const r = boundedAuthority({ HEALER_GREEN_AUTO_TOKEN: 'same-tok', [broadKey]: 'same-tok' });
    assert.equal(r.ok, false, `must refuse when bound == ${broadKey}`);
    assert.match(r.reason, /DISTINCT/);
  }
});

// ── Gate 4+5: cage substrate ─────────────────────────────────────────────────

test('cageSubstrate: names every missing var and fails closed', () => {
  const r = cageSubstrate({});
  assert.equal(r.ok, false);
  for (const v of ['HEALER_CAGE_IMAGE', 'HEALER_CAGE_NETWORK', 'HEALER_CAGE_PROXY_URL', 'HEALER_CAGE_AGENT_CMD']) {
    assert.match(r.reason, new RegExp(v), `reason should name ${v}`);
  }
});

test('cageSubstrate: ok when all provisioned', () => {
  const r = cageSubstrate({
    HEALER_CAGE_IMAGE: 'agent:1', HEALER_CAGE_NETWORK: 'cage-internal',
    HEALER_CAGE_PROXY_URL: 'http://proxy:3128', HEALER_CAGE_AGENT_CMD: 'claude -p',
  });
  assert.equal(r.ok, true);
  assert.equal(r.agentCmd, 'claude -p');
});

// ── Pure spawn shape ─────────────────────────────────────────────────────────

test('buildRunCageSpawn: routes through run-cage.mjs and carries the BOUNDED token only', () => {
  const substrate = { image: 'agent:1', network: 'cage-internal', proxyUrl: 'http://proxy:3128', agentCmd: 'claude -p --headless' };
  const spec = buildRunCageSpawn({
    finding: greenFinding(), repo: 'imagineering-cc/embodied-dreamfinder',
    workdirHost: '/tmp/healer-green-auto.AAA', token: 'repo-scoped-xyz', substrate,
  });

  // routes through run-cage.mjs (NOT a raw `docker run`), agent argv after `--`
  assert.equal(spec.argv[0], RUN_CAGE_PATH);
  assert.equal(spec.argv[1], '--');
  assert.deepEqual(spec.argv.slice(2), ['claude', '-p', '--headless']);

  // the bounded token rides in; the broad host token name is absent
  assert.equal(spec.env.CAGE_GH_TOKEN, 'repo-scoped-xyz');
  assert.equal(spec.env.HEALER_GH_TOKEN, undefined);
  assert.equal(spec.env.CAGE_WORKDIR, '/tmp/healer-green-auto.AAA');
  assert.equal(spec.env.CAGE_IMAGE, 'agent:1');
  assert.equal(spec.env.CAGE_AGENT_REPO, 'imagineering-cc/embodied-dreamfinder');

  // deterministic, fingerprint-derived container name
  assert.match(spec.name, /^healer-green-auto-[0-9a-f]{12}$/);
});

test('buildRunCageSpawn: scrubs a secret out of attacker-influenceable finding context', () => {
  const substrate = { image: 'i', network: 'n', proxyUrl: 'p', agentCmd: 'a' };
  const spec = buildRunCageSpawn({
    finding: greenFinding({ diagnosis: 'leak ghp_0123456789012345678901234567890123 oops' }),
    repo: 'o/r', workdirHost: '/w', token: 't', substrate,
  });
  assert.ok(!spec.env.CAGE_AGENT_DIAGNOSIS.includes('ghp_0123456789012345678901234567890123'),
    'a GitHub PAT in the diagnosis must be scrubbed before it reaches the cage env');
});

// ── Top-level gating (no spawn) ──────────────────────────────────────────────

test('autoFixIfActionable: OFF by default → empty, spawns nothing', async () => {
  await withEnv({}, async () => {
    const out = await autoFixIfActionable({ findings: [greenFinding()] });
    assert.deepEqual(out, []);
  });
});

test('autoFixIfActionable: flag on but remote (HEALER_HOST set) → single refusal, no spawn', async () => {
  await withEnv({ HEALER_GREEN_AUTO: '1', HEALER_HOST: 'nick@host' }, async () => {
    const out = await autoFixIfActionable({ findings: [greenFinding()] });
    assert.equal(out.length, 1);
    assert.equal(out[0].action, 'refused');
    assert.match(out[0].detail, /on-box only/);
  });
});

test('autoFixIfActionable: on-box + flag on but no bounded token → refusal, no spawn', async () => {
  await withEnv({ HEALER_GREEN_AUTO: '1' }, async () => {
    const out = await autoFixIfActionable({ findings: [greenFinding()] });
    assert.equal(out[0].action, 'refused');
    assert.match(out[0].detail, /HEALER_GREEN_AUTO_TOKEN/);
  });
});

test('autoFixIfActionable: bounded token present but cage substrate missing → refusal, no spawn', async () => {
  await withEnv({ HEALER_GREEN_AUTO: '1', HEALER_GREEN_AUTO_TOKEN: 'repo-scoped' }, async () => {
    const out = await autoFixIfActionable({ findings: [greenFinding()] });
    assert.equal(out[0].action, 'refused');
    assert.match(out[0].detail, /cage substrate not provisioned/);
  });
});

test('autoFixIfActionable: a non-actionable verdict yields no findings even when fully gated', async () => {
  await withEnv({
    HEALER_GREEN_AUTO: '1', HEALER_GREEN_AUTO_TOKEN: 'repo-scoped',
    HEALER_CAGE_IMAGE: 'i', HEALER_CAGE_NETWORK: 'n', HEALER_CAGE_PROXY_URL: 'p', HEALER_CAGE_AGENT_CMD: 'a',
  }, async () => {
    // amber finding → not in the green-auto set → empty (gates passed, nothing to do)
    const out = await autoFixIfActionable({ findings: [greenFinding({ tier: 'amber' })] });
    assert.deepEqual(out, []);
  });
});
