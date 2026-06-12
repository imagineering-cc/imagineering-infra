// CD Bus relay
// ============
// Fans out `image.published` events from CI to OCI-host subscribers over SSE,
// so a merge-to-main reaches the running container in ~seconds without the
// host ever opening an inbound port. Design + rationale:
// https://outline.imagineering.cc/doc/the-imagineering-deploy-bus-qz9QscpP6Q
//
// Routes:
//   POST /publish           Bearer PUBLISH_TOKEN. Body is the event JSON
//                           (must include `service`). Fans out to that
//                           service's subscribers; returns delivered count.
//   GET  /events/:service   SSE stream. Replays the last retained event on
//                           connect (the replay leg that complements the
//                           host's poll backstop), then streams live events.
//   GET  /health            Liveness.
//
// Secure by direction: this relay is the only internet-facing component. It
// holds nothing but the verify-side of PUBLISH_TOKEN, can only emit deploy
// events, and the host still only ever pulls named GHCR digests in response.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "cd-bus" });
    }

    if (request.method === "POST" && url.pathname === "/publish") {
      // Fail CLOSED when the secret is unbound (misdeploy / forgotten
      // `wrangler secret put`): without this guard the comparison below
      // would accept the literal header "Bearer undefined".
      if (typeof env.PUBLISH_TOKEN !== "string" || env.PUBLISH_TOKEN.length === 0) {
        return json({ error: "relay misconfigured: PUBLISH_TOKEN is not bound" }, 500);
      }
      if ((request.headers.get("authorization") || "") !== `Bearer ${env.PUBLISH_TOKEN}`) {
        return json({ error: "unauthorized" }, 401);
      }
      let event;
      try { event = await request.json(); }
      catch { return json({ error: "body is not valid JSON" }, 400); }
      // Same grammar as the /events route below — otherwise a publish to
      // "my/cool/image" succeeds but is impossible to subscribe to, and the
      // retained event replays a state no host will ever see.
      if (!event || typeof event.service !== "string" || !SERVICE_RE.test(event.service)) {
        return json({ error: "event.service must match [A-Za-z0-9._-]+" }, 400);
      }
      // digest, when present, is what subscribers deploy — reject junk at the
      // boundary rather than persisting it for replay.
      if ("digest" in event && typeof event.digest !== "string") {
        return json({ error: "event.digest must be a string when present" }, 400);
      }
      // Route to the per-service Durable Object and return its result verbatim.
      const stub = env.BUS.get(env.BUS.idFromName(event.service));
      return stub.fetch("https://do/publish", { method: "POST", body: JSON.stringify(event) });
    }

    // Service names: GHCR-image-name shaped (alnum, dot, underscore, hyphen).
    const m = url.pathname.match(/^\/events\/(.+)$/);
    if (request.method === "GET" && m && SERVICE_RE.test(m[1])) {
      const stub = env.BUS.get(env.BUS.idFromName(m[1]));
      // Forward headers so the DO can honor Last-Event-ID on reconnect.
      return stub.fetch(new Request("https://do/subscribe", { headers: request.headers }));
    }

    return json({ error: "not found" }, 404);
  },
};

// One instance per service (keyed by idFromName(service)). Durable Objects are
// single-threaded per instance, so the in-memory session Set needs no locking.
export class ServiceChannel {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sessions = new Set(); // active SSE writers for this service
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/publish") {
      const event = await request.json();
      // Persist the last event so a subscriber connecting after a DO eviction
      // (or after host downtime) still receives the most recent state. This is
      // the replay handshake between the push (SSE) and pull (poll) legs.
      //
      // The id is MONOTONIC, not just a timestamp: two publishes inside the
      // same millisecond must not mint the same id, because subscribers dedupe
      // replays by id — a collision would silently swallow the second event.
      const prev = await this.state.storage.get("last");
      const id = Math.max(Date.now(), (prev?.id ?? 0) + 1);
      await this.state.storage.put("last", { id, event });
      const frame = sseFrame(id, event);
      // Do NOT await the per-client writes: a TransformStream's readable side
      // has highWaterMark 0, so awaiting a write to a slow/backpressured client
      // would stall the whole fan-out. Fire-and-forget; reap on failure.
      const targets = [...this.sessions];
      for (const w of targets) {
        w.write(frame).catch(() => this.sessions.delete(w)); // dead connection, drop it
      }
      // `subscribers`, not `delivered`: writes are fire-and-forget, so this
      // counts attempted fan-out targets — actual delivery is unobservable here.
      return json({ ok: true, service: event.service, subscribers: targets.length });
    }

    if (url.pathname === "/subscribe") {
      const { readable, writable } = new TransformStream();
      const writer = writable.getWriter();
      this.sessions.add(writer);

      // Build the response FIRST and return it without awaiting any write. The
      // TransformStream readable side has highWaterMark 0, so awaiting a write
      // before a reader attaches would deadlock (the reader only attaches once
      // this Response is handed back to the runtime). Fire writes async.
      const response = new Response(readable, {
        headers: {
          "content-type": "text/event-stream; charset=utf-8",
          "cache-control": "no-cache, no-transform",
          "x-accel-buffering": "no",
        },
      });

      // Replay the last retained event immediately, so a freshly (re)connected
      // host converges to current state without waiting for the next publish —
      // UNLESS the client proves it already saw it via Last-Event-ID (standard
      // SSE resumption; the worker route forwards request headers through).
      const last = await this.state.storage.get("last");
      const seenId = request.headers.get("last-event-id");
      const replay = last && String(last.id) !== seenId;
      writer.write(replay ? sseFrame(last.id, last.event) : enc(": connected\n\n"))
        .catch(() => this.sessions.delete(writer));

      // Heartbeat keeps the connection warm through proxies and lets us reap
      // dead writers; a subscriber that cannot hold the stream becomes a
      // failed systemd unit on the host, which is alertable (the observability
      // win — a dead deployer is loud, not silent).
      await this.armHeartbeat();

      return response;
    }

    return json({ error: "not found" }, 404);
  }

  async armHeartbeat() {
    if ((await this.state.storage.getAlarm()) === null) {
      await this.state.storage.setAlarm(Date.now() + HEARTBEAT_MS);
    }
  }

  async alarm() {
    const frame = enc(`: ping ${Date.now()}\n\n`);
    for (const w of [...this.sessions]) {
      w.write(frame).catch(() => this.sessions.delete(w)); // non-blocking; reap dead
    }
    // Reschedule only while someone is listening, so an idle channel costs
    // nothing. Because reaping happens in async .catch() handlers, the size
    // check can race one tick behind reality — worst case is a single extra
    // "ghost" alarm 25s later that finds zero sessions and stops. Bounded,
    // accepted.
    if (this.sessions.size > 0) {
      await this.state.storage.setAlarm(Date.now() + HEARTBEAT_MS);
    }
  }
}

const HEARTBEAT_MS = 25_000;
// One grammar for service names on BOTH the publish and subscribe sides —
// GHCR-image-name shaped. Asymmetry here would let events be published into
// channels no subscriber can reach.
const SERVICE_RE = /^[A-Za-z0-9._-]+$/;
const encoder = new TextEncoder();
const enc = (s) => encoder.encode(s);
// SSE frame: `id:` enables Last-Event-ID resumption; `data:` carries the JSON.
const sseFrame = (id, event) => enc(`id: ${id}\ndata: ${JSON.stringify(event)}\n\n`);
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
