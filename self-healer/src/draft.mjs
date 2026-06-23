// draft.mjs — green-draft: the self-healer's first ACTION stage.
//
// On a CONFIDENT GREEN finding with a concrete proposedAction, file a
// remediation issue in the finding's source repo. This is the smallest real
// outward action with bounded blast radius — "build the cage before the
// monster":
//   - It files an ISSUE, never code. It never opens a PR, merges, or deploys.
//   - It is OFF by default (HEALER_DRAFT_ISSUES=1 to enable).
//   - It dedups against the SOURCE OF TRUTH (open issues on the repo carrying
//     the finding's fingerprint marker) and fails CLOSED: if it can't confirm
//     "not a duplicate", it does NOT file (cage-match PR #104).
//   - It uses the GitHub API via fetch — NO shell.
//   - All issue text is scrubbed and length-capped, and @mentions neutralized.
//
// The auto-code-writing PR (an LLM patching source from a log diagnosis) is the
// real "monster" — a prompt-injection-into-codegen surface — and is a
// deliberately separate, cage-built step. This is its safe precursor.

import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync, rmSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { scrubSecrets } from './notify.mjs';
import { repoForContainer } from './repos.mjs';

const GH_API = 'https://api.github.com';
const LABEL = 'self-healer';
const ZWSP = '​'; // zero-width space, to neutralize @mentions

// Single-box owner-fenced lock for the green-draft race window.
//
// The fingerprint-marker dedup (alreadyFiled) reconciles against GitHub's open
// issues, but GitHub's List API is eventually-consistent and the check-then-
// create sequence has no atomic step — two near-simultaneous healer runs on the
// SAME box (an overlapping cron tick + a manual run) can both read "not filed"
// and both create. This lock closes that window: each per-finding draft first
// takes a per-fingerprint lock; exactly one caller wins, the others SKIP.
//
// OWNER IDENTITY + SERIALIZED RECLAIM (cage-match PR #108, Maxwell + Carnot).
// The naive "mkdir wins, rm-then-mkdir reclaims" design has two races because
// the lock has no owner and the reclaim isn't atomic:
//   1. the steal+re-create is multi-step, so under concurrent stale-reclaim two
//      runs can both end up creating (a stat/rename TOCTOU ABA) → DOUBLE FILE;
//   2. unconditional release deletes whatever's at the path, not the lock THIS
//      caller took — so a run whose filing outran the TTL and was reclaimed out
//      from under it would, in its finally, delete the NEW owner's lock → a
//      third run enters the critical section.
// The fix has THREE atomic gates, all fenced on a unique OWNER TOKEN
// (crypto.randomBytes) written into the lock dir:
//   - ACQUIRE (fast path): `mkdirSync(lockPath)` — atomic on POSIX (exactly one
//     caller wins; others get EEXIST), then write the token file. Returns the
//     token, or null if another live run owns it.
//   - RECLAIM (stale lock): the steal+re-create runs UNDER a per-fingerprint
//     O_EXCL reclaim-gate file (`writeFileSync(gate, …, {flag:'wx'})`), so the
//     takeover is SINGLE-THREADED — exactly one reclaimer holds the gate, re-
//     checks staleness inside it, removes the stale dir, and re-creates with its
//     token. This single-writer reclaim eliminates the lock-free ABA that
//     defeats a pure rename/stat steal under 3+ concurrent reclaimers. (A
//     stale gate, from a crashed reclaimer, is itself broken on a TTL basis.)
//   - RELEASE: read the token file; only remove the lock if it STILL MATCHES the
//     token we acquired. A run reclaimed out from under itself reads a different
//     (or missing) token → it does NOT delete the new owner's lock.
// Net guarantee: AT MOST ONE winner for any number of concurrent callers
// (verified by an N-process stress test). Under pathological contention a caller
// may get a false `null` (skip) — SAFE for a fail-closed write gate (the next
// cron tick re-files), never a double.
//
// The lock is keyed on the SAME findingFingerprint the marker dedup uses, so
// distinct findings never contend and the two layers agree by construction. The
// lock guards the short race window; the marker guards across longer spans (it
// survives a crash, a TTL reclaim, or a process restart). The lock is ADDITIVE
// to the marker, never a replacement.
//
// SCOPE — this is a SINGLE-HOST lock. The real deployment is one OCI box (cron +
// manual runs), which is exactly what this covers. It does NOT provide cross-
// host / distributed mutual exclusion; if green-auto ever runs on multiple hosts
// concurrently, a shared store (Redis SETNX, a GitHub-side claim, etc.) would be
// required. Documented as future work.

