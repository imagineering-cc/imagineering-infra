// host.mjs — the ONE primitive everything else is built on.
//
// The self-healer needs two things that both live on the OCI box:
//   1. prod `docker logs` (the sensor signal)
//   2. claude-shim inference at http://127.0.0.1:8088 (the brain)
//
// claude-shim is bound to localhost ONLY (127.0.0.1:8088) — it is NOT
// publicly reachable. So inference calls MUST originate from the OCI host.
// Rather than special-case "am I local or remote?" at every call site, we
// funnel ALL host work through `runOnHost`:
//
//   - on-box (deployed on OCI):   spawn `bash -c <cmd>` directly
//   - remote (dev from a laptop): spawn `ssh <host> bash -c <cmd>`
//
// Because both the log reads AND the curl-to-localhost-shim go through this
// one door, remote development "just works" over SSH with zero extra infra
// (no tunnel, no exposed port). The shim stays localhost-only — which is also
// its security boundary (see claude-shim/src/server.js).

import { spawn } from 'node:child_process';

/**
 * Run a shell command "on the host" — locally, or over SSH when HEALER_HOST
 * is set. Optionally feed `stdin` (used to POST a JSON body to the shim via
 * `curl --data-binary @-`).
 *
 * @param {string} cmd          shell command to run on the host
 * @param {object} [opts]
 * @param {string} [opts.stdin] data to pipe to the command's stdin
 * @param {number} [opts.timeoutMs=70000] hard kill ceiling
 * @returns {Promise<{stdout: string, stderr: string, code: number}>}
 */
export function runOnHost(cmd, { stdin, timeoutMs = 70_000 } = {}) {
  const host = process.env.HEALER_HOST; // e.g. "nick@149.118.69.221"; empty ⇒ on-box
  // NOTE: ssh runs its command argument through the REMOTE login shell itself,
  // so we pass `cmd` as a single arg — wrapping it in `bash -c` here would make
  // ssh hand the remote shell `bash -c <cmd> …`, where only the first token
  // survives as the script and the rest collapse into positional params (curl
  // ends up with no args → exit 2). On-box we DO need the explicit `bash -c`.
  const [bin, args] = host
    ? ['ssh', ['-o', 'ConnectTimeout=8', host, cmd]]
    : ['bash', ['-c', cmd]];

  return new Promise((resolve, reject) => {
    const proc = spawn(bin, args);
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`runOnHost timed out after ${timeoutMs}ms: ${cmd.slice(0, 80)}`));
    }, timeoutMs);

    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });
    proc.on('error', (err) => { clearTimeout(timer); reject(err); });
    proc.on('close', (code) => { clearTimeout(timer); resolve({ stdout, stderr, code: code ?? -1 }); });

    if (stdin !== undefined) { proc.stdin.write(stdin); proc.stdin.end(); }
  });
}

/** True when we're running directly on the OCI box (no SSH hop). */
export function isOnBox() {
  return !process.env.HEALER_HOST;
}
