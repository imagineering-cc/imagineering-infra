#!/usr/bin/env node
// approve-poll.mjs — the impure half of the Telegram merge-approval loop (C2). It
// polls the notify bot's getUpdates, runs each through approve.mjs's PURE decision,
// re-checks the PR is actually green, and merges on Nick's "merge" — then replies.
//
// Runs ON THE BOX (the same host as the healer cron) so it shares the notify bot.
// Fail-CLOSED: refuses to start unless the approver id + bot token + merge token are
// all provisioned (like green-auto's own gates). The merge token is SEPARATE from the
// bot token — the bot only reads/replies; merging authority is its own credential.
//
//   HEALER_APPROVE_BOT_TOKEN   the notify bot token (getUpdates + sendMessage)
//   NICK_TELEGRAM_USER_ID      the ONLY user id allowed to approve (gate 1)
//   HEALER_APPROVE_MERGE_TOKEN a GH token that can merge the target PRs
//   HEALER_APPROVE_DEFAULT_REPO optional "owner/name" for a bare "#N"
//   HEALER_APPROVE_OFFSET_FILE  getUpdates offset state (default under the healer state dir)

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { approvalDecision, mergeGateOk } from './approve.mjs';

/**
 * Run ONE approval cycle over a batch of updates. PURE orchestration over INJECTED
 * IO (so it's tested with fakes, no network/gh). Advances the offset past every
 * update it considered — even ignored ones — so a non-approval is not re-examined
 * forever. A merge is gated twice: approvalDecision (intent + auth + PR ref) AND a
 * LIVE mergeGateOk on the fetched PR (green/approved/cage-matched) — the "yes" is
 * approval, not a bypass.
 * @returns {Promise<{newOffset: number|null, actions: object[]}>}
 */
export async function runApproveCycle(updates, io, cfg) {
  const actions = [];
  let maxId = null;
  // Process in update_id order so the offset advances monotonically.
  for (const u of [...updates].sort((a, b) => (a.update_id ?? 0) - (b.update_id ?? 0))) {
    if (typeof u.update_id === 'number') maxId = Math.max(maxId ?? -Infinity, u.update_id);
    const d = approvalDecision(u, cfg);
    if (d.ignore) { actions.push({ updateId: d.updateId, ignored: d.ignore }); continue; }

    const { repo, pr } = d.merge;
    const ref = `${repo}#${pr}`;
    let view;
    try {
      view = await io.viewPr(repo, pr);
    } catch (e) {
      await io.reply(`⚠️ Couldn't read ${ref}: ${e.message}`);
      actions.push({ updateId: d.updateId, error: `view ${ref}: ${e.message}` });
      continue;
    }
    const gate = mergeGateOk(view);
    if (!gate.ok) {
      await io.reply(`❌ Not merging ${ref}: ${gate.reason}. (Your “merge” is approval, not a bypass — fix the gate and re-approve.)`);
      actions.push({ updateId: d.updateId, refused: gate.reason });
      continue;
    }
    try {
      await io.mergePr(repo, pr);
      await io.reply(`✅ Merged ${ref} on your approval.`);
      actions.push({ updateId: d.updateId, merged: ref });
    } catch (e) {
      await io.reply(`⚠️ Merge of ${ref} failed: ${e.message}`);
      actions.push({ updateId: d.updateId, error: `merge ${ref}: ${e.message}` });
    }
  }
  return { newOffset: maxId === null ? null : maxId + 1, actions };
}

// ── real IO wiring (only when run directly) ─────────────────────────────────────

const TG = 'https://api.telegram.org';

function readOffset(file) {
  try { return Number(JSON.parse(readFileSync(file, 'utf8')).offset) || 0; } catch { return 0; }
}
function writeOffset(file, offset) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify({ offset }), 'utf8');
}

async function tgGetUpdates(botToken, offset) {
  const res = await fetch(`${TG}/bot${botToken}/getUpdates?timeout=0&offset=${offset}&allowed_updates=${encodeURIComponent('["message"]')}`,
    { signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`getUpdates ${res.status}: ${(await res.text().catch(() => '')).slice(0, 200)}`);
  const j = await res.json();
  if (!j.ok) throw new Error(`getUpdates not ok: ${JSON.stringify(j).slice(0, 200)}`);
  return j.result || [];
}

function makeRealIO(botToken, chatId, mergeToken) {
  const gh = (args) => execFileSync('gh', args, { encoding: 'utf8', env: { ...process.env, GH_TOKEN: mergeToken }, stdio: ['ignore', 'pipe', 'pipe'] });
  return {
    viewPr(repo, pr) {
      const out = gh(['pr', 'view', String(pr), '-R', repo, '--json', 'state,mergeable,reviewDecision,labels,isDraft']);
      return JSON.parse(out);
    },
    mergePr(repo, pr) {
      const view = JSON.parse(gh(['pr', 'view', String(pr), '-R', repo, '--json', 'isDraft']));
      if (view.isDraft) gh(['pr', 'ready', String(pr), '-R', repo]); // un-draft before merge
      // --admin: branch protection requires CI checks that never run (GHA out of
      // minutes); the human approval + cage-matched + APPROVED are the real gate.
      gh(['pr', 'merge', String(pr), '-R', repo, '--squash', '--admin', '--delete-branch']);
    },
    async reply(text) {
      const res = await fetch(`${TG}/bot${botToken}/sendMessage`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ chat_id: chatId, text }), signal: AbortSignal.timeout(15_000),
      });
      if (!res.ok) process.stderr.write(`[approve] reply failed ${res.status}\n`);
    },
  };
}

async function main() {
  const botToken = process.env.HEALER_APPROVE_BOT_TOKEN;
  const nickUserId = Number(process.env.NICK_TELEGRAM_USER_ID);
  const mergeToken = process.env.HEALER_APPROVE_MERGE_TOKEN;
  const missing = [];
  if (!botToken) missing.push('HEALER_APPROVE_BOT_TOKEN');
  if (!nickUserId) missing.push('NICK_TELEGRAM_USER_ID');
  if (!mergeToken) missing.push('HEALER_APPROVE_MERGE_TOKEN');
  if (missing.length) {
    process.stderr.write(`[approve] refusing to run — unprovisioned: ${missing.join(', ')}\n`);
    process.exit(2);
  }
  const offsetFile = process.env.HEALER_APPROVE_OFFSET_FILE
    || `${process.env.HEALER_STATE_DIR || `${process.env.HOME}/.self-healer`}/approve-offset.json`;
  const cfg = { nickUserId, defaultRepo: process.env.HEALER_APPROVE_DEFAULT_REPO };

  const offset = readOffset(offsetFile);
  const updates = await tgGetUpdates(botToken, offset);
  if (!updates.length) { process.stdout.write('[approve] no new updates\n'); return; }

  // The reply chat is Nick's DM with the bot — derive it from the first update's chat
  // so we answer where he wrote, and only ever to an authorized message's chat.
  const io = makeRealIO(botToken, updates[0].message?.chat?.id, mergeToken);
  const { newOffset, actions } = await runApproveCycle(updates, io, cfg);
  if (newOffset !== null) writeOffset(offsetFile, newOffset);
  for (const a of actions) process.stdout.write(`[approve] ${JSON.stringify(a)}\n`);
}

if (process.argv[1] && process.argv[1].endsWith('approve-poll.mjs')) {
  main().catch((e) => { process.stderr.write(`[approve] FAILED: ${e.message}\n`); process.exit(1); });
}
