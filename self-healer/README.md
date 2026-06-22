# self-healer

An in-prod log-reading operator for the Tech World stack. It reads production
container signals, asks a Max-plan Claude brain (via `claude-shim`) what's
wrong, and emits a structured **traffic-light verdict**.

> **v1 is read-only.** It looks and it tells. It does **not** open PRs, merge,
> deploy, or restart anything. That is deliberate — see *Autonomy roadmap*.

## Why it exists

We kept running the same loop by hand: notice a prod symptom → read OCI docker
logs → diagnose → fix → cage-match → merge → deploy → verify. Every primitive
for automating it already exists on the box (`docker logs`, the `claude-shim`
Max-plan inference service, `gh`, `deploy-to.sh`). The self-healer is that
loop, pointed at prod logs instead of a human's attention.

It's the **dual of the integration harness** (`tech_world` #531): the harness
feeds *synthetic* input and asserts runtime behaviour *pre-prod*; the healer
reads *organic* runtime and works back to cause *in-prod*. Both terminate their
claims in actual runtime state — which is the point.

## Architecture

```
docker logs + inspect ──► sensor.mjs ──► diagnose.mjs ──► claude-shim ──► verdict
 (liveness + log tails)                  (POST /chat)     (localhost:8088)
```

- **`src/host.mjs`** — the one primitive. Runs a command "on the host":
  directly when deployed on OCI, or over SSH when `HEALER_HOST` is set. Both
  the log reads *and* the shim call go through it, because `claude-shim` binds
  to `127.0.0.1:8088` only and is reachable solely from the box.
- **`src/sensor.mjs`** — gathers `Status`, `RestartCount`, and log tails per
  container. RestartCount is the one unambiguous crash-loop signal.
- **`src/prompt.mjs`** — the brain's system prompt + output contract. Encodes
  the traffic-light tiers and the **classify-by-sequence-not-severity** rule.
- **`src/diagnose.mjs`** — POSTs the bundle to `claude-shim` (asks for a
  stronger model than its haiku default) and parses the JSON verdict.
- **`src/healer.mjs`** — orchestrates and renders. Read-only.

## Run it

From a dev laptop (reaches OCI over SSH — needs your SSH access to the box):

```bash
HEALER_HOST=nick@149.118.69.221 node src/healer.mjs
# or: npm run diagnose:remote
```

Deployed on the OCI box (no SSH hop; talks to localhost shim directly):

```bash
node src/healer.mjs
```

Human-readable report goes to **stderr**; the machine-readable JSON verdict
goes to **stdout** (pipe it into a monitor or the future action stage). Exit
code encodes the worst tier: `0`=green, `1`=amber, `2`=red, `3`=healer error.

### Environment

| Var            | Default                        | Meaning                                   |
| -------------- | ------------------------------ | ----------------------------------------- |
| `HEALER_HOST`  | *(empty = on-box)*             | `user@host` to SSH through for dev        |
| `SHIM_URL`     | `http://127.0.0.1:8088/chat`   | claude-shim endpoint (host-local)         |
| `HEALER_MODEL` | `sonnet`                       | model the shim runs for diagnosis         |
| `HEALER_TARGETS` | `./targets.json`             | watch-list path                           |

## The traffic-light leash

Every finding gets a tier. The tier is the contract a *future* version acts on:

| Tier      | Examples                                        | Eventual autonomy                          |
| --------- | ----------------------------------------------- | ------------------------------------------ |
| 🟢 green  | self-recovered reconnect, log typo, null-guard  | auto: diagnose→fix→cage-match→merge→deploy |
| 🟡 amber  | wire-format / state-lifecycle / multi-file fix  | do the work, **ping a human before merge** |
| 🔴 red    | auth, Caddy/TLS, credentials, DB migration      | diagnose + **draft only**, never self-ship |

Misclassifying red→green is a disaster; green→red is merely annoying. The brain
is told: when unsure, pick the higher tier and lower confidence.

## Autonomy roadmap (NOT yet built)

v1 stops at the verdict on purpose — the classifier must earn trust against
real prod signals before any hands are wired. In order:

1. **v1:** sensor → diagnose → read-only verdict. ✅
2. **amber ping:** notify on amber+ via the `notify` proxy. ✅ (still read-only)
3. **green draft:** file a remediation *issue* for a confident-green finding. ✅
   (the first ACTION stage — bounded blast radius: issue, never code/merge/deploy)
4. **green auto:** behind an explicit flag, run the full green-tier loop
   (fix → cage-match → merge → deploy → re-sense to confirm the symptom is gone).

Each step is gated on the previous one being *observed correct in prod*, not
just coded. The cage is built before the monster.

### green-draft (the first action stage)

When a finding is **confident green with a concrete proposedAction**, the healer
files a remediation issue in that container's source repo. This is the smallest
real outward action with bounded blast radius — it files an **issue**, never
code; it never opens a PR, merges, or deploys.

- **OFF by default.** Set `HEALER_DRAFT_ISSUES=1` to enable. The action stage
  exists but must be explicitly switched on.
- **No shell.** Issues are created via the GitHub API (`fetch` + token), so
  there's none of the command-injection surface a `gh` shell-out would add.
  Token from `HEALER_GH_TOKEN` (or `GITHUB_TOKEN`/`GH_TOKEN`); needs `issues:write`.
