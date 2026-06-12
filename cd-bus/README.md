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
| `GET` | `/events/:service` | — | SSE stream; replays the last retained event on connect unless `Last-Event-ID` proves it was already seen |

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
echo "<token>" | wrangler secret put PUBLISH_TOKEN   # publish auth (prod)
BASE=https://cd-bus.nick-meinhold.workers.dev PUBLISH_TOKEN=<token> ./smoke-test.sh
```

## Implementation notes

- **Don't `await` writes to the SSE TransformStream before returning the
  Response.** Its readable side has `highWaterMark: 0`, so a pre-return
  `await writer.write()` deadlocks (no reader attached yet → write never
  resolves → the DO `fetch()` never returns → no headers). Writes are
  fire-and-forget with `.catch()` reaping dead connections.
- **Heartbeat** via DO alarm every 25s pings open clients and reaps the dead;
  it reschedules only while subscribers remain, so an idle channel is free.
- **Last-event retention** is persisted to DO storage, surviving eviction.

## Hardening backlog (pilot → production)

- `/events` is currently **public-read** — anyone can watch deploy events
  (image names, shas, cadence; no secrets, but info-leaky). Add a subscribe
  token or restrict before fleet rollout.
- Move off `*.workers.dev` to `cd-bus.imagineering.cc` (Cloudflare custom
  domain + DNS) once past pilot.
