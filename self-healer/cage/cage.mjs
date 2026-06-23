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

/**
 * Build the argv to run `cmd …args` inside the cage.
 *
 * @param {object} o
 * @param {string} o.image        the agent image (built from the shim image + tools)
 * @param {string} o.network      the `--internal` docker network name (NO egress)
 * @param {string} o.workdirHost  host path of the FRESH single-repo clone, bind-mounted rw at /work
 * @param {string} o.proxyUrl     e.g. http://cage-egress-proxy:3128 — the ONLY egress path
 * @param {string} [o.name]       container name (ephemeral)
 * @param {Record<string,string>} [o.env]  extra env (e.g. a repo-scoped GH token). NEVER host secrets.
 * @param {string} o.cmd          the command to run (e.g. "claude" or, in the probe, "sh")
 * @param {string[]} [o.args]     args to cmd
 * @returns {{bin: string, argv: string[]}}
 */
export function buildCageArgv({ image, network, workdirHost, proxyUrl, name, env = {}, cmd, args = [] }) {
  if (!image) throw new Error('cage: image required');
  if (!network) throw new Error('cage: internal network required');
  if (!workdirHost) throw new Error('cage: workdirHost required');
  if (!proxyUrl) throw new Error('cage: proxyUrl required (egress is allowlist-only)');
  if (!cmd) throw new Error('cage: cmd required');

  const argv = ['run', ...CONFINEMENT_FLAGS];
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

  // Caller env first, proxy env LAST so a caller can never clobber the egress
  // routing (a clobbered HTTPS_PROXY would let the agent egress directly).
  for (const [k, v] of Object.entries({ ...env, ...proxyEnv })) {
    argv.push('-e', `${k}=${v}`);
  }

  argv.push(image, cmd, ...args);
  return { bin: 'docker', argv };
}
