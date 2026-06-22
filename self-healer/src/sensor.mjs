// sensor.mjs — gather the prod signals the brain reasons over.
//
// DESIGN NOTE: logs alone are ambiguous in BOTH directions, which is why we
// collect structured liveness facts alongside them:
//
//   - A QUIET log is not proof of health (the process could be wedged).
//   - A NOISY error log is not proof of sickness — observed live on
//     2026-06-22, tw-gremlin logged `level:50 "worker connection closed
//     unexpectedly"` then re-registered 66ms later under a new LiveKit node.
//     That's LiveKit Cloud rotating a node; the bot self-healed. Grepping for
//     `level:50` would page on a non-event.
//
// So we also pull `Status` (uptime string) and `RestartCount` from
// `docker inspect`. A climbing RestartCount is the one UNAMBIGUOUS crash-loop
// signal — a container that keeps dying and respawning, regardless of how
// calm any single log snapshot looks.

import { runOnHost } from './host.mjs';

/**
 * Legal Docker container-name grammar. Container names are interpolated into a
 * shell command, so they are a command-injection surface (cage-match PR #100).
 * targets.json is trusted config, but validating here makes the trust boundary
 * EXPLICIT instead of assumed — a name with a space, `;`, `$()` etc. is
 * rejected at load before any command string is built. Mirrors Docker's own
 * `[a-zA-Z0-9][a-zA-Z0-9_.-]+` name rule.
 */
export const CONTAINER_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/;

/** Throw if a container name isn't shell-inert per the Docker grammar. */
export function assertValidContainerName(name) {
  if (typeof name !== 'string' || !CONTAINER_NAME_RE.test(name)) {
    throw new Error(`invalid container name (must match ${CONTAINER_NAME_RE}): ${JSON.stringify(name)}`);
  }
  return name;
}

/**
 * Collapse runs of identical consecutive log lines into `<line>  (×N)`.
 * This is not just a size hack: a line repeated 25× carries no MORE diagnostic
 * detail than the line plus its count, but it does waste inference tokens and
 * latency. Collapsing surfaces the repetition AS a signal while shrinking the
 * payload — e.g. "OpenAI Realtime mode ready  (×25)".
 */
export function collapseRepeats(text) {
  const out = [];
  let prev = null;
  let run = 0;
  const flush = () => {
    if (prev === null) return;
    out.push(run > 1 ? `${prev}  (×${run})` : prev);
  };
  for (const line of text.split('\n')) {
    if (line === prev) { run += 1; continue; }
    flush();
    prev = line;
    run = 1;
  }
  flush();
  return out.join('\n');
}

/**
 * @typedef {object} ContainerSignal
 * @property {string} name
 * @property {boolean} present      false if the container doesn't exist on the host
 * @property {string}  status       docker Status string, e.g. "Up 2 days"
 * @property {number}  restartCount how many times docker has restarted it
 * @property {string}  logTail      the last N lines of stdout/stderr
 */

/**
 * Gather signals for one container.
 * @param {string} name
 * @param {number} logLines
 * @returns {Promise<ContainerSignal>}
 */
async function gatherContainer(name, logLines) {
  assertValidContainerName(name);
  // One combined call keeps SSH round-trips down. We capture docker inspect's
  // OWN exit code so we can distinguish THREE cases (cage-match PR #100
  // re-review): the container exists (rc 0), it's genuinely absent ("No such
  // object", rc≠0), or docker/the host is unreachable (daemon down, perm
  // denied, ssh fail) — the last MUST fail CLOSED, never look like "absent".
  // Split on the FIRST sentinel occurrence (indexOf) so log content can't
  // corrupt the meta/logs boundary.
  const SENTINEL = '@@HEALER_SPLIT@@';
  const cmd =
    `__i=$(docker inspect '${name}' --format '{{.State.Status}}|{{.RestartCount}}|{{.State.Running}}' 2>&1); __rc=$?; ` +
    `printf 'INSPECT_RC=%s\\n' "$__rc"; printf '%s\\n' "$__i"; ` +
    `echo '${SENTINEL}'; ` +
    `docker logs '${name}' --tail ${logLines} 2>&1`;

  const { stdout, stderr, code } = await runOnHost(cmd);
  // ssh returns 255 when the connection itself fails — a SENSING failure.
  if (code === 255) {
    throw new Error(`host unreachable while sensing ${name} (ssh exit 255): ${stderr.trim()}`);
  }

  const splitAt = stdout.indexOf(SENTINEL);
  const head = splitAt === -1 ? stdout : stdout.slice(0, splitAt);
  const logs = splitAt === -1 ? '' : stdout.slice(splitAt + SENTINEL.length);

  const headLines = head.split('\n');
  const rcLine = headLines.find((l) => l.startsWith('INSPECT_RC=')) ?? '';
  const inspectRc = rcLine.slice('INSPECT_RC='.length).trim();
  const inspectOut = headLines.filter((l) => !l.startsWith('INSPECT_RC=')).join('\n').trim();

  if (inspectRc === '0') {
    const [state, restarts, running] = inspectOut.split('|');
    return {
      name,
      present: true,
      status: running === 'true' ? `running (${state})` : `NOT running (${state})`,
      restartCount: Number.parseInt(restarts, 10) || 0,
      logTail: collapseRepeats(logs.trim()),
    };
  }
  // inspect failed. "No such object/container" is a genuine ABSENT verdict.
  if (/no such (object|container)/i.test(inspectOut)) {
    return { name, present: false, status: 'absent', restartCount: 0, logTail: '' };
  }
  // Anything else (daemon down, permission denied, unparseable) is a SENSING
  // failure — fail CLOSED so a broken host never masquerades as "all absent".
  throw new Error(`docker inspect failed for ${name} (rc=${inspectRc || '?'}): ${inspectOut || stderr.trim() || '(no output)'}`);
}

/**
 * Gather signals for every watched container.
 * @param {{name: string}[]} targets
 * @param {number} [logLines=40]
 * @returns {Promise<ContainerSignal[]>}
 */
export async function gatherSignals(targets, logLines = 40) {
  // Sequential, not parallel: in remote mode each is an SSH hop and we'd
  // rather be polite to the box than shave a second. Watch lists are small.
  const signals = [];
  for (const t of targets) {
    signals.push(await gatherContainer(t.name, logLines));
  }
  return signals;
}
