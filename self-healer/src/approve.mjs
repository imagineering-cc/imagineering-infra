// approve.mjs — the PURE decision core of the two-way Telegram merge-approval loop
// (Increment C2). Given a Telegram `getUpdates` message and the config, it decides:
// merge PR <repo#N>, or ignore (with a reason). The impure half — polling
// getUpdates, re-checking the PR is green, running `gh pr merge`, replying — lives
// in approve-poll.mjs. Keeping the decision pure means the THREE security gates the
// task mandates are unit-tested exhaustively without a network:
//
//   1. AUTHENTICATE THE APPROVER — the message must come from Nick's SPECIFIC
//      Telegram user id (from.id), not "anyone in the chat". A group the bot is in
//      could contain others; only Nick's id may approve.
//   2. UNAMBIGUOUS PR REFERENCE — the approval must name exactly which PR, either by
//      a full GitHub PR URL in the text, or by replying to the bot's PR ping (whose
//      text carries the URL). A bare "#N" without a repo is refused (green-auto spans
//      repos — an unqualified number is ambiguous, so fail closed).
//   3. The decision here is APPROVAL INTENT ONLY. Whether the PR is actually green
//      (mergeable + cage-matched + reviewed) is re-checked live by the poller before
//      it merges — the "yes" is human approval, never a gate bypass.
//
// Fail-closed everywhere: anything not unambiguously "Nick said merge THIS pr" → ignore.

/** A full GitHub PR URL → {repo: "owner/name", pr: N}, or null. Tightened to the
 * exact host + /pull/ shape so a lookalike (evil-github.com, /pulls/) can't match. */
