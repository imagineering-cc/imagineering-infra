// repos.mjs — maps a watched container to the source repo where a fix would
// land. green-draft can only file a remediation issue for a container whose
// source home is known; an unmapped container is skipped (logged), never
// guessed — filing an issue against the wrong repo is worse than not filing.

/**
 * container name → "owner/repo". Keep this explicit and conservative. A
 * container with no entry yields null from repoForContainer and green-draft
 * skips it.
 *
 * NOTE: claude-shim's source is NOT checked into any repo (it lives only on the
 * OCI box, deployed by rsync — see README "known substrate facts"). So a
 * claude-shim finding has no repo to file against and is intentionally absent
 * here until that source is versioned (tracked separately).
 */
export const CONTAINER_REPOS = Object.freeze({
  'tw-clawd': 'enspyrco/tech_world_bot',
  'tw-gremlin': 'enspyrco/tech_world_bot',
  'embodied-dreamfinder': 'imagineering-cc/embodied-dreamfinder',
});

/** @returns {string|null} "owner/repo" or null if the container has no known source repo. */
export function repoForContainer(name) {
  return CONTAINER_REPOS[name] ?? null;
}
