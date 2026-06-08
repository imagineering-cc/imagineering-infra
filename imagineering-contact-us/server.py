"""Minimal contact form email relay.

Accepts POST with name/email/message, sends via SMTP, redirects back.
Zero dependencies — stdlib only.

Abuse controls (added after the 2026-06-08 form-flood incident, where a bot
fired ~800 submissions and exhausted the shared Brevo SMTP quota):
  * Origin/Referer allowlist  — rejects header-less direct-POST bots
  * Per-IP sliding-window rate limit
  * Global daily send cap      — circuit breaker protecting the Brevo quota
  * Honeypot field (pre-existing)

These run *upstream* of Brevo on purpose: Brevo can't distinguish this abuse
from legitimate notifications (same trusted recipients, valid DKIM/SPF from our
own domain), so the only place to stop it is here, before a send is issued.
"""

import os
import sys
import time
import smtplib
import threading
from collections import deque
from email.message import EmailMessage
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

SMTP_HOST = os.environ["SMTP_HOST"]
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USERNAME = os.environ["SMTP_USERNAME"]
SMTP_PASSWORD = os.environ["SMTP_PASSWORD"]
SMTP_FROM = os.environ.get("SMTP_FROM_EMAIL", "noreply@imagineering.cc")
CONTACT_TO = os.environ.get("CONTACT_TO", "langer.robin@gmail.com")
SITE_URL = os.environ.get("SITE_URL", "https://imagineering.cc")
MAX_BODY = 10 * 1024  # 10 KB

# --- Abuse controls (all tunable via env) ---
# Per-IP: at most RATE_MAX successful-shaped submissions per RATE_WINDOW seconds.
RATE_MAX = int(os.environ.get("RATE_MAX", "3"))
RATE_WINDOW = int(os.environ.get("RATE_WINDOW", "3600"))  # 1 hour
# Global: hard ceiling on sends per rolling 24h — protects the Brevo quota even
# under a distributed (many-IP) flood.
GLOBAL_DAILY_MAX = int(os.environ.get("GLOBAL_DAILY_MAX", "50"))
# Require the request to originate from our own site. Set ENFORCE_ORIGIN=0 to
# disable (e.g. for curl-based testing).
ENFORCE_ORIGIN = os.environ.get("ENFORCE_ORIGIN", "1") == "1"
# Allowed origins, comma-separated. Defaults to SITE_URL + its apex/www variants.
_default_origins = ",".join(
    {
        SITE_URL,
        SITE_URL.replace("https://www.", "https://"),
        SITE_URL.replace("https://", "https://www."),
    }
)
ALLOWED_ORIGINS = tuple(
    o.strip().rstrip("/")
    for o in os.environ.get("ALLOWED_ORIGINS", _default_origins).split(",")
    if o.strip()
)


class RateLimiter:
    """In-memory sliding-window limiter — per-IP and a global daily cap.

    Stdlib-only and thread-safe. State is per-process (the relay is a single
    container), so a restart resets the windows — acceptable for a nuisance
    control whose job is to blunt bursts, not to be a distributed quota.
    """

    def __init__(self, per_ip_max, per_ip_window, global_max, global_window=86400):
        self._per_ip_max = per_ip_max
        self._per_ip_window = per_ip_window
        self._global_max = global_max
        self._global_window = global_window
        self._ip_hits = {}              # ip -> deque[timestamps]
        self._global_hits = deque()     # timestamps across all IPs
        self._lock = threading.Lock()

    @staticmethod
    def _prune(dq, now, window):
        while dq and now - dq[0] > window:
            dq.popleft()

    def check_and_record(self, ip, now=None):
        """Return (allowed: bool, reason: str). Records the hit if allowed."""
        now = now if now is not None else time.time()
        with self._lock:
            # Global cap first — cheapest guard against quota exhaustion.
            self._prune(self._global_hits, now, self._global_window)
            if len(self._global_hits) >= self._global_max:
                return False, "global-daily-cap"

            dq = self._ip_hits.get(ip)
            if dq is None:
                dq = deque()
                self._ip_hits[ip] = dq
            self._prune(dq, now, self._per_ip_window)
            if len(dq) >= self._per_ip_max:
                return False, "per-ip-rate"

            dq.append(now)
            self._global_hits.append(now)

            # Opportunistic memory hygiene: drop IPs whose windows have aged out.
            if len(self._ip_hits) > 10_000:
                stale = [k for k, v in self._ip_hits.items() if not v]
                for k in stale:
                    del self._ip_hits[k]

            return True, "ok"


limiter = RateLimiter(RATE_MAX, RATE_WINDOW, GLOBAL_DAILY_MAX)


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
    def _client_ip(self):
        """Real client IP. Behind Caddy, trust the first X-Forwarded-For hop."""
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def _origin_ok(self):
        """True if the request demonstrably came from our own site.

        Browsers send `Origin` on cross-/same-origin POSTs and `Referer` on
        classic form submits; scripted direct-POST bots typically send neither.
        Requiring one to match our allowlist blocks the header-less case for free.
        """
        if not ENFORCE_ORIGIN:
            return True
        origin = self.headers.get("Origin", "").rstrip("/")
        if origin:
            return origin in ALLOWED_ORIGINS
        referer = self.headers.get("Referer", "")
        if referer:
            p = urlparse(referer)
            base = f"{p.scheme}://{p.netloc}".rstrip("/")
            return base in ALLOWED_ORIGINS
        # Neither header present — not a real browser form submit.
        return False

    def do_POST(self):
        ip = self._client_ip()

        # Reject oversized bodies (drain so the socket closes cleanly).
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            print(f"[contact] reject oversized body from {ip}", file=sys.stderr)
            self._respond(ok=False)
            return

        # Origin/Referer allowlist — kills naive direct-POST bots.
        if not self._origin_ok():
            print(f"[contact] reject bad-origin from {ip}", file=sys.stderr)
            self._respond(ok=False, status=403)
            return

        body = self.rfile.read(length).decode("utf-8")
        fields = parse_qs(body, max_num_fields=10)

        # Honeypot — if filled, a bot submitted it. Pretend success, send nothing.
        if fields.get("_honey", [""])[0]:
            print(f"[contact] honeypot tripped from {ip}", file=sys.stderr)
            self._respond(ok=True)
            return

        name = fields.get("name", [""])[0].strip()
        email = fields.get("email", [""])[0].strip()
        message = fields.get("message", [""])[0].strip()

        if not all([name, email, message]):
            self._respond(ok=False)
            return

        # Rate limit — per-IP window + global daily cap — before we spend a send.
        allowed, reason = limiter.check_and_record(ip)
        if not allowed:
            print(f"[contact] rate-limited ({reason}) from {ip}", file=sys.stderr)
            self._respond(ok=False, status=429)
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

    def _respond(self, ok=True, status=None):
        """JSON for fetch, redirect for plain form POST.

        `status` overrides the HTTP code for the JSON path (e.g. 429/403) so
        callers can see *why* they were refused; the browser-redirect path keeps
        its 303 + ?error so a human just lands back on the page.
        """
        if "application/json" in (self.headers.get("Accept", "")):
            self.send_response(status or 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", SITE_URL)
            self.end_headers()
            payload = "sent" if ok else "error"
            self.wfile.write(f'{{"status":"{payload}"}}'.encode())
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
    print(
        f"Contact form relay listening on :{port} "
        f"(rate {RATE_MAX}/{RATE_WINDOW}s per IP, "
        f"global {GLOBAL_DAILY_MAX}/day, enforce_origin={ENFORCE_ORIGIN})",
        file=sys.stderr,
    )
    server.serve_forever()
