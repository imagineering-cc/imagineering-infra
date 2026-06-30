// notify.mjs — amber-ping: when a verdict is amber or red, send Nick a
// Telegram message via the existing `notify` proxy.
//
// TOPOLOGY: we do NOT hold a Telegram bot token or build a Telegram path. The
// `notify` service (imagineering-infra/notify, https://notify.imagineering.cc)
// already is the notification bus — it holds the bot token centrally and takes
// a thin `POST /send` with a Bearer API key. Because notify is PUBLIC https
// (unlike claude-shim's loopback bind), this is a plain `fetch` — no shell, no
// SSH, no host primitive, no injection surface.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

/** Resolve + validate the notify endpoint. The Bearer key is sent in this
 * request, so we refuse to send it anywhere but https (TLS) or loopback http —
 * an env-poisoned NOTIFY_URL can't redirect the key to an attacker over plain
 * http (cage-match PR #101). Mirrors diagnose.mjs's SHIM_URL discipline. */
function resolveNotifyUrl() {
  const raw = process.env.NOTIFY_URL || 'https://notify.imagineering.cc/send';
  let u;
  try { u = new URL(raw); } catch { throw new Error(`NOTIFY_URL is not a valid URL: ${JSON.stringify(raw)}`); }
  const loopback = u.hostname === '127.0.0.1' || u.hostname === 'localhost' || u.hostname === '::1';
  if (u.protocol === 'https:' || (u.protocol === 'http:' && loopback)) return u.toString();
  throw new Error(`NOTIFY_URL must be https (or http to loopback) so the Bearer key isn't sent in cleartext. Got: ${raw}`);
}

const TELEGRAM_MAX = 4096; // Telegram's hard message-length limit.

// Known secret PREFIXES — the first line of defence (cheap, precise). NOT the
// only line: the generic rules below catch the shapes a prefix list can't.
const KNOWN_SECRET_PATTERNS = [
  [/\bsk-ant-[a-zA-Z0-9_-]{6,}/g, '<redacted:anthropic-key>'],
  [/\b(?:github_pat|gh[posru])_[A-Za-z0-9_]{16,}/g, '<redacted:github-token>'],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}/g, '<redacted:slack-token>'],
  [/\bAIza[A-Za-z0-9_-]{20,}/g, '<redacted:google-key>'],
  [/\bsk-(?:proj-)?[A-Za-z0-9]{20,}/g, '<redacted:openai-key>'],
  [/\bsk_(?:live|test)_[A-Za-z0-9]{16,}/g, '<redacted:stripe-key>'],
  [/\bxkeysib-[A-Za-z0-9]{16,}/g, '<redacted:brevo-key>'],
  [/\bAKIA[0-9A-Z]{16}\b/g, '<redacted:aws-key-id>'],
  [/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{12,}/g, '<redacted:bearer>'],
  [/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}/g, '<redacted:jwt>'],
  [/-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----/g, '<redacted:private-key>'],
];

/**
 * Scrub secret-shaped text out of a message before it leaves the box. The
 * model's diagnosis/evidence MAY quote a credential-bearing log line. A prefix
 * denylist alone is a sieve (cage-match PR #101: AWS secret keys, unknown
 * tokens, k=v configs all slip it), so we LAYER three defences, leak-side
 * conservative (over-redaction in an outbound notification is cheap; a leak is
 * not):
 *   1. known secret prefixes (precise);
 *   2. key=value / key: value for sensitive key NAMES (catches unknown formats);
 *   3. a high-entropy catch-all for any 32+ char opaque token (catches AWS
 *      secret keys & unknown credentials). The 32 floor preserves shorter
 *      diagnostic IDs like LiveKit's ~24-char nodeIds.
 * @param {string} text
 * @returns {string}
 */
