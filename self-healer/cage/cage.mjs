// cage.mjs — build the `docker run` argv that confines the green-auto codegen
// agent. PURE (no spawn) so the confinement flags can be asserted in CI without
// a Docker daemon, exactly like host.mjs/buildHostScriptArgv. The LIVE proof
// that these flags actually hold is cage/escape-probe.sh on the box — an argv
// assertion is necessary but NOT the boundary (a green flag list ≠ a held
// boundary; you must attempt the escape).
//
// Every flag here maps to a row in cage/README.md's contract table. If you add a
// capability to the agent, add the matching escape case to the probe FIRST.

/** Flags that drop the container's authority. Order-independent; kept as a frozen
 * list so the unit test can assert the SET is present regardless of arrangement. */
export const CONFINEMENT_FLAGS = Object.freeze([
  '--rm', // ephemeral: nothing persists across runs
  '--cap-drop=ALL', // no raw sockets, mount, ptrace, …
  '--security-opt=no-new-privileges', // setuid/sudo cannot escalate
  '--read-only', // in-image rootfs immutable; only the workdir bind is writable
  '--pids-limit=512', // a fork bomb can't take the box
  '--memory=2g', // an alloc bomb can't take the box
  '--cpus=2',
]);

/** Default non-root uid:gid the cage forces. Pinned by the CAGE, not delegated to
 * the image's USER directive (cage-match PR #111, Maxwell F1 + Carnot HIGH): an
 * agent image built without a USER line would otherwise run as ROOT in the cage.
 * Enforcing --user here makes non-root true regardless of image hygiene, and lets
 * the escape probe prove the CAGE (start from a root image) rather than the image. */
export const CAGE_UID_GID = '1000:1000';

/**
 * Build the argv to run `cmd …args` inside the cage.
 *
 * @param {object} o
 * @param {string} o.image        the agent image (built from the shim image + tools)
 * @param {string} o.network      the `--internal` docker network name (NO egress)
 * @param {string} o.workdirHost  host path of the FRESH single-repo clone, bind-mounted rw at /work
 * @param {string} o.proxyUrl     e.g. http://cage-egress-proxy:3128 — the ONLY egress path
 * @param {string} [o.name]       container name (ephemeral)
 * @param {Record<string,string>} [o.env]  extra VALUE-carrying env (non-secret context). A value here lands in the argv (host `ps`), so NEVER a secret — for a secret use passEnv.
 * @param {string[]} [o.passEnv]  env var NAMES passed through key-only (`-e NAME`, no value) — docker reads the VALUE from the SPAWNING process's env, so a SECRET (a repo-scoped token) never appears in this argv / host `ps` (cage-match #114, Maxwell F1). Caller must have the var set in its own env.
 * @param {string} o.cmd          the command to run (e.g. "claude" or, in the probe, "sh")
 * @param {string[]} [o.args]     args to cmd
 * @param {string} [o.userGid]    forced non-root uid:gid (default CAGE_UID_GID); never trusts the image
 * @returns {{bin: string, argv: string[]}}
 */
export function buildCageArgv({ image, network, workdirHost, proxyUrl, name, env = {}, passEnv = [], cmd, args = [], userGid = CAGE_UID_GID }) {
  if (!image) throw new Error('cage: image required');
  if (!network) throw new Error('cage: internal network required');
  if (!workdirHost) throw new Error('cage: workdirHost required');
  if (!proxyUrl) throw new Error('cage: proxyUrl required (egress is allowlist-only)');
  if (!cmd) throw new Error('cage: cmd required');

  const argv = ['run', ...CONFINEMENT_FLAGS];
  // Force non-root at the CAGE, never trusting the image's USER (cage-match #111).
  argv.push('--user', userGid);
  if (name) argv.push('--name', name);

  // Egress: deny-all internal network is the backstop; the proxy is the only
  // reachable name and the only allowlist gate. Set BOTH upper- and lower-case
  // proxy vars (curl honors lower, many libs honor upper) and NO_PROXY empty so
  // nothing is exempted. NO direct route exists regardless, but be explicit.
  argv.push('--network', network);
  const proxyEnv = {
    HTTP_PROXY: proxyUrl,
    HTTPS_PROXY: proxyUrl,
    http_proxy: proxyUrl,
    https_proxy: proxyUrl,
    NO_PROXY: '',
    no_proxy: '',
  };

  // Only the fresh clone is writable; rootfs is read-only. /tmp is a small
  // noexec/nosuid tmpfs (tools need scratch space but must not run code from it).
  argv.push('-v', `${workdirHost}:/work:rw`, '-w', '/work');
  argv.push('--tmpfs', '/tmp:rw,noexec,nosuid,size=64m');

  // Key-only `-e NAME` pass-through: docker reads NAME's VALUE from the SPAWNING
  // process's env, so a secret (the repo-scoped token) rides in the docker
  // client's env, NEVER in this argv / host `ps` (cage-match #114, Maxwell F1).
  // Disjoint by construction from `env` and the proxy keys.
  for (const k of passEnv) {
    argv.push('-e', k); // bare name, no "=value"
  }

  // Caller env first, proxy env LAST so a caller can never clobber the egress
  // routing (a clobbered HTTPS_PROXY would let the agent egress directly). The
  // spread dedupes by key, so a caller-set proxy key is OVERWRITTEN (not
  // duplicated) by proxyEnv — docker's last-wins then can't be turned against us.
  for (const [k, v] of Object.entries({ ...env, ...proxyEnv })) {
    argv.push('-e', `${k}=${v}`);
  }

  argv.push(image, cmd, ...args);
  return { bin: 'docker', argv };
}