/** State dir, resolved the SAME way as notify.mjs's passesCooldown so the
 * healer keeps all its on-box state in one place. */
function lockStateDir() {
  return process.env.HEALER_STATE_DIR || '/tmp/self-healer';
}

/** Lock TTL in ms. A crashed run must not block a fingerprint forever, so a
 * lock older than the TTL is reclaimable. Env knob HEALER_LOCK_TTL_MIN (minutes,
 * default 10). A non-positive / non-finite value falls back to the default
 * rather than disabling staleness — never leave a fingerprint permanently
 * lockable-but-unreclaimable. */
function lockTtlMs() {
  const min = Number.parseInt(process.env.HEALER_LOCK_TTL_MIN ?? '10', 10);
  return (Number.isFinite(min) && min > 0 ? min : 10) * 60_000;
}

/** Path of the per-fingerprint lock directory. */
function lockPath(fp) {
  return join(lockStateDir(), `draft-lock-${fp}`);
}

/** Path of the owner-token file inside a lock dir. */
function ownerFile(path) {
  return join(path, 'owner');
}

/** Create the canonical lock dir atomically and stamp it with `tok`.
 * Returns the token on success; null if another caller won the mkdir (EEXIST);
 * rethrows on any unexpected error (fail-closed). The token write happens AFTER
 * the atomic mkdir, so the mkdir is the single point of mutual exclusion. */
function stampNewLock(path, tok) {
  try {
    mkdirSync(path); // atomic: exactly one caller wins
  } catch (err) {
    if (err && err.code === 'EEXIST') return null; // someone else owns it
    throw err; // unexpected → fail closed
  }
  writeFileSync(ownerFile(path), tok);
  return tok;
}

/** Path of the per-fingerprint RECLAIM GATE file. This is a SEPARATE O_EXCL
 * file that serializes stale-lock reclaimers: only its holder may steal +
 * re-create the canonical lock, so the reclaim critical section is single-
 * threaded and free of the rename/stat ABA races that defeat a lock-free steal
 * under 3+ concurrent reclaimers. */
function reclaimGatePath(fp) {
  return `${lockPath(fp)}.reclaim`;
}

/**
 * Try to acquire the per-fingerprint draft lock.
 *
 * Returns a non-empty OWNER TOKEN string if THIS caller now owns the lock (pass
 * it to releaseDraftLock so release is owner-fenced); returns `null` if another
 * live run owns it (skip). Throws ONLY on an unexpected error so the caller
 * fails closed (does NOT file) — consistent with the dedup read's "can't confirm
 * → don't write". A `null` is a clean "someone else owns it", not an error.
 *
 * Mutual exclusion has TWO atomic gates:
 *   1. the canonical lock dir — `mkdirSync` (exactly one creator wins);
 *   2. the reclaim gate — an O_EXCL file that single-threads stale takeover so
 *      the steal+re-create can't ABA-race under N≥3 concurrent reclaimers.
 * Together they guarantee AT MOST ONE winner for any number of concurrent
 * callers (verified by an N-process stress test). Under pathological contention
 * a caller may get a false `null` (skip) — which is SAFE for a fail-closed write
 * gate (the next cron tick re-files), never a double.
 * @returns {string|null}
 */