export function scrubSecrets(text) {
  if (typeof text !== 'string') return '';
  let out = text;
  for (const [re, repl] of KNOWN_SECRET_PATTERNS) out = out.replace(re, repl);
  // 2. sensitive key=value / key: value (preserve the key name, redact value).
  out = out.replace(
    /\b(pass(?:word|wd)?|secret|api[_-]?key|apikey|client[_-]?secret|access[_-]?key|auth(?:orization)?|token)\b(\s*[=:]\s*)('?"?)[^\s'"]+/gi,
    (_m, key, sep) => `${key}${sep}<redacted>`,
  );
  // 3. high-entropy catch-all: any 32+ char run of credential-alphabet chars.
  out = out.replace(/\b[A-Za-z0-9+/_-]{32,}={0,2}\b/g, '<redacted:high-entropy>');
  return out;
}

/** Escape the five HTML metacharacters so dynamic text can't break out of (or
 * inject into) the Telegram HTML parse_mode — including quotes, so the markup
 * stays safe if an attribute-bearing tag is ever added. */
function esc(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const DOT = { green: '🟢', amber: '🟡', red: '🔴' };

/**
 * Format a verdict into a compact Telegram HTML message. Includes ONLY the
 * verdict fields (summary + findings), never the raw `signals`/log tails, with
 * every dynamic string scrubbed then escaped, then capped to Telegram's limit.
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

  let msg = lines.join('\n');
  if (msg.length > TELEGRAM_MAX) msg = msg.slice(0, TELEGRAM_MAX - 20) + '\n<i>…(truncated)</i>';
  return msg;
}

/** A stable fingerprint of the PROBLEM SET (tiers + per-finding
 * container/tier/signature), order-independent. Same problems ⇒ same key; a new
 * finding or a tier escalation ⇒ different key ⇒ re-ping immediately. */
export function verdictFingerprint(verdict) {
  const parts = (verdict.findings || [])
    .map((f) => `${f.container}:${f.tier}:${f.signature}`)
    .sort();
  return createHash('sha256').update(`${verdict.overallTier}|${parts.join('|')}`).digest('hex').slice(0, 16);
}

/**
 * Cooldown gate (default ON, escalation-aware). Returns true if we should ping.
 * Skips a re-ping of the SAME problem set within HEALER_COOLDOWN_MIN minutes
 * (default 60) so a persistently-amber signal on a cron doesn't notify every
 * run — but an escalation or a new problem (different fingerprint) always pings,
 * and the same problem re-pings once the window lapses (an hourly reminder, not
 * spam). Degrades OPEN: if the state file can't be read/written, we ping anyway
 * (missing a real alert is worse than a duplicate). @returns {boolean} */
export function passesCooldown(verdict, nowMs) {
  const windowMin = Number.parseInt(process.env.HEALER_COOLDOWN_MIN ?? '60', 10);
  if (!Number.isFinite(windowMin) || windowMin <= 0) return true; // cooldown disabled
  const dir = process.env.HEALER_STATE_DIR || '/tmp/self-healer';
  const file = join(dir, 'last-ping.json');
  const fp = verdictFingerprint(verdict);

  let prior = null;
  try { prior = JSON.parse(readFileSync(file, 'utf8')); } catch { /* no/!corrupt state ⇒ ping */ }
  if (prior && prior.fp === fp && typeof prior.atMs === 'number' && nowMs - prior.atMs < windowMin * 60_000) {
    return false; // same problem set, still inside the window
  }
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, JSON.stringify({ fp, atMs: nowMs }));
  } catch { /* best-effort: a write failure must not suppress the alert */ }
  return true;
}

/**
 * Ping Nick about a verdict IF it's amber+, a NOTIFY_API_KEY is configured, and
 * the cooldown allows it. Green / unconfigured / disabled / cooled-down cases
 * are silent no-ops so a dev run never errors and nothing spams.
 * @param {{summary: string, overallTier: string, findings: object[]}} verdict
 * @param {number} [nowMs] injectable clock for tests
 * @returns {Promise<{pinged: boolean, reason?: string}>}
 */
export async function pingIfNoteworthy(verdict, nowMs = Date.now()) {
  if (verdict.overallTier === 'green') return { pinged: false, reason: 'green — nothing to report' };
  if (process.env.HEALER_NO_PING === '1') return { pinged: false, reason: 'disabled via HEALER_NO_PING' };
  if (!process.env.NOTIFY_API_KEY) return { pinged: false, reason: 'no NOTIFY_API_KEY configured' };
  if (!passesCooldown(verdict, nowMs)) return { pinged: false, reason: 'cooldown — same problem set recently pinged' };

  const { sent, reason } = await sendNotify(formatVerdict(verdict));
  return sent ? { pinged: true } : { pinged: false, reason };
}

/**
 * Send a raw message to Nick via the notify proxy. Scrubs secrets + caps to
 * Telegram's length limit. A SILENT no-op (sent:false) when NOTIFY_API_KEY is
 * unset, so a dev run never errors and an unconfigured box never throws. Used for
 * green-auto lifecycle pings (PR opened / failed) where there is no verdict —
 * `pingIfNoteworthy` delegates its actual POST here too. Respects HEALER_NO_PING.
 * @param {string} message  may contain attacker-influenceable diagnosis text → scrubbed
 * @param {{parseMode?: string}} [opts]
 * @returns {Promise<{sent: boolean, reason?: string}>}
 */
export async function sendNotify(message, { parseMode = 'HTML' } = {}) {
  if (process.env.HEALER_NO_PING === '1') return { sent: false, reason: 'disabled via HEALER_NO_PING' };
  const apiKey = process.env.NOTIFY_API_KEY;
  if (!apiKey) return { sent: false, reason: 'no NOTIFY_API_KEY configured' };

  const safe = scrubSecrets(String(message ?? '')).slice(0, TELEGRAM_MAX);
  const res = await fetch(resolveNotifyUrl(), {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({ message: safe, parse_mode: parseMode }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`notify /send failed (${res.status}): ${body.slice(0, 200)}`);
  }
  return { sent: true };
}
