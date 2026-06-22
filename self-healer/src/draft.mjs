// draft.mjs — green-draft: the self-healer's first ACTION stage.
//
// On a CONFIDENT GREEN finding with a concrete proposedAction, file a
// remediation issue in the finding's source repo. This is the smallest real
// outward action with bounded blast radius — "build the cage before the
// monster":
//   - It files an ISSUE, never code. It never opens a PR, merges, or deploys.
//   - It is OFF by default (HEALER_DRAFT_ISSUES=1 to enable) — the action
//     stage exists but must be explicitly switched on.
//   - It dedups against the SOURCE OF TRUTH (open issues on the repo carrying
//     the finding's fingerprint marker), so a cron can't mint duplicates.
//   - It uses the GitHub API via fetch — NO shell, so none of the command
//     injection surface the cage-match flagged.
//   - All issue text is run through scrubSecrets first.
//
// The auto-code-writing PR (an LLM patching source from a log diagnosis) is the
// real "monster" — a prompt-injection-into-codegen surface — and is a
// deliberately separate, cage-built step. This is its safe precursor.

import { createHash } from 'node:crypto';
import { scrubSecrets } from './notify.mjs';
import { repoForContainer } from './repos.mjs';

const GH_API = 'https://api.github.com';
const LABEL = 'self-healer';

function token() {
  return process.env.HEALER_GH_TOKEN || process.env.GITHUB_TOKEN || process.env.GH_TOKEN || null;
}

/** Stable fingerprint of a single finding (container + tier + signature). The
 * SAME problem yields the SAME fp, which is embedded in the issue body as a
 * marker so we never file it twice. */
export function findingFingerprint(f) {
  return createHash('sha256').update(`${f.container}|${f.tier}|${f.signature}`).digest('hex').slice(0, 12);
}

/** Build the issue {title, body} for a finding. All dynamic text scrubbed; the
 * fingerprint marker is what makes filing idempotent (mirrors the
 * claude-task-id marker pattern used elsewhere). */
export function buildIssue(finding) {
  const s = (x) => scrubSecrets(String(x ?? ''));
  const fp = findingFingerprint(finding);
  const title = `[self-healer] ${s(finding.container)}: ${s(finding.signature)}`.slice(0, 250);
  const body = [
    `**Diagnosed by the self-healer** (read-only; this issue is a remediation *proposal*, not an automated fix).`,
    '',
    `- **Container:** ${s(finding.container)}`,
    `- **Tier:** ${s(finding.tier)} · confidence ${s(finding.confidence)}`,
    '',
    `**Diagnosis**`,
    s(finding.diagnosis) || '_(none provided)_',
    '',
    `**Evidence**`,
    '```',
    s(finding.evidence) || '(none)',
    '```',
    '',
    `**Proposed action**`,
    s(finding.proposedAction),
    '',
    `<!-- self-healer-fp: ${fp} -->`,
  ].join('\n');
  return { title, body, fp };
}

async function ghApi(method, path, body) {
  const res = await fetch(`${GH_API}${path}`, {
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
  return res;
}

/** Is there already an open self-healer issue in `repo` carrying this fp? Uses
 * the List Issues API (no search-index lag) filtered by our label — the
 * authoritative live state, reconciled BEFORE we mutate. */
async function alreadyFiled(repo, fp) {
  const res = await ghApi('GET', `/repos/${repo}/issues?state=open&labels=${LABEL}&per_page=100`);
  if (!res.ok) {
    // A 404 (label never created) or other read error ⇒ treat as "not filed"
    // but surface upstream; we'd rather risk a dup than suppress on a read glitch.
    return false;
  }
  const issues = await res.json();
  return Array.isArray(issues) && issues.some((i) => typeof i.body === 'string' && i.body.includes(`self-healer-fp: ${fp}`));
}

/** Best-effort: make sure the label exists so the create call (and the dedup
 * list filter) work. Tolerates 422 already-exists. */
async function ensureLabel(repo) {
  try {
    await ghApi('POST', `/repos/${repo}/labels`, { name: LABEL, color: '5319e7', description: 'Filed by the self-healer' });
  } catch { /* best-effort */ }
}

/**
 * For every confident-green, actionable finding, file a remediation issue in
 * its source repo (deduped). Returns a per-finding outcome list. A NO-OP (empty
 * list) when disabled, untokened, or nothing is actionable.
 *
 * "Actionable green" = tier green AND high confidence AND a concrete
 * proposedAction (not "none"). Self-recovered non-events have action "none" and
 * are correctly skipped.
 *
 * @param {{findings: object[]}} verdict
 * @returns {Promise<Array<{container: string, action: string, detail?: string, url?: string}>>}
 */
/** The findings green-draft will act on: confident-green with a concrete
 * action. Self-recovered non-events (action "none") and lower-confidence greens
 * are correctly excluded. Pure — exported for testing. */
export function actionableFindings(verdict) {
  return (verdict.findings || []).filter(
    (f) => f.tier === 'green' && f.confidence === 'high' && f.proposedAction && f.proposedAction !== 'none',
  );
}

export async function draftIfActionable(verdict) {
  if (process.env.HEALER_DRAFT_ISSUES !== '1') return [];
  if (!token()) return [{ container: '*', action: 'skipped', detail: 'no GitHub token (HEALER_GH_TOKEN)' }];

  const actionable = actionableFindings(verdict);

  const outcomes = [];
  for (const f of actionable) {
    const repo = repoForContainer(f.container);
    if (!repo) {
      outcomes.push({ container: f.container, action: 'skipped', detail: 'no known source repo' });
      continue;
    }
    const { title, body, fp } = buildIssue(f);
    try {
      if (await alreadyFiled(repo, fp)) {
        outcomes.push({ container: f.container, action: 'deduped', detail: `already open (fp ${fp})` });
        continue;
      }
      await ensureLabel(repo);
      const res = await ghApi('POST', `/repos/${repo}/issues`, { title, body, labels: [LABEL] });
      if (!res.ok) {
        const txt = await res.text().catch(() => '');
        outcomes.push({ container: f.container, action: 'failed', detail: `${res.status}: ${txt.slice(0, 120)}` });
        continue;
      }
      const issue = await res.json();
      outcomes.push({ container: f.container, action: 'filed', url: issue.html_url });
    } catch (err) {
      outcomes.push({ container: f.container, action: 'failed', detail: err.message });
    }
  }
  return outcomes;
}
