// approve.test.mjs — the merge-approval loop's security gates (Increment C2).
//
// This decides whether a Telegram message MERGES a PR, so the gates get exhaustive,
// adversarial coverage: only Nick's id may approve; the PR must be unambiguously
// referenced; a non-green PR is refused even on a valid approval; the offset always
// advances so a message isn't acted on twice. Every "merge" path is also re-gated by
// a LIVE mergeGateOk in runApproveCycle — proven here with a fake that returns a
// non-green PR and asserting NO merge fires.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parsePrUrl, isApprovalText, approvalDecision, mergeGateOk, failingCheck } from '../src/approve.mjs';
import { runApproveCycle } from '../src/approve-poll.mjs';

const NICK = 12345;
const BOT = 555; // the notify bot's own user id
const CFG = { nickUserId: NICK, botUserId: BOT };
const ping = (n) => `🤖 green-auto opened a draft PR\nhttps://github.com/imagineering-cc/x/pull/${n}\nfoo`;
const botPing = (n) => ({ text: ping(n), from: { id: BOT } }); // a reply-to that IS the bot's ping
const msg = (over = {}) => ({ update_id: 1, message: { from: { id: NICK }, text: 'merge', chat: { id: 999 }, ...over } });
const GREEN = { state: 'OPEN', mergeable: 'MERGEABLE', reviewDecision: 'APPROVED', labels: [{ name: 'cage-matched' }], statusCheckRollup: [] };

// ── parsing ──────────────────────────────────────────────────────────────────

test('parsePrUrl: exact github PR URL only', () => {
  assert.deepEqual(parsePrUrl('see https://github.com/o/r/pull/42 now'), { repo: 'o/r', pr: 42 });
  assert.equal(parsePrUrl('https://evil-github.com/o/r/pull/42'), null); // lookalike host
  assert.equal(parsePrUrl('https://github.com/o/r/pulls/42'), null); // wrong path
  assert.equal(parsePrUrl('https://github.com/o/r/issues/42'), null);
});

test('isApprovalText: requires the word merge/approve, not a bare yes', () => {
  assert.ok(isApprovalText('merge #42'));
  assert.ok(isApprovalText('yes, merge it'));
  assert.ok(isApprovalText('APPROVE'));
  assert.equal(isApprovalText('yes'), false); // too weak to fire a merge
  assert.equal(isApprovalText('ok'), false);
  assert.equal(isApprovalText(''), false);
});

// ── gate 1: authentication ─────────────────────────────────────────────────────

test('approvalDecision: a message from anyone but Nick is IGNORED', () => {
  const d = approvalDecision(msg({ from: { id: 99999 }, text: `merge ${ping(42)}` }), CFG);
  assert.ok(d.ignore);
  assert.match(d.ignore, /not the authorized approver/);
});

test('approvalDecision: nickUserId unset → never authorizes (fail closed)', () => {
  const d = approvalDecision(msg({ text: 'merge https://github.com/o/r/pull/1' }), {});
  assert.ok(d.ignore);
});

// ── gate 2: unambiguous PR reference ───────────────────────────────────────────

test('approvalDecision: URL in the approval text → merge that exact repo+pr (+ carries chatId)', () => {
  const d = approvalDecision(msg({ text: 'merge https://github.com/o/r/pull/7' }), CFG);
  assert.deepEqual(d.merge, { repo: 'o/r', pr: 7 });
  assert.equal(d.chatId, 999); // the chat to answer in, carried per update
});

test('approvalDecision: reply to the BOT ping → PR resolved from the quoted text', () => {
  const d = approvalDecision(msg({ text: 'merge', reply_to_message: botPing(55) }), CFG);
  assert.deepEqual(d.merge, { repo: 'imagineering-cc/x', pr: 55 });
});

test('approvalDecision: reply to a NON-bot message is NOT trusted (planted-URL defense, #122)', () => {
  // An attacker in a group plants a message with a PR URL; Nick replies "merge".
  // The replied-to message is not from the bot → its URL must NOT resolve the target.
  const d = approvalDecision(msg({ text: 'merge', reply_to_message: { text: ping(999), from: { id: 99999 } } }), CFG);
  assert.ok(d.ignore);
  assert.match(d.ignore, /unambiguously reference/);
});

