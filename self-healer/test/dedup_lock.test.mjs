// dedup_lock.test.mjs — the single-box owner-fenced lock that closes the
// green-draft check-then-create race (an overlapping cron tick + a manual run on
// the same OCI box can't double-file the same fingerprint).
//
// acquireDraftLock returns an OWNER TOKEN (truthy string) on success or null
// when another live run owns the lock; releaseDraftLock(fp, token) is fenced on
// that token so a run reclaimed out from under itself can't delete the new
// owner's lock. Stale-lock takeover is serialized through an O_EXCL reclaim gate
// so N concurrent reclaimers yield exactly one winner (cage-match PR #108:
// Maxwell + Carnot — non-atomic reclaim + unfenced release).
//
// Zero-dep node:test. Each test uses an isolated tmp HEALER_STATE_DIR so the
// lock paths never collide between cases or with a real run.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, existsSync, utimesSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

import { acquireDraftLock, releaseDraftLock } from '../src/draft.mjs';

/** Run `fn` with a fresh isolated state dir + lock TTL, restoring env after. */
function withState(fn, { ttlMin } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'healer-lock-'));
  const savedDir = process.env.HEALER_STATE_DIR;
  const savedTtl = process.env.HEALER_LOCK_TTL_MIN;
  process.env.HEALER_STATE_DIR = dir;
  if (ttlMin !== undefined) process.env.HEALER_LOCK_TTL_MIN = String(ttlMin);
  try {
    return fn(dir);
  } finally {
    if (savedDir === undefined) delete process.env.HEALER_STATE_DIR;
    else process.env.HEALER_STATE_DIR = savedDir;
    if (savedTtl === undefined) delete process.env.HEALER_LOCK_TTL_MIN;
    else process.env.HEALER_LOCK_TTL_MIN = savedTtl;
    rmSync(dir, { recursive: true, force: true });
  }
}

const lockDirOf = (dir, fp) => join(dir, `draft-lock-${fp}`);
const ownerOf = (dir, fp) => readFileSync(join(lockDirOf(dir, fp), 'owner'), 'utf8');

test('atomic acquire returns a token; second on same fp skips (null)', () => {
  withState(() => {
    const fp = 'aaaa1111';
    const tok = acquireDraftLock(fp);
    assert.equal(typeof tok, 'string', 'first acquire returns a token');
    assert.ok(tok.length >= 16, 'token is non-trivial');
    assert.equal(acquireDraftLock(fp), null, 'second acquire (lock still held) skips');
  });
});

test('stale lock is reclaimed after TTL (new owner gets a fresh token)', () => {
  withState((dir) => {
    const fp = 'bbbb2222';
    const tok1 = acquireDraftLock(fp);
    assert.ok(tok1, 'first acquire wins');
    assert.equal(acquireDraftLock(fp), null, 'fresh lock blocks a second run');

    // Simulate a crashed run by back-dating the lock dir's mtime past the TTL.
    const old = new Date(Date.now() - 60 * 60_000); // 1h ago
    utimesSync(lockDirOf(dir, fp), old, old);

    const tok2 = acquireDraftLock(fp);
    assert.ok(tok2, 'stale lock reclaimed → new acquire succeeds');
    assert.notEqual(tok2, tok1, 'reclaimer holds a DIFFERENT owner token');
    assert.equal(ownerOf(dir, fp), tok2, 'on-disk owner is the reclaimer');
  });
});

test('owner-fenced release: matching token removes the lock; later run re-acquires', () => {
  withState((dir) => {
    const fp = 'cccc3333';
    const tok = acquireDraftLock(fp);
    assert.ok(tok, 'acquire');
    releaseDraftLock(fp, tok);
    assert.equal(existsSync(lockDirOf(dir, fp)), false, 'release removes the lock dir');
    assert.ok(acquireDraftLock(fp), 'a later run can re-acquire after release');
  });
});

