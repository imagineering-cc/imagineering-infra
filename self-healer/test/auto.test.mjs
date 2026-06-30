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
  actionForExit,
  AUTO_ACTIONS,
  RUN_CAGE_PATH,
  CLONE_SCRIPT,
} from '../src/auto.mjs';

/** Run `fn` with a fully-cleared green-auto/cage env, restoring after. */
function withEnv(overrides, fn) {
  const keys = [
    'HEALER_GREEN_AUTO', 'HEALER_GREEN_AUTO_TOKEN', 'HEALER_HOST',
    'HEALER_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN',
    'HEALER_CAGE_IMAGE', 'HEALER_CAGE_NETWORK', 'HEALER_CAGE_PROXY_URL', 'HEALER_CAGE_AGENT_CMD',
    'HEALER_CAGE_CLAUDE_TOKEN',
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

test('boundedAuthority: refuses when bound matches a NON-FIRST broad token (cage-match #114 regression)', () => {
  // The Carnot bug: a first-only `A || B || C` check compared the bound token
  // against HEALER_GH_TOKEN only. With two broad tokens set and the bound token
  // equal to the SECOND one, the broad token would have slipped into the cage.
  const r = boundedAuthority({
    HEALER_GH_TOKEN: 'broad-a',
    GITHUB_TOKEN: 'broad-b',
    HEALER_GREEN_AUTO_TOKEN: 'broad-b', // matches the second broad token, not the first
  });
  assert.equal(r.ok, false, 'must refuse a bound token equal to ANY present broad token');
  assert.match(r.reason, /EVERY broad host token/);
});

// ── Gate 4+5: cage substrate ─────────────────────────────────────────────────

test('cageSubstrate: names every missing var and fails closed', () => {
  const r = cageSubstrate({});
  assert.equal(r.ok, false);
  for (const v of ['HEALER_CAGE_IMAGE', 'HEALER_CAGE_NETWORK', 'HEALER_CAGE_PROXY_URL', 'HEALER_CAGE_AGENT_CMD', 'HEALER_CAGE_CLAUDE_TOKEN']) {
    assert.match(r.reason, new RegExp(v), `reason should name ${v}`);
  }
});

test('cageSubstrate: missing ONLY the inference token still fails closed (no spawn without inference creds)', () => {
  const r = cageSubstrate({
    HEALER_CAGE_IMAGE: 'agent:1', HEALER_CAGE_NETWORK: 'cage-internal',
    HEALER_CAGE_PROXY_URL: 'http://proxy:3128', HEALER_CAGE_AGENT_CMD: 'claude -p',
    // HEALER_CAGE_CLAUDE_TOKEN omitted
  });
  assert.equal(r.ok, false);
  assert.match(r.reason, /HEALER_CAGE_CLAUDE_TOKEN/);
});

test('cageSubstrate: ok when all provisioned (incl. inference token)', () => {
  const r = cageSubstrate({
    HEALER_CAGE_IMAGE: 'agent:1', HEALER_CAGE_NETWORK: 'cage-internal',
    HEALER_CAGE_PROXY_URL: 'http://proxy:3128', HEALER_CAGE_AGENT_CMD: 'claude -p',
    HEALER_CAGE_CLAUDE_TOKEN: 'sk-ant-oat-xyz',
  });
  assert.equal(r.ok, true);
  assert.equal(r.agentCmd, 'claude -p');
  assert.equal(r.claudeToken, 'sk-ant-oat-xyz');
});

// ── exit-code → outcome mapping (cage-match #121, Carnot) ────────────────────

test('actionForExit: clean exit 0 → CAGED (a draft PR was opened)', () => {
  const r = actionForExit(0, 'abc123def456789');
  assert.equal(r.action, AUTO_ACTIONS.CAGED);
  assert.match(r.detail, /abc123def456/);
});

test('actionForExit: NO_DIFF (exit 3) → NO_FIX, NOT FAILED (benign empty-diff is not failure telemetry)', () => {
  const r = actionForExit(3, 'abc123def456789');
  assert.equal(r.action, AUTO_ACTIONS.NO_FIX);
  assert.notEqual(r.action, AUTO_ACTIONS.FAILED);
});

test('actionForExit: any other non-zero exit → FAILED', () => {
  for (const code of [1, 2, 4, 5, 6, 7, 'signal:SIGKILL']) {
    assert.equal(actionForExit(code, 'fp').action, AUTO_ACTIONS.FAILED, `exit ${code} should be FAILED`);
  }
});

// ── Pure spawn shape ─────────────────────────────────────────────────────────

test('buildRunCageSpawn: routes through run-cage.mjs and carries the BOUNDED token only', () => {
  const substrate = { image: 'agent:1', network: 'cage-internal', proxyUrl: 'http://proxy:3128', agentCmd: 'claude -p --headless', claudeToken: 'sk-ant-oat-xyz' };
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
  // the inference token rides in as CAGE_CLAUDE_TOKEN (run-cage maps it key-only to
  // CLAUDE_CODE_OAUTH_TOKEN inside the cage); the raw env var name is NEVER set here
  assert.equal(spec.env.CAGE_CLAUDE_TOKEN, 'sk-ant-oat-xyz');
  assert.equal(spec.env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
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

test('autoFixIfActionable: gate 2 honors the PASSED env, not process.env (cage-match #114, Carnot)', async () => {
  // process.env has NO HEALER_HOST (withEnv clears it); HEALER_HOST is supplied
  // ONLY via the explicit env arg. Before the fix, isOnBox() read process.env and
  // wrongly passed gate 2 (would have fallen through to the token gate); now
  // isOnBox(env) reads the SAME env object the other gates use and refuses remote.
  await withEnv({}, async () => {
    assert.equal(process.env.HEALER_HOST, undefined); // precondition: not in process.env
    const out = await autoFixIfActionable(
      { findings: [greenFinding()] },
      {
        HEALER_GREEN_AUTO: '1',
        HEALER_HOST: 'nick@host', // remote — must trip gate 2 via the passed env
        HEALER_GREEN_AUTO_TOKEN: 'repo-scoped-xyz',
        HEALER_CAGE_IMAGE: 'i', HEALER_CAGE_NETWORK: 'n',
        HEALER_CAGE_PROXY_URL: 'p', HEALER_CAGE_AGENT_CMD: 'a',
      },
    );
    assert.equal(out.length, 1);
    assert.equal(out[0].action, 'refused');
    assert.match(out[0].detail, /on-box only/); // the gate-2 refusal, not the token/substrate one
  });
});

test('CLONE_SCRIPT: the repo-scoped token rides via STDIN, never a positional arg (cage-match #114)', () => {
  // The consensus finding: a positional token is base64-decodable in host `ps`.
  // Lock the fix — token comes from stdin ($(cat)), and only repo ($1) + uid:gid
  // ($2) are positionals (no $3, which is where the token used to be).
  assert.match(CLONE_SCRIPT, /tok=\$\(cat\)/); // token from stdin
  assert.doesNotMatch(CLONE_SCRIPT, /\$3/); // no third positional (token is gone from argv)
  // And the clone lives under a non-sticky, healer-owned workroot so cleanup can't
  // leak a chowned dir from sticky /tmp (Carnot HIGH).
  assert.match(CLONE_SCRIPT, /workroot=/);
  assert.doesNotMatch(CLONE_SCRIPT, /mktemp -d \/tmp\/healer-green-auto/); // not bare sticky /tmp
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

test('autoFixIfActionable: substrate present but inference token missing → refusal, no spawn', async () => {
  // The agent can't run `claude -p` without CLAUDE_CODE_OAUTH_TOKEN, so a missing
  // HEALER_CAGE_CLAUDE_TOKEN must fail closed exactly like a missing image/network.
  await withEnv({
    HEALER_GREEN_AUTO: '1', HEALER_GREEN_AUTO_TOKEN: 'repo-scoped',
    HEALER_CAGE_IMAGE: 'i', HEALER_CAGE_NETWORK: 'n', HEALER_CAGE_PROXY_URL: 'p', HEALER_CAGE_AGENT_CMD: 'a',
    // HEALER_CAGE_CLAUDE_TOKEN omitted
  }, async () => {
    const out = await autoFixIfActionable({ findings: [greenFinding()] });
    assert.equal(out[0].action, 'refused');
    assert.match(out[0].detail, /HEALER_CAGE_CLAUDE_TOKEN/);
  });
});

test('autoFixIfActionable: a non-actionable verdict yields no findings even when fully gated', async () => {
  await withEnv({
    HEALER_GREEN_AUTO: '1', HEALER_GREEN_AUTO_TOKEN: 'repo-scoped',
    HEALER_CAGE_IMAGE: 'i', HEALER_CAGE_NETWORK: 'n', HEALER_CAGE_PROXY_URL: 'p', HEALER_CAGE_AGENT_CMD: 'a',
    HEALER_CAGE_CLAUDE_TOKEN: 'sk-ant-oat-xyz',
  }, async () => {
    // amber finding → not in the green-auto set → empty (gates passed, nothing to do)
    const out = await autoFixIfActionable({ findings: [greenFinding({ tier: 'amber' })] });
    assert.deepEqual(out, []);
  });
});