test('approvalDecision: reply-to ignored when botUserId is unset (fail closed)', () => {
  const d = approvalDecision(msg({ text: 'merge', reply_to_message: botPing(55) }), { nickUserId: NICK });
  assert.ok(d.ignore); // no botUserId → can't trust any reply-to
});

test('approvalDecision: bare "#N" with NO repo context is refused (multi-repo ambiguity)', () => {
  const d = approvalDecision(msg({ text: 'merge #42' }), CFG);
  assert.ok(d.ignore);
  assert.match(d.ignore, /unambiguously reference/);
});

test('approvalDecision: bare "#N" resolves ONLY against a configured defaultRepo', () => {
  const d = approvalDecision(msg({ text: 'merge #42' }), { ...CFG, defaultRepo: 'o/r' });
  assert.deepEqual(d.merge, { repo: 'o/r', pr: 42 });
});

test('approvalDecision: approval verb but no PR anywhere → ignore', () => {
  assert.ok(approvalDecision(msg({ text: 'merge it please' }), CFG).ignore);
});

test('approvalDecision: a non-approval message from Nick → ignore (not every message merges)', () => {
  assert.ok(approvalDecision(msg({ text: 'thanks!' }), CFG).ignore);
});

// ── gate 3: the live green gate ─────────────────────────────────────────────────

test('mergeGateOk: passes only an OPEN, MERGEABLE, APPROVED, cage-matched, checks-green PR', () => {
  assert.deepEqual(mergeGateOk(GREEN), { ok: true });
});

test('mergeGateOk: a not-yet-computed mergeable (UNKNOWN/null) is REFUSED — whitelist, not blacklist (#122)', () => {
  assert.match(mergeGateOk({ ...GREEN, mergeable: 'UNKNOWN' }).reason, /not mergeable/);
  assert.match(mergeGateOk({ ...GREEN, mergeable: undefined }).reason, /not mergeable/);
  assert.match(mergeGateOk({ ...GREEN, mergeable: 'CONFLICTING' }).reason, /not mergeable/);
});

test('mergeGateOk: refuses each missing condition', () => {
  assert.match(mergeGateOk({ state: 'MERGED', labels: [] }).reason, /not open/);
  assert.match(mergeGateOk({ ...GREEN, reviewDecision: 'REVIEW_REQUIRED' }).reason, /not approved/);
  assert.match(mergeGateOk({ ...GREEN, labels: [] }).reason, /not cage-matched/);
});

test('mergeGateOk: a FAILING or still-running check blocks the merge (no --admin bypass of a real signal)', () => {
  assert.match(mergeGateOk({ ...GREEN, statusCheckRollup: [{ name: 'ci', conclusion: 'FAILURE' }] }).reason, /not passing/);
  assert.match(mergeGateOk({ ...GREEN, statusCheckRollup: [{ name: 'ci', status: 'IN_PROGRESS', conclusion: null }] }).reason, /not passing/);
});

test('mergeGateOk: trustedReviewers (opt-in) requires an APPROVE from a trusted login', () => {
  const withReviews = { ...GREEN, reviews: [{ state: 'APPROVED', author: { login: 'nick' } }] };
  // unset → named tradeoff, passes on reviewDecision alone
  assert.deepEqual(mergeGateOk(withReviews), { ok: true });
  // configured + a trusted approver present → ok
  assert.deepEqual(mergeGateOk(withReviews, { trustedReviewers: ['nick', 'maxwell'] }), { ok: true });
  // configured but the approve came from an UNtrusted login → refused
  const byStranger = { ...GREEN, reviews: [{ state: 'APPROVED', author: { login: 'randobot' } }] };
  assert.match(mergeGateOk(byStranger, { trustedReviewers: ['nick'] }).reason, /trusted reviewer/);
  // configured but NO approving review object present → refused
  assert.match(mergeGateOk(GREEN, { trustedReviewers: ['nick'] }).reason, /trusted reviewer/);
});

