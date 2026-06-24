# green-auto cage — the boundary contract

> **Status: boundary spec + escape probe.** The cage is the *prerequisite* to
> turning on green-auto. green-auto itself (the codegen agent that writes a fix →
> opens a PR → cage-match → auto-merge) is **not enabled** until the escape probe
> below passes on the production box. *Build the cage before you spawn the monster.*

## What is being caged, and why

green-auto's worker is a **headless `claude -p` codegen agent with tool
permissions** (it edits files, runs `git`, runs `gh`). It is spawned from a
*log diagnosis*, so its entire input is **attacker-influenceable**:

- a malicious container log line → became the self-healer's `diagnosis`/`evidence`
  (the `green-draft` issue body is built from exactly these fields);
- the target repo's own source — which the agent reads to write its patch — can
  carry prompt-injection aimed at the agent.

So the threat is a **prompt-injection-into-codegen** surface with **write + network
capability**. The mechanism (the model, the prompt, the tool-loop) is *not* the
boundary. The boundary is: *even if the agent is fully subverted mid-run, what can
it touch?* The cage's job is to make that answer "only its own throwaway clone and
two allowlisted hosts" — and to **prove it by attempting the escape**, never by
reading a config.

## Mechanism (box-grounded — see ADR below)

An ephemeral Docker container:

| Property | Flag | Boundary it enforces |
|---|---|---|
| non-root | **`--user 1000:1000` (forced by the cage, NOT the image)** | no host-uid authority, regardless of image hygiene |
| no new privileges | `--security-opt=no-new-privileges` | setuid/sudo can't escalate |
| drop all caps | `--cap-drop=ALL` | no raw sockets, mount, ptrace, … |
| read-only rootfs | `--read-only` | host fs (in-image) immutable |
| only the clone is writable | a single **rw bind-mount of the fresh host clone** at `/work` (+ a `noexec,nosuid` `/tmp` tmpfs) | writes can't leave the workdir |
| no docker socket | (never mounted) | can't control the daemon / sibling containers |
| ephemeral | `--rm` + a fresh clone dir per run | nothing persists across runs |
| pid / mem caps | `--pids-limit`, `--memory`, `--cpus` | a fork/alloc bomb can't take the box |
| **egress denied** | `--network <internal>` — **verified `Internal=true` at spawn** (`run-cage.mjs` refuses a non-internal net) | **kernel-level: no direct off-box route, no external DNS** |
| **egress allowlisted** | `HTTPS_PROXY → egress-proxy` | the proxy CONNECTs only to the named hosts, and only to **public** resolved IPs (SSRF guard) |

`/work` is a **bind-mount of a fresh single-repo clone on the host**, chowned to the
cage uid by the orchestrator (the host user is uid 1002, the cage is 1000). It is
the only writable reservoir connected to the host. The cage prevents *host escape*;
it does **not** stop the agent executing the (malicious) code it generates *inside*
that clone — that's the codegen threat, bounded by the repo-scoped token + the
cage-match on the resulting PR, not by this OS boundary.

Seccomp/AppArmor: the cage relies on Docker's **default** seccomp + AppArmor
profiles (not loosened, not custom-tightened). Stated explicitly so it's a
conscious reliance, not an unexamined default.

Egress is **layered**: the internal network denies *all* direct egress (verified:
`curl https://example.com` → "Could not resolve host"); the only reachable name on
that network is the **egress-proxy**, which forwards CONNECT **only** to an explicit
host allowlist. A denylist is a sieve; this is allow-by-exact-host.

## The contract — what the escape probe asserts

Run `cage/escape-probe.sh` **on the production box**. It spawns the real cage around
each case below. The probe is the gate; a green ruleset grep is **not**.

### MUST FAIL (the escapes — each asserts non-success)

| id | attempt | expected |
|---|---|---|
| `egress-forbidden` | `curl https://example.com` (a non-allowlisted host) | blocked (proxy denies CONNECT) |
| `egress-metadata` | `curl --noproxy http://169.254.169.254/…` (cloud metadata, direct) | blocked (link-local unrouted) |
| `egress-direct-ip` | `curl --noproxy https://1.1.1.1` (public IP, *bypassing the proxy*) | blocked (only the proxy has egress) |
| `egress-ipv6` | `curl --noproxy https://[2606:4700:4700::1111]` (direct IPv6) | blocked (no v6 escape) |
| `egress-gateway` | `curl --noproxy http://172.17.0.1` (docker bridge gateway) | blocked (internal net has no gateway) |
| `egress-host-internal` | `curl --noproxy http://host.docker.internal` | blocked (never `--add-host`ed) |
| `fs-host-secret` | read the OAuth token / `self-healer.env` / `/etc/shadow` / `~/.ssh` | not present (never mounted) |
| `fs-host-write` | write outside the workdir (`/`, `/etc`, another path) | read-only → EROFS |
| `priv-esc` | a **root** image, then `sudo` / `id -u` | cage's `--user` forces non-root despite a root image |
| `docker-escape` | reach `/var/run/docker.sock` | not present |
| `self-defense` | run the cage on a non-`--internal` network | `run-cage.mjs` refuses to spawn (exit 3) |

