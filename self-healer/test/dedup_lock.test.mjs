// dedup_lock.test.mjs — the single-box atomic lock that closes the green-draft
// check-then-create race (an overlapping cron tick + a manual run on the same
// OCI box can't double-file the same fingerprint).
//
// Zero-dep node:test. Each test uses an isolated tmp HEALER_STATE_DIR so the
// lock paths never collide between cases or with a real run.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, existsSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

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

test('atomic acquire: first wins, second on same fingerprint skips', () => {
  withState(() => {
    const fp = 'aaaa1111';
    assert.equal(acquireDraftLock(fp), true, 'first acquire should win');
    assert.equal(acquireDraftLock(fp), false, 'second acquire (lock still held) should skip');
  });
});

test('stale lock is reclaimed after TTL', () => {
  withState((dir) => {
    const fp = 'bbbb2222';
    assert.equal(acquireDraftLock(fp), true, 'first acquire wins');
    // A concurrent live run still sees it held.
    assert.equal(acquireDraftLock(fp), false, 'fresh lock blocks a second run');

    // Simulate a crashed run by back-dating the lock dir's mtime well past the
    // 10-min default TTL.
    const lockDir = join(dir, `draft-lock-${fp}`);
    const old = new Date(Date.now() - 60 * 60_000); // 1h ago
    utimesSync(lockDir, old, old);

    assert.equal(acquireDraftLock(fp), true, 'stale lock should be reclaimed and re-acquired');
  });
});

test('lock released after a filing attempt → a later run can re-acquire', () => {
  withState((dir) => {
    const fp = 'cccc3333';
    assert.equal(acquireDraftLock(fp), true, 'acquire');
    releaseDraftLock(fp);
    assert.equal(existsSync(join(dir, `draft-lock-${fp}`)), false, 'release removes the lock dir');
    assert.equal(acquireDraftLock(fp), true, 'a later run can re-acquire after release');
  });
});

test('unexpected error path fails CLOSED (throws → caller does not file)', () => {
  withState(() => {
    // Point the state dir at a path whose PARENT is a regular file, so mkdir of
    // the state dir (and thus the lock) raises a NON-EEXIST error (ENOTDIR).
    const base = mkdtempSync(join(tmpdir(), 'healer-bad-'));
    const fileAsParent = join(base, 'not-a-dir');
    // Create a regular file where a directory is expected.
    rmSync(fileAsParent, { force: true });
    mkdirSync(base, { recursive: true });
    // Write a file, then use it as if it were the state dir's parent.
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
    assert.equal(acquireDraftLock('eeee5555'), true, 'fp A acquires');
    assert.equal(acquireDraftLock('ffff6666'), true, 'fp B acquires independently');
    // And each is still independently held.
    assert.equal(acquireDraftLock('eeee5555'), false, 'fp A still held');
    assert.equal(acquireDraftLock('ffff6666'), false, 'fp B still held');
  });
});
