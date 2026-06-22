#!/usr/bin/env node
// healer.mjs — v1 entry point: sensor → diagnose → REPORT. Nothing else.
//
// ┌──────────────────────────────────────────────────────────────────────┐
// │ v1 IS READ-ONLY BY DESIGN. It does not open PRs, merge, deploy, or    │
// │ restart anything. It looks and it tells. The traffic-light tiers it   │
// │ assigns are the CONTRACT a future version will act on — but the       │
// │ classifier has to earn trust against real prod signals first.         │
// │ "Build the cage before you spawn the monster."                        │
// └──────────────────────────────────────────────────────────────────────┘

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { gatherSignals } from './sensor.mjs';
import { diagnose } from './diagnose.mjs';
import { isOnBox } from './host.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

const DOT = { green: '🟢', amber: '🟡', red: '🔴' };

function render(verdict, signals) {
  const lines = [];
  lines.push('');
  lines.push(`${DOT[verdict.overallTier] || '⚪'}  SELF-HEALER VERDICT — ${verdict.overallTier?.toUpperCase()}`);
  lines.push(`   ${verdict.summary}`);
  lines.push('');

  // Always show the liveness facts we sampled, so a clean verdict is auditable
  // (you can see WHAT was healthy, not just be told it was).
  lines.push('   sampled:');
  for (const s of signals) {
    const flag = !s.present ? '⚠ absent'
      : s.status.startsWith('NOT') ? '⚠ down'
        : s.restartCount > 0 ? `restarts=${s.restartCount}` : 'ok';
    lines.push(`     • ${s.name.padEnd(22)} ${s.status.padEnd(20)} ${flag}`);
  }
  lines.push('');

  const findings = verdict.findings || [];
  if (findings.length === 0) {
    lines.push('   ✔ no findings — clean bill of health.');
  } else {
    lines.push(`   ${findings.length} finding(s):`);
    for (const f of findings) {
      lines.push('');
      lines.push(`   ${DOT[f.tier] || '⚪'} [${f.tier}] ${f.container} — ${f.signature}` +
        `${f.selfRecovered ? ' (self-recovered)' : ''}  conf:${f.confidence}`);
      lines.push(`      diagnosis: ${f.diagnosis}`);
      if (f.evidence) lines.push(`      evidence:  ${f.evidence}`);
      lines.push(`      action:    ${f.proposedAction}`);
    }
  }
  lines.push('');
  lines.push('   (v1 is read-only — no remediation taken. See README for the autonomy roadmap.)');
  lines.push('');
  return lines.join('\n');
}

async function main() {
  const targetsPath = process.env.HEALER_TARGETS || join(HERE, '..', 'targets.json');
  const { targets } = JSON.parse(await readFile(targetsPath, 'utf8'));

  const mode = isOnBox() ? 'on-box' : `remote via ${process.env.HEALER_HOST}`;
  process.stderr.write(`[healer] sensing ${targets.length} containers (${mode})…\n`);

  const signals = await gatherSignals(targets);
  process.stderr.write('[healer] diagnosing via claude-shim…\n');

  const verdict = await diagnose(signals);

  // Human-readable to stderr; machine-readable verdict to stdout so the
  // healer can be piped into the (future) action stage or a monitor.
  process.stderr.write(render(verdict, signals));
  process.stdout.write(JSON.stringify({ ...verdict, sampledAt: new Date().toISOString(), signals }, null, 2) + '\n');

  // Exit code communicates tier to a cron/monitor without parsing JSON.
  process.exitCode = verdict.overallTier === 'red' ? 2
    : verdict.overallTier === 'amber' ? 1 : 0;
}

main().catch((err) => {
  process.stderr.write(`[healer] FAILED: ${err.message}\n`);
  process.exitCode = 3;
});
