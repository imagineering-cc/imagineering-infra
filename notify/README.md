# notify

Tiny Telegram notify proxy. Lets remote agents (claude.ai routines, GitHub Actions, cron jobs anywhere) send Nick Telegram messages via a single curl call without holding the bot token themselves.

**URL**: `https://notify.imagineering.cc`

## Why

Telegram bot tokens are sensitive — embedding them in every routine prompt or CI config means N copies of one secret. This service holds the token in one place, exposes a thin HTTP shim, and clients authenticate with a per-purpose API key that's much cheaper to rotate.

This is *not* an MCP server. It's a CLI/HTTP-style endpoint for fire-and-forget notifications. Heuristic: MCP is for "Claude needs to think with this service," CLI/HTTP is for "Claude needs to act on this service." Sending a notification is acting.

## Endpoints

```
GET  /health     -> 200 {"ok": true}
POST /send       -> forwards to Telegram sendMessage
```

### POST /send

```bash
curl -s -X POST https://notify.imagineering.cc/send \
  -H "Authorization: Bearer $NOTIFY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"message": "<b>Hello</b> from a remote agent"}'
```

Body:
```json
{
  "message": "...",                       // required
  "parse_mode": "HTML",                   // optional, default "HTML"; pass null to disable
  "chat_id": "...",                       // optional, override default chat
  "disable_notification": false           // optional, silent send
}
```

Response: Telegram's raw `sendMessage` response.

## Setup

```bash
# Encrypt secrets (one-time, with your age key in ~/.config/sops/age/keys.txt)
cp secrets.yaml.example secrets.yaml
# edit values, then:
sops -e -i secrets.yaml

# Deploy
./scripts/deploy-to.sh 149.118.69.221 notify
./scripts/deploy-to.sh 149.118.69.221 caddy   # to pick up the new route
```

## Local dev

```bash
TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... NOTIFY_API_KEY=test \
  python3 notify.py
# in another shell:
curl -s -X POST http://localhost:8090/send \
  -H "Authorization: Bearer test" \
  -H "Content-Type: application/json" \
  -d '{"message": "test"}'
```
