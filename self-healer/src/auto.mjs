// auto.mjs — green-auto: the FOURTH stage of the autonomy roadmap, and the first
// that runs the "monster" — a codegen agent that writes a fix from a log
// diagnosis. It is built, wired, and SHIPPED OFF. It does not act until an
// operator provisions every gate below.
//
// "Build the cage before you spawn the monster." The cage already exists
// (cage/run-cage.mjs → cage/cage.mjs → egress-proxy, proven by
// cage/escape-probe.sh). This orchestrator's only job is to ROUTE each eligible
// finding through that proven cage — never to bypass it — and to enforce the one
// boundary the OS cage can't: that the agent's GitHub authority is bounded to the
// single target repo.
//
// FIVE INDEPENDENT GATES, each fail-CLOSED, all required before a single spawn:
//   1. HEALER_GREEN_AUTO=1            — the feature is OFF by default.
//   2. on-box (isOnBox())            — the cage is a box-local Docker primitive;
//      a remote dev run has no daemon to cage into, so refuse rather than pretend.
//   3. bounded authority             — a DEDICATED repo-scoped token
//      (HEALER_GREEN_AUTO_TOKEN) that is DISTINCT from the healer's broad host
//      token. This is the ENFORCED form of cage/README.md's "Credential scope"
//      contract ("the token handed to the agent MUST be scoped to the one target
//      repo"): a prose gate, upgraded to a runtime valve. We refuse to hand an
//      injectable agent the keys to the whole org.
//   4. cage substrate provisioned    — image / internal network / egress proxy
//      all named in env; a missing one means the escape probe hasn't been wired,
//      so there is no proven cage to spawn into.
//   5. an agent command              — HEALER_CAGE_AGENT_CMD, the codegen
//      entrypoint. Unset by default; the "monster" is operator-installed, never
//      hardcoded here.
//
// The per-finding loop reuses green-draft's machinery verbatim: the SAME
// actionable-finding filter, the SAME fingerprint, and the SAME single-box
// owner-fenced lock (acquireDraftLock/releaseDraftLock) — so two CONCURRENT healer
// PROCESSES on one box never act on the same finding twice, and the two stages
// agree on "what is actionable" by construction. NOTE: the lock is concurrent-
// process exclusion, NOT draft-vs-auto mutual exclusion: healer.mjs runs draft to
// completion THEN auto, each acquiring+releasing per finding, so with BOTH flags
// on a single run files an issue AND runs the caged agent for the same finding
// (by design — the issue documents what the agent is fixing).
//
// What this orchestrator deliberately does NOT do: open the PR, merge, or deploy.
// Those happen (eventually) INSIDE/after the caged agent, bounded by the
// repo-scoped token and the cage-match on the resulting PR — not by this module.
// The orchestrator's outcome reports the CAGE RUN, never a merged fix.