test("release with a STALE token does NOT delete the new owner's lock", () => {
  withState((dir) => {
    const fp = 'gggg7777';
    // Run A acquires, then is "reclaimed out from under itself": back-date and
    // let run B reclaim. A still holds its (now stale) token.
    const tokA = acquireDraftLock(fp);
    assert.ok(tokA, 'A acquires');
    const old = new Date(Date.now() - 60 * 60_000);
    utimesSync(lockDirOf(dir, fp), old, old);
    const tokB = acquireDraftLock(fp);
    assert.ok(tokB, 'B reclaims');
    assert.notEqual(tokA, tokB);

    // A's finally fires LATE with its stale token — must be a no-op on B's lock.
    releaseDraftLock(fp, tokA);
    assert.equal(existsSync(lockDirOf(dir, fp)), true, "A's stale release must NOT delete B's lock");
    assert.equal(ownerOf(dir, fp), tokB, 'B still owns the lock');

    // B's own (owner-matched) release works.
    releaseDraftLock(fp, tokB);
    assert.equal(existsSync(lockDirOf(dir, fp)), false, "B's owner-matched release removes it");
  });
});

test('two sequential reclaimers of one stale lock: exactly one wins', () => {
  withState((dir) => {
    const fp = 'hhhh8888';
    // Establish a stale lock by hand (a crashed prior run).
    const lockDir = lockDirOf(dir, fp);
    mkdirSync(lockDir, { recursive: true });
    writeFileSync(join(lockDir, 'owner'), 'crashed-prior-run');
    const old = new Date(Date.now() - 60 * 60_000);
    utimesSync(lockDir, old, old);

    // The first reclaimer takes the O_EXCL reclaim gate, removes the stale lock,
    // and re-creates a fresh one; the second then sees a FRESH (non-stale) lock
    // and returns null. (The true-concurrency guarantee is exercised by the
    // N-process test below; this asserts the sequential invariant + the on-disk
    // owner matches the single winner with no clobber.)
    const r1 = acquireDraftLock(fp);
    const r2 = acquireDraftLock(fp);
    const winners = [r1, r2].filter(Boolean);
    assert.equal(winners.length, 1, 'exactly one reclaimer acquires the lock');
    assert.equal(ownerOf(dir, fp), winners[0], 'on-disk owner == the single winner (no clobber)');
  });
});

