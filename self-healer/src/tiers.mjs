// tiers.mjs — the traffic-light closed set, made a real type instead of three
// magic strings sprayed across the codebase.
//
// The cage-match (PR #100) flagged the core failure mode: the exit-code logic
// treated any value other than exactly "red"/"amber" as green/exit-0, so a
// brain that emitted "RED", "Green", a trailing space, or a missing tier would
// silently report a 🔴 as all-clear. For a health tool, failing OPEN like that
// is the one unacceptable direction. So: one frozen closed set, one
// normalizer, fail-CLOSED on anything off the set.

/** The only legal tier values, worst → best is RED > AMBER > GREEN. */
export const TIERS = Object.freeze({ GREEN: 'green', AMBER: 'amber', RED: 'red' });

const VALID = new Set(Object.values(TIERS));

/** Severity rank for "max tier" comparisons. Higher = worse. */
const RANK = { green: 0, amber: 1, red: 2 };

/**
 * Normalize a raw tier value to the closed set, or return null if it isn't a
 * legal tier. Trims + lowercases first so "RED " ⇒ "red"; anything still off
 * the set (typo, missing, non-string) ⇒ null so the caller can fail closed.
 * @param {unknown} raw
 * @returns {('green'|'amber'|'red')|null}
 */
export function normalizeTier(raw) {
  if (typeof raw !== 'string') return null;
  const t = raw.trim().toLowerCase();
  return VALID.has(t) ? t : null;
}

/** Exit code for a tier: green=0, amber=1, red=2. */
export function tierExitCode(tier) {
  return tier === TIERS.RED ? 2 : tier === TIERS.AMBER ? 1 : 0;
}

/** The worse (higher-rank) of two tiers. */
export function maxTier(a, b) {
  return RANK[a] >= RANK[b] ? a : b;
}
