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
| `SHIM_HTTP_TIMEOUT_MS` | `150000`               | curl `--max-time` for the shim call; outer SIGKILL is this + 10s |

> **Timeout chain.** The ceilings are monotonic from the inside out —
> `claude generation < shim (SHIM_TIMEOUT_MS, default 180s on the box) < curl
> --max-time (SHIM_HTTP_TIMEOUT_MS, default 200s) < runOnHost SIGKILL (+10s)` —
> so a too-slow diagnosis fails on the shim with a clean "claude timed out"
> rather than `curl exit 28` discarding an answer the shim already produced.
> Keep `SHIM_HTTP_TIMEOUT_MS` above the shim's `SHIM_TIMEOUT_MS`. (Observed live:
> a 93s sonnet verdict for 4 containers — the old hardcoded 90s curl ceiling
> threw it away; and on 2026-07-13 the whole chain moved 120→180 / 150→200 after
> back-to-back nightly timeouts left the 4-container sonnet diagnosis, measured
> at 96s, with under 4s of headroom against the old 120s wall.)

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
4. **green auto:** behind an explicit flag, run the green-tier remediation agent
   inside the cage. **Scaffolded + SHIPPED OFF** (`src/auto.mjs`) — see below.

Each step is gated on the previous one being *observed correct in prod*, not
just coded. The cage is built before the monster.

### green-auto (the caged action stage — built, OFF, not yet enabled)

`src/auto.mjs` is the orchestrator for the first stage that runs the **monster** —
a codegen agent that writes a fix from a log diagnosis. It does not relax any
earlier guarantee; it **routes** each eligible finding through the already-proven
cage (`cage/run-cage.mjs`, gated by `cage/escape-probe.sh`), never around it, and
enforces the one boundary the OS cage can't: that the agent's GitHub authority is
**bounded to the single target repo**.

It mirrors `green-draft` exactly — same `actionableFindings` filter, same
fingerprint, same single-box owner-fenced lock — with the cage swapped in for the
GitHub-issue POST. Its outcome reports the **cage run**, never a merged fix; the
PR / cage-match / merge / deploy happen (eventually) inside/after the caged agent,
bounded by the repo-scoped token and the cage-match on the resulting PR.

**Five independent fail-closed gates, ALL required before a single spawn:**

| # | Gate | Env / condition | Why |
| - | ---- | --------------- | --- |
| 1 | feature flag | `HEALER_GREEN_AUTO=1` | OFF by default |
| 2 | on-box | `HEALER_HOST` unset | the cage is a host-local Docker primitive — refuse remote runs rather than pretend |
| 3 | **bounded authority** | `HEALER_GREEN_AUTO_TOKEN` set **and distinct** from the broad host token | the agent gets a repo-scoped token, never the healer's org-wide one |
| 4 | cage substrate | `HEALER_CAGE_IMAGE` / `HEALER_CAGE_NETWORK` / `HEALER_CAGE_PROXY_URL` | the proven cage must exist to spawn into |
| 5 | agent command | `HEALER_CAGE_AGENT_CMD` | the codegen "monster" is operator-installed, never hardcoded |

> ⚠️ **DO NOT enable green-auto until a repo-scoped token bounds authority.**
> Gate 3 is the *enforced* form of `cage/README.md`'s "Credential scope" contract:
> the orchestrator structurally refuses to hand the agent the broad host token.
> **Named residual:** distinct-from-broad guarantees a *dedicated* token; it does
> not by itself prove the token is fine-grained-scoped to exactly one repo — that
> narrowing is the operator's provisioning responsibility (a fine-grained PAT / App
> installation token for the one repo). An online control-repo reachability probe
> to verify the bound is tracked as follow-up.

The token rides into the cage as `CAGE_GH_TOKEN` (→ `GH_TOKEN`/`GITHUB_TOKEN`
inside the container) via `run-cage.mjs`'s bounded forward allowlist — **key-only
(`-e GH_TOKEN`, no value), so the secret never enters the `docker run` argv / host
`ps`**; the finding context rides as scrubbed+capped `CAGE_AGENT_*` vars;
`HOME=/work` is set for the agent. Nothing else crosses, and the proxy routing is
appended LAST so none of it can clobber egress.

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

## Security posture (v2)

