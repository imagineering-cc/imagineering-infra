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
      if ((request.headers.get("authorization") || "") !== `Bearer ${env.PUBLISH_TOKEN}`) {
        return json({ error: "unauthorized" }, 401);
      }
      let event;
      try { event = await request.json(); }
      catch { return json({ error: "body is not valid JSON" }, 400); }
      if (!event || typeof event.service !== "string" || event.service === "") {
        return json({ error: "event.service (non-empty string) is required" }, 400);
      }
      // Route to the per-service Durable Object and return its result verbatim.
      const stub = env.BUS.get(env.BUS.idFromName(event.service));
      return stub.fetch("https://do/publish", { method: "POST", body: JSON.stringify(event) });
    }

    // Service names: GHCR-image-name shaped (alnum, dot, underscore, hyphen).
    const m = url.pathname.match(/^\/events\/([A-Za-z0-9._-]+)$/);
    if (request.method === "GET" && m) {
      const stub = env.BUS.get(env.BUS.idFromName(m[1]));
      return stub.fetch("https://do/subscribe");
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
      const id = Date.now();
      await this.state.storage.put("last", { id, event });
      const frame = sseFrame(id, event);
      // Do NOT await the per-client writes: a TransformStream's readable side
      // has highWaterMark 0, so awaiting a write to a slow/backpressured client
      // would stall the whole fan-out. Fire-and-forget; reap on failure.
      const targets = [...this.sessions];
      for (const w of targets) {
        w.write(frame).catch(() => this.sessions.delete(w)); // dead connection, drop it
      }
      return json({ ok: true, service: event.service, delivered: targets.length });
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
      // host converges to current state without waiting for the next publish.
      const last = await this.state.storage.get("last");
      writer.write(last ? sseFrame(last.id, last.event) : enc(": connected\n\n"))
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
    // nothing.
    if (this.sessions.size > 0) {
      await this.state.storage.setAlarm(Date.now() + HEARTBEAT_MS);
    }
  }
}

const HEARTBEAT_MS = 25_000;
const encoder = new TextEncoder();
const enc = (s) => encoder.encode(s);
// SSE frame: `id:` enables Last-Event-ID resumption; `data:` carries the JSON.
const sseFrame = (id, event) => enc(`id: ${id}\ndata: ${JSON.stringify(event)}\n\n`);
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
