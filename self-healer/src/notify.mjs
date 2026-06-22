// notify.mjs — amber-ping: when a verdict is amber or red, send Nick a
// Telegram message via the existing `notify` proxy.
//
// TOPOLOGY: we do NOT hold a Telegram bot token or build a Telegram path. The
// `notify` service (imagineering-infra/notify, https://notify.imagineering.cc)
// already is the notification bus — it holds the bot token centrally and takes
// a thin `POST /send` with a Bearer API key. amber-ping just POSTs to it.
// Because notify is PUBLIC https (unlike claude-shim's loopback bind), this is
// a plain `fetch` — no shell, no SSH, no host primitive, no injection surface.

const NOTIFY_URL = process.env.NOTIFY_URL || 'https://notify.imagineering.cc/send';

/**
 * Scrub secret-shaped tokens out of any text before it leaves the box. The
 * verdict's diagnosis/evidence fields are model-generated and MAY quote a log
 * line that contains a credential (cage-match PR #100 concern). We replace
 * known token shapes with a typed placeholder rather than trusting the model
 * not to echo a secret.
 * @param {string} text
 * @returns {string}
 */
export function scrubSecrets(text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/sk-ant-[a-zA-Z0-9_-]{8,}/g, '<redacted:anthropic-key>')
    .replace(/\bgh[posru]_[A-Za-z0-9]{16,}/g, '<redacted:github-token>')
    .replace(/\bxkeysib-[a-f0-9]{16,}/g, '<redacted:brevo-key>')
    .replace(/\bAKIA[0-9A-Z]{16}\b/g, '<redacted:aws-key>')
    .replace(/\bBearer\s+[A-Za-z0-9._-]{12,}/g, 'Bearer <redacted>')
    .replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}/g, '<redacted:jwt>');
}

/** Escape the five HTML metacharacters so dynamic text can't break (or inject
 * into) the Telegram HTML parse_mode markup. */
function esc(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

const DOT = { green: '🟢', amber: '🟡', red: '🔴' };

/**
 * Format a verdict into a compact Telegram HTML message. Includes ONLY the
 * verdict fields (summary + findings), never the raw `signals`/log tails — and
 * scrubs secrets from every dynamic string as defence in depth.
 * @param {{summary: string, overallTier: string, findings: object[]}} verdict
 * @returns {string}
 */
export function formatVerdict(verdict) {
  const clean = (s) => esc(scrubSecrets(s));
  const lines = [
    `${DOT[verdict.overallTier] || '⚪'} <b>Self-healer: ${esc(verdict.overallTier?.toUpperCase())}</b>`,
    clean(verdict.summary),
  ];
  for (const f of verdict.findings || []) {
    lines.push('');
    lines.push(`${DOT[f.tier] || '⚪'} <b>${clean(f.container)}</b> — ${clean(f.signature)}` +
      `${f.selfRecovered ? ' <i>(self-recovered)</i>' : ''}`);
    if (f.diagnosis) lines.push(clean(f.diagnosis));
    if (f.proposedAction && f.proposedAction !== 'none') lines.push(`→ ${clean(f.proposedAction)}`);
  }
  lines.push('');
  lines.push('<i>read-only v1 — no remediation taken</i>');
  return lines.join('\n');
}

/**
 * Ping Nick about a verdict IF it's worth pinging about (amber or red) and a
 * NOTIFY_API_KEY is configured. Green verdicts and unconfigured environments
 * are silent no-ops — so a dev run without a key doesn't error, and a clean
 * bill of health doesn't spam.
 *
 * NOTE (known limitation, intentional for v1): this is STATELESS — it has no
 * cooldown/dedup. A persistently-amber signal pinged on a cron would notify
 * every run. The healer is not scheduled yet, so this can't spam today; a
 * cooldown MUST be added before wiring the cron (tracked as a follow-up).
 *
 * @param {{summary: string, overallTier: string, findings: object[]}} verdict
 * @returns {Promise<{pinged: boolean, reason?: string}>}
 */
export async function pingIfNoteworthy(verdict) {
  if (verdict.overallTier === 'green') return { pinged: false, reason: 'green — nothing to report' };
  if (process.env.HEALER_NO_PING === '1') return { pinged: false, reason: 'disabled via HEALER_NO_PING' };

  const apiKey = process.env.NOTIFY_API_KEY;
  if (!apiKey) return { pinged: false, reason: 'no NOTIFY_API_KEY configured' };

  const message = formatVerdict(verdict);
  const res = await fetch(NOTIFY_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({ message, parse_mode: 'HTML' }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`notify /send failed (${res.status}): ${body.slice(0, 200)}`);
  }
  return { pinged: true };
}
