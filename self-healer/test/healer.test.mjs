// Unit tests for the self-healer's pure functions. Zero-dep: Node's built-in
// test runner (`node --test`). These pin exactly the failure modes the
// cage-match (PR #100) surfaced — fail-OPEN verdicts, brace-fragile parsing,
// sentinel collisions, and shell-injection-shaped names.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { normalizeTier, tierExitCode, maxTier, TIERS } from '../src/tiers.mjs';
import { extractVerdict, validateVerdict, resolveHttpTimeouts } from '../src/diagnose.mjs';
import { collapseRepeats, assertValidContainerName } from '../src/sensor.mjs';
import { scrubSecrets, formatVerdict, pingIfNoteworthy, verdictFingerprint, passesCooldown } from '../src/notify.mjs';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join as pjoin } from 'node:path';
import { findingFingerprint, buildIssue, actionableFindings, draftIfActionable } from '../src/draft.mjs';
import { repoForContainer } from '../src/repos.mjs';

test('repoForContainer: maps known containers, null for unknown', () => {
  assert.equal(repoForContainer('tw-clawd'), 'enspyrco/tech_world_bot');
  assert.equal(repoForContainer('embodied-dreamfinder'), 'imagineering-cc/embodied-dreamfinder');
  assert.equal(repoForContainer('claude-shim'), null); // source not versioned anywhere
  assert.equal(repoForContainer('nope'), null);
});

test('findingFingerprint: stable per problem, differs on signature/tier', () => {
  const a = { container: 'tw-clawd', tier: 'green', signature: 'sig' };
  assert.equal(findingFingerprint(a), findingFingerprint({ ...a }));
  assert.notEqual(findingFingerprint(a), findingFingerprint({ ...a, tier: 'amber' }));
  assert.notEqual(findingFingerprint(a), findingFingerprint({ ...a, signature: 'other' }));
});

test('buildIssue: scrubs secrets, embeds fp marker, bounds the title', () => {
  const { title, body, fp } = buildIssue({
    container: 'tw-clawd', tier: 'green', confidence: 'high', signature: 'crash',
    diagnosis: 'leaked sk-ant-oat01-SECRETvalue_here in the log',
    evidence: 'AKIA1234567890ABCDEF', proposedAction: 'add a null guard',
  });
  assert.doesNotMatch(body, /SECRETvalue/);          // diagnosis secret scrubbed
  assert.doesNotMatch(body, /AKIA1234567890ABCDEF/); // evidence secret scrubbed
  assert.match(body, new RegExp(`self-healer-fp: ${fp}`)); // dedup marker present
  assert.ok(title.length <= 250);
});

test('actionableFindings: only confident-green with a concrete action', () => {
  const v = { findings: [
    { container: 'a', tier: 'green', confidence: 'high', proposedAction: 'fix' },   // ✓
    { container: 'b', tier: 'green', confidence: 'high', proposedAction: 'none' },   // ✗ no action
    { container: 'c', tier: 'green', confidence: 'low', proposedAction: 'fix' },     // ✗ low confidence
    { container: 'd', tier: 'amber', confidence: 'high', proposedAction: 'fix' },    // ✗ not green
  ] };
  const out = actionableFindings(v);
  assert.equal(out.length, 1);
  assert.equal(out[0].container, 'a');
});

test('actionableFindings: normalizes the none-check (" None ", empty excluded)', () => {
  const v = { findings: [
    { container: 'a', tier: 'green', confidence: 'high', proposedAction: ' None ' }, // ✗ normalized none
    { container: 'b', tier: 'green', confidence: 'high', proposedAction: '   ' },      // ✗ empty
    { container: 'c', tier: 'green', confidence: 'high', proposedAction: 'patch it' }, // ✓
  ] };
  const out = actionableFindings(v);
  assert.equal(out.length, 1);
  assert.equal(out[0].container, 'c');
});

test('buildIssue: neutralizes @mentions and caps long fields', () => {
  const { body } = buildIssue({
    container: 'tw-clawd', tier: 'green', confidence: 'high', signature: 'sig',
    diagnosis: 'cc @nickmeinhold and @everyone ' + 'word '.repeat(400), // spaced so the high-entropy scrubber doesn't collapse it
    evidence: 'e', proposedAction: 'fix',
  });
  assert.doesNotMatch(body, /@nickmeinhold/);  // mention neutralized (zero-width inserted after @)
  assert.doesNotMatch(body, /@everyone/);
  assert.match(body, /…\(truncated\)/);          // long diagnosis capped
});

