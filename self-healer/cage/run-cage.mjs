#!/usr/bin/env node
// run-cage.mjs — the one entry point that spawns the cage. Both the escape probe
// AND the (future) green-auto orchestrator go through this, so the flags proven
// by the probe are byte-identical to the flags green-auto runs. No drift.
//
// Config via env; the command to run inside the cage is argv after `--`:
//   CAGE_IMAGE     agent/probe image                 (required)
//   CAGE_NETWORK   the --internal network name       (required)
//   CAGE_WORKDIR   host path of the fresh clone       (required)
//   CAGE_PROXY_URL http://<proxy>:3128               (required)
//   CAGE_NAME      container name                     (optional)
//
//   node run-cage.mjs -- curl -sS https://example.com
//
// Exit code is the caged container's exit code (so the probe can assert it).

import { spawn, spawnSync } from 'node:child_process';
import { buildCageArgv } from './cage.mjs';

const sep = process.argv.indexOf('--');
if (sep === -1 || sep === process.argv.length - 1) {
  process.stderr.write('usage: node run-cage.mjs -- <cmd> [args…]\n');
  process.exit(2);
}
const [cmd, ...args] = process.argv.slice(sep + 1);

// FAIL CLOSED on the egress boundary: the deny-all backstop is the network being
// `--internal`. cage.mjs can only put the NAME in the argv — it cannot know the
// network is actually internal. A caller (or a future green-auto bug) that passes
// a normal bridge network would keep every proxy-env flag yet retain direct
// egress (cage-match PR #111, Carnot). So verify Internal==true at spawn time and
// refuse otherwise — the one boundary property the pure builder can't assert.
function resolveInternalNetwork(network) {
  // Read Internal AND the immutable network Id in one inspect. Returning the Id and
  // spawning against THAT (not the name) closes the inspect-then-run race: a name
  // could be deleted+recreated as a bridge between check and run, but the Id of a
  // recreated network differs, so `docker run --network <stale-id>` fails rather
  // than silently attaching to a non-internal replacement (cage-match #111, Carnot).
  const r = spawnSync('docker', ['network', 'inspect', network, '--format', '{{.Internal}} {{.Id}}'], { encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(`cage: cannot inspect network "${network}" (refusing to spawn): ${(r.stderr || '').trim()}\n`);
    process.exit(3);
  }
  const [internal, id] = r.stdout.trim().split(/\s+/);
  if (internal !== 'true') {
    process.stderr.write(`cage: network "${network}" is NOT --internal (Internal=${internal}); egress backstop absent — refusing to spawn.\n`);
    process.exit(3);
  }
  return id;
}
const networkId = resolveInternalNetwork(process.env.CAGE_NETWORK);

const { bin, argv } = buildCageArgv({
  image: process.env.CAGE_IMAGE,
  network: networkId, // the inspected Id, not the name — closes the inspect→run race
  workdirHost: process.env.CAGE_WORKDIR,
  proxyUrl: process.env.CAGE_PROXY_URL,
  name: process.env.CAGE_NAME,
  cmd,
  args,
});

const proc = spawn(bin, argv, { stdio: 'inherit' });
proc.on('exit', (code, signal) => {
  if (signal) { process.stderr.write(`cage killed by ${signal}\n`); process.exit(1); }
  process.exit(code ?? 1);
});