- **Reconcile-before-mutate dedup, fail-CLOSED.** Before filing, it lists the
  repo's open `self-healer` issues (paginated) and checks for the finding's
  fingerprint marker (`<!-- self-healer-fp: … -->`). If that read *fails* (403,
  rate-limit, 5xx), it does **not** file — for a write stage, "can't confirm
  it's not a duplicate" means don't write. Container→repo map in `repos.mjs`; an
  unmapped container is skipped, never guessed.
- **Content-safe.** All issue text is scrubbed (`scrubSecrets`), length-capped,
  and @mentions are neutralized so attacker-influenced log content can't leak a
  secret, ping people, or run unbounded.

> ⚠️ **Dedup is best-effort, not exclusive.** It reduces duplicates but does not
> *guarantee* their absence: GitHub's List Issues API is eventually-consistent
> (a few seconds of read-after-write lag, verified live), and the check-then-
> create sequence has no atomic lock. For a minutes-spaced cron this is robust;
> two near-simultaneous runs could double-file. A real single-writer/lock is a
> prerequisite before any higher-stakes action stage (e.g. auto-merge) reuses
> this pattern.

> The **auto-code-writing PR** (an LLM patching source from a log diagnosis) is
> the real "monster" — a prompt-injection-into-codegen surface — and is a
> deliberately separate, cage-built step. green-draft is its safe precursor.

### amber-ping

When a verdict is amber or red, the healer sends Nick a Telegram message. It
does **not** hold a bot token or build a Telegram path — it POSTs to the
existing `notify` proxy (`https://notify.imagineering.cc/send`, a public HTTPS
endpoint), so this is a plain `fetch` with no shell/SSH surface.

- **Still read-only.** A ping is a notification, not a remediation.
- **Best-effort secret scrubbing** (`scrubSecrets`) — the model's diagnosis
  could quote a credential-bearing log line. A prefix denylist alone is a sieve,
  so it's *layered*: known prefixes (anthropic/github/slack/google/openai/
  stripe/brevo/aws/JWT/PEM) + a `key=value` redactor for sensitive key names +
  a high-entropy catch-all for any 32+ char opaque token (the floor preserves
  shorter diagnostic IDs like LiveKit's ~24-char nodeIds). Leak-side
  conservative: over-redaction in an outbound message is cheap; a leak is not.
  Only verdict fields (summary + findings) are sent — never the raw
  `signals`/log tails. Dynamic text is HTML-escaped (all five metacharacters).
- **Cooldown (default ON, escalation-aware).** A persistently-amber signal is
  re-pinged at most once per `HEALER_COOLDOWN_MIN` (default 60) — but a *new*
  problem or a *tier escalation* (different fingerprint) pings immediately, and
  the same problem re-pings as an hourly reminder once the window lapses. State
  in `HEALER_STATE_DIR/last-ping.json`; degrades OPEN (a state-file failure
  pings anyway — missing a real alert is worse than a duplicate). Set
  `HEALER_COOLDOWN_MIN=0` to disable.
- **Silent when it should be:** green verdicts and environments without a
  `NOTIFY_API_KEY` are no-ops, so a dev run never errors and a clean bill never
  spams. `HEALER_NO_PING=1` force-disables.
- **`NOTIFY_URL` is validated** to https (or loopback http) so an env-poisoned
  URL can't redirect the Bearer key to an attacker over cleartext.
- **Config:** `NOTIFY_API_KEY` (required to send), `NOTIFY_URL` (default the
  public proxy), `HEALER_COOLDOWN_MIN`, `HEALER_STATE_DIR`, `HEALER_NO_PING`.

## Security posture (v1)

"Read-only intent" is not "harmless" — command injection on the prod host is
RCE regardless of what the tool is *for*. The cage-match (PR #100) hardened the
string boundaries:

- **Shell interpolation is validated, not assumed.** The only values that reach
  a shell string are container names (allowlisted to Docker's
  `[a-zA-Z0-9][a-zA-Z0-9_.-]*` grammar at config load) and `SHIM_URL` (parsed +
  required to be a loopback `http://` URL). The big JSON body goes via stdin,
  never the command line.
- **The verdict fails CLOSED.** Tiers are a validated closed set; `overallTier`
  is *derived* from the per-finding tiers, not trusted from the model. An
  off-set or missing tier throws (exit 3) rather than silently becoming green.
- **Log content is framed as untrusted data** to the brain (prompt-injection),
  and the code-side schema validation means the model cannot redefine the
  contract even if a log line tries to. This framing is the *gate* on the
  green-auto roadmap step: the action stage must never treat the LLM verdict as
  authority without an independent guardrail.

Residual (named tradeoff): the remote path still composes a command string run
through the SSH login shell. With the two interpolation points validated this
is closed for v1's inputs; a fully typed argv primitive (`ssh host -- bash -s`
with data on a separate channel) is the v2 hardening if the input set grows.

## Known substrate facts (2026-06-22)

- `claude-shim` lives at `~/apps/claude-shim` **on OCI only** — not checked in
  anywhere (deployed by rsync). Versioning it is separate debt.
- Observed live: `tw-gremlin` logged `level:50 "worker connection closed
  unexpectedly"` then re-registered under a new LiveKit node ~66ms later — a
  self-healed node rotation, the canonical "error that isn't a problem".
- `embodied-dreamfinder` was logging `OpenAI Realtime mode ready`, i.e. the
  *deployed* DF is on OpenAI Realtime, not the Max-plan `claude-shim` brain —
  worth reconciling against the intended architecture.
