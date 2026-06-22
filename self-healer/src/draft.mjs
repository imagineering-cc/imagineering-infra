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
import { scrubSecrets } from './notify.mjs';
import { repoForContainer } from './repos.mjs';

const GH_API = 'https://api.github.com';
const LABEL = 'self-healer';
const ZWSP = '​'; // zero-width space, to neutralize @mentions

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
    }
  }
  return outcomes;
}
