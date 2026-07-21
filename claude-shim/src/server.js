// claude-shim — a tiny HTTP front door to Max-plan headless Claude Code.
//
// WHY THIS EXISTS
// ---------------
// Programmatic Claude calls on OCI should run on Nick's Max subscription
// (zero marginal cost) via headless Claude Code, NOT the metered Anthropic
// API. But two would-be callers live in Docker containers:
//   - dreamfinder-avatar's voice brain (was 400-erroring on zero API credit)
//   - the in-prod log-reading self-healer (diagnosis stage)
// Both need the same thing: "run Claude on the Max plan from this box."
// This service is that one shared artifact. It exposes a minimal
// chat-completion endpoint and, under the hood, spawns `claude -p`.
//
// AUTH
// ----
// The `claude` CLI reads CLAUDE_CODE_OAUTH_TOKEN directly from the
// environment (the output of `claude setup-token` on a Max account). This is
// the same mechanism claudius uses. No credentials file, no interactive login
// inside the container. Whichever account mints the token owns the weekly
// turn quota these calls consume.
//
// CONTRACT
// --------
//   POST /chat
//     body: { system?: string, messages: [{ role, content }], model?: string }
//     200:  { text: string }
//     4xx/5xx: { error: string }
//   GET /health -> { ok: true }
//
// Callers keep their own conversation history and send the full `messages`
// array each turn; the shim is stateless (`--no-session-persistence`).

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';

const PORT = Number(process.env.PORT || 8088);
// Default to the same Haiku tier DF used on the API, to preserve its latency
// profile. Callers may override per-request (e.g. the healer wants a stronger
// model for diagnosis).
const DEFAULT_MODEL = process.env.SHIM_DEFAULT_MODEL || 'haiku';
// Hard ceiling so a wedged `claude` process can't pin a request forever. DF's
// own pipeline budgets 4-8s per turn; give generous headroom for cold starts.
const TIMEOUT_MS = Number(process.env.SHIM_TIMEOUT_MS || 60_000);

if (!process.env.CLAUDE_CODE_OAUTH_TOKEN && !process.env.ANTHROPIC_API_KEY) {
  // Fail loud at boot rather than 500 on every request — a missing token is
  // an ops mistake, not a runtime condition to limp through.
  console.error(
    '[claude-shim] FATAL: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY set. ' +
    'Mint a token with `claude setup-token` and put it in .env.',
  );
  process.exit(1);
}

/**
 * Render a chat-style messages array into a single prompt string for `claude
 * -p`. The CLI takes one prompt, not a structured turn list, so we flatten the
 * transcript with explicit role markers. The system prompt is passed
 * separately via --system-prompt (it replaces Claude Code's coding-agent
 * framing entirely). History is capped by the caller (DF keeps ~20 turns).
 */
function renderPrompt(messages) {
  return messages
    .map((m) => {
      const who = m.role === 'assistant' ? 'Assistant' : 'Human';
      return `${who}: ${m.content}`;
    })
    .join('\n\n');
}

/**
 * Spawn `claude -p` and resolve with its text output. Rejects on non-zero
 * exit, spawn error, or timeout.
 *
 * SECURITY: this is a network-reachable endpoint with caller-supplied input,
 * so it must NOT be able to take actions. We deliberately do NOT pass
 * --dangerously-skip-permissions. In -p (non-interactive) mode there is no
 * one to answer a permission prompt, so Claude Code auto-denies tool use and
 * continues with text only — exactly the constrained "pure inference, no
 * tools" behaviour we want. A prompt-injected message therefore cannot make
 * the shim execute anything: the worst it can do is produce text.
 */
function runClaude({ system, prompt, model }) {
  return new Promise((resolve, reject) => {
    const args = [
      '-p', prompt,
      '--model', model || DEFAULT_MODEL,
      '--output-format', 'text',
      '--no-session-persistence',
    ];
    if (system) args.push('--system-prompt', system);

    // Empty cwd so there's no project CLAUDE.md / settings to auto-discover —
    // keeps the call closer to pure inference and trims startup work.
    const proc = spawn('claude', args, {
      cwd: '/tmp',
      env: process.env,
    });

    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`claude timed out after ${TIMEOUT_MS}ms`));
    }, TIMEOUT_MS);

    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });
    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    proc.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(`claude exited ${code}: ${stderr.trim() || '(no stderr)'}`));
    });
  });
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      // Defensive cap — a chat payload is small; anything huge is a bug or abuse.
      if (raw.length > 1_000_000) {
        reject(new Error('request body too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(raw));
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return sendJson(res, 200, { ok: true });
  }

  if (req.method === 'POST' && req.url === '/chat') {
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch (err) {
      return sendJson(res, 400, { error: `bad request body: ${err.message}` });
    }

    const { system, messages, model } = body || {};
    if (!Array.isArray(messages) || messages.length === 0) {
      return sendJson(res, 400, { error: 'messages must be a non-empty array' });
    }

    const started = Date.now();
    try {
      const text = await runClaude({ system, prompt: renderPrompt(messages), model });
      const ms = Date.now() - started;
      console.log(`[claude-shim] /chat ok in ${ms}ms (${text.length} chars)`);
      return sendJson(res, 200, { text });
    } catch (err) {
      const ms = Date.now() - started;
      console.error(`[claude-shim] /chat FAILED in ${ms}ms: ${err.message}`);
      return sendJson(res, 502, { error: err.message });
    }
  }

  return sendJson(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`[claude-shim] listening on :${PORT} (default model: ${DEFAULT_MODEL})`);
});
