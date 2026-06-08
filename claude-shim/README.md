# claude-shim

A tiny HTTP front door to **Max-plan headless Claude Code** for callers that
live in OCI containers. It turns "call Claude" into "call the Max plan at zero
marginal cost" by spawning `claude -p` under the hood, instead of hitting the
metered Anthropic API.

## Why it exists

Two callers on the OCI box need Claude inference but were paying per-token (or
failing on a zero API balance):

- **embodied-dreamfinder's voice brain** — was 400-erroring when the Anthropic
  credit balance hit zero.
- **the in-prod log-reading self-healer** (diagnosis stage) — wants Claude to
  read a log window and propose a fix.

Both need the same thing: *run Claude on the Max plan from this box*. This
service is that one shared artifact.

## The one gate: mint an OAuth token

Headless Claude Code authenticates via `CLAUDE_CODE_OAUTH_TOKEN` (same as
`claudius`). Mint it once, on the Max account you want these calls billed
against:

```bash
claude setup-token      # interactive OAuth; prints a long-lived token
```

Put the token in `.env` on the host (copy from `.env.example`):

```
CLAUDE_CODE_OAUTH_TOKEN=<token>
```

> **Quota note:** the account that mints the token owns the weekly turn budget
> these calls consume. `claudius` already burns one Max account on this box
> (its logs showed ~305/500 weekly). Decide whether the shim shares that
> account or gets its own — a chatty voice agent can move the needle.

## Contract

```
POST /chat
  body: { "system": "...", "messages": [{ "role": "user", "content": "..." }], "model": "haiku" }
  200:  { "text": "..." }
  4xx/5xx: { "error": "..." }

GET /health -> { "ok": true }
```

Callers keep their own conversation history and send the full `messages` array
each turn; the shim is stateless. `system` and `model` are optional (`model`
defaults to `haiku` to preserve DF's latency profile).

## Deploy

```bash
./scripts/deploy-to.sh 149.118.69.221 claude-shim
```

claude-shim **builds from its Dockerfile** (it isn't a published image), so the
generic `deploy-to.sh` case — which does `docker compose pull` — won't work as
is. Add a build case alongside the other build services (e.g. `notify`,
`imagineering-contact-us`):

```sh
claude-shim)
    rsync -avz --delete --exclude '.env' "$REPO_ROOT/claude-shim/" "$REMOTE":~/apps/claude-shim/
    ssh "$REMOTE" "cd ~/apps/claude-shim && docker compose build && docker compose up -d"
    ;;
```

(The `.env` is provisioned on the host out-of-band and excluded from rsync.)

## Verify

After the token is in place and the container is up:

```bash
# from the host
curl -s 127.0.0.1:8088/health
curl -s 127.0.0.1:8088/chat \
  -H 'content-type: application/json' \
  -d '{"system":"You are terse.","messages":[{"role":"user","content":"reply with exactly: PONG"}]}'
# -> {"text":"PONG"}  (note the wall-clock — first call is cold)
```

From another container on the `imagineering` network, the URL is
`http://claude-shim:8088/chat`.

## Consumers

- `embodied-dreamfinder` — set `DF_BRAIN=maxplan` and `CLAUDE_SHIM_URL=http://claude-shim:8088`.
- the healer (future) — same endpoint, a stronger `model` per request for diagnosis.