test('findingFingerprint: 32 hex chars (128-bit, collision-resistant)', () => {
  const fp = findingFingerprint({ container: 'a', tier: 'green', signature: 's' });
  assert.match(fp, /^[0-9a-f]{32}$/);
});

test('draftIfActionable: OFF by default (no network, no env)', async () => {
  const saved = process.env.HEALER_DRAFT_ISSUES;
  delete process.env.HEALER_DRAFT_ISSUES;
  try {
    const out = await draftIfActionable({ findings: [{ container: 'tw-clawd', tier: 'green', confidence: 'high', proposedAction: 'fix' }] });
    assert.deepEqual(out, []); // disabled ⇒ no-op
  } finally {
    if (saved !== undefined) process.env.HEALER_DRAFT_ISSUES = saved;
  }
});

test('draftIfActionable: enabled but no token ⇒ skipped, no network', async () => {
  const savedFlag = process.env.HEALER_DRAFT_ISSUES;
  const savedTokens = [process.env.HEALER_GH_TOKEN, process.env.GITHUB_TOKEN, process.env.GH_TOKEN];
  process.env.HEALER_DRAFT_ISSUES = '1';
  delete process.env.HEALER_GH_TOKEN; delete process.env.GITHUB_TOKEN; delete process.env.GH_TOKEN;
  try {
    const out = await draftIfActionable({ findings: [{ container: 'tw-clawd', tier: 'green', confidence: 'high', proposedAction: 'fix' }] });
    assert.equal(out[0].action, 'skipped');
    assert.match(out[0].detail, /token/);
  } finally {
    if (savedFlag !== undefined) process.env.HEALER_DRAFT_ISSUES = savedFlag; else delete process.env.HEALER_DRAFT_ISSUES;
    const [a, b, c] = savedTokens;
    if (a !== undefined) process.env.HEALER_GH_TOKEN = a;
    if (b !== undefined) process.env.GITHUB_TOKEN = b;
    if (c !== undefined) process.env.GH_TOKEN = c;
  }
});

test('scrubSecrets: redacts known token prefixes', () => {
  assert.match(scrubSecrets('token sk-ant-oat01-abc123DEF_xyz here'), /<redacted:anthropic-key>/);
  assert.match(scrubSecrets('ghs_AAAABBBBCCCCDDDD1111'), /<redacted:github-token>/);
  assert.match(scrubSecrets('github_pat_11ABCDEFG_longtailwithunderscores0000'), /<redacted:github-token>/);
  assert.doesNotMatch(scrubSecrets('Authorization: Bearer abcdef1234567890'), /abcdef1234567890/);
  assert.equal(scrubSecrets('nothing secret here'), 'nothing secret here');
});

test('scrubSecrets: catches the shapes a prefix list misses (cage-match PR #101)', () => {
  // AWS *secret* key (40-char base64, no prefix) → high-entropy catch-all.
  assert.match(scrubSecrets('aws wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1'), /<redacted/);
  // k=v with a sensitive key name and an unknown token format.
  assert.match(scrubSecrets('password=hunter2supersecret'), /password=<redacted>/);
  assert.match(scrubSecrets('client_secret: abc.def.ghi'), /client_secret:\s*<redacted>/);
  // PEM private key block.
  assert.match(scrubSecrets('-----BEGIN PRIVATE KEY-----\nMIIabc\n-----END PRIVATE KEY-----'), /<redacted:private-key>/);
});