import { spawn } from 'node:child_process';
import { rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { actionableFindings, findingFingerprint, acquireDraftLock, releaseDraftLock } from './draft.mjs';
import { repoForContainer } from './repos.mjs';
import { runOnHostScript, isOnBox } from './host.mjs';
import { scrubSecrets, esc } from './notify.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
/** The one spawn door. green-auto and the escape probe share it so the
 * confinement flags green-auto runs are byte-identical to the ones the probe
 * proved (run-cage.mjs's "no drift" guarantee). */
export const RUN_CAGE_PATH = join(HERE, '..', 'cage', 'run-cage.mjs');

/** The closed set of per-finding outcome actions. Frozen so the values are a
 * compile-checkable closed set (the same discipline tiers.mjs uses), not ad-hoc
 * string literals scattered through the loop (cage-match #114, Carnot). */
export const AUTO_ACTIONS = Object.freeze({
  REFUSED: 'refused', // a global gate (on-box / authority / substrate) was unmet — spawned nothing
  SKIPPED: 'skipped', // this finding has no known source repo
  DEDUPED: 'deduped', // a concurrent run owns the finding's lock
  CAGED: 'caged', // the cage ran and exited clean (a draft PR was opened)
  NO_FIX: 'no_fix', // the agent ran but made no change (entrypoint EXIT.NO_DIFF) — benign, NOT a failure
  FAILED: 'failed', // clone/spawn error, lock error, or other non-zero cage exit
});

/** The agent entrypoint's EXIT.NO_DIFF — a non-zero exit that is nonetheless a
 * BENIGN "the agent confidently made no change" (cage-match #121, Carnot). Mapping
 * it to FAILED would mislabel a safe outcome as failure telemetry and re-attempt the
 * same finding daily. The entrypoint is operator-installed so we can't import its
 * EXIT object; this magic number IS the cross-process contract (agent-entrypoint.mjs). */
const AGENT_EXIT_NO_DIFF = 3;

/** PURE: map a finished cage's exit code to a per-finding outcome. Three classes:
 * 0 = a draft PR was opened (CAGED); NO_DIFF = the agent confidently changed nothing
 * (NO_FIX — benign, must NOT read as failure telemetry, cage-match #121, Carnot);
 * anything else = FAILED. Exported so the exit→action contract is asserted in CI
 * without a Docker daemon. @returns {{action: string, detail: string}} */
export function actionForExit(exitCode, fp) {
  const short = String(fp).slice(0, 12);
  if (exitCode === 0) return { action: AUTO_ACTIONS.CAGED, detail: `cage exited clean (fp ${short}…)` };
  if (exitCode === AGENT_EXIT_NO_DIFF) return { action: AUTO_ACTIONS.NO_FIX, detail: `agent made no change (fp ${short}…)` };
  return { action: AUTO_ACTIONS.FAILED, detail: `cage exited ${exitCode}` };
}

/** PURE: the PR number from a GitHub PR URL, or null. */
export function prNumberFromUrl(url) {
  const m = /^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/(\d+)/.exec(String(url || ''));
  return m ? Number(m[1]) : null;
}

/** PURE: the Telegram lifecycle message for one green-auto outcome, or null when
 * the outcome doesn't warrant pinging Nick (deduped / skipped / no-fix / refused are
 * quiet — only an actual PR or a stumble is news). The CAGED ping carries the PR link
 * + the finding signature + the exact "merge #N" reply that the approve listener
 * (Increment C2) accepts; the FAILED ping flags that the monster stumbled. HTML. */
export function formatAutoOutcome(o) {
  // The container/signature/detail are log-derived = attacker-influenceable, and this
  // renders under Telegram HTML parse_mode → escape every dynamic field (cage-match
  // #122, Carnot). The PR URL is validated GitHub shape, but escape it too for safety.
  if (o.action === AUTO_ACTIONS.CAGED) {
    const n = prNumberFromUrl(o.prUrl);
    const mergeHint = n ? `reply <b>“merge #${n}”</b>` : 'reply <b>“merge #&lt;PR&gt;”</b>';
    return `🤖 <b>green-auto opened a draft PR</b>\n${esc(o.prUrl || '(no url captured)')}\n<code>${esc(o.container)}</code>: ${esc(o.signature || o.detail || '')}\n\nReview, then ${mergeHint} to merge (it must still be mergeable + cage-matched + approved — your “merge” is approval, not a bypass).`;
  }
  if (o.action === AUTO_ACTIONS.FAILED) {
    return `⚠️ <b>green-auto stumbled</b> on <code>${esc(o.container)}</code>: ${esc(o.detail || 'unknown error')} — no PR opened. Check the healer logs.`;
  }
  return null; // deduped / skipped / no-fix / refused → quiet
}

/** EVERY broad host token currently in the env (the healer's own GH-API creds,
 * any of the three names draft.mjs accepts). The bound green-auto token must
 * equal NONE of them — checking only the first (a `A || B || C` short-circuit)
 * was a real hole: with HEALER_GH_TOKEN=a AND GITHUB_TOKEN=b both set, a bound
 * token of `b` would slip past a first-only check and get forwarded into the
 * cage (cage-match #114, Carnot). A closed-set check must inspect the WHOLE set. */
function broadHostTokens(env) {
  return [env.HEALER_GH_TOKEN, env.GITHUB_TOKEN, env.GH_TOKEN].filter(Boolean);
}

/**
 * Gate 3 — the bounded-authority valve. Returns the repo-scoped token to hand
 * the cage, or a refusal reason. PURE (env in, decision out) so it's asserted in
 * CI without spawning anything.
 *
 * ENFORCED: HEALER_GREEN_AUTO_TOKEN must be set AND distinct from the broad host
 * token. NAMED RESIDUAL (cage/README.md "Credential scope"): this structurally
 * guarantees a *dedicated* token, not the healer's org-wide one — it does NOT by
 * itself prove the token is fine-grained-scoped to exactly one repo. That
 * narrowing is the operator's provisioning responsibility (a fine-grained PAT /
 * App installation token for the single target repo); a control-repo reachability
 * probe to verify the bound online is tracked as follow-up. The hard gate here is
 * "never the broad token"; the fine-grain is disciplined-not-enforced and stated.
 * @returns {{ok: true, token: string} | {ok: false, reason: string}}
 */
export function boundedAuthority(env = process.env) {
  const bound = env.HEALER_GREEN_AUTO_TOKEN;
  if (!bound) {
    return { ok: false, reason: 'no repo-scoped token: set HEALER_GREEN_AUTO_TOKEN to a token scoped to ONLY the target repo' };
  }
  if (broadHostTokens(env).includes(bound)) {
    return { ok: false, reason: 'HEALER_GREEN_AUTO_TOKEN must be DISTINCT from EVERY broad host token (HEALER_GH_TOKEN / GITHUB_TOKEN / GH_TOKEN) — a repo-scoped token, not the healer’s own org-wide one' };
  }
  return { ok: true, token: bound };
}

/**
 * Gate 4+5 — the cage substrate + agent command, read from env. A missing value
 * is a refusal (fail closed): without the proven images/network/proxy there is no
 * cage to spawn into, and without an agent command there is nothing to run.
 * PURE. @returns {{ok: true, image, network, proxyUrl, agentCmd, claudeToken} | {ok: false, reason}}
 */
export function cageSubstrate(env = process.env) {
  const image = env.HEALER_CAGE_IMAGE;
  const network = env.HEALER_CAGE_NETWORK;
  const proxyUrl = env.HEALER_CAGE_PROXY_URL;
  const agentCmd = env.HEALER_CAGE_AGENT_CMD; // the codegen "monster"; operator-installed
  // The inference credential the caged `claude -p` agent authenticates with. Unlike
  // the GH token (gate 3) it is NOT bounded-distinct — it is the shared Max-plan
  // OAuth token by nature, so there's nothing to make it distinct FROM; the gate
  // here is only "present, fail-closed". It is part of the substrate because the
  // agent literally cannot run inference without it. Forwarded into the cage
  // KEY-ONLY (run-cage.mjs CAGE_CLAUDE_TOKEN → CLAUDE_CODE_OAUTH_TOKEN), so it
  // never lands in argv / host `ps`.
  const claudeToken = env.HEALER_CAGE_CLAUDE_TOKEN;
  const missing = [];
  if (!image) missing.push('HEALER_CAGE_IMAGE');
  if (!network) missing.push('HEALER_CAGE_NETWORK');
  if (!proxyUrl) missing.push('HEALER_CAGE_PROXY_URL');
  if (!agentCmd) missing.push('HEALER_CAGE_AGENT_CMD');
  if (!claudeToken) missing.push('HEALER_CAGE_CLAUDE_TOKEN');
  if (missing.length) return { ok: false, reason: `cage substrate not provisioned: ${missing.join(', ')}` };
  return { ok: true, image, network, proxyUrl, agentCmd, claudeToken };
}

/** Scrub secrets out of (attacker-influenceable) log-derived text and length-cap
 * it before it becomes the caged agent's task context. The agent is caged
 * regardless, but a host secret must not ride into the container env even so. */
function safeContext(x, max) {
  const s = scrubSecrets(String(x ?? ''));
  return s.length > max ? s.slice(0, max) + ' …(truncated)' : s;
}

/**
 * PURE: build the `node run-cage.mjs -- <agentCmd>` spawn for one finding —
 * argv + the env that run-cage.mjs forwards INTO the cage. Exported so a test can
 * assert, without Docker, that (a) the bounded token rides in as CAGE_GH_TOKEN,
 * (b) the broad host token NEVER does, (c) the finding context is scrubbed, and
 * (d) the spawn routes through run-cage.mjs (not a raw `docker run`).
 *
 * run-cage.mjs forwards a BOUNDED allowlist into the container: CAGE_GH_TOKEN →
 * GH_TOKEN/GITHUB_TOKEN, CAGE_CLAUDE_TOKEN → CLAUDE_CODE_OAUTH_TOKEN, every
 * CAGE_AGENT_* var, and HOME=/work (the writable-HOME residual cage/README.md
 * assigns to the orchestrator). Both secrets ride key-only. Nothing else crosses.
 */
export function buildRunCageSpawn({ finding, repo, workdirHost, token, substrate, runCagePath = RUN_CAGE_PATH }) {
  const fp = findingFingerprint(finding);
  const env = {
    CAGE_IMAGE: substrate.image,
    CAGE_NETWORK: substrate.network,
    CAGE_WORKDIR: workdirHost,
    CAGE_PROXY_URL: substrate.proxyUrl,
    CAGE_NAME: `healer-green-auto-${fp.slice(0, 12)}`,
    // The bounded repo-scoped token. run-cage.mjs maps this to GH_TOKEN/GITHUB_TOKEN
    // INSIDE the cage; the broad host token is never referenced here.
    CAGE_GH_TOKEN: token,
    // The inference credential (shared Max-plan OAuth). run-cage.mjs maps this to
    // CLAUDE_CODE_OAUTH_TOKEN inside the cage, key-only — so the caged `claude -p`
    // can reach api.anthropic.com through the egress proxy. Provisioned, not bounded
    // (it can't be repo-scoped); the cage + human merge-gate bound its blast radius.
    CAGE_CLAUDE_TOKEN: substrate.claudeToken,
    // Finding context for the agent, scrubbed + capped (it is log-derived =
    // attacker-influenceable). run-cage forwards CAGE_AGENT_* into the cage.
    CAGE_AGENT_REPO: repo,
    CAGE_AGENT_CONTAINER: safeContext(finding.container, 60),
    CAGE_AGENT_SIGNATURE: safeContext(finding.signature, 150),
    CAGE_AGENT_DIAGNOSIS: safeContext(finding.diagnosis, 1000),
    CAGE_AGENT_PROPOSED_ACTION: safeContext(finding.proposedAction, 500),
    CAGE_AGENT_FP: fp,
  };
  // agentCmd is operator-controlled (trusted env); the agent reads its task from
  // the CAGE_AGENT_* env, so the command itself carries no untrusted data. NOTE:
  // this whitespace split is quote-HOSTILE — it can't express an arg containing a
  // space (`-p "fix the bug"`). That's fine because the task rides in env, not
  // argv; if a future agent needs spaced args, switch to a JSON-argv env var
  // rather than teaching this a shell-quoting grammar (cage-match #114).
  const agentArgv = substrate.agentCmd.split(/\s+/).filter(Boolean);
  const argv = [runCagePath, '--', ...agentArgv];
  return { bin: process.execPath, argv, env, name: env.CAGE_NAME };
}

// Fixed host script: clone the target repo into a FRESH throwaway dir and make it
// writable by the cage uid (the host user is 1002, the cage forces 1000). The
// non-secret values arrive as base64 positionals ($1 repo, $2 uid:gid) decoded
// on-box — the injection-safe host primitive (see host.mjs buildHostScriptArgv).
//
// The TOKEN arrives on STDIN, never as a positional (cage-match #114, Maxwell F1
// + Carnot HIGH): base64 is reversible, so a positional token would sit decodable
// in the host process argv (`ps` / /proc/<pid>/cmdline, world-readable by default)
// for the clone's duration — the exact `token not in argv` property the cage-spawn
// step (run-cage.mjs key-only `-e`) is built to hold. stdin is a pipe: invisible
// to the process table, and ssh forwards it on the remote path. git reads it via a
// transient GIT_ASKPASS helper, then it's removed. Only the workdir path is printed
// to stdout; all git chatter goes to stderr.
export const CLONE_SCRIPT = [
  'set -euo pipefail',
  'repo=$(printf %s "$1" | base64 -d)',
  'ug=$(printf %s "$2" | base64 -d)',
  // The repo-scoped token, read from stdin (see header). $(cat) consumes the whole
  // pipe and strips a trailing newline, so a sloppily-sourced token is sanitized.
  'tok=$(cat)',
  // Clone under a HEALER-OWNED, non-sticky workroot — NOT bare /tmp, which is
  // sticky. In a sticky dir only the file's owner may unlink it, so if the clone
  // is chowned to the cage uid (1000) the healer (1002) could no longer remove it
  // → a systematic leak of shallow clones (cage-match #114, Carnot HIGH). In a
  // non-sticky, healer-owned parent, unlink permission comes from WRITE on the
  // parent dir, not file ownership, so cleanupWorkdir always succeeds regardless
  // of the chown. mkdir -p is idempotent; the healer owns the workroot it creates.
  'workroot="${HEALER_GREEN_AUTO_WORKROOT:-/tmp/self-healer-green-auto}"',
  'mkdir -p "$workroot"',
  'dir=$(mktemp -d "$workroot/clone.XXXXXX")',
  'askpass=$(mktemp "$workroot/askpass.XXXXXX")',
  "printf '#!/bin/sh\\nprintf %%s \"$HEALER_CLONE_TOKEN\"\\n' > \"$askpass\"",
  'chmod 0700 "$askpass"',
  'if ! HEALER_CLONE_TOKEN="$tok" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \\',
  '     git clone --depth 1 "https://x-access-token@github.com/$repo" "$dir" 1>&2; then',
  '  rm -f "$askpass"; rm -rf "$dir"; exit 4',
  'fi',
  'rm -f "$askpass"',
  // Make the clone writable by the cage uid. chown needs privilege; fall back to
  // a world-writable throwaway (the dir is ephemeral and host-isolated) so the
  // cage uid can write even where the deploy user can't chown. Either way the
  // non-sticky workroot above keeps the dir removable by the healer.
  'chown -R "$ug" "$dir" 2>/dev/null || chmod -R 0777 "$dir"',
  'printf %s "$dir"',
].join('\n');

/** Cage uid:gid the fresh clone must be writable by (matches cage.mjs CAGE_UID_GID). */
const CAGE_UID_GID = '1000:1000';

/** Prepare a fresh, cage-writable clone of `repo`; returns its host path. Throws
 * on failure so the caller fails closed (no spawn against a missing workdir). The
 * clone script itself cleans up after a FAILED clone (rm dir + askpass); this
 * throw path leaves nothing behind. A SUCCESSFUL clone's dir is the caller's to
 * remove — see cleanupWorkdir. */
async function prepareWorkdir(repo, token) {
  // Token via stdin (NOT a positional) so it never lands in host argv/`ps`; repo +
  // uid:gid are non-secret and ride as base64 positionals (cage-match #114).
  const { stdout, stderr, code } = await runOnHostScript(CLONE_SCRIPT, [repo, CAGE_UID_GID], { stdin: token, timeoutMs: 120_000 });
  const dir = stdout.trim();
  if (code !== 0 || !dir) {
    throw new Error(`workdir clone failed (code ${code}): ${stderr.trim().slice(0, 200)}`);
  }
  return dir;
}

/** Best-effort removal of a finished cage's host clone dir, so the workroot
 * doesn't accumulate one clone per run (cage-match #114, Maxwell F2 + Carnot).
 * The clone lives under a non-sticky, healer-owned workroot (see CLONE_SCRIPT),
 * so even when chown hands the dir to the cage uid (1000) the healer (1002) can
 * still unlink it — unlink permission comes from WRITE on the non-sticky parent,
 * not file ownership. The try/catch stays as a belt-and-braces backstop. */
function cleanupWorkdir(dir) {
  if (!dir) return;
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort; see note */ }
}