export function parsePrUrl(text) {
  const m = /https:\/\/github\.com\/([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)\/pull\/(\d+)\b/.exec(String(text || ''));
  return m ? { repo: m[1], pr: Number(m[2]) } : null;
}

/** True iff `text` carries an explicit approval verb. Deliberately strict: the word
 * "merge" or "approve" must be present — a bare "yes"/"ok" is NOT enough (too easy to
 * fire by accident in a chat). Case-insensitive, allows a leading "yes ,". */
export function isApprovalText(text) {
  return /\b(merge|approve)\b/i.test(String(text || ''));
}

/**
 * Decide what to do with one Telegram update. PURE.
 * @param {object} update  a Telegram getUpdates result item
 * @param {{nickUserId: number, botUserId?: number, defaultRepo?: string}} cfg
 *   nickUserId — the ONLY user id allowed to approve (gate 1).
 *   botUserId — the notify bot's own user id; a reply-to only resolves the PR when
 *     the replied-to message is the BOT's ping (cage-match #122, Carnot MEDIUM — else
 *     an attacker in a group could plant a PR URL for Nick to reply to).
 *   defaultRepo — optional "owner/name" to resolve a bare "#N" against; omit to
 *     REQUIRE a URL/reply (the safe default for a multi-repo healer).
 * @returns {{merge: {repo: string, pr: number}, updateId: number, chatId: number}
 *          | {ignore: string, updateId: number, chatId: number}}
 */
export function approvalDecision(update, cfg = {}) {
  const updateId = update?.update_id;
  const msg = update?.message;
  if (!msg) return { ignore: 'no message in update', updateId, chatId: undefined };
  const chatId = msg.chat?.id; // the chat to answer in — carried per update (cage-match #122)

  // Gate 1: the approver MUST be Nick's specific user id.
  if (!cfg.nickUserId || msg.from?.id !== cfg.nickUserId) {
    return { ignore: `sender ${msg.from?.id ?? '?'} is not the authorized approver`, updateId, chatId };
  }

  // Must carry an explicit approval verb.
  if (!isApprovalText(msg.text)) return { ignore: 'no approval verb (need "merge"/"approve")', updateId, chatId };

  // Gate 2: resolve WHICH PR. Prefer a URL in the approval text; then the quoted
  // ping's text — but ONLY when the replied-to message is the BOT's own ping (so a
  // planted group message can't supply the target); then a bare #N against a
  // configured default repo.
  const fromText = parsePrUrl(msg.text);
  const replyIsBotPing = cfg.botUserId && msg.reply_to_message?.from?.id === cfg.botUserId;
  const fromReply = replyIsBotPing ? parsePrUrl(msg.reply_to_message?.text) : null;
  let target = fromText || fromReply;
  if (!target) {
    const bare = /(?:^|\s)#?(\d{1,7})\b/.exec(String(msg.text || ''));
    if (bare && cfg.defaultRepo) target = { repo: cfg.defaultRepo, pr: Number(bare[1]) };
  }
  if (!target) return { ignore: 'approval did not unambiguously reference a PR (need a PR URL, or a reply to the bot ping)', updateId, chatId };

  return { merge: target, updateId, chatId };
}

/**
 * The LIVE merge gate, evaluated by the poller against `gh pr view` JSON before it
 * merges — the "your yes is approval, not a bypass" rule. PURE so it's exhaustively
 * tested. Requires the PR to be OPEN, not conflicting, reviewer-APPROVED, AND carry
 * the `cage-matched` label (the signal that the adversarial review passed). A draft
 * is allowed (the poller marks it ready first) — draftness is not a block, an
 * un-reviewed or un-cage-matched PR is.
 * @param {{state?: string, mergeable?: string, reviewDecision?: string, labels?: Array<{name?:string}|string>, statusCheckRollup?: Array<object>, reviews?: Array<{state?: string, author?: {login?: string}}>}} pr
 * @param {{trustedReviewers?: string[]}} [cfg]  when non-empty, an APPROVE must come
 *   from one of these logins (provenance pin, cage-match #122). Unset → the named
 *   tradeoff: reviewDecision===APPROVED already excludes the PR author, so the
 *   green-auto bot can't self-approve; Nick's explicit Telegram "merge" is gate 1.
 * @returns {{ok: true} | {ok: false, reason: string}}
 */
export function mergeGateOk(pr, cfg = {}) {
  if (!pr || pr.state !== 'OPEN') return { ok: false, reason: `PR is not open (state=${pr?.state ?? '?'})` };
  // WHITELIST, not blacklist: only an explicitly MERGEABLE PR. GitHub's UNKNOWN /
  // null is "not yet computed" and must NOT slip through to an --admin merge
  // (cage-match #122, both adversaries).
  if (pr.mergeable !== 'MERGEABLE') return { ok: false, reason: `PR is not mergeable (mergeable=${pr.mergeable || 'unknown'})` };
  if (pr.reviewDecision !== 'APPROVED') return { ok: false, reason: `PR is not approved (reviewDecision=${pr.reviewDecision || 'none'})` };
  const labels = (pr.labels || []).map((l) => (typeof l === 'string' ? l : l?.name));
  if (!labels.includes('cage-matched')) return { ok: false, reason: 'PR is not cage-matched (missing the cage-matched label)' };
  const badCheck = failingCheck(pr.statusCheckRollup);
  if (badCheck) return { ok: false, reason: `a status check is not passing: ${badCheck}` };
  // Provenance pin (opt-in): when a trusted-reviewer allowlist is configured, require
  // an APPROVE from one of those logins, so an APPROVED PR can't ride a review from an
  // unexpected identity into an --admin merge (cage-match #122, Carnot HIGH).
  const trusted = cfg.trustedReviewers;
  if (trusted && trusted.length) {
    const byTrusted = (pr.reviews || []).some((r) => r?.state === 'APPROVED' && trusted.includes(r?.author?.login));
    if (!byTrusted) return { ok: false, reason: `no APPROVE from a trusted reviewer (${trusted.join(', ')})` };
  }
  return { ok: true };
}

/** The name of the first status check that is NOT terminally passing (failing OR
 * still running), or null if every check passes. An EMPTY/absent rollup → null: with
 * GHA permanently out of minutes there are no checks, and `--admin` merges past the
 * *absent required* check — but a check that EXISTS and is failing/pending blocks the
 * merge here, so --admin never bypasses a real signal (cage-match #122, Carnot HIGH).
 * Pass states: a CheckRun conclusion of SUCCESS/NEUTRAL/SKIPPED, or a StatusContext
 * state of SUCCESS. Everything else (FAILURE/ERROR/PENDING/IN_PROGRESS/…) blocks. */
export function failingCheck(rollup) {
  for (const c of rollup || []) {
    const concl = c?.conclusion; // CheckRun
    const state = c?.state; // StatusContext
    const passes = ['SUCCESS', 'NEUTRAL', 'SKIPPED'].includes(concl) || state === 'SUCCESS';
    if (!passes) return c?.name || c?.context || concl || state || 'unknown check';
  }
  return null;
}
