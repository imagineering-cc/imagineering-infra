# cd-bus fleet template — reactive CD for any OCI-host service

Generalises the proven `downstream-server` deploy-bus pilot
(`nickmeinhold/downstream` `deploy/oci`) into **one templated set of systemd
units + shared scripts** so any GHCR-built service gets push+poll CD by adding
an env file and enabling three units. The relay itself lives one level up in
[`../`](../README.md); this directory is the *subscriber* side.

> Full design + rationale: [The Imagineering Deploy Bus](https://outline.imagineering.cc/doc/the-imagineering-deploy-bus-qz9QscpP6Q)

## How it works (per service `%i`)

```
CI build ──image.published──▶ cd-bus relay ──SSE──▶ cd-bus-subscriber@%i ─┐
(announce step)              (Cloudflare Worker)                          ├─▶ /opt/cd-bus/deploy.sh %i
                                                  cd-poll@%i.timer (5min)─┘   (flock-serialised, idempotent
                                                  poll backstop                docker compose pull && up -d)
```

- **`cd-bus-subscriber@%i`** holds an outbound SSE connection and deploys on each event. Fast path (~seconds).
- **`cd-poll@%i.timer`** polls every 5 min — the backstop that catches anything the push misses.
- **`cd-bus-recover@%i.timer`** revives the subscriber if a sustained relay outage drove it to `failed` (so the fast leg can never die permanently silent).
- **`cd-bus-subscriber-alert@%i` / `cd-poll-alert@%i`** fire on real failure (Telegram, via `/opt/scripts/lib/telegram.sh`).

All legs run the **same** `deploy.sh` under a **per-service flock**: legs of one service serialise; different services deploy in parallel.

## Files

| File | Installs to | Role |
|---|---|---|
| `subscribe.sh` | `/opt/cd-bus/subscribe.sh` | SSE subscriber (one copy, all services) |
| `deploy.sh` | `/opt/cd-bus/deploy.sh` | the one deploy action every leg runs |
| `subscriber-alert.sh` / `poll-alert.sh` | `/opt/cd-bus/` | OnFailure Telegram handlers |
| `systemd/*@.service`, `*@.timer`, `*.d/` | `/etc/systemd/system/` | instance-unit templates |
| `common.env.example` | → `/etc/cd-bus/common.env` | shared `BUS_URL` + `SUBSCRIBE_TOKEN` |
| `install-shared.sh` | — | one-time host installer for the shared bits |

## One-time host setup

```bash
scp -r cd-bus/fleet nick@HOST:/tmp/cd-bus-fleet
ssh HOST 'cd /tmp/cd-bus-fleet && sudo ./install-shared.sh'
# Create the shared config (token must match the relay's bound SUBSCRIBE_TOKEN):
ssh HOST 'sudo install -d -o root -g nick -m 0750 /etc/cd-bus && \
  printf "SUBSCRIBE_TOKEN=%s\n" "<token>" | sudo tee /etc/cd-bus/common.env >/dev/null && \
  sudo chown root:nick /etc/cd-bus/common.env && sudo chmod 0640 /etc/cd-bus/common.env'
```

## Onboard a service (`<svc>` = its cd-bus channel name)

1. **Per-service env** (only if it deviates from the convention — `APP_DIR=/home/nick/apps/<svc>`, compose service name `= <svc>`):
   ```bash
   # /etc/cd-bus/<svc>.env  (root:nick 0640) — omit entirely if conventions hold
   APP_DIR=/home/nick/apps/<svc>
   COMPOSE_SERVICE=<svc>        # if the compose service name differs from <svc>
   ```
2. **CI announce step** in that service's build workflow, after the image is pushed (digest required — see the snippet below).
3. **Enable the units:**
   ```bash
   systemctl enable --now cd-bus-subscriber@<svc> \
                          cd-bus-recover@<svc>.timer \
                          cd-poll@<svc>.timer
   ```
4. **Verify:** `journalctl -u cd-bus-subscriber@<svc> -n 5` shows `subscribing to https://cd-bus.imagineering.cc/events/<svc>` and holds; a test merge logs `deploy ok`.

### CI announce snippet

Add to the build job (after build+push), generalised from the downstream pilot.
`BUS_PUBLISH_TOKEN` is a repo secret = the relay's bound `PUBLISH_TOKEN`.

```yaml
      - name: Announce image.published to the deploy bus
        if: github.ref == 'refs/heads/main'
        env:
          BUS_PUBLISH_TOKEN: ${{ secrets.BUS_PUBLISH_TOKEN }}
          DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          [ -n "$DIGEST" ] || { echo "::error::no image digest; not announcing"; exit 1; }
          curl -fsS -X POST https://cd-bus.imagineering.cc/publish \
            -H "Authorization: Bearer $BUS_PUBLISH_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$(jq -nc --arg service <svc> \
              --arg image ghcr.io/OWNER/<svc> --arg digest "$DIGEST" \
              '{event:"image.published",service:$service,image:$image,digest:$digest}')"
```

## Config reference (env, all optional)

| Var | Default | Where | Meaning |
|---|---|---|---|
| `BUS_URL` | `https://cd-bus.imagineering.cc` | common.env | relay base |
| `SUBSCRIBE_TOKEN` | (empty → public-pilot) | common.env | `/events` bearer; one token gates all channels |
| `APP_DIR` | `/home/nick/apps/<svc>` | <svc>.env | compose dir |
| `COMPOSE_SERVICE` | `<svc>` | <svc>.env | compose service name if it differs |
| `HEALTHY_MIN_SECS` | `60` | <svc>.env | hold ≥ this before a relay-closed stream is "healthy" |

## Candidate first services

`dreamfinder`, `img-contact`, `notify` (all GHCR-built). The `downstream-server`
pilot keeps its own `deploy/oci` copy for now; migrating it onto this template
is a later consolidation once the template has proven on a second service.

## Relationship to the pilot

This template is a faithful generalisation of the downstream pilot, with one
hardening applied (claude-tasks #20): `subscribe.sh` passes the bearer via a
`0600` header file (`curl -H @file`) instead of a `-H "Bearer …"` argument, so
the token never appears in the process table — it matters once a host runs more
than one service user.
