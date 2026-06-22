// diagnose.mjs — send the sensor bundle to the claude-shim brain and parse
// the structured verdict back out, validating it against the closed tier set.

import { runOnHost } from './host.mjs';
import { SYSTEM_PROMPT, buildUserMessage } from './prompt.mjs';
import { normalizeTier, maxTier, TIERS } from './tiers.mjs';

// Diagnosis wants a stronger model than the shim's haiku default — getting the
// tier classification right matters more than latency here. The shim explicitly
// supports a per-request model override for exactly this caller.
const DIAGNOSE_MODEL = process.env.HEALER_MODEL || 'sonnet';

/**
 * Resolve + validate the shim endpoint. SHIM_URL is interpolated into a shell
 * command (curl …), so an unvalidated env value would be a command-injection
 * vector (cage-match PR #100: `SHIM_URL='http://x; rm -rf /'`). We require a
 * well-formed http URL pointing at loopback — which is also the shim's actual
 * binding (127.0.0.1:8088), so this both closes the injection surface AND
 * encodes a true invariant.
 */
function resolveShimUrl() {
  const raw = process.env.SHIM_URL || 'http://127.0.0.1:8088/chat';
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error(`SHIM_URL is not a valid URL: ${JSON.stringify(raw)}`);
  }
  const loopback = u.hostname === '127.0.0.1' || u.hostname === 'localhost' || u.hostname === '::1';
  if (u.protocol !== 'http:' || !loopback) {
    throw new Error(`SHIM_URL must be http://(127.0.0.1|localhost) — claude-shim is loopback-only. Got: ${raw}`);
  }
  // Re-serialize from the parsed URL so only structurally-valid, shell-inert
  // characters survive into the command string.
  return u.toString();
}

const SHIM_URL = resolveShimUrl();

/**
 * Pull the FIRST balanced JSON object out of the model's text, tracking string
 * state so braces inside string values (and the brace-heavy pino log lines we
 * feed the brain) don't throw off the span. Falls back with a clear error if
 * no balanced object is found.
 * @param {string} text
 * @returns {object}
 */
export function extractVerdict(text) {
  const start = text.indexOf('{');
  if (start === -1) throw new Error(`brain returned no JSON object. Raw:\n${text.slice(0, 400)}`);

  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return JSON.parse(text.slice(start, i + 1));
    }
  }
  throw new Error(`brain returned an unbalanced JSON object. Raw:\n${text.slice(0, 400)}`);
}

/**
 * Validate + normalize a parsed verdict against the closed tier set. Fails
 * CLOSED: anything we can't trust (bad tier, non-array findings) throws rather
 * than silently degrading to a green all-clear. Also recomputes overallTier as
 * the max of the per-finding tiers so the headline can't disagree with the
 * findings (and can't be steered by a prompt-injected top-level tier).
 * @param {any} v
 * @returns {{summary: string, overallTier: 'green'|'amber'|'red', findings: object[]}}
 */
export function validateVerdict(v) {
  if (!v || typeof v !== 'object') throw new Error('verdict is not an object');
  if (!Array.isArray(v.findings)) throw new Error('verdict.findings is not an array');

  const findings = v.findings.map((f, i) => {
    const tier = normalizeTier(f?.tier);
    if (!tier) throw new Error(`finding[${i}].tier is not a valid tier: ${JSON.stringify(f?.tier)}`);
    return { ...f, tier };
  });

  // overallTier is DERIVED, not trusted from the model — the max of the
  // findings (green when there are none). A prompt-injected "overallTier:
  // green" with a red finding underneath can't slip through.
  const derived = findings.reduce((acc, f) => maxTier(acc, f.tier), TIERS.GREEN);

  // If the model also supplied an overallTier, it must not be LOWER than the
  // derived one (i.e. must not under-report). We use the stricter of the two.
  const claimed = normalizeTier(v.overallTier);
  const overallTier = claimed ? maxTier(derived, claimed) : derived;

  return {
    summary: typeof v.summary === 'string' ? v.summary : '(no summary)',
    overallTier,
    findings,
  };
}

/**
 * @param {import('./sensor.mjs').ContainerSignal[]} signals
 * @returns {Promise<{summary: string, overallTier: string, findings: object[]}>}
 */
export async function diagnose(signals) {
  const body = JSON.stringify({
    system: SYSTEM_PROMPT,
    model: DIAGNOSE_MODEL,
    messages: [{ role: 'user', content: buildUserMessage(signals) }],
  });

  // curl ON THE HOST so we hit the shim's localhost bind. Body comes in via
  // stdin (@-) so we never have to quote a multi-KB JSON blob through a shell.
  // SHIM_URL was validated to be a shell-inert loopback http URL at load.
  const cmd = `curl -s --max-time 90 -H 'content-type: application/json' --data-binary @- '${SHIM_URL}'`;
  const { stdout, stderr, code } = await runOnHost(cmd, { stdin: body, timeoutMs: 100_000 });
  if (code !== 0) {
    throw new Error(`shim curl failed (exit ${code}): ${stderr.trim() || stdout.trim()}`);
  }

  let shimResponse;
  try {
    shimResponse = JSON.parse(stdout);
  } catch {
    throw new Error(`shim returned non-JSON envelope:\n${stdout.slice(0, 400)}`);
  }
  if (shimResponse.error) throw new Error(`shim error: ${shimResponse.error}`);
  if (typeof shimResponse.text !== 'string') {
    throw new Error(`shim envelope missing .text:\n${stdout.slice(0, 400)}`);
  }

  return validateVerdict(extractVerdict(shimResponse.text));
}
