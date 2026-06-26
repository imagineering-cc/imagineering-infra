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

import { randomBytes } from 'node:crypto';
import { runOnHostScript } from './host.mjs';

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
 * payload.
 *
 * CADENCE-AWARE (deploy #49 follow-up): logs are fetched with `docker logs -t`,
 * so each line is prefixed with an RFC3339 timestamp. We fold consecutive lines
 * that share the same MESSAGE (ignoring the timestamp) and report the time SPAN
 * of the run — e.g. "OpenAI Realtime mode ready  (×40, 2026-06-23T02:10:17Z→
 * 2026-06-23T03:50:17Z)". That span is the difference between a benign 10-minute
 * heartbeat and a tight reconnect storm — a distinction the brain CANNOT make
 * from a bare "(×40)". (A real run mis-diagnosed exactly this: 40 identical
 * timestamp-less "ready" lines read as a storm when they were a 10-min beat.)
 * Lines without a leading timestamp collapse to the plain "(×N)" form.
 */

/** Split a log line into its leading RFC3339 timestamp (fractional seconds
 * trimmed for compactness) and the remaining message. Returns ts:null for a
 * line that doesn't start with a docker `-t` timestamp. */
export function splitLogTimestamp(line) {
  const m = line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})\s([\s\S]*)$/);
  if (!m) return { ts: null, msg: line };
  return { ts: `${m[1]}${m[2]}`, msg: m[3] };
}

export function collapseRepeats(text) {
  const out = [];
  let prevMsg = null;
  let firstTs = null;
  let lastTs = null;
  let run = 0;
  const flush = () => {
    if (prevMsg === null) return;
    if (run > 1) {
      const span = firstTs ? `, ${firstTs}→${lastTs}` : '';
      out.push(`${prevMsg}  (×${run}${span})`);
    } else {
      out.push(firstTs ? `${firstTs} ${prevMsg}` : prevMsg);
    }
  };
  for (const line of text.split('\n')) {
    const { ts, msg } = splitLogTimestamp(line);
    if (msg === prevMsg) { run += 1; lastTs = ts; continue; }
    flush();
    prevMsg = msg;
    firstTs = ts;
    lastTs = ts;
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
 * The fixed sensor script. NOTHING here is interpolated at build time — the
 * container name, log-line count, and split nonce all arrive as base64
 * positional args ($1,$2,$3) and are decoded INSIDE the script, so attacker- or
 * config-shaped values can never become script text (see host.mjs
 * `runOnHostScript`). The script:
 *   - $1 → container name, $2 → tail count, $3 → per-call split nonce.
 *   - captures `docker inspect`'s OWN exit code (INSPECT_RC) so the caller can
 *     distinguish exists / absent / unreachable.
 *   - prints the nonce on its own line as the meta↔logs boundary.
 *   - `docker logs -t` keeps the RFC3339 timestamps collapseRepeats folds.
 * The tail count is `printf %d`-coerced to an integer (defence-in-depth: it is
 * already a JS number at the call site, but this guarantees no non-numeric token
 * reaches `--tail` even if a caller passes something odd).
 */
export const SENSOR_SCRIPT =
  '__n=$(printf %s "$1" | base64 -d); ' +
  '__t=$(printf %d "$(printf %s "$2" | base64 -d)" 2>/dev/null); ' +
  '__s=$(printf %s "$3" | base64 -d); ' +
  '__i=$(docker inspect "$__n" --format \'{{.State.Status}}|{{.RestartCount}}|{{.State.Running}}\' 2>&1); __rc=$?; ' +
  "printf 'INSPECT_RC=%s\\n' \"$__rc\"; printf '%s\\n' \"$__i\"; " +
  'printf \'%s\\n\' "$__s"; ' +
  'docker logs -t "$__n" --tail "$__t" 2>&1';

/**
 * Split a sensor-script stdout on the per-call nonce boundary. Pure + exported
 * for adversarial testing: a log line that CONTAINS a guessed/forged boundary
 * marker must not corrupt the meta↔logs split, because the real boundary is a
 * random per-call nonce the log content cannot predict. We split on the FIRST
 * occurrence so even a (vanishingly unlikely) nonce echo can't move the seam
 * earlier than the real one.
 * @param {string} stdout
 * @param {string} nonce
 * @returns {{head: string, logs: string}}
 */
export function splitOnNonce(stdout, nonce) {
  const marker = `${nonce}\n`;
  let at = stdout.indexOf(marker);
  let skip = marker.length;
  if (at === -1) { at = stdout.indexOf(nonce); skip = nonce.length; } // tolerate a missing trailing newline
  if (at === -1) return { head: stdout, logs: '' };
  return { head: stdout.slice(0, at), logs: stdout.slice(at + skip) };
}

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
  //
  // #46a/#46c hardening: the name + tail count go in as base64 positional args
  // (injection-inert by construction), and the meta↔logs boundary is a RANDOM
  // per-call nonce — not a static sentinel an attacker could embed in a log line
  // to forge the boundary.
  const nonce = `HEALER_SPLIT_${randomBytes(16).toString('hex')}`;
  const { stdout, stderr, code } = await runOnHostScript(SENSOR_SCRIPT, [name, logLines, nonce]);
  // ssh returns 255 when the connection itself fails — a SENSING failure.
  if (code === 255) {
    throw new Error(`host unreachable while sensing ${name} (ssh exit 255): ${stderr.trim()}`);
  }

  const { head, logs } = splitOnNonce(stdout, nonce);

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