export function acquireDraftLock(fp, nowMs = Date.now()) {
  const path = lockPath(fp);
  const tok = randomBytes(16).toString('hex');
  mkdirSync(lockStateDir(), { recursive: true });

  // Fast path: an uncontended / free path is claimed by a single atomic mkdir.
  const fresh = stampNewLock(path, tok);
  if (fresh) return fresh;

  // The lock exists. Decide stale vs live by age.
  let ageMs;
  try {
    ageMs = nowMs - statSync(path).mtimeMs;
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      // Vanished between mkdir and stat (a concurrent release). Retry the atomic
      // create once; its outcome is authoritative.
      return stampNewLock(path, tok); // token | null
    }
    throw err; // unexpected → fail closed
  }
  if (ageMs <= lockTtlMs()) return null; // fresh lock held by a live run → skip

  // STALE → serialize the takeover through the O_EXCL reclaim gate so exactly
  // one reclaimer runs the steal+re-create at a time (no lock-free ABA).
  return reclaimStaleLock(fp, path, tok, nowMs);
}

/** Reclaim a STALE canonical lock under the single-writer reclaim gate. Returns
 * the new owner token if this caller reclaimed it, else null (another reclaimer
 * holds the gate, or the lock turned out live/already-reclaimed on re-check). */
function reclaimStaleLock(fp, path, tok, nowMs) {
  const gate = reclaimGatePath(fp);

  // Acquire the reclaim gate atomically (O_EXCL). If held, try to break it only
  // if it's itself stale (a crashed reclaimer); otherwise skip — a live
  // reclaimer is handling this fingerprint.
  try {
    writeFileSync(gate, tok, { flag: 'wx' }); // atomic create-exclusive
  } catch (err) {
    if (err && err.code === 'EEXIST') {
      let gateAgeMs;
      try { gateAgeMs = nowMs - statSync(gate).mtimeMs; } catch { return null; }
      if (gateAgeMs <= lockTtlMs()) return null; // a live reclaimer holds the gate → skip
      // Stale gate: clear it and retry the exclusive create ONCE.
      try { rmSync(gate, { force: true }); } catch { /* tolerate */ }
      try {
        writeFileSync(gate, tok, { flag: 'wx' });
      } catch (e2) {
        if (e2 && e2.code === 'EEXIST') return null; // another reclaimer won the gate
        throw e2; // unexpected → fail closed
      }
    } else {
      throw err; // unexpected → fail closed
    }
  }

  // GATE HELD — single-threaded critical section. Re-check the lock under the
  // gate (it may have been reclaimed/released since our pre-gate stat), then
  // steal + re-create.
  try {
    let curAgeMs;
    try {
      curAgeMs = nowMs - statSync(path).mtimeMs;
    } catch (err) {
      if (err && err.code === 'ENOENT') {
        // Lock gone (released under us) → just create fresh.
        return stampNewLock(path, tok); // token | null
      }
      throw err; // unexpected → fail closed
    }
    if (curAgeMs <= lockTtlMs()) return null; // became live → skip
    // Still stale, and we are the sole reclaimer: remove + re-create.
    rmSync(path, { recursive: true, force: true });
    return stampNewLock(path, tok); // token | null (null only on an impossible race)
  } finally {
    try { rmSync(gate, { force: true }); } catch { /* gate TTL is the backstop */ }
  }
}

/**
 * Release the per-fingerprint lock after a filing ATTEMPT completes (success or
 * failure), so the next legitimate run isn't blocked. OWNER-FENCED: removes the
 * lock ONLY if its on-disk owner token still matches `tok` (the token returned
 * by acquireDraftLock). A run that was reclaimed out from under itself reads a
 * different/missing token and does NOT delete the new owner's lock. Best-effort:
 * a release failure must not throw (the TTL reclaim is the backstop).
 * @param {string} fp
 * @param {string} tok the token returned by acquireDraftLock for this fp
 */