The `priv-esc` case deliberately uses a **root** probe image (`Dockerfile.probe` sets no `USER`): if the image were non-root, the test would prove the image, not the cage. Starting from root, only the cage's `--user` can make `id -u` non-zero.

### MUST SUCCEED (or the cage is uselessly tight — each asserts success)

| id | attempt | expected |
|---|---|---|
| `allow-inference` | reach the inference brain **through the proxy** | 2xx/expected |
| `allow-github` | reach `api.github.com` **through the proxy** | 2xx |
| `workdir-rw` | write+read a file in the clone workdir | ok |
| `token-forward` | with `CAGE_GH_TOKEN` set, `$GITHUB_TOKEN`/`$GH_TOKEN` inside the cage match it | forwarded (the agent can auth) |
| `token-not-leaked` | with `CAGE_GH_TOKEN` **unset**, no GitHub token in the cage env | absent (no stray credential) |

A cage that fails an escape-FAIL case is **broken open** (the dangerous direction).
A cage that fails a MUST-SUCCEED case is **broken shut** (green-auto can't work, but
it's safe) — fix forward, never relax an escape gate to make a success case pass.

## Known residuals (named, not hidden)

- **Writable `HOME` for the real agent.** `--read-only` + only `/work`/`/tmp`
  writable means a real `claude -p` (writes `~/.claude`) and `git` (writes
  `$HOME`) will fail until the orchestrator gives the agent a writable HOME
  (`HOME=/work`, or a small tmpfs). The probe used `alpine sh`, which needs none.
  Owned by the orchestrator/real-image PR. *Broken-shut, not broken-open.*
- **Same-subnet host bridge IP.** The probe proves the *default* bridge gateway
  (`172.17.0.1`) and `host.docker.internal` are unreachable, but does not yet
  probe the internal network's *own* in-subnet gateway IP. Docker binds no host
  services to an internal bridge by default, so there's nothing there today;
  flagged as the next probe to add if any host service is ever bound to it.
- **Inference host in the allowlist.** The allowlist is only as strong as its
  entries. The inference endpoint added alongside GitHub must not be an open
  redirect / SSRF-amplifier / surprisingly-CDN-fronted host. The resolved-IP
  guard blocks *internal* targets but not a *public* open-proxy.

## Credential scope (boundary, partly outside the OS cage)

The GitHub token handed to the agent MUST be scoped to the **one** target repo
(fine-grained PAT / installation token), so a fully-subverted agent that *does* open
a malicious PR still cannot reach another repo. The OS cage bounds *reachability*;
the token scope bounds *authority*. Both are required.

**Now partly enforced (`src/auto.mjs` gate 3, `boundedAuthority`).** The green-auto
orchestrator refuses to spawn unless `HEALER_GREEN_AUTO_TOKEN` is set AND **distinct
from the healer's broad host token** (`HEALER_GH_TOKEN`/`GITHUB_TOKEN`/`GH_TOKEN`) —
so the agent can never receive the org-wide token. The token reaches the cage only
as `CAGE_GH_TOKEN`, forwarded by `run-cage.mjs` into `GH_TOKEN`/`GITHUB_TOKEN` inside
the container (alongside `HOME=/work` and the scrubbed `CAGE_AGENT_*` task context;
nothing else). **Residual (named, not enforced):** distinct-from-broad guarantees a
*dedicated* token, not that it is *fine-grained-scoped to exactly one repo* — that
narrowing is the operator's provisioning duty. A control-repo reachability probe
(reach a forbidden repo with the token, expect 404/403) to verify the bound online
is the next gate to add.

## ADR — why Docker, not bwrap/systemd (deviates from the original plan)

The original plan named *bwrap sandbox user + systemd confinement + egress filter*.
Verified on the box (`149.118.69.221`, Ubuntu 24.04 aarch64):

- **bwrap is absent** (so is firejail). It would need an `apt install` (host
  mutation) and still **can't allowlist egress** — only all-or-nothing
  `--unshare-net`; the agent needs *some* network (inference + GitHub).
- **systemd's `IPAddressDeny`/`DynamicUser`** (the egress filter + sandbox uid)
  require the **system** manager = **root**. The healer cron runs as **`nick`
  (non-root)**; `systemd-run --user` does *not* support those properties.
- **Docker is already the box's delegated-confinement primitive** — `nick` is in
  the `docker` group and the shim, claudius, and DF are all caged this way. It
  delivers every property in the table above with **no new sudo and no new
  package**, and matches the existing claude-shim cage precedent.

Net: Docker is the production-substrate-correct mechanism here. The egress filter
that bwrap/systemd would have provided is delivered by `--internal` + the proxy.