/** Spawn `node run-cage.mjs -- <agentCmd>` for one finding; resolve {exitCode,
 * stdout}. stderr is INHERITED (the agent's log() chatter streams to the healer's
 * logs live); stdout is CAPTURED because the agent entrypoint prints ONLY the PR
 * URL there — so the orchestrator can ping Nick with the link (Increment C). */
function spawnCage({ bin, argv, env }) {
  return new Promise((resolve, reject) => {
    const proc = spawn(bin, argv, { stdio: ['ignore', 'pipe', 'inherit'], env: { ...process.env, ...env } });
    let stdout = '';
    proc.stdout.on('data', (d) => { stdout += d; });
    proc.on('error', reject);
    proc.on('exit', (code, signal) => resolve({ exitCode: signal ? `signal:${signal}` : (code ?? -1), stdout }));
  });
}

/** The PR URL the agent printed on stdout (last non-blank line; the entrypoint
 * writes ONLY the URL there). Returns '' if absent. A light guard that it looks
 * like a GitHub PR URL so a stray stdout line doesn't masquerade as one. */
export function prUrlFromStdout(stdout) {
  const lines = String(stdout || '').split('\n').map((l) => l.trim()).filter(Boolean);
  const last = lines[lines.length - 1] || '';
  // Extract JUST the URL (anchored at start), so a trailing "…/pull/42 DO-NOT-MERGE"
  // can't ride along as part of the "url" (cage-match #122, Kelvin).
  const m = /^(https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/\d+)\b/.exec(last);
  return m ? m[1] : '';
}