test('scrubSecrets: preserves short diagnostic IDs (LiveKit nodeIds ~24 chars)', () => {
  // The 32-char floor on the high-entropy rule keeps diagnostic value.
  assert.match(scrubSecrets('rotated to NC_OSYDNEY1A_VTmCnBmjsS8o ok'), /NC_OSYDNEY1A_VTmCnBmjsS8o/);
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

test('verdictFingerprint: stable, order-independent, changes on escalation', () => {
  const a = { overallTier: 'amber', findings: [{ container: 'x', tier: 'amber', signature: 's1' }, { container: 'y', tier: 'green', signature: 's2' }] };
  const b = { overallTier: 'amber', findings: [{ container: 'y', tier: 'green', signature: 's2' }, { container: 'x', tier: 'amber', signature: 's1' }] };
  assert.equal(verdictFingerprint(a), verdictFingerprint(b)); // order-independent
  const escalated = { overallTier: 'red', findings: [{ container: 'x', tier: 'red', signature: 's1' }, { container: 'y', tier: 'green', signature: 's2' }] };
  assert.notEqual(verdictFingerprint(a), verdictFingerprint(escalated)); // escalation ⇒ new fp
});

test('passesCooldown: same problem within window skips, escalation + expiry re-ping', () => {
  const saved = process.env.HEALER_STATE_DIR;
  process.env.HEALER_STATE_DIR = mkdtempSync(pjoin(tmpdir(), 'healer-cd-'));
  try {
    const v = { overallTier: 'amber', findings: [{ container: 'c', tier: 'amber', signature: 's' }] };
    const t0 = 1_000_000_000_000;
    assert.equal(passesCooldown(v, t0), true);                 // first time ⇒ ping
    assert.equal(passesCooldown(v, t0 + 60_000), false);       // 1 min later, same ⇒ skip
    const worse = { overallTier: 'red', findings: [{ container: 'c', tier: 'red', signature: 's' }] };
    assert.equal(passesCooldown(worse, t0 + 120_000), true);   // escalated ⇒ ping despite window (re-stamps clock to here)
    assert.equal(passesCooldown(worse, t0 + 120_000 + 61 * 60_000), true); // >60min after LAST ping ⇒ re-ping (reminder)
  } finally {
    if (saved !== undefined) process.env.HEALER_STATE_DIR = saved; else delete process.env.HEALER_STATE_DIR;
  }
});

test('passesCooldown: HEALER_COOLDOWN_MIN=0 disables the cooldown', () => {
  const saved = process.env.HEALER_COOLDOWN_MIN;
  process.env.HEALER_COOLDOWN_MIN = '0';
  try {
    const v = { overallTier: 'amber', findings: [{ container: 'c', tier: 'amber', signature: 's' }] };
    assert.equal(passesCooldown(v, 5), true);
    assert.equal(passesCooldown(v, 6), true); // no suppression
  } finally {
    if (saved !== undefined) process.env.HEALER_COOLDOWN_MIN = saved; else delete process.env.HEALER_COOLDOWN_MIN;
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

test('resolveHttpTimeouts: defaults sit above the 120s shim ceiling, monotonic (deploy #49)', () => {
  const { curlMaxTimeSec, runOnHostMs } = resolveHttpTimeouts({});
  assert.equal(curlMaxTimeSec, 150);
  assert.equal(runOnHostMs, 160_000);
  // curl must kill BEFORE the outer hard SIGKILL...
  assert.ok(curlMaxTimeSec * 1000 < runOnHostMs);
  // ...and AFTER the shim's own 120s ceiling, so the shim fails first (clean
  // "claude timed out") rather than curl exit 28 discarding a live answer.
  assert.ok(curlMaxTimeSec * 1000 > 120_000);
});

test('resolveHttpTimeouts: honors SHIM_HTTP_TIMEOUT_MS, falls back on garbage/non-positive', () => {
  assert.equal(resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '200000' }).curlMaxTimeSec, 200);
  assert.equal(resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '200000' }).runOnHostMs, 210_000);
  assert.equal(resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: 'xyz' }).curlMaxTimeSec, 150); // unparseable ⇒ default
  assert.equal(resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '0' }).curlMaxTimeSec, 150);   // non-positive ⇒ default
  assert.equal(resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '-5' }).curlMaxTimeSec, 150);
});

test('resolveHttpTimeouts: curlMaxTimeSec is an integer (shell-inert interpolation)', () => {
  const { curlMaxTimeSec } = resolveHttpTimeouts({ SHIM_HTTP_TIMEOUT_MS: '95500' });
  assert.equal(Number.isInteger(curlMaxTimeSec), true);
  assert.equal(curlMaxTimeSec, 96); // ceil(95500/1000)
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