"Read-only intent" is not "harmless" — command injection on the prod host is
RCE regardless of what the tool is *for*. PR #100 hardened the string boundaries
by *validating* every interpolated value; the v2 hardening (#46a/#46c) makes
injection **structurally impossible** rather than validated-away, so the safety
no longer depends on per-input regexes that stop scaling as the command set
grows (the green-auto roadmap step).

- **Typed-argv host primitive (`runOnHostScript`).** Untrusted values
  (container name, `SHIM_URL`, `--max-time`) are no longer interpolated into a
  shell string. They are passed as **positional arguments to a FIXED script**:
  - *on-box:* `spawn('bash', ['-c', SCRIPT, '_', ...args])` — bash binds the
    args to `$1,$2…` positionally; they are never part of the script text, so
    the local shell can't parse them as code.
  - *remote (ssh):* ssh has **no argv channel** — it space-joins its entire
    trailing argv into ONE string that the **remote login shell re-parses**.
    This breaks naive positional passing two ways: (1) the script (which
    contains `;` and spaces) would be split, so `_ arg…` never reaches the inner
    `bash -c` and `$1,$2…` bind to **empty** (the PR #109 bug); and (2) an
    unescaped untrusted value could re-open injection at the second parse. So we
    compose the remote command ourselves as `bash -c '<script>' _ <b64> <b64>…`:
    the developer-controlled **script is single-quoted** (`shSingleQuote`) so it
    survives as ONE `-c` argument and the positionals bind, and **every
    untrusted arg is base64-encoded** (alphabet `[A-Za-z0-9+/=]` has no shell
    metacharacters, so each is one inert word needing no quoting) and
    base64-DECODEd inside the fixed script. `base64 -d` runs on the OCI box in
    both paths, so **one fixed script serves on-box and remote**. The big JSON
    body still goes via stdin, never the command line. The remote path is
    covered by a wire-re-tokenization test AND a live `ssh localhost` round-trip
    asserting `$1` actually binds.
  - `runOnHost(cmdString)` is retained for fixed/trusted command strings; the
    self-healer's own untrusted-input call sites (sensor, diagnose) all use the
    typed primitive.
- **Collision-proof sensor framing.** The sensor splits inspect-output from log
  tails on a boundary marker. That marker is now a **random per-call nonce**
  (`crypto.randomBytes`), not a static sentinel — attacker-controlled log content
  cannot predict or forge it, so a log line can't spoof the meta↔logs boundary.
  (We still split on the first occurrence as belt-and-braces.)
- **Shim-timeout floor (#50).** The healer can't see the shim's own
  `SHIM_TIMEOUT_MS` (120s on the box). `resolveHttpTimeouts` now clamps the
  effective curl `--max-time` UP to at least 120s (warning on stderr when it
  does), so a too-small `SHIM_HTTP_TIMEOUT_MS` can't silently recreate the
  deploy-#49 bug (curl killing an answer the shim is still producing).
- **The verdict fails CLOSED.** Tiers are a validated closed set; `overallTier`
  is *derived* from the per-finding tiers, not trusted from the model. An
  off-set or missing tier throws (exit 3) rather than silently becoming green.
- **Log content is framed as untrusted data** to the brain (prompt-injection),
  and the code-side schema validation means the model cannot redefine the
  contract even if a log line tries to. This framing is the *gate* on the
  green-auto roadmap step: the action stage must never treat the LLM verdict as
  authority without an independent guardrail.

Defence-in-depth retained: the container-name allowlist and the loopback
`SHIM_URL` check still run — they're no longer the *sole* injection gate, but
they encode true invariants (Docker name grammar; shim is loopback-only) and
fail fast on misconfiguration.

## Known substrate facts (2026-06-22)

- `claude-shim` is versioned in this repo at `claude-shim/` (source + Dockerfile
  + compose + SOPS `secrets.yaml`) and deploys via
  `./scripts/deploy-to.sh 149.118.69.221 claude-shim`, which rsyncs it to
  `~/apps/claude-shim` on OCI and `docker compose build && up -d`. Non-secret
  config (e.g. `SHIM_TIMEOUT_MS`) lives in the compose `environment:` block; only
  the OAuth token is generated into `.env` from `secrets.yaml` at deploy time.
  (This corrects an earlier note that claimed it was rsync-only / not in git.)
- Observed live: `tw-gremlin` logged `level:50 "worker connection closed
  unexpectedly"` then re-registered under a new LiveKit node ~66ms later — a
  self-healed node rotation, the canonical "error that isn't a problem".
- `embodied-dreamfinder` was logging `OpenAI Realtime mode ready`, i.e. the
  *deployed* DF is on OpenAI Realtime, not the Max-plan `claude-shim` brain —
  worth reconciling against the intended architecture.
