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
import { gatherSignals, assertValidContainerName } from './sensor.mjs';
import { diagnose } from './diagnose.mjs';
import { isOnBox } from './host.mjs';
import { tierExitCode } from './tiers.mjs';
import { pingIfNoteworthy, sendNotify } from './notify.mjs';
import { draftIfActionable } from './draft.mjs';
import { autoFixIfActionable, formatAutoOutcome } from './auto.mjs';

/**
 * Load + validate the watch list. Fails CLOSED on a malformed config so a bad
 * targets file is caught at load — before any host command is built from it —
 * rather than crashing cryptically mid-run (cage-match PR #100).
 */
async function loadTargets(path) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(path, 'utf8'));
  } catch (e) {
    throw new Error(`could not read/parse targets file ${path}: ${e.message}`);
  }
  if (!parsed || !Array.isArray(parsed.targets) || parsed.targets.length === 0) {
    throw new Error(`targets file ${path} must contain a non-empty "targets" array`);
  }
  for (const t of parsed.targets) {
    if (!t || typeof t.name !== 'string') throw new Error(`each target needs a string "name": ${JSON.stringify(t)}`);
    assertValidContainerName(t.name);
  }
  return parsed.targets;
}

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
  const targets = await loadTargets(targetsPath);

  const mode = isOnBox() ? 'on-box' : `remote via ${process.env.HEALER_HOST}`;
  process.stderr.write(`[healer] sensing ${targets.length} containers (${mode})…\n`);

  const signals = await gatherSignals(targets);
  process.stderr.write('[healer] diagnosing via claude-shim…\n');

  const verdict = await diagnose(signals);

  // Human-readable to stderr; machine-readable verdict to stdout so the
  // healer can be piped into the (future) action stage or a monitor.
  process.stderr.write(render(verdict, signals));
  process.stdout.write(JSON.stringify({ ...verdict, sampledAt: new Date().toISOString(), signals }, null, 2) + '\n');

  // amber-ping: notify Nick via the `notify` proxy when the verdict is amber
  // or red. Green and unconfigured (no NOTIFY_API_KEY) environments are silent.
  // A ping FAILURE must not change the diagnostic exit code (the verdict stands
  // either way) — surface it on stderr and carry on.
  try {
    const { pinged, reason } = await pingIfNoteworthy(verdict);
    process.stderr.write(pinged ? '[healer] amber-ping sent.\n' : `[healer] no ping (${reason}).\n`);
  } catch (err) {
    process.stderr.write(`[healer] amber-ping FAILED (verdict still stands): ${err.message}\n`);
  }

  // green-draft: file a remediation ISSUE for confident-green actionable
  // findings. OFF by default (HEALER_DRAFT_ISSUES=1). Never code/merge/deploy.
  // Like the ping, a failure here must not change the diagnostic exit code.
  try {
    const outcomes = await draftIfActionable(verdict);
    for (const o of outcomes) {
      process.stderr.write(`[healer] draft ${o.action}: ${o.container}${o.url ? ` → ${o.url}` : ''}${o.detail ? ` (${o.detail})` : ''}\n`);
    }
  } catch (err) {
    process.stderr.write(`[healer] green-draft FAILED (verdict still stands): ${err.message}\n`);
  }

  // green-auto: the FIRST stage that runs a codegen agent, fully caged. SHIPPED
  // OFF (HEALER_GREEN_AUTO=1) and additionally gated on on-box + a repo-scoped
  // token + a provisioned cage + an agent command — it spawns NOTHING until an
  // operator wires all five. Like the ping/draft, a failure here must not change
  // the diagnostic exit code (the verdict stands either way).
  try {
    const outcomes = await autoFixIfActionable(verdict);
    for (const o of outcomes) {
      process.stderr.write(`[healer] green-auto ${o.action}: ${o.container}${o.workdir ? ` [${o.workdir}]` : ''}${o.detail ? ` (${o.detail})` : ''}\n`);
      // Lifecycle ping (Increment C): "PR opened" carries the link + the exact
      // "merge #N" reply the approve listener accepts; a stumble flags for a look.
      // The orchestrator (NOT the caged agent — it has no egress to notify) sends it.
      // A notify failure must never change the diagnostic exit code, so each send is
      // isolated: an error here is logged, not thrown.
      const msg = formatAutoOutcome(o);
      if (msg) {
        try { await sendNotify(msg); }
        catch (e) { process.stderr.write(`[healer] green-auto notify failed (non-fatal): ${e.message}\n`); }
      }
    }
  } catch (err) {
    process.stderr.write(`[healer] green-auto FAILED (verdict still stands): ${err.message}\n`);
  }

  // Exit code communicates tier to a cron/monitor without parsing JSON.
  // verdict.overallTier is already validated to the closed set in diagnose().
  process.exitCode = tierExitCode(verdict.overallTier);
}

main().catch((err) => {
  process.stderr.write(`[healer] FAILED: ${err.message}\n`);
  process.exitCode = 3;
});
