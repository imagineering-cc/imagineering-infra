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

import { spawn } from 'node:child_process';
import { buildCageArgv } from './cage.mjs';

const sep = process.argv.indexOf('--');
if (sep === -1 || sep === process.argv.length - 1) {
  process.stderr.write('usage: node run-cage.mjs -- <cmd> [args…]\n');
  process.exit(2);
}
const [cmd, ...args] = process.argv.slice(sep + 1);

const { bin, argv } = buildCageArgv({
  image: process.env.CAGE_IMAGE,
  network: process.env.CAGE_NETWORK,
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
