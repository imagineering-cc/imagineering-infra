#!/usr/bin/env bash
# escape-probe.sh — THE GATE. Run on the production box. Spawns the real cage
# (via run-cage.mjs → cage.mjs) around each case in README.md's contract and
# asserts the MUST-FAIL escapes fail and the MUST-SUCCEED cases succeed.
#
# "Attempt the escape, expect failure" — a green flag list is NOT this. This is.
#
#   bash cage/escape-probe.sh
#
# Exit 0 iff every escape is blocked AND every legit path works. Any escape that
# succeeds → non-zero (the cage is broken OPEN — the unacceptable direction).
set -uo pipefail
cd "$(dirname "$0")"

PROXY_IMG=cage-egress-proxy:probe
PROBE_IMG=cage-probe:probe
NET_INT=cage-internal-probe
NET_EGR=cage-egress-probe
PROXY_NAME=cage-egress-proxy-probe
WORKDIR="$(mktemp -d /tmp/cage-workdir.XXXXXX)"
# The cage runs as a fixed non-root image uid (1000) which won't match the host
# user (nick is 1002), so make the THROWAWAY clone dir writable by it. In real
# green-auto the orchestrator chowns the fresh clone to the cage uid instead.
chmod 0777 "$WORKDIR"

# Allowlist for the probe: github is the "allowed" host; example.com is "forbidden".
ALLOW_HOSTS="api.github.com,.github.com"

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }

cleanup() {
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1
  docker network rm "$NET_INT" "$NET_EGR" >/dev/null 2>&1
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== build images ==="
docker build -q -f Dockerfile.proxy -t "$PROXY_IMG" . >/dev/null || { echo "proxy build failed"; exit 3; }
docker build -q -f Dockerfile.probe -t "$PROBE_IMG" . >/dev/null || { echo "probe build failed"; exit 3; }

echo "=== networks ==="
docker network create --internal "$NET_INT" >/dev/null
docker network create "$NET_EGR" >/dev/null

echo "=== start egress proxy (on BOTH nets: egress to reach allowlist, internal to be reachable) ==="
docker run -d --rm --name "$PROXY_NAME" \
  --network "$NET_EGR" \
  -e "CAGE_ALLOW_HOSTS=$ALLOW_HOSTS" \
  "$PROXY_IMG" >/dev/null
docker network connect "$NET_INT" "$PROXY_NAME"
sleep 1

export CAGE_IMAGE="$PROBE_IMG"
export CAGE_NETWORK="$NET_INT"
export CAGE_WORKDIR="$WORKDIR"
export CAGE_PROXY_URL="http://${PROXY_NAME}:3128"

# run a command in the cage, return its exit code
cage() { node run-cage.mjs -- "$@"; }

echo
echo "=== MUST FAIL (escapes — each must NOT succeed) ==="

# NOTE on curl exit codes: --fail makes curl return non-zero on an HTTP >= 400,
# so a proxy 403 (plaintext refused / host denied) counts as BLOCKED. Without it
# curl exits 0 on a 403 — it got a valid response — and a refusal reads as a reach.

# egress-forbidden: a non-allowlisted host, through the proxy → CONNECT denied
if cage curl -sS --fail --max-time 8 -o /dev/null https://example.com >/dev/null 2>&1; then
  bad "egress-forbidden: reached example.com (CAGE BROKEN OPEN)"
else
  ok "egress-forbidden: example.com blocked"
fi

# egress-metadata: cloud metadata is link-local (169.254/16). The real concern is
# whether the internal net can route to it DIRECTLY (no proxy) — an SSRF-grade
# escape. Bypass the proxy to test the network boundary itself.
if cage curl -sS --fail --max-time 6 --noproxy '*' -o /dev/null http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
  bad "egress-metadata: reached 169.254.169.254 directly (CAGE BROKEN OPEN — link-local routable)"
else
  ok "egress-metadata: metadata endpoint blocked"
fi

# egress-direct-ip: bypass the proxy and hit a public IP directly → no route
if cage curl -sS --fail --max-time 8 --noproxy '*' -o /dev/null https://1.1.1.1 >/dev/null 2>&1; then
  bad "egress-direct-ip: reached 1.1.1.1 directly (CAGE BROKEN OPEN — internal net leaks)"
else
  ok "egress-direct-ip: direct (proxy-bypass) egress blocked"
fi

# fs-host-secret: host secrets must not be visible inside the cage
if cage sh -c 'cat /etc/shadow' >/dev/null 2>&1; then
  bad "fs-host-secret: read /etc/shadow"
else
  ok "fs-host-secret: /etc/shadow not readable"
fi
if cage sh -c 'cat /home/nick/apps/self-healer.env' >/dev/null 2>&1; then
  bad "fs-host-secret: read host self-healer.env (HOST FS LEAKED IN)"
else
  ok "fs-host-secret: host self-healer.env not present"
fi

# fs-host-write: rootfs is read-only outside the workdir
if cage sh -c 'echo x > /etc/cage-pwned' >/dev/null 2>&1; then
  bad "fs-host-write: wrote /etc/cage-pwned (rootfs writable)"
else
  ok "fs-host-write: rootfs read-only (write rejected)"
fi

# priv-esc: sudo must be absent / non-functional
if cage sh -c 'command -v sudo && sudo -n id' >/dev/null 2>&1; then
  bad "priv-esc: sudo worked"
else
  ok "priv-esc: no sudo path"
fi
# running as non-root
uid="$(cage sh -c 'id -u' 2>/dev/null | tr -d '[:space:]')"
if [ "$uid" = "0" ] || [ -z "$uid" ]; then
  bad "priv-esc: running as uid='$uid' (want non-zero)"
else
  ok "priv-esc: non-root (uid=$uid)"
fi

# docker-escape: the docker socket must not be mounted
if cage sh -c 'test -S /var/run/docker.sock' >/dev/null 2>&1; then
  bad "docker-escape: /var/run/docker.sock present (daemon reachable)"
else
  ok "docker-escape: no docker socket"
fi

echo
echo "=== MUST SUCCEED (cage must not be uselessly tight) ==="

# allow-github: api.github.com THROUGH the proxy must work
if cage curl -sS --max-time 12 -o /dev/null -w '%{http_code}' https://api.github.com/zen 2>/dev/null | grep -qE '^(200|30.)$'; then
  ok "allow-github: api.github.com reachable via proxy"
else
  bad "allow-github: api.github.com NOT reachable via proxy (cage broken shut)"
fi

# workdir-rw: the clone workdir must be writable+readable
if cage sh -c 'echo hello > /work/probe.txt && cat /work/probe.txt' 2>/dev/null | grep -q hello; then
  ok "workdir-rw: /work writable+readable"
else
  bad "workdir-rw: /work not writable (cage broken shut)"
fi

echo
echo "=== RESULT: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
