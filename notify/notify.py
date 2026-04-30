#!/usr/bin/env python3
"""Tiny Telegram notify proxy.

Accepts authed POSTs and forwards to the Telegram Bot API. Built so remote
scheduled agents (claude.ai routines, GitHub Actions, etc.) can send Nick a
Telegram message via a single curl call without holding the bot token themselves.

Endpoints:
  GET  /health                  -> 200 {"ok": true}
  POST /send                    -> forwards to Telegram sendMessage
       Header: Authorization: Bearer <NOTIFY_API_KEY>
       Body:   {"message": "...", "parse_mode": "HTML"|"MarkdownV2"|null,
                "chat_id": "<override>"} (chat_id optional)

All secrets come from env vars:
  TELEGRAM_BOT_TOKEN  - bot token from @BotFather
  TELEGRAM_CHAT_ID    - default chat to send to
  NOTIFY_API_KEY      - shared secret clients must present in Bearer auth
  PORT                - listen port (default 8090)
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_ID = os.environ["TELEGRAM_CHAT_ID"]
API_KEY = os.environ["NOTIFY_API_KEY"]
PORT = int(os.environ.get("PORT", "8090"))


class NotifyHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", file=sys.stderr, flush=True)

    def _reply(self, status, body):
        body_b = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_b)))
        self.end_headers()
        self.wfile.write(body_b)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[len("Bearer "):] != API_KEY:
            self._reply(401, {"error": "unauthorized"})
            return
        if self.path != "/send":
            self._reply(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length).decode() or "{}")
        except json.JSONDecodeError:
            self._reply(400, {"error": "invalid json"})
            return
        message = payload.get("message")
        if not message:
            self._reply(400, {"error": "missing 'message' field"})
            return
        tg_payload = {
            "chat_id": payload.get("chat_id", CHAT_ID),
            "text": message,
        }
        parse_mode = payload.get("parse_mode", "HTML")
        if parse_mode:
            tg_payload["parse_mode"] = parse_mode
        if payload.get("disable_notification"):
            tg_payload["disable_notification"] = True

        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data=json.dumps(tg_payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                tg_body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            tg_body = {"ok": False, "error": f"telegram http {e.code}: {e.read().decode()[:200]}"}
        except Exception as e:
            self._reply(502, {"error": f"telegram api error: {e}"})
            return
        self._reply(200 if tg_body.get("ok") else 502, tg_body)


if __name__ == "__main__":
    print(f"notify listening on 0.0.0.0:{PORT}", file=sys.stderr, flush=True)
    HTTPServer(("0.0.0.0", PORT), NotifyHandler).serve_forever()