test('failingCheck: passes SUCCESS/NEUTRAL/SKIPPED + StatusContext SUCCESS; absent → null', () => {
  assert.equal(failingCheck([]), null);
  assert.equal(failingCheck(undefined), null);
  assert.equal(failingCheck([{ name: 'a', conclusion: 'SUCCESS' }, { name: 'b', conclusion: 'SKIPPED' }, { context: 'c', state: 'SUCCESS' }]), null);
  assert.equal(failingCheck([{ name: 'x', conclusion: 'FAILURE' }]), 'x');
  assert.equal(failingCheck([{ context: 'y', state: 'PENDING' }]), 'y');
});

// ── runApproveCycle: orchestration over injected IO ─────────────────────────────

function fakeIO(prView) {
  const calls = { merged: [], replies: [] };
  return {
    calls,
    viewPr: async () => prView,
    mergePr: async (repo, pr) => { calls.merged.push(`${repo}#${pr}`); },
    reply: async (chatId, t) => { calls.replies.push({ chatId, t }); },
  };
}
const nickMerge = (id, pr, chat = 1) => ({ update_id: id, message: { from: { id: NICK }, text: 'merge', chat: { id: chat }, reply_to_message: botPing(pr) } });

test('runApproveCycle: a valid approval of a GREEN PR merges + confirms + advances offset', async () => {
  const io = fakeIO(GREEN);
  const { newOffset, actions } = await runApproveCycle([nickMerge(10, 7)], io, CFG);
  assert.deepEqual(io.calls.merged, ['imagineering-cc/x#7']);
  assert.match(io.calls.replies[0].t, /Merged/);
  assert.equal(newOffset, 11); // offset advances past the processed update
  assert.equal(actions[0].merged, 'imagineering-cc/x#7');
});

test('runApproveCycle: a valid approval of a NON-GREEN PR does NOT merge (the live gate holds)', async () => {
  const io = fakeIO({ state: 'OPEN', mergeable: 'MERGEABLE', reviewDecision: 'REVIEW_REQUIRED', labels: [] });
  const { newOffset, actions } = await runApproveCycle([nickMerge(5, 7)], io, CFG);
  assert.deepEqual(io.calls.merged, [], 'must NOT merge an un-approved PR even on a valid "merge"');
  assert.match(io.calls.replies[0].t, /Not merging/);
  assert.equal(newOffset, 6); // still advances so it isn't re-tried forever
  assert.equal(actions[0].refused !== undefined, true);
});

test('runApproveCycle: an impostor message merges nothing AND gets no reply, but advances the offset', async () => {
  const io = fakeIO(GREEN);
  const updates = [{ update_id: 8, message: { from: { id: 666 }, text: 'merge', chat: { id: 1 }, reply_to_message: botPing(7) } }];
  const { newOffset, actions } = await runApproveCycle(updates, io, CFG);
  assert.deepEqual(io.calls.merged, []);
  assert.deepEqual(io.calls.replies, []); // we don't even reply to an impostor
  assert.equal(newOffset, 9);
  assert.ok(actions[0].ignored);
});

test('runApproveCycle: the reply goes to the AUTHORIZED message chat, not the batch-first chat (#122)', async () => {
  // update 30 is an impostor in a GROUP (chat 111); update 31 is Nick's valid
  // approval in his DM (chat 222). The "Merged" reply must go to 222, never 111.
  const io = fakeIO(GREEN);
  const updates = [
    { update_id: 30, message: { from: { id: 666 }, text: 'merge', chat: { id: 111 }, reply_to_message: botPing(9) } },
    nickMerge(31, 9, 222),
  ];
  await runApproveCycle(updates, io, CFG);
  assert.deepEqual(io.calls.merged, ['imagineering-cc/x#9']);
  assert.equal(io.calls.replies.length, 1);
  assert.equal(io.calls.replies[0].chatId, 222, 'reply must go to Nick’s chat, not the impostor group');
});

test('runApproveCycle: processes a batch in update_id order; offset = max+1', async () => {
  const io = fakeIO(GREEN);
  const updates = [
    { update_id: 30, message: { from: { id: NICK }, text: 'hi', chat: { id: 1 } } },
    nickMerge(31, 9),
  ];
  const { newOffset } = await runApproveCycle(updates, io, CFG);
  assert.deepEqual(io.calls.merged, ['imagineering-cc/x#9']);
  assert.equal(newOffset, 32);
});