test('N truly-concurrent processes racing one stale lock: exactly one reclaims', async () => {
  // The sequential tests above can't observe the reclaim race under real
  // contention (the first call completes before the second starts). Spawn N OS
  // processes that all hit the SAME stale lock simultaneously and assert exactly
  // one acquires — this is the test that FAILS under a lock-free rename/stat
  // steal (an ABA double-reclaim → double file) and passes only because the
  // takeover is serialized through the O_EXCL reclaim gate.
  const dir = mkdtempSync(join(tmpdir(), 'healer-race-'));
  try {
    const fp = 'kkkk1111';
    const lockDir = join(dir, `draft-lock-${fp}`);
    mkdirSync(lockDir, { recursive: true });
    writeFileSync(join(lockDir, 'owner'), 'crashed-prior-run');
    const old = new Date(Date.now() - 60 * 60_000);
    utimesSync(lockDir, old, old);

    const here = new URL('.', import.meta.url).pathname;
    const draftUrl = pathToFileURL(join(here, '..', 'src', 'draft.mjs')).href;
    // Each child imports the real module and prints '1' if it acquired, '0' else.
    const child = () => new Promise((resolve, reject) => {
      const code =
        `import('${draftUrl}').then(m => {` +
        `const t = m.acquireDraftLock('${fp}');` +
        `process.stdout.write(t ? '1' : '0');});`;
      const p = spawn(process.execPath, ['--input-type=module', '-e', code], {
        env: { ...process.env, HEALER_STATE_DIR: dir, HEALER_LOCK_TTL_MIN: '10' },
      });
      let out = '';
      p.stdout.on('data', (d) => { out += d; });
      p.on('error', reject);
      p.on('exit', () => resolve(out.trim()));
    });

    const N = 12;
    const results = await Promise.all(Array.from({ length: N }, () => child()));
    const acquired = results.filter((r) => r === '1').length;
    assert.equal(acquired, 1, `exactly one of ${N} concurrent processes should reclaim (got ${acquired}: ${results.join('')})`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a STALE reclaim-gate (crashed reclaimer) does not block reclaim forever', () => {
  withState((dir) => {
    const fp = 'iiii9999';
    // A reclaimer that crashed mid-takeover leaves the O_EXCL reclaim-gate file
    // behind. Pair it with a stale lock. A fresh run must break the stale gate
    // (TTL) and still reclaim — the gate is not a permanent deadlock.
    const lockDir = lockDirOf(dir, fp);
    mkdirSync(lockDir, { recursive: true });
    writeFileSync(join(lockDir, 'owner'), 'crashed-owner');
    const gate = `${lockDir}.reclaim`;
    writeFileSync(gate, 'crashed-reclaimer');
    const old = new Date(Date.now() - 60 * 60_000);
    utimesSync(lockDir, old, old);
    utimesSync(gate, old, old); // gate itself is stale

    const tok = acquireDraftLock(fp);
    assert.ok(tok, 'a stale reclaim-gate is broken on TTL → reclaim proceeds');
    assert.equal(ownerOf(dir, fp), tok, 'reclaimer owns the fresh lock');
    assert.equal(existsSync(gate), false, 'reclaim-gate is released after the takeover');
  });
});

test('a FRESH reclaim-gate (a live reclaimer) makes a second run skip (null)', () => {
  withState((dir) => {
    const fp = 'llll1212';
    // A live reclaimer is mid-takeover: stale lock present, gate freshly held.
    const lockDir = lockDirOf(dir, fp);
    mkdirSync(lockDir, { recursive: true });
    writeFileSync(join(lockDir, 'owner'), 'crashed-owner');
    const gate = `${lockDir}.reclaim`;
    writeFileSync(gate, 'live-reclaimer'); // fresh mtime (just written)
    const old = new Date(Date.now() - 60 * 60_000);
    utimesSync(lockDir, old, old); // lock is stale...

    // ...but the gate is fresh, so a second run must NOT also reclaim → null.
    assert.equal(acquireDraftLock(fp), null, 'a live reclaim-gate holder blocks a second reclaimer');
  });
});

test('unexpected error path fails CLOSED (throws → caller does not file)', () => {
  withState(() => {
    // Point the state dir at a path whose PARENT is a regular file, so mkdir of
    // the state dir (and thus the lock) raises a NON-EEXIST error (ENOTDIR).
    const base = mkdtempSync(join(tmpdir(), 'healer-bad-'));
    const fileAsParent = join(base, 'not-a-dir');
    rmSync(fileAsParent, { force: true });
    writeFileSync(fileAsParent, 'x');
    process.env.HEALER_STATE_DIR = join(fileAsParent, 'state'); // parent is a file → ENOTDIR

    assert.throws(
      () => acquireDraftLock('dddd4444'),
      (err) => err && err.code !== 'EEXIST',
      'an unexpected (non-EEXIST) error must propagate so the caller fails closed',
    );
    rmSync(base, { recursive: true, force: true });
  });
});

test('distinct fingerprints do not block each other', () => {
  withState(() => {
    assert.ok(acquireDraftLock('eeee5555'), 'fp A acquires');
    assert.ok(acquireDraftLock('ffff6666'), 'fp B acquires independently');
    assert.equal(acquireDraftLock('eeee5555'), null, 'fp A still held');
    assert.equal(acquireDraftLock('ffff6666'), null, 'fp B still held');
  });
});
