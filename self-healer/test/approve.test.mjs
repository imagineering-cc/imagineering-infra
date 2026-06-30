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
import { parsePrUrl, isApprovalText, approvalDecision, mergeGateOk } from '../src/approve.mjs';
import { runApproveCycle } from '../src/approve-poll.mjs';

const NICK = 12345;
const ping = (n) => `🤖 green-auto opened a draft PR\nhttps://github.com/imagineering-cc/x/pull/${n}\nfoo`;
const msg = (over = {}) => ({ update_id: 1, message: { from: { id: NICK }, text: 'merge', chat: { id: 999 }, ...over } });

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
  const d = approvalDecision(msg({ from: { id: 99999 }, text: `merge ${ping(42)}` }), { nickUserId: NICK });
  assert.ok(d.ignore);
  assert.match(d.ignore, /not the authorized approver/);
});

test('approvalDecision: nickUserId unset → never authorizes (fail closed)', () => {
  const d = approvalDecision(msg({ text: 'merge https://github.com/o/r/pull/1' }), {});
  assert.ok(d.ignore);
});

// ── gate 2: unambiguous PR reference ───────────────────────────────────────────

test('approvalDecision: URL in the approval text → merge that exact repo+pr', () => {
  const d = approvalDecision(msg({ text: 'merge https://github.com/o/r/pull/7' }), { nickUserId: NICK });
  assert.deepEqual(d.merge, { repo: 'o/r', pr: 7 });
});

test('approvalDecision: reply to the ping → PR resolved from the QUOTED text', () => {
  const d = approvalDecision(msg({ text: 'merge', reply_to_message: { text: ping(55) } }), { nickUserId: NICK });
  assert.deepEqual(d.merge, { repo: 'imagineering-cc/x', pr: 55 });
});

test('approvalDecision: bare "#N" with NO repo context is refused (multi-repo ambiguity)', () => {
  const d = approvalDecision(msg({ text: 'merge #42' }), { nickUserId: NICK });
  assert.ok(d.ignore);
  assert.match(d.ignore, /unambiguously reference/);
});

test('approvalDecision: bare "#N" resolves ONLY against a configured defaultRepo', () => {
  const d = approvalDecision(msg({ text: 'merge #42' }), { nickUserId: NICK, defaultRepo: 'o/r' });
  assert.deepEqual(d.merge, { repo: 'o/r', pr: 42 });
});

test('approvalDecision: approval verb but no PR anywhere → ignore', () => {
  assert.ok(approvalDecision(msg({ text: 'merge it please' }), { nickUserId: NICK }).ignore);
});

test('approvalDecision: a non-approval message from Nick → ignore (not every message merges)', () => {
  assert.ok(approvalDecision(msg({ text: 'thanks!' }), { nickUserId: NICK }).ignore);
});

// ── gate 3: the live green gate ─────────────────────────────────────────────────

test('mergeGateOk: passes only an OPEN, non-conflicting, APPROVED, cage-matched PR', () => {
  assert.deepEqual(mergeGateOk({ state: 'OPEN', mergeable: 'MERGEABLE', reviewDecision: 'APPROVED', labels: [{ name: 'cage-matched' }] }), { ok: true });
});

test('mergeGateOk: refuses each missing condition', () => {
  assert.match(mergeGateOk({ state: 'MERGED', labels: [] }).reason, /not open/);
  assert.match(mergeGateOk({ state: 'OPEN', mergeable: 'CONFLICTING', reviewDecision: 'APPROVED', labels: [{ name: 'cage-matched' }] }).reason, /conflict/);
  assert.match(mergeGateOk({ state: 'OPEN', reviewDecision: 'REVIEW_REQUIRED', labels: [{ name: 'cage-matched' }] }).reason, /not approved/);
  assert.match(mergeGateOk({ state: 'OPEN', reviewDecision: 'APPROVED', labels: [] }).reason, /not cage-matched/);
});

// ── runApproveCycle: orchestration over injected IO ─────────────────────────────

function fakeIO(prView) {
  const calls = { merged: [], replies: [] };
  return {
    calls,
    viewPr: async () => prView,
    mergePr: async (repo, pr) => { calls.merged.push(`${repo}#${pr}`); },
    reply: async (t) => { calls.replies.push(t); },
  };
}

test('runApproveCycle: a valid approval of a GREEN PR merges + confirms + advances offset', async () => {
  const io = fakeIO({ state: 'OPEN', mergeable: 'MERGEABLE', reviewDecision: 'APPROVED', labels: [{ name: 'cage-matched' }] });
  const updates = [{ update_id: 10, message: { from: { id: NICK }, text: 'merge', chat: { id: 1 }, reply_to_message: { text: ping(7) } } }];
  const { newOffset, actions } = await runApproveCycle(updates, io, { nickUserId: NICK });
  assert.deepEqual(io.calls.merged, ['imagineering-cc/x#7']);
  assert.match(io.calls.replies[0], /Merged/);
  assert.equal(newOffset, 11); // offset advances past the processed update
  assert.equal(actions[0].merged, 'imagineering-cc/x#7');
});

test('runApproveCycle: a valid approval of a NON-GREEN PR does NOT merge (the live gate holds)', async () => {
  const io = fakeIO({ state: 'OPEN', reviewDecision: 'REVIEW_REQUIRED', labels: [] });
  const updates = [{ update_id: 5, message: { from: { id: NICK }, text: 'merge', chat: { id: 1 }, reply_to_message: { text: ping(7) } } }];
  const { newOffset, actions } = await runApproveCycle(updates, io, { nickUserId: NICK });
  assert.deepEqual(io.calls.merged, [], 'must NOT merge an un-approved PR even on a valid "merge"');
  assert.match(io.calls.replies[0], /Not merging/);
  assert.equal(newOffset, 6); // still advances so it isn't re-tried forever
  assert.equal(actions[0].refused !== undefined, true);
});

test('runApproveCycle: an impostor message merges nothing but still advances the offset', async () => {
  const io = fakeIO({ state: 'OPEN', mergeable: 'MERGEABLE', reviewDecision: 'APPROVED', labels: [{ name: 'cage-matched' }] });
  const updates = [{ update_id: 8, message: { from: { id: 666 }, text: 'merge', chat: { id: 1 }, reply_to_message: { text: ping(7) } } }];
  const { newOffset, actions } = await runApproveCycle(updates, io, { nickUserId: NICK });
  assert.deepEqual(io.calls.merged, []);
  assert.deepEqual(io.calls.replies, []); // we don't even reply to an impostor
  assert.equal(newOffset, 9);
  assert.ok(actions[0].ignored);
});

test('runApproveCycle: processes a batch in update_id order; offset = max+1', async () => {
  const io = fakeIO({ state: 'OPEN', mergeable: 'MERGEABLE', reviewDecision: 'APPROVED', labels: ['cage-matched'] });
  const updates = [
    { update_id: 30, message: { from: { id: NICK }, text: 'hi', chat: { id: 1 } } },
    { update_id: 31, message: { from: { id: NICK }, text: 'merge', chat: { id: 1 }, reply_to_message: { text: ping(9) } } },
  ];
  const { newOffset } = await runApproveCycle(updates, io, { nickUserId: NICK });
  assert.deepEqual(io.calls.merged, ['imagineering-cc/x#9']);
  assert.equal(newOffset, 32);
});
