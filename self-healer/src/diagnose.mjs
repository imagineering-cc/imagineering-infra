// diagnose.mjs — send the sensor bundle to the claude-shim brain and parse
// the structured verdict back out.

import { runOnHost } from './host.mjs';
import { SYSTEM_PROMPT, buildUserMessage } from './prompt.mjs';

const SHIM_URL = process.env.SHIM_URL || 'http://127.0.0.1:8088/chat';
// Diagnosis wants a stronger model than the shim's haiku default — getting the
// tier classification right matters more than latency here. The shim explicitly
// supports a per-request model override for exactly this caller.
const DIAGNOSE_MODEL = process.env.HEALER_MODEL || 'sonnet';

/**
 * Pull a JSON object out of the model's text, tolerant of stray prose or
 * ```json fences despite the contract asking for bare JSON. We grab the
 * outermost {...} span and parse that.
 */
function extractVerdict(text) {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end < start) {
    throw new Error(`brain returned no JSON object. Raw:\n${text.slice(0, 400)}`);
  }
  const json = text.slice(start, end + 1);
  return JSON.parse(json);
}

/**
 * @param {import('./sensor.mjs').ContainerSignal[]} signals
 * @returns {Promise<object>} the parsed verdict (see prompt.mjs OUTPUT CONTRACT)
 */
export async function diagnose(signals) {
  const body = JSON.stringify({
    system: SYSTEM_PROMPT,
    model: DIAGNOSE_MODEL,
    messages: [{ role: 'user', content: buildUserMessage(signals) }],
  });

  // curl ON THE HOST so we hit the shim's localhost bind. Body comes in via
  // stdin (@-) so we never have to quote a multi-KB JSON blob through a shell.
  const cmd = `curl -s --max-time 90 -H 'content-type: application/json' --data-binary @- ${SHIM_URL}`;
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

  return extractVerdict(shimResponse.text);
}
