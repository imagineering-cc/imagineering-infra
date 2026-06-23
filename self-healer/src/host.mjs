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
import { Buffer } from 'node:buffer';

/**
 * Low-level spawn → buffered result. Shared by both primitives so the
 * stdin-piping + timeout/SIGKILL behaviour lives in ONE place.
 *
 * @param {string} bin
 * @param {string[]} args
 * @param {object} [opts]
 * @param {string} [opts.stdin]
 * @param {number} [opts.timeoutMs=70000]
 * @param {string} [opts.label]  short string for the timeout error message
 * @returns {Promise<{stdout: string, stderr: string, code: number}>}
 */
function spawnBuffered(bin, args, { stdin, timeoutMs = 70_000, label = '' } = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(bin, args);
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`runOnHost timed out after ${timeoutMs}ms: ${label.slice(0, 80)}`));
    }, timeoutMs);

    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });
    proc.on('error', (err) => { clearTimeout(timer); reject(err); });
    proc.on('close', (code) => { clearTimeout(timer); resolve({ stdout, stderr, code: code ?? -1 }); });

    if (stdin !== undefined) { proc.stdin.write(stdin); proc.stdin.end(); }
  });
}

/**
 * Run a shell command "on the host" — locally, or over SSH when HEALER_HOST
 * is set. Optionally feed `stdin` (used to POST a JSON body to the shim via
 * `curl --data-binary @-`).
 *
 * ⚠️ This primitive runs an arbitrary shell STRING. Any untrusted value
 * interpolated into `cmd` is a command-injection (= RCE on prod) surface.
 * For the self-healer's own call sites prefer {@link runOnHostScript}, which
 * passes untrusted values as shell-inert positional args. `runOnHost` is kept
 * for fixed/trusted command strings.
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

  return spawnBuffered(bin, args, { stdin, timeoutMs, label: cmd });
}

/**
 * Build the spawn argv for {@link runOnHostScript} WITHOUT spawning. Exported so
 * tests can assert — without touching a real process — that untrusted values
 * never enter the script text, only the positional-arg tail (as base64).
 *
 * The contract: `fixedScript` is a constant string the developer wrote; `args`
 * are untrusted runtime values. Each arg is base64-encoded so it survives every
 * shell parse on the way to the box as inert data:
 *
 *   - on-box:  bash binds $0='_', $1=b64(arg0), $2=b64(arg1)… positionally.
 *     The args are passed AFTER the script text, never spliced INTO it, so the
 *     local shell never parses them as code.
 *   - remote:  ssh concatenates ALL of its trailing argv into ONE string and
 *     the REMOTE login shell re-parses that string. base64's alphabet
 *     ([A-Za-z0-9+/=]) contains no shell metacharacters, so even after that
 *     second parse each base64 token survives as a single word — inert.
 *
 * Either way the FIXED_SCRIPT base64-DECODEs each positional ($1,$2…) back to
 * the real value internally before use (`v=$(printf %s "$1" | base64 -d)`).
 * Because base64 -d runs on the OCI Linux box in BOTH paths (on-box = OCI;
 * remote = decode happens on the remote OCI box), one fixed script serves both.
 *
 * @param {string} fixedScript   constant script text ($1,$2… are decoded args)
 * @param {string[]} args        untrusted values, in $1,$2… order
 * @param {string} [host]        HEALER_HOST (empty ⇒ on-box)
 * @returns {{bin: string, argv: string[]}}
 */
export function buildHostScriptArgv(fixedScript, args = [], host = process.env.HEALER_HOST) {
  const b64 = args.map((a) => Buffer.from(String(a), 'utf8').toString('base64'));
  // '_' is $0 (a conventional placeholder name); the b64 values become $1, $2…
  return host
    ? { bin: 'ssh', argv: ['-o', 'ConnectTimeout=8', host, 'bash', '-c', fixedScript, '_', ...b64] }
    : { bin: 'bash', argv: ['-c', fixedScript, '_', ...b64] };
}

/**
 * Run a FIXED shell script on the host, passing untrusted values as positional
 * arguments that are shell-inert by construction (base64). This is the
 * injection-safe primitive: the untrusted data never becomes part of the script
 * text, so neither the local shell nor — critically — the remote ssh login
 * shell can ever parse it as code. See {@link buildHostScriptArgv} for the why.
 *
 * @param {string} fixedScript   constant script ($1,$2… are base64 of `args`)
 * @param {string[]} args        untrusted values, in $1,$2… order
 * @param {object} [opts]
 * @param {string} [opts.stdin]  data to pipe to stdin (e.g. the curl body)
 * @param {number} [opts.timeoutMs=70000] hard kill ceiling
 * @returns {Promise<{stdout: string, stderr: string, code: number}>}
 */
export function runOnHostScript(fixedScript, args = [], { stdin, timeoutMs = 70_000 } = {}) {
  const { bin, argv } = buildHostScriptArgv(fixedScript, args);
  return spawnBuffered(bin, argv, { stdin, timeoutMs, label: fixedScript });
}

/** True when we're running directly on the OCI box (no SSH hop). */
export function isOnBox() {
  return !process.env.HEALER_HOST;
}
