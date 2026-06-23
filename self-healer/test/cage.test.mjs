// cage.test.mjs — CI-safe assertions on the cage's argv shape + the proxy
// allowlist. These run with no Docker daemon and no box, exactly like
// host_typed_argv.test.mjs proves the host primitive without spawning.
//
// ⚠️ THESE TESTS ARE NECESSARY BUT NOT THE BOUNDARY. An argv that CONTAINS
// `--read-only` does not prove the rootfs is actually immutable; a `hostAllowed`
// unit does not prove the kernel drops a forbidden packet. The boundary is
// proven by cage/escape-probe.sh ON THE BOX (attempt the escape, watch it fail).
// What these guard is REGRESSION: that a future edit doesn't silently drop a
// confinement flag or widen the allowlist matcher. Pair, never substitute.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildCageArgv, CONFINEMENT_FLAGS } from '../cage/cage.mjs';
import { hostAllowed } from '../cage/egress-proxy.mjs';

const base = {
  image: 'cage-agent:latest',
  network: 'cage-internal',
  workdirHost: '/tmp/clone.abc',
  proxyUrl: 'http://cage-egress-proxy:3128',
  cmd: 'claude',
  args: ['-p', 'fix it'],
};

// -- confinement flags: every authority-dropping flag is present --------------

test('buildCageArgv includes every confinement flag', () => {
  const { bin, argv } = buildCageArgv(base);
  assert.equal(bin, 'docker');
  assert.equal(argv[0], 'run');
  for (const flag of CONFINEMENT_FLAGS) {
    assert.ok(argv.includes(flag), `missing confinement flag: ${flag}`);
  }
  // The specific ones the contract table leans on, spelled out so a rename fails.
  for (const must of ['--rm', '--cap-drop=ALL', '--security-opt=no-new-privileges', '--read-only']) {
    assert.ok(argv.includes(must), `missing: ${must}`);
  }
});

test('buildCageArgv puts the agent on the internal (no-egress) network', () => {
  const { argv } = buildCageArgv(base);
  const i = argv.indexOf('--network');
  assert.notEqual(i, -1, '--network present');
  assert.equal(argv[i + 1], 'cage-internal');
});

test('buildCageArgv mounts ONLY the workdir rw at /work and sets it as cwd', () => {
  const { argv } = buildCageArgv(base);
  assert.ok(argv.includes('/tmp/clone.abc:/work:rw'), 'workdir bind-mounted rw at /work');
  const w = argv.indexOf('-w');
  assert.equal(argv[w + 1], '/work');
  // /tmp is a noexec/nosuid tmpfs — scratch space that can't run code.
  const tmpfs = argv[argv.indexOf('--tmpfs') + 1];
  assert.match(tmpfs, /^\/tmp:.*noexec.*nosuid/);
});

test('buildCageArgv sets all proxy env vars and an empty NO_PROXY (nothing exempt)', () => {
  const { argv } = buildCageArgv(base);
  const envs = argv.filter((_, i) => argv[i - 1] === '-e');
  for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy']) {
    assert.ok(envs.includes(`${k}=http://cage-egress-proxy:3128`), `proxy env ${k} set`);
  }
  assert.ok(envs.includes('NO_PROXY='), 'NO_PROXY empty — no host exempted from the proxy');
  assert.ok(envs.includes('no_proxy='), 'no_proxy empty');
});

test('a caller cannot clobber the egress proxy via env (proxy wins last)', () => {
  const { argv } = buildCageArgv({ ...base, env: { HTTPS_PROXY: 'http://evil:9999', GH_TOKEN: 't' } });
  const envs = argv.filter((_, i) => argv[i - 1] === '-e');
  assert.ok(envs.includes('HTTPS_PROXY=http://cage-egress-proxy:3128'), 'proxy not clobbered');
  assert.ok(!envs.includes('HTTPS_PROXY=http://evil:9999'), 'evil proxy override rejected');
  assert.ok(envs.includes('GH_TOKEN=t'), 'non-proxy caller env still passes through');
});

test('buildCageArgv ends with image then the command + args', () => {
  const { argv } = buildCageArgv(base);
  const img = argv.indexOf('cage-agent:latest');
  assert.notEqual(img, -1);
  assert.deepEqual(argv.slice(img), ['cage-agent:latest', 'claude', '-p', 'fix it']);
});

for (const missing of ['image', 'network', 'workdirHost', 'proxyUrl', 'cmd']) {
  test(`buildCageArgv throws when ${missing} is missing (fail closed)`, () => {
    const bad = { ...base }; delete bad[missing];
    assert.throws(() => buildCageArgv(bad), new RegExp(missing.replace('Host', '')));
  });
}

// -- proxy allowlist: exact + dotted-suffix, never substring ------------------

test('hostAllowed: exact host matches', () => {
  assert.ok(hostAllowed('api.github.com', ['api.github.com']));
  assert.ok(!hostAllowed('api.github.com', ['github.com']), 'exact entry does not match a subdomain');
});

test('hostAllowed: a leading-dot entry matches the family but not look-alikes', () => {
  const allow = ['.github.com'];
  assert.ok(hostAllowed('github.com', allow), 'apex matches');
  assert.ok(hostAllowed('api.github.com', allow), 'subdomain matches');
  assert.ok(hostAllowed('codeload.github.com', allow), 'another subdomain matches');
  assert.ok(!hostAllowed('evilgithub.com', allow), 'look-alike must NOT match');
  assert.ok(!hostAllowed('github.com.evil.com', allow), 'suffix-injection must NOT match');
});

test('hostAllowed: empty allowlist denies everything (fail closed)', () => {
  assert.ok(!hostAllowed('api.github.com', []));
  assert.ok(!hostAllowed('anything', []));
});

test('hostAllowed: case-insensitive', () => {
  assert.ok(hostAllowed('API.GitHub.com', ['api.github.com']));
});
