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

1. **v1 (this):** sensor → diagnose → read-only verdict. ✅
2. **amber ping:** post the verdict to a channel (Telegram/Discord) on amber+.
3. **green draft:** on a confident green finding, draft a fix PR (no merge).
4. **green auto:** behind an explicit flag, run the full green-tier loop
   (fix → cage-match → merge → deploy → re-sense to confirm the symptom is gone).

Each step is gated on the previous one being *observed correct in prod*, not
just coded. The cage is built before the monster.

## Known substrate facts (2026-06-22)

- `claude-shim` lives at `~/apps/claude-shim` **on OCI only** — not checked in
  anywhere (deployed by rsync). Versioning it is separate debt.
- Observed live: `tw-gremlin` logged `level:50 "worker connection closed
  unexpectedly"` then re-registered under a new LiveKit node ~66ms later — a
  self-healed node rotation, the canonical "error that isn't a problem".
- `embodied-dreamfinder` was logging `OpenAI Realtime mode ready`, i.e. the
  *deployed* DF is on OpenAI Realtime, not the Max-plan `claude-shim` brain —
  worth reconciling against the intended architecture.
