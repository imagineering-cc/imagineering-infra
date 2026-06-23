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
import dns from 'node:dns/promises';

const PORT = Number.parseInt(process.env.CAGE_PROXY_PORT ?? '3128', 10);

/** Max concurrent CONNECT tunnels + per-socket idle timeout. A subverted agent
 * must not be able to exhaust the proxy's fds/memory by holding open tunnels
 * (cage-match PR #111, Maxwell F4 + Carnot). The agent's own container has pid/
 * mem caps; the proxy is a separate process, so it caps itself here. */
const MAX_TUNNELS = Number.parseInt(process.env.CAGE_PROXY_MAX_CONN ?? '64', 10);
const IDLE_MS = Number.parseInt(process.env.CAGE_PROXY_IDLE_MS ?? '30000', 10);
let activeTunnels = 0;

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

/**
 * Strictly parse a CONNECT authority ("host:port") into {host, port}, or null if
 * it isn't exactly one host and one decimal port (cage-match PR #111, Carnot).
 * Handles a bracketed IPv6 literal ("[2606:::]:443"). Rejects empty host, missing
 * or non-decimal or out-of-range port, and any extra structure. A loose parse is
 * a loose door latch on the one gate that matters.
 * @param {string} url
 * @returns {{host: string, port: number}|null}
 */
export function parseConnectAuthority(url) {
  const s = String(url);
  let host; let portStr;
  if (s.startsWith('[')) {
    const close = s.indexOf(']');
    if (close === -1 || s[close + 1] !== ':') return null;
    host = s.slice(1, close);
    portStr = s.slice(close + 2);
  } else {
    const i = s.lastIndexOf(':');
    if (i === -1) return null; // a port is mandatory for CONNECT
    host = s.slice(0, i);
    portStr = s.slice(i + 1);
    if (host.includes(':')) return null; // bare (unbracketed) IPv6 / multiple colons → reject
  }
  if (!host || !/^[0-9]+$/.test(portStr)) return null;
  const port = Number(portStr);
  if (port < 1 || port > 65535) return null;
  return { host, port };
}

/**
 * True if `ip` is NOT a globally-routable public address the proxy may connect to
 * (cage-match PR #111, Maxwell F2 SSRF + Carnot re-review). This is an ALLOWLIST,
 * not a denylist-of-bad-ranges — a hand-rolled denylist is a sieve (the first cut
 * missed fe80::/10 beyond fe80:, plus v6 multicast and v4 reserved/multicast).
 *
 *  - IPv6: forbidden UNLESS it's in global unicast 2000::/3 (first nibble 2 or 3).
 *    That single rule rejects loopback (::1), unspecified (::), link-local
 *    (fe80::/10 — ALL of fe80–febf), ULA (fc00::/7), site-local (fec0::/10),
 *    multicast (ff00::/8), and everything else non-global in one shot.
 *  - IPv4: forbidden if in any special-use block (loopback, RFC1918, link-local
 *    incl. cloud metadata, CGNAT, this-network, multicast 224/4, reserved 240/4,
 *    benchmarking 198.18/15, the TEST-NET/doc/protocol 192.0.0/24 family).
 *  - IPv4-mapped IPv6 (::ffff:a.b.c.d) is normalized to its IPv4 tail first.
 *
 * Without this, an allowlisted host that resolves to an internal IP would let the
 * agent reach internal targets THROUGH the proxy (the one process with egress).
 * @param {string} ip  a resolved numeric address
 */
