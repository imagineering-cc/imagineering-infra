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
| `allow-inference` | reach `api.anthropic.com` (the codegen agent's inference endpoint) **through the proxy** | a real HTTP status (401/404/405) — the tunnel opened |
| `allow-github` | reach `api.github.com` **through the proxy** | 2xx |
| `workdir-rw` | write+read a file in the clone workdir | ok |
| `token-forward` | with `CAGE_GH_TOKEN` set, `$GITHUB_TOKEN`/`$GH_TOKEN` inside the cage match it | forwarded (the agent can auth `git`/`gh`) |
| `token-not-leaked` | with `CAGE_GH_TOKEN` **unset**, no GitHub token in the cage env | absent (no stray credential) |
| `claude-token-forward` | with `CAGE_CLAUDE_TOKEN` set, `$CLAUDE_CODE_OAUTH_TOKEN` inside the cage matches it | forwarded (the agent can auth inference) |
| `claude-token-not-leaked` | with `CAGE_CLAUDE_TOKEN` **unset**, no `CLAUDE_CODE_OAUTH_TOKEN` in the cage — *even though the operator's own shell has it exported* | absent (the shared Max token never silently rides in) |

A cage that fails an escape-FAIL case is **broken open** (the dangerous direction).
A cage that fails a MUST-SUCCEED case is **broken shut** (green-auto can't work, but
it's safe) — fix forward, never relax an escape gate to make a success case pass.

## Known residuals (named, not hidden)

- **Writable `HOME` for the real agent.** ✅ *Resolved.* `--read-only` + only
  `/work`/`/tmp` writable would make a real `claude -p` (writes `~/.claude`) and
  `git` (writes `$HOME`) fail. Two layers: `run-cage.mjs` forwards `HOME=/work` into
  the cage whenever either agent token is present (so `git`'s `$HOME` is writable);
  AND `agent-entrypoint.mjs` then runs the `claude` subprocess with its OWN tmpfs
  HOME (`/tmp/agent-home-*`), NOT `/work` — so `~/.claude` lands in tmpfs and can't
  be swept into `git add -A` and shipped in the PR. The probe used `alpine sh`,
  which needs neither.
- **Same-subnet host bridge IP.** The probe proves the *default* bridge gateway
  (`172.17.0.1`) and `host.docker.internal` are unreachable, but does not yet
  probe the internal network's *own* in-subnet gateway IP. Docker binds no host
  services to an internal bridge by default, so there's nothing there today;
  flagged as the next probe to add if any host service is ever bound to it.
- **Inference host in the allowlist.** `api.anthropic.com` is now wired into the
  egress allowlist (and the `allow-inference` probe case), with the agent's
  inference credential forwarded key-only as `CAGE_CLAUDE_TOKEN` →
  `CLAUDE_CODE_OAUTH_TOKEN`. The named residual stands: the allowlist is only as
  strong as its entries — `api.anthropic.com` must not be an open redirect /
  SSRF-amplifier / surprisingly-CDN-fronted host. The resolved-IP guard blocks
  *internal* targets but not a *public* open-proxy. (Anthropic's API host is a
  fixed, non-redirecting JSON endpoint, so this is low-risk but unenforced.)
- **Token exfil via the PR diff.** ✅ *Now enforced* (cage-match #121, Carnot HIGH).
  The cage bounds *reachability* to two hosts, but GitHub egress IS the publish
  channel, so a subverted agent could write a token into its own diff. Three layers
  now stop that: (1) the codegen `claude` runs with **no GitHub credentials in its
  env** (it only edits files — it can't `git push` itself); (2) `agent-entrypoint.mjs`
  **scans the staged diff for the exact token values and hard-fails** (`EXIT.SECRET_LEAK`)
  before any commit/push; (3) the inference token is dropped from the env before the
  git/gh phase. Residual (named): the scan matches *exact* values, not arbitrary
  re-encodings, and the draft-PR + human review remain the backstop.

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
the container — **key-only (`-e GH_TOKEN`, no value), so the secret rides in the
docker client env, never the `docker run` argv / host `ps`** (cage-match #114) —
alongside `HOME=/work` and the scrubbed `CAGE_AGENT_*` task context; nothing else. **Residual (named, not enforced):** distinct-from-broad guarantees a
*dedicated* token, not that it is *fine-grained-scoped to exactly one repo* — that
narrowing is the operator's provisioning duty. A control-repo reachability probe
(reach a forbidden repo with the token, expect 404/403) to verify the bound online
is the next gate to add.

### The inference credential (`CLAUDE_CODE_OAUTH_TOKEN`)

The codegen agent runs `claude -p` against `api.anthropic.com`, so it needs an
inference token *inside* the cage. Unlike the GitHub token this one is **not
bounded-distinct** — it is the shared Max-plan OAuth token by nature; there is
nothing to scope it down to. So the gate is "present, fail-closed":
`src/auto.mjs`'s `cageSubstrate` refuses to spawn unless `HEALER_CAGE_CLAUDE_TOKEN`
is set, and it reaches the cage **key-only** as `CAGE_CLAUDE_TOKEN` →
`CLAUDE_CODE_OAUTH_TOKEN` (the same `-e NAME`, value-from-client-env discipline as
the GH token, so it never lands in argv / host `ps`). Crucially, `run-cage.mjs`
forwards it ONLY via that explicit indirection — **never by ambient name** — so the
operator's own shell having `CLAUDE_CODE_OAUTH_TOKEN` exported does NOT leak it into
the cage (the `claude-token-not-leaked` probe asserts exactly this). Its blast
radius (a subverted agent could embed it in a PR diff) is a named residual above,
bounded by the draft-PR + human merge gate.

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

## Provisioning the monster (on-box — the gate to turning green-auto ON)

green-auto ships **OFF**: `src/auto.mjs` refuses to spawn until ALL of the gates
below are set, and they are unset by default. Turning it on is a deliberate on-box
act, done in this order (each step is the precondition for the next):

1. **Build the agent image** on the box (arm64; build needs egress, the cage's
   no-egress is a runtime property):
   ```sh
   docker build -f cage/Dockerfile.agent -t self-healer-agent:latest self-healer/cage/
   ```
2. **Create the cage networks + egress proxy** (the same shapes the probe builds):
   an `--internal` network for the agent, an egress network for the proxy, the
   proxy container on BOTH with `CAGE_ALLOW_HOSTS=api.github.com,.github.com,api.anthropic.com`.
3. **Run the escape probe LIVE** — *this is the gate, not a config read*:
   ```sh
   bash self-healer/cage/escape-probe.sh   # exit 0 iff every escape is blocked AND every legit path works
   ```
   Do not proceed unless it exits 0. A broken-OPEN cage must never be armed.
4. **Provision a fine-grained, repo-scoped PAT** (or App installation token) scoped
   to ONLY the target repo — this is the `HEALER_GREEN_AUTO_TOKEN` gate 3 enforces
   distinct-from-the-broad-host-token. The cage bounds reachability; this bounds
   authority. A control-repo reachability probe (token must 404/403 a forbidden
   repo) is the recommended manual check before arming.
5. **Set the gate env** in the file the self-healer cron sources (the same env the
   read-only stages already read; NOT a world-readable path):
   ```sh
   HEALER_GREEN_AUTO=1
   HEALER_GREEN_AUTO_TOKEN=<fine-grained repo-scoped PAT>     # gate 3 (authority)
   HEALER_CAGE_IMAGE=self-healer-agent:latest                 # gate 4
   HEALER_CAGE_NETWORK=<the --internal network name>          # gate 4
   HEALER_CAGE_PROXY_URL=http://<proxy-name>:3128             # gate 4
   HEALER_CAGE_CLAUDE_TOKEN=<Max-plan CLAUDE_CODE_OAUTH_TOKEN># gate 4 (inference)
   HEALER_CAGE_AGENT_CMD=node /opt/self-healer/agent-entrypoint.mjs  # gate 5
   ```
6. **Smoke a single real green finding** with the flag on, watch it draft a PR, and
   confirm the PR is a DRAFT against the right repo with the self-healer provenance
   in its body. Foreground the first run (verify each step) — do not cron-arm it
   until one finding has gone end-to-end and been reviewed.

### Telegram approve loop (Increment C — built, provisioned separately)

green-auto pings Nick when it opens a draft PR (the orchestrator sends it — the caged
agent has no egress to notify), and Nick can reply **"merge #N"** to merge from his
phone. The merge gate stays HUMAN; the "yes" is approval, never a bypass.

- **Notify (one-way)** rides the existing `notify` proxy — only needs `NOTIFY_API_KEY`
  (already a healer env). Each draft PR → a ping with the link + the exact "merge #N"
  reply; a stumble → a warning ping.
- **Approve (two-way)** is `src/approve-poll.mjs`, run on a short cron on the box. It
  polls the notify bot's `getUpdates`, and merges ONLY when all three gates hold:
  (1) the message is from `NICK_TELEGRAM_USER_ID` (his specific id, not "anyone in the
  chat"); (2) it unambiguously names the PR (URL, or a reply to the ping); (3) a LIVE
  re-check shows the PR OPEN + mergeable + reviewer-APPROVED + `cage-matched`-labelled.
  Fail-closed: refuses to start unless its creds are provisioned.
  ```sh
  HEALER_APPROVE_BOT_TOKEN=<the notify bot token>     # getUpdates + replies (read-only authority)
  NICK_TELEGRAM_USER_ID=<Nick's Telegram user id>     # the ONLY approver (gate 1)
  HEALER_APPROVE_MERGE_TOKEN=<a GH token that can merge>  # SEPARATE from the bot token
  # optional: HEALER_APPROVE_DEFAULT_REPO=owner/name (resolves a bare "#N")
  # cron (box): * * * * * node /opt/self-healer/src/approve-poll.mjs   # or every 2 min
  ```
  Note: `getUpdates` conflicts with a Telegram webhook — the notify bot must be in
  polling mode (it is; `notify.py` only sends). The merge token is its OWN credential:
  the bot only reads/replies, merge authority never rides the bot token.
