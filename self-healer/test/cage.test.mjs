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

import { buildCageArgv, CONFINEMENT_FLAGS, CAGE_UID_GID } from '../cage/cage.mjs';
import { hostAllowed, parseConnectAuthority, isForbiddenAddress } from '../cage/egress-proxy.mjs';

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

test('buildCageArgv FORCES non-root via --user (not delegated to the image) — cage-match #111', () => {
  const { argv } = buildCageArgv(base);
  const u = argv.indexOf('--user');
  assert.notEqual(u, -1, '--user present');
  assert.equal(argv[u + 1], CAGE_UID_GID);
  assert.ok(!/^0:/.test(argv[u + 1]), 'must not be uid 0');
  // a caller can override the uid:gid but it is always emitted
  const custom = buildCageArgv({ ...base, userGid: '65532:65532' });
  assert.equal(custom.argv[custom.argv.indexOf('--user') + 1], '65532:65532');
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

test('a caller cannot clobber the egress proxy via env (proxy wins last, exactly once)', () => {
  const { argv } = buildCageArgv({ ...base, env: { HTTPS_PROXY: 'http://evil:9999', GH_TOKEN: 't' } });
  const envs = argv.filter((_, i) => argv[i - 1] === '-e');
  assert.ok(envs.includes('HTTPS_PROXY=http://cage-egress-proxy:3128'), 'proxy not clobbered');
  assert.ok(!envs.includes('HTTPS_PROXY=http://evil:9999'), 'evil proxy override rejected');
  assert.ok(envs.includes('GH_TOKEN=t'), 'non-proxy caller env still passes through');
  // Docker uses the LAST -e wins, so there must be exactly ONE HTTPS_PROXY emitted
  // (a duplicate with the evil value last would silently win) — cage-match #111 Carnot.
  for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy']) {
    const n = envs.filter((e) => e.startsWith(`${k}=`)).length;
    assert.equal(n, 1, `exactly one ${k} assignment (got ${n})`);
  }
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

// -- CONNECT authority parse: exactly one host + one decimal port -------------

test('parseConnectAuthority: accepts host:port', () => {
  assert.deepEqual(parseConnectAuthority('api.github.com:443'), { host: 'api.github.com', port: 443 });
});

test('parseConnectAuthority: accepts a bracketed IPv6 literal', () => {
  assert.deepEqual(parseConnectAuthority('[2606:4700:4700::1111]:443'), { host: '2606:4700:4700::1111', port: 443 });
});

test('parseConnectAuthority: rejects malformed / ambiguous authorities (cage-match #111)', () => {
  for (const bad of ['', 'api.github.com', ':443', 'api.github.com:', 'api.github.com:0',
    'api.github.com:99999', 'api.github.com:44a', '2606::1:443', 'a:b:443', 'host:443:extra']) {
    assert.equal(parseConnectAuthority(bad), null, `must reject "${bad}"`);
  }
});

// -- SSRF guard: an allowlisted name that resolves to a private IP is refused --

test('isForbiddenAddress: rejects loopback/link-local/private/metadata (cage-match #111 F2)', () => {
  for (const ip of ['127.0.0.1', '169.254.169.254', '10.0.0.5', '172.16.4.4', '172.31.255.1',
    '192.168.1.1', '100.64.0.1', '0.0.0.0', '::1', '::', 'fe80::1', 'fc00::1', 'fd12::3',
    '::ffff:10.0.0.1', '::ffff:169.254.169.254']) {
    assert.ok(isForbiddenAddress(ip), `must forbid ${ip}`);
  }
});

test('isForbiddenAddress: allows public addresses', () => {
  for (const ip of ['1.1.1.1', '140.82.112.3', '8.8.8.8', '172.15.0.1', '172.32.0.1',
    '2606:4700:4700::1111']) {
    assert.ok(!isForbiddenAddress(ip), `must allow ${ip}`);
  }
});
