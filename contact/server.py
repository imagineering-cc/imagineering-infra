"""Minimal contact form email relay.

Accepts POST with name/email/message, sends via SMTP, redirects back.
Zero dependencies — stdlib only.
"""

import os
import sys
import smtplib
import threading
from email.message import EmailMessage
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs

SMTP_HOST = os.environ["SMTP_HOST"]
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USERNAME = os.environ["SMTP_USERNAME"]
SMTP_PASSWORD = os.environ["SMTP_PASSWORD"]
SMTP_FROM = os.environ.get("SMTP_FROM_EMAIL", "noreply@imagineering.cc")
CONTACT_TO = os.environ.get("CONTACT_TO", "langer.robin@gmail.com")
SITE_URL = os.environ.get("SITE_URL", "https://imagineering.cc")
MAX_BODY = 10 * 1024  # 10 KB


def _send_email(msg, sender_email, sender_name):
    """Send email in a background thread."""
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as smtp:
            smtp.starttls()
            smtp.login(SMTP_USERNAME, SMTP_PASSWORD)
            smtp.send_message(msg)
        print(f"Sent email from {sender_email} ({sender_name})", file=sys.stderr)
    except Exception as exc:
        print(f"SMTP error: {exc}", file=sys.stderr)


class ContactHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        # Reject oversized bodies
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            self._respond(ok=False)
            return

        body = self.rfile.read(length).decode("utf-8")
        fields = parse_qs(body, max_num_fields=10)

        # Honeypot — if filled, a bot submitted it
        if fields.get("_honey", [""])[0]:
            self._respond(ok=True)
            return

        name = fields.get("name", [""])[0].strip()
        email = fields.get("email", [""])[0].strip()
        message = fields.get("message", [""])[0].strip()

        if not all([name, email, message]):
            self._respond(ok=False)
            return

        msg = EmailMessage()
        msg["From"] = SMTP_FROM
        msg["To"] = CONTACT_TO
        msg["Reply-To"] = email
        msg["Subject"] = f"New enquiry from imagineering.cc — {name}"
        msg.set_content(
            f"Name: {name}\n"
            f"Email: {email}\n\n"
            f"{message}"
        )

        # Send in background so the user gets an instant redirect
        threading.Thread(target=_send_email, args=(msg, email, name)).start()
        self._respond(ok=True)

    def do_GET(self):
        """Health check on GET, 405 otherwise."""
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(405)
            self.end_headers()

    def _respond(self, ok=True):
        """JSON for fetch, redirect for plain form POST."""
        if "application/json" in (self.headers.get("Accept", "")):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", SITE_URL)
            self.end_headers()
            status = "sent" if ok else "error"
            self.wfile.write(f'{{"status":"{status}"}}'.encode())
        else:
            query = "?sent=1" if ok else "?error=1"
            self.send_response(303)
            self.send_header("Location", f"{SITE_URL}{query}")
            self.end_headers()

    def log_message(self, fmt, *args):
        """Log to stderr (Docker captures this)."""
        print(f"[contact] {fmt % args}", file=sys.stderr)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    server = HTTPServer(("0.0.0.0", port), ContactHandler)
    print(f"Contact form relay listening on :{port}", file=sys.stderr)
    server.serve_forever()
