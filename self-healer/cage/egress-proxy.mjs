// egress-proxy — the cage's single hostname-allowlist gate.
//
// The caged codegen agent runs on an `--internal` Docker network with NO direct
// egress and NO external DNS. The ONLY name it can resolve+reach on that network
// is this proxy. So every byte the agent sends to the outside world passes this
// one CONNECT check. The allowlist below IS the egress security boundary — keep
// it a literal, glanceable set, never a regex or a wildcard.
//
// Design choices that ARE the security property:
//   - CONNECT-only. We tunnel TLS (we never see plaintext, never MITM). Plain
//     HTTP proxy requests (GET http://…) are REFUSED — there is no plaintext
//     egress path to bypass the allowlist with.
//   - Allowlist by EXACT host (optionally a leading-dot suffix for a known
//     subdomain family). No substring/regex matching — `evil-github.com` must
//     not match `github.com`.
//   - Port allowlist (443 only by default). No exfil over an arbitrary port.
//   - Fail CLOSED: anything not explicitly allowed → 403, connection closed.
//
// The proxy itself sits on a network WITH egress (so it can resolve + reach the
// allowlisted hosts) AND on the internal network (so the agent can reach it).

import net from 'node:net';
import http from 'node:http';

const PORT = Number.parseInt(process.env.CAGE_PROXY_PORT ?? '3128', 10);

/** Allowed CONNECT ports. TLS only by default — no plaintext, no odd ports. */
const ALLOW_PORTS = new Set(
  (process.env.CAGE_ALLOW_PORTS ?? '443').split(',').map((p) => p.trim()).filter(Boolean),
);

/**
 * Exact-host allowlist. An entry beginning with "." is a suffix match for that
 * subdomain family (".github.com" allows api.github.com AND codeload.github.com
 * but NOT evilgithub.com). Everything else must match the host EXACTLY.
 *
 * Supplied at deploy via CAGE_ALLOW_HOSTS (comma-separated). No default set here
 * on purpose: an unconfigured proxy allows NOTHING (fail closed), so a misdeploy
 * can't silently open egress.
 */
const ALLOW_HOSTS = (process.env.CAGE_ALLOW_HOSTS ?? '')
  .split(',')
  .map((h) => h.trim().toLowerCase())
  .filter(Boolean);

/** True iff `host` is on the allowlist by exact match or dotted-suffix family. */
export function hostAllowed(host, allow = ALLOW_HOSTS) {
  const h = String(host).toLowerCase();
  for (const entry of allow) {
    if (entry.startsWith('.')) {
      // ".github.com" allows "github.com" and "*.github.com", nothing else.
      if (h === entry.slice(1) || h.endsWith(entry)) return true;
    } else if (h === entry) {
      return true;
    }
  }
  return false;
}

function log(...a) { process.stderr.write(`[egress-proxy] ${a.join(' ')}\n`); }

const server = http.createServer((req, res) => {
  // Any non-CONNECT request is a plaintext proxy attempt — refuse it. There is
  // no plaintext egress path; the agent must use HTTPS through CONNECT.
  res.writeHead(403, { 'content-type': 'text/plain' });
  res.end('egress-proxy: plaintext proxying disabled; CONNECT (https) only\n');
  log('REFUSED plaintext', req.method, req.url ?? '');
});

server.on('connect', (req, clientSocket, head) => {
  // req.url for a CONNECT is "host:port".
  const [host, portStr] = String(req.url).split(':');
  const port = portStr ?? '443';

  if (!hostAllowed(host) || !ALLOW_PORTS.has(port)) {
    log('DENY', `${host}:${port}`);
    clientSocket.write('HTTP/1.1 403 Forbidden\r\n\r\negress-proxy: host not on allowlist\r\n');
    clientSocket.destroy();
    return;
  }

  // Allowed: open the upstream tunnel and splice the two sockets together. We
  // never inspect or alter the tunneled bytes (it's TLS) — only the destination.
  const upstream = net.connect(Number(port), host, () => {
    log('ALLOW', `${host}:${port}`);
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  const kill = (why) => { log('tunnel closed', `${host}:${port}`, why ?? ''); upstream.destroy(); clientSocket.destroy(); };
  upstream.on('error', (e) => kill(`upstream:${e.code || e.message}`));
  clientSocket.on('error', (e) => kill(`client:${e.code || e.message}`));
});

// Run only when invoked directly (not when imported by the unit test).
if (process.argv[1] && process.argv[1].endsWith('egress-proxy.mjs')) {
  server.listen(PORT, () => {
    log(`listening on :${PORT}`);
    log(`allow hosts: ${ALLOW_HOSTS.length ? ALLOW_HOSTS.join(', ') : '(none — fail closed)'}`);
    log(`allow ports: ${[...ALLOW_PORTS].join(', ')}`);
  });
}
