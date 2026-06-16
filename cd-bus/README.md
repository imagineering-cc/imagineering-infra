# cd-bus — Imagineering deploy-bus relay

Fans out `image.published` events from CI to OCI-host subscribers over **SSE**,
so a merge-to-main reaches the running container in ~seconds without the host
opening an inbound port. This is the keystone (component 2) of the deploy-bus.

> Full design + rationale: [The Imagineering Deploy Bus](https://outline.imagineering.cc/doc/the-imagineering-deploy-bus-qz9QscpP6Q)

**Deployed:** https://cd-bus.nick-meinhold.workers.dev (Cloudflare Worker + Durable Object)

## Routes

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/health` | — | liveness |
| `POST` | `/publish` | `Bearer $PUBLISH_TOKEN` | fan an event to subscribers of `event.service`; returns `subscribers` (attempted fan-out count — delivery is fire-and-forget). Fails closed (500) if the secret is unbound; `service` must match the same grammar as `/events/:service`. |
| `GET` | `/events/:service` | `Bearer $SUBSCRIBE_TOKEN` **when bound** | SSE stream; replays the last retained event on connect unless `Last-Event-ID` proves it was already seen. Auth is enforced **only when `SUBSCRIBE_TOKEN` is bound** — see "Locking down /events" below. |

**Token-compare is constant-time.** Both `/publish` and `/events` compare the
presented bearer token against the secret by HMAC'ing each side under a per-call
random key and comparing the fixed-length digests, so neither token length nor
the position of the first mismatch leaks through response timing.

**Why the auth asymmetry** (`/publish` fails closed when unbound, `/events`
falls open): an unauthenticated `/publish` would let anyone inject deploy events
— dangerous, so it must fail closed (500). An unauthenticated `/events` only
leaks event metadata (image names, shas, deploy cadence — no secrets), which is
the current accepted pilot state. Gating `/events` enforcement on the secret
being bound is what lets the lock-down deploy without a flag-day break.

One **Durable Object instance per service** (`idFromName(service)`) holds that
service's open SSE connections and its last-published event. The retained event
is replayed on (re)connect — unless the client sends a `Last-Event-ID` header
proving it already saw it (standard SSE resumption). This is the handshake that
lets the host's poll backstop and this push leg converge. Event ids are
monotonic (not bare timestamps), so id-based dedupe on the subscriber side is
safe even across same-millisecond publishes.

## Event shape

```json
{ "event": "image.published", "service": "downstream-server",
  "image": "ghcr.io/nickmeinhold/downstream-server", "sha": "sha-6a38cea",
  "digest": "sha256:…", "git_sha": "…", "run_url": "…" }
```
`service` is required; `digest` is what a subscriber pulls (deterministic).

## Develop / deploy

```bash
wrangler dev          # local — NOTE: SSE-over-DO does not stream under miniflare
                      # local dev; validate streaming against a real deploy.
wrangler deploy
echo "<token>" | wrangler secret put PUBLISH_TOKEN     # publish auth (prod)
echo "<token>" | wrangler secret put SUBSCRIBE_TOKEN   # subscribe auth (prod) — see lock-down runbook
BASE=https://cd-bus.nick-meinhold.workers.dev PUBLISH_TOKEN=<token> SUBSCRIBE_TOKEN=<token> ./smoke-test.sh
```

`SUBSCRIBE_TOKEN` is optional: bind it only when you are ready to lock down
`/events` (and have already taught every subscriber to send it). When it is
unset, `/events` is public (pilot mode) and the smoke test skips the
subscribe-auth assertions. When set, the smoke test sends it on `/events` reads
and asserts an unauthenticated read is rejected with 401.

## Implementation notes

- **Don't `await` writes to the SSE TransformStream before returning the
  Response.** Its readable side has `highWaterMark: 0`, so a pre-return
  `await writer.write()` deadlocks (no reader attached yet → write never
  resolves → the DO `fetch()` never returns → no headers). Writes are
  fire-and-forget with `.catch()` reaping dead connections.
- **Heartbeat** via DO alarm every 25s pings open clients and reaps the dead;
  it reschedules only while subscribers remain, so an idle channel is free.
- **Last-event retention** is persisted to DO storage, surviving eviction.

## Locking down /events (subscribe-auth rollout)

The worker already enforces `Bearer $SUBSCRIBE_TOKEN` on `/events` **when the
secret is bound** — so flipping it on is a coordinated, no-downtime sequence,
not a flag day. Do it in this order (otherwise live subscribers 401 and stop
deploying):

1. **Teach every subscriber to send the token first.** Add
   `-H "Authorization: Bearer $SUBSCRIBE_TOKEN"` to the SSE `curl` in each
   host's subscribe script (today: `nickmeinhold/downstream` `deploy/oci`'s
   `cd-bus-subscribe.sh`; later: the fleet template from claude-tasks #16), and
   put `SUBSCRIBE_TOKEN` in each host's subscriber env. Deploy that — it is a
   no-op while the worker is still unbound (the header is simply ignored).
2. **Bind the secret on the worker:** `echo "<token>" | wrangler secret put
   SUBSCRIBE_TOKEN`. Enforcement flips on at the next request.
3. **Verify** with the smoke test against the deploy:
   `BASE=… PUBLISH_TOKEN=… SUBSCRIBE_TOKEN=… ./smoke-test.sh` — it asserts an
   unauthenticated `/events` read now 401s and that an authenticated one still
   streams.

To roll back, `wrangler secret delete SUBSCRIBE_TOKEN` returns `/events` to
public (pilot) mode instantly.

## Hardening backlog (pilot → production)

- [x] **Constant-time token compare** on `/publish` (and `/events`) — done.
- [x] **Subscribe-auth on `/events`** — implemented as enforce-when-bound; flip
  on via the runbook above before fleet rollout (claude-tasks #16).
- [ ] **Custom domain** — move off `*.workers.dev` to `cd-bus.imagineering.cc`
  (Cloudflare custom domain + DNS; zone `1444f67680d10386df2a55e5f016e2b2`).
  Needs a `wrangler deploy` under Nick's Cloudflare OAuth + a DNS record, then
  update the announce job URL and every subscriber's `BUS_URL`. Deploy-gated;
  not in the worker source.
