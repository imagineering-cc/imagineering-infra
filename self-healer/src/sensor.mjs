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
 * Collapse runs of identical consecutive log lines into `<line>  (×N)`.
 * This is not just a size hack: a line repeated 25× carries no MORE diagnostic
 * detail than the line plus its count, but it does waste inference tokens and
 * latency. Collapsing surfaces the repetition AS a signal while shrinking the
 * payload — e.g. "OpenAI Realtime mode ready  (×25)".
 */
function collapseRepeats(text) {
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
  // One combined call keeps SSH round-trips down: inspect (status+restarts)
  // then logs, separated by a sentinel we split on.
  const SENTINEL = '@@HEALER_SPLIT@@';
  const cmd =
    `docker inspect ${name} --format '{{.State.Status}}|{{.RestartCount}}|{{.State.Running}}' 2>/dev/null; ` +
    `echo '${SENTINEL}'; ` +
    `docker logs ${name} --tail ${logLines} 2>&1`;

  const { stdout } = await runOnHost(cmd);
  const [meta, logs = ''] = stdout.split(SENTINEL);
  const metaLine = meta.trim();

  if (!metaLine) {
    return { name, present: false, status: 'absent', restartCount: 0, logTail: '' };
  }

  const [state, restarts, running] = metaLine.split('|');
  return {
    name,
    present: true,
    status: running === 'true' ? `running (${state})` : `NOT running (${state})`,
    restartCount: Number.parseInt(restarts, 10) || 0,
    logTail: collapseRepeats(logs.trim()),
  };
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
