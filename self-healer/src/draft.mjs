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

import { createHash } from 'node:crypto';
import { mkdirSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { scrubSecrets } from './notify.mjs';
import { repoForContainer } from './repos.mjs';

const GH_API = 'https://api.github.com';
const LABEL = 'self-healer';
const ZWSP = '​'; // zero-width space, to neutralize @mentions

// Single-box atomic lock for the green-draft race window.
//
// The fingerprint-marker dedup (alreadyFiled) reconciles against GitHub's open
// issues, but GitHub's List API is eventually-consistent and the check-then-
// create sequence has no atomic step — two near-simultaneous healer runs on the
// SAME box (an overlapping cron tick + a manual run) can both read "not filed"
// and both create. This lock closes that window: each per-finding draft first
// takes a per-fingerprint lock; exactly one caller wins, the others SKIP.
//
// Primitive: `mkdirSync(lockPath)` — directory creation is atomic on POSIX
// filesystems (the kernel guarantees a single winner; concurrent callers get
// EEXIST). The lock is keyed on the SAME findingFingerprint the marker dedup
// uses, so distinct findings never contend and the two layers agree by
// construction. The lock guards the short race window; the marker guards across
// longer spans (it survives a crash, a TTL reclaim, or a process restart). The
// lock is ADDITIVE to the marker, never a replacement.
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

/**
 * Try to atomically acquire the per-fingerprint draft lock.
 *
 * Returns `true` if THIS caller now owns the lock (proceed to file), `false` if
 * another live run owns it (skip). Behaviour:
 *   - mkdir succeeds                → acquired (true).
 *   - mkdir throws EEXIST, lock STALE (mtime older than TTL) → reclaim it
 *     (remove + re-mkdir) and acquire. If the reclaim mkdir itself loses an
 *     EEXIST race to a concurrent reclaimer, the other run owns it → skip
 *     (false).
 *   - mkdir throws EEXIST, lock FRESH → another run owns it → skip (false).
 *   - any OTHER (unexpected) error   → FAIL CLOSED: rethrow so the caller does
 *     NOT file (consistent with the dedup read's "can't confirm → don't write").
 *
 * Note `false` is a clean "someone else owns it, skip"; only an UNEXPECTED error
 * propagates, which the caller treats as fail-closed (no filing).
 * @returns {boolean}
 */
export function acquireDraftLock(fp, nowMs = Date.now()) {
  const path = lockPath(fp);
  mkdirSync(lockStateDir(), { recursive: true });
  try {
    mkdirSync(path); // atomic: exactly one caller wins
    return true;
  } catch (err) {
    if (err && err.code === 'EEXIST') {
      // Lock exists. Reclaim only if it's stale (a crashed prior run).
      let ageMs;
      try {
        ageMs = nowMs - statSync(path).mtimeMs;
      } catch {
        // The lock vanished between mkdir and stat (a concurrent release/
        // reclaim). Re-attempt acquire ONCE; treat its outcome as authoritative.
        try { mkdirSync(path); return true; } catch (e2) {
          if (e2 && e2.code === 'EEXIST') return false; // someone else re-took it
          throw e2; // unexpected → fail closed
        }
      }
      if (ageMs > lockTtlMs()) {
        // Stale: reclaim. rm then re-mkdir; if a concurrent reclaimer beats us
        // to the re-mkdir, they own it and we skip.
        try { rmSync(path, { recursive: true, force: true }); } catch { /* tolerate; mkdir below decides */ }
        try { mkdirSync(path); return true; } catch (e3) {
          if (e3 && e3.code === 'EEXIST') return false;
          throw e3; // unexpected → fail closed
        }
      }
      return false; // fresh lock held by a live run → skip
    }
    throw err; // unexpected error → fail closed (do NOT file)
  }
}

/** Release the per-fingerprint lock after a filing ATTEMPT completes (success or
 * failure), so the next legitimate run isn't blocked. Best-effort: a release
 * failure must not throw (the TTL reclaim is the backstop). */
export function releaseDraftLock(fp) {
  try { rmSync(lockPath(fp), { recursive: true, force: true }); } catch { /* TTL reclaims */ }
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
    // A clean loss (false) = another live run owns this fingerprint → skip.
    // An UNEXPECTED lock error throws → caught below → fail closed (no filing).
    let locked = false;
    try {
      locked = acquireDraftLock(fp);
    } catch (err) {
      outcomes.push({ container: f.container, action: 'failed', detail: `lock error (fail-closed): ${err.message}` });
      continue;
    }
    if (!locked) {
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
      // Release after the attempt (success OR failure) so the next legitimate
      // run isn't blocked; the TTL reclaim is the backstop if release fails.
      releaseDraftLock(fp);
    }
  }
  return outcomes;
}