export function releaseDraftLock(fp, tok) {
  const path = lockPath(fp);
  try {
    const onDisk = readFileSync(ownerFile(path), 'utf8');
    if (onDisk !== tok) return; // not ours anymore (reclaimed) → do NOT delete
    rmSync(path, { recursive: true, force: true });
  } catch { /* missing/unreadable token or rm failure → leave it; TTL reclaims */ }
}

function token() {
  return process.env.HEALER_GH_TOKEN || process.env.GITHUB_TOKEN || process.env.GH_TOKEN || null;
}

/** Stable fingerprint of a single finding (container + tier + signature).
 * 32 hex (128 bits) — collision-resistant even against an attacker who can
 * influence those fields via log content (cage-match PR #104). Embedded in the
 * issue body as a marker so we never file the same finding twice. */
export function findingFingerprint(f) {
  return createHash('sha256').update(`${f.container}|${f.tier}|${f.signature}`).digest('hex').slice(0, 32);
}

/** Scrub secrets, neutralize @mentions (a zero-width space after @ stops GitHub
 * from linking it), and cap length — so attacker-influenced log content in an
 * issue body can't leak a secret, ping people, or run unbounded. */
function safeField(x, max) {
  let s = scrubSecrets(String(x ?? '')).replace(/@(?=[a-zA-Z0-9_-])/g, `@${ZWSP}`);
  if (s.length > max) s = s.slice(0, max) + ' …(truncated)';
  return s;
}

/** Build the issue {title, body, fp}. The fingerprint marker is what makes
 * filing idempotent (mirrors the claude-task-id marker pattern). */
export function buildIssue(finding) {
  const fp = findingFingerprint(finding);
  const title = `[self-healer] ${safeField(finding.container, 60)}: ${safeField(finding.signature, 150)}`.slice(0, 250);
  const body = [
    '**Diagnosed by the self-healer** (read-only; this issue is a remediation *proposal*, not an automated fix).',
    '',
    `- **Container:** ${safeField(finding.container, 60)}`,
    `- **Tier:** ${safeField(finding.tier, 10)} · confidence ${safeField(finding.confidence, 10)}`,
    '',
    '**Diagnosis**',
    safeField(finding.diagnosis, 1000) || '_(none provided)_',
    '',
    '**Evidence**',
    '```',
    safeField(finding.evidence, 1500) || '(none)',
    '```',
    '',
    '**Proposed action**',
    safeField(finding.proposedAction, 500),
    '',
    `<!-- self-healer-fp: ${fp} -->`,
  ].join('\n');
  return { title, body, fp };
}

async function ghApi(method, path, body) {
  return fetch(`${GH_API}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token()}`,
      accept: 'application/vnd.github+json',
      'x-github-api-version': '2022-11-28',
      'content-type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20_000),
  });
}

/** Best-effort: ensure the label exists so the dedup list-filter and the create
 * call both work. Called BEFORE the dedup read so the list query always has a
 * valid label to filter on. Tolerates 422 already-exists / transient errors. */
async function ensureLabel(repo) {
  try {
    await ghApi('POST', `/repos/${repo}/labels`, { name: LABEL, color: '5319e7', description: 'Filed by the self-healer' });
  } catch { /* best-effort */ }
}

/**
 * Is there already an open self-healer issue in `repo` carrying this fp?
 * Reconciles against the live issue list (no search-index lag), PAGINATED past
 * the 100-per-page cap. FAILS CLOSED: a non-OK read THROWS, so the caller skips
 * filing rather than mutating blindly on a transient 403/5xx (cage-match PR
 * #104 — the right failure direction for a WRITE stage). @returns {boolean} */