export function isForbiddenAddress(ip) {
  const a = String(ip).toLowerCase();
  const mapped = a.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  const v4 = mapped ? mapped[1] : (/^\d+\.\d+\.\d+\.\d+$/.test(a) ? a : null);
  if (v4) {
    const [o0, o1] = v4.split('.').map(Number);
    if (o0 === 0) return true; // 0.0.0.0/8 "this network" / unspecified
    if (o0 === 10) return true; // RFC1918
    if (o0 === 127) return true; // loopback
    if (o0 === 100 && o1 >= 64 && o1 <= 127) return true; // CGNAT 100.64/10
    if (o0 === 169 && o1 === 254) return true; // link-local incl. cloud metadata
    if (o0 === 172 && o1 >= 16 && o1 <= 31) return true; // RFC1918
    if (o0 === 192 && o1 === 0) return true; // 192.0.0/24 protocol assignments + 192.0.2/24 TEST-NET-1
    if (o0 === 192 && o1 === 168) return true; // RFC1918
    if (o0 === 198 && (o1 === 18 || o1 === 19)) return true; // 198.18/15 benchmarking
    if (o0 === 198 && o1 === 51) return true; // 198.51.100/24 TEST-NET-2
    if (o0 === 203 && o1 === 0) return true; // 203.0.113/24 TEST-NET-3
    if (o0 >= 224) return true; // 224/4 multicast + 240/4 reserved + 255.255.255.255
    return false;
  }
  // IPv6: allow ONLY global unicast 2000::/3. The first hextet of a global-unicast
  // address is 2000–3fff, i.e. its first hex nibble is 2 or 3. Everything else is
  // non-global (link-local/ULA/multicast/loopback/unspecified) → forbidden.
  const first = a.replace(/^\[/, '')[0];
  return !(first === '2' || first === '3');
}

function log(...a) { process.stderr.write(`[egress-proxy] ${a.join(' ')}\n`); }

const server = http.createServer((req, res) => {
  // Any non-CONNECT request is a plaintext proxy attempt — refuse it. There is
  // no plaintext egress path; the agent must use HTTPS through CONNECT.
  res.writeHead(403, { 'content-type': 'text/plain' });
  res.end('egress-proxy: plaintext proxying disabled; CONNECT (https) only\n');
  log('REFUSED plaintext', req.method, req.url ?? '');
});

function deny(clientSocket, why, detail) {
  log('DENY', why, detail ?? '');
  clientSocket.write(`HTTP/1.1 403 Forbidden\r\n\r\negress-proxy: ${why}\r\n`);
  clientSocket.destroy();
}

server.on('connect', async (req, clientSocket, head) => {
  const parsed = parseConnectAuthority(req.url);
  if (!parsed) { deny(clientSocket, 'malformed CONNECT authority', String(req.url)); return; }
  const { host, port } = parsed;

  if (!hostAllowed(host) || !ALLOW_PORTS.has(String(port))) {
    deny(clientSocket, 'host/port not on allowlist', `${host}:${port}`);
    return;
  }

  if (activeTunnels >= MAX_TUNNELS) {
    deny(clientSocket, 'too many concurrent tunnels', `${activeTunnels}/${MAX_TUNNELS}`);
    return;
  }

  // SSRF guard: resolve the allowlisted name and refuse if ANY resolved address is
  // non-public — a hostname that answers with both a public and a private record is
  // a DNS-rebinding tell, so we taint the whole hostname rather than cherry-pick the
  // public record (cage-match PR #111, Carnot re-review). Connect to the VETTED IP
  // (not the name) so there's no resolve→check→connect TOCTOU.
  let addr;
  try {
    const got = await dns.lookup(host, { all: true });
    if (got.length === 0) { deny(clientSocket, 'host did not resolve', host); return; }
    const forbidden = got.find((g) => isForbiddenAddress(g.address));
    if (forbidden) { deny(clientSocket, 'host resolves to a non-public address', `${host} → ${forbidden.address}`); return; }
    addr = got[0];
  } catch (e) {
    deny(clientSocket, 'dns resolution failed', `${host}: ${e.code || e.message}`);
    return;
  }

  activeTunnels += 1;
  let closed = false;
  const upstream = net.connect(port, addr.address, () => {
    log('ALLOW', `${host}:${port}`, `→ ${addr.address}`, `(${activeTunnels}/${MAX_TUNNELS})`);
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  const kill = (why) => {
    if (closed) return;
    closed = true; activeTunnels -= 1;
    log('tunnel closed', `${host}:${port}`, why ?? '');
    upstream.destroy(); clientSocket.destroy();
  };
  // Idle timeout: a held-open-but-silent tunnel is reaped so it can't pin an fd.
  upstream.setTimeout(IDLE_MS, () => kill('upstream idle timeout'));
  clientSocket.setTimeout(IDLE_MS, () => kill('client idle timeout'));
  upstream.on('error', (e) => kill(`upstream:${e.code || e.message}`));
  clientSocket.on('error', (e) => kill(`client:${e.code || e.message}`));
  upstream.on('close', () => kill('upstream close'));
  clientSocket.on('close', () => kill('client close'));
});

// Run only when invoked directly (not when imported by the unit test).
if (process.argv[1] && process.argv[1].endsWith('egress-proxy.mjs')) {
  server.listen(PORT, () => {
    log(`listening on :${PORT}`);
    log(`allow hosts: ${ALLOW_HOSTS.length ? ALLOW_HOSTS.join(', ') : '(none — fail closed)'}`);
    log(`allow ports: ${[...ALLOW_PORTS].join(', ')}`);
  });
}