/**
 * For every confident-green, actionable finding, run a CAGED remediation agent
 * routed through run-cage.mjs. NO-OP (empty list) when the feature flag is off;
 * a single refusal outcome when any global gate (on-box / bounded-authority /
 * substrate) is unmet — spawning NOTHING. Returns a per-finding outcome list.
 *
 * Mirrors draft.mjs's draftIfActionable: same filter, same fingerprint, same
 * owner-fenced lock, same fail-closed posture, same {container, action, detail}
 * outcome shape — green-auto is green-draft with the cage swapped in for the
 * GitHub-issue POST.
 *
 * @param {{findings: object[]}} verdict
 * @param {object} [env]
 * @returns {Promise<Array<{container: string, action: string, detail?: string, workdir?: string, exitCode?: number|string}>>}
 */
export async function autoFixIfActionable(verdict, env = process.env) {
  // Gate 1: OFF by default.
  if (env.HEALER_GREEN_AUTO !== '1') return [];

  // Gate 2: the cage is a box-local Docker primitive — refuse remote runs.
  // Evaluate against the SAME `env` as the other gates (cage-match #114, Carnot).
  if (!isOnBox(env)) {
    return [{ container: '*', action: AUTO_ACTIONS.REFUSED, detail: 'green-auto runs on-box only (the cage is a host-local Docker primitive); unset HEALER_HOST to run on the box' }];
  }

  // Gate 3: bounded authority — a dedicated repo-scoped token, never the broad one.
  const auth = boundedAuthority(env);
  if (!auth.ok) return [{ container: '*', action: AUTO_ACTIONS.REFUSED, detail: auth.reason }];

  // Gate 4+5: the proven cage substrate + the agent command.
  const sub = cageSubstrate(env);
  if (!sub.ok) return [{ container: '*', action: AUTO_ACTIONS.REFUSED, detail: sub.reason }];

  const outcomes = [];
  for (const f of actionableFindings(verdict)) {
    const repo = repoForContainer(f.container);
    if (!repo) {
      outcomes.push({ container: f.container, action: AUTO_ACTIONS.SKIPPED, detail: 'no known source repo' });
      continue;
    }
    const fp = findingFingerprint(f);

    // Same single-box owner-fenced lock as green-draft: a concurrent draft or
    // auto run on this box can't act on the same finding twice. null = another
    // live run owns it (skip); an UNEXPECTED lock error throws → fail closed.
    let lockTok = null;
    try {
      lockTok = acquireDraftLock(fp);
    } catch (err) {
      outcomes.push({ container: f.container, action: AUTO_ACTIONS.FAILED, detail: `lock error (fail-closed): ${err.message}` });
      continue;
    }
    if (!lockTok) {
      outcomes.push({ container: f.container, action: AUTO_ACTIONS.DEDUPED, detail: `concurrent run owns lock (fp ${fp.slice(0, 12)}…)` });
      continue;
    }

    let workdirHost = null;
    try {
      workdirHost = await prepareWorkdir(repo, auth.token);
      const spawnSpec = buildRunCageSpawn({ finding: f, repo, workdirHost, token: auth.token, substrate: sub });
      const { exitCode, stdout } = await spawnCage(spawnSpec);
      const { action, detail } = actionForExit(exitCode, fp);
      const prUrl = action === AUTO_ACTIONS.CAGED ? prUrlFromStdout(stdout) : '';
      outcomes.push({
        container: f.container,
        action,
        detail,
        signature: f.signature, // for the lifecycle Telegram ping (Increment C)
        prUrl,
        workdir: workdirHost,
        exitCode,
      });
    } catch (err) {
      // A clone failure or spawn error lands here → we did NOT run the agent.
      outcomes.push({ container: f.container, action: AUTO_ACTIONS.FAILED, detail: err.message });
    } finally {
      cleanupWorkdir(workdirHost); // the cage is --rm; the host clone is not
      releaseDraftLock(fp, lockTok);
    }
  }
  return outcomes;
}