async function alreadyFiled(repo, fp) {
  const marker = `self-healer-fp: ${fp}`;
  for (let page = 1; page <= 20; page++) { // bound at 2000 open issues
    const res = await ghApi('GET', `/repos/${repo}/issues?state=open&labels=${LABEL}&per_page=100&page=${page}`);
    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      throw new Error(`dedup list read failed (${res.status}): ${txt.slice(0, 120)}`);
    }
    const issues = await res.json();
    if (!Array.isArray(issues) || issues.length === 0) return false;
    if (issues.some((i) => typeof i.body === 'string' && i.body.includes(marker))) return true;
    if (issues.length < 100) return false; // last page reached
  }
  return false; // exhausted the page bound; treat as not-filed (worst case: a dup)
}

/** The findings green-draft will act on: confident-green with a concrete
 * action. Normalizes proposedAction so " none ", "None", or empty are correctly
 * excluded (cage-match PR #104). Pure — exported for testing. */
export function actionableFindings(verdict) {
  return (verdict.findings || []).filter((f) => {
    if (f.tier !== 'green' || f.confidence !== 'high') return false;
    const action = String(f.proposedAction ?? '').trim().toLowerCase();
    return action !== '' && action !== 'none';
  });
}

/**
 * For every confident-green, actionable finding, file a remediation issue in
 * its source repo (deduped, fail-closed). NO-OP (empty list) when disabled or
 * untokened. Returns a per-finding outcome list.
 * @param {{findings: object[]}} verdict
 * @returns {Promise<Array<{container: string, action: string, detail?: string, url?: string}>>}
 */
export async function draftIfActionable(verdict) {
  if (process.env.HEALER_DRAFT_ISSUES !== '1') return [];
  if (!token()) return [{ container: '*', action: 'skipped', detail: 'no GitHub token (HEALER_GH_TOKEN)' }];

  const outcomes = [];
  for (const f of actionableFindings(verdict)) {
    const repo = repoForContainer(f.container);
    if (!repo) {
      outcomes.push({ container: f.container, action: 'skipped', detail: 'no known source repo' });
      continue;
    }
    const { title, body, fp } = buildIssue(f);

    // Atomic single-box lock: take it BEFORE the dedup read + create so a
    // concurrent run on the same box can't slip between our check and create.
    // A null return = another live run owns this fingerprint → skip. An
    // UNEXPECTED lock error throws → caught here → fail closed (no filing).
    let lockTok = null;
    try {
      lockTok = acquireDraftLock(fp);
    } catch (err) {
      outcomes.push({ container: f.container, action: 'failed', detail: `lock error (fail-closed): ${err.message}` });
      continue;
    }
    if (!lockTok) {
      outcomes.push({ container: f.container, action: 'deduped', detail: `concurrent run owns lock (fp ${fp.slice(0, 12)}…)` });
      continue;
    }

    try {
      await ensureLabel(repo); // before the dedup read, so the label filter is valid
      if (await alreadyFiled(repo, fp)) {
        outcomes.push({ container: f.container, action: 'deduped', detail: `already open (fp ${fp.slice(0, 12)}…)` });
        continue;
      }
      const res = await ghApi('POST', `/repos/${repo}/issues`, { title, body, labels: [LABEL] });
      if (!res.ok) {
        const txt = await res.text().catch(() => '');
        outcomes.push({ container: f.container, action: 'failed', detail: `${res.status}: ${txt.slice(0, 120)}` });
        continue;
      }
      const issue = await res.json();
      outcomes.push({ container: f.container, action: 'filed', url: issue.html_url });
    } catch (err) {
      // A dedup-read failure lands here → we do NOT file (fail closed).
      outcomes.push({ container: f.container, action: 'failed', detail: err.message });
    } finally {
      // Owner-fenced release after the attempt (success OR failure) so the next
      // legitimate run isn't blocked; the TTL reclaim is the backstop if release
      // fails. Passing our token ensures we never delete a lock that was
      // reclaimed out from under us (cage-match PR #108).
      releaseDraftLock(fp, lockTok);
    }
  }
  return outcomes;
}
