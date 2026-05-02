# Watchers

Lightweight bash skeleton for "watch external state on owned infra, notify
on transitions, disable yourself when done."

Extracted from `oci-melbourne-watch.sh` (deployed on Sydney 2026-04-30 to
detect an OCI free-tier → PAYG flip; fired correctly, notified twice,
self-disabled). The watcher worked because it was specific. This template
keeps the shape that made it work and parameterizes the parts that vary.

**Requires:** bash 4+, `jq`, `curl`, `crontab` on the target box. (Sydney
has all four; verify on a fresh host before installing.)

## When to reach for this

The decision tree (recorded in auto-memory under
`feedback_co_locate_watcher_with_watched.md`, not in the repo):

- Does Sydney have credentials + network reach to query the thing? → **cron on Sydney**
- Watched cadence faster than 1hr? → **cron on Sydney** (remote agents floor at 1hr)
- The thing lives inside Anthropic's network, or needs an MCP-style connector? → `/schedule` remote agent
- One-off / parked indefinitely? → still cron on Sydney; cheaper to leave a stub

If the answer is "cron on Sydney," start from `template.sh`.

## The shape

```
┌─────────┐   condition flips    ┌─────────┐  target materializes  ┌──────┐
│ Phase A │ ───── 🎉 ──────────▶ │ Phase B │ ────── 🚀 ──────────▶ │ DONE │
└─────────┘                      └─────────┘    + self-disable     └──────┘
```

A `state` file under `~/.config/imagineering/<watcher>.state` gates the
transition. The cron entry runs the script; the script reads the state
file and dispatches to the right phase function. On final success, the
script edits its own crontab line out via `crontab -l | grep -v $TAG | crontab -`.

**Why two phases.** The OCI watch needed both: first wait for the *quota
flip* (a permission change), then wait for the *instance to materialize*
(a side effect of automation downstream of the flip). Most "watch X"
problems have this shape — the *signal* is rarely the *thing you want*.
Cert expiry watch: phase A = "cert is now <14 days from expiry," phase B
= "renewed cert deployed." Disk watch: phase A = "disk > 90%," phase B =
"disk back below 80% after cleanup ran."

For genuinely single-phase watchers ("alert when X, then stop"), make
`phase_b_check` a one-liner returning 0. The state machine collapses to
"fire once, self-disable" with no extra ceremony:

```bash
phase_a_check() {
    USAGE=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
    if [[ "$USAGE" -ge 85 ]]; then
        tg "🚨 Sydney disk at ${USAGE}% (top dirs): $(du -sh /var/log/* 2>/dev/null | sort -rh | head -3)"
        return 0
    fi
    return 1
}

phase_b_check() {
    return 0   # immediately transition to DONE; one-shot watcher
}
```

## Layout (post-#34 / lib extraction)

```
scripts/watchers/
├── lib/
│   └── watcher-base.sh    # shared helpers + state machine (sourced by all watchers)
├── template.sh            # skeleton for new watchers
├── README.md              # this file
├── disk-usage-watch.sh    # built example
└── …                       # other watchers
```

Each watcher sources `lib/watcher-base.sh`, which provides `log()`, `tg()`,
`self_disable()`, and `run_watcher()` (the state machine driver). The
watcher itself defines only `WATCHER_NAME`, `CRON_TAG`, `phase_a_check`,
and `phase_b_check`. Typical watcher size: 50-80 lines.

On Sydney, the lib is deployed once at `/home/ubuntu/lib/watcher-base.sh`
and watchers source it via `"$(dirname "$0")/lib/watcher-base.sh"` (or
`$HOME/lib/watcher-base.sh` as fallback). Updating the lib is a single
file change that all watchers pick up on next cron tick.

## Spawn a new watcher

```bash
# 1. Copy the template, name your watcher.
cp scripts/watchers/template.sh /tmp/cert-expiry-watch.sh
$EDITOR /tmp/cert-expiry-watch.sh
#    - Set WATCHER_NAME and CRON_TAG to "cert-expiry-watch" (or similar).
#    - Implement phase_a_check + phase_b_check.

# 2. Ship the watcher (and the lib if Sydney doesn't have it yet) to Sydney.
ssh 149.118.69.221 'mkdir -p /home/ubuntu/lib'
scp scripts/watchers/lib/watcher-base.sh 149.118.69.221:/tmp/   # one-time
ssh 149.118.69.221 'sudo install -m 0755 -o ubuntu -g ubuntu /tmp/watcher-base.sh /home/ubuntu/lib/'
scp /tmp/cert-expiry-watch.sh 149.118.69.221:/tmp/
ssh 149.118.69.221 'sudo install -m 0755 -o ubuntu -g ubuntu /tmp/cert-expiry-watch.sh /home/ubuntu/'

# 3. Confirm notify creds exist on the box (one-time, already in place
#    if any other watcher has run there):
ssh 149.118.69.221 'ls -la ~/.config/imagineering/notify-credentials'
#    File should exist, mode 0600, with NOTIFY_URL + NOTIFY_API_KEY.
#    If absent: sops -d notify/secrets.yaml to retrieve, install with
#    `chmod 0600`.

# 4. Install the cron entry. Tag it with the same name as CRON_TAG.
ssh 149.118.69.221 'crontab -l | { cat; echo "*/15 * * * * /home/ubuntu/cert-expiry-watch.sh  # cert-expiry-watch"; } | crontab -'
#    Note the trailing comment — self_disable() greps for it. The literal
#    string after the # must match $CRON_TAG exactly.

# 5. Watch the log on first cycle to confirm it's wiring up:
ssh 149.118.69.221 'tail -f ~/cert-expiry-watch.log'
```

## The self-disable mechanic

```bash
crontab -l | grep -vF "$CRON_TAG" | crontab -
```

Three things to know:

1. **The grep is on the trailing comment, not the path.** The cron entry
   ends with `  # cert-expiry-watch` and `$CRON_TAG="cert-expiry-watch"`.
   This is fragile if the tag is too short (e.g. tagging with `oci`
   would also nuke any cron line that happens to mention OCI). Use a
   distinctive tag — usually `<watcher-name>` is fine.
2. **It edits the user's own crontab**, not root's. Install your cron
   entry under the same user that runs the script (typically `ubuntu` on
   Sydney). If you install under root and the script runs as ubuntu,
   self-disable will silently fail (no root crontab to edit).
3. **It's idempotent.** If you re-run the script after self-disable, it
   sees `phase=DONE` and tries to self-disable again (harmless no-op).
   The DONE branch also retries self-disable in case an earlier attempt
   silently failed.

## Notify integration

Watchers send via [`notify.imagineering.cc`](https://notify.imagineering.cc) —
HTTP shim around the Telegram bot API, lets cron jobs and remote agents
notify without holding the bot token. See
`memory/project_notify_service.md` for full context.

The template inlines the `tg()` helper rather than sourcing it from
`scripts/lib/`, on purpose: a watcher should be a single self-contained
file you can `scp` to the target box without dragging the repo. The
existing `scripts/lib/telegram.sh` is a different abstraction — it talks
*directly* to the Telegram bot API (needs `TELEGRAM_BOT_TOKEN`); use it
when you need MarkdownV2 escaping or threaded replies. For watchers,
prefer `notify.imagineering.cc`.

Credentials live at `~/.config/imagineering/notify-credentials` on the
Sydney box (mode 0600, exports `NOTIFY_URL` and `NOTIFY_API_KEY`). The
template sources this file silently — if it's missing, `tg()` logs a
warning and continues; the watcher still polls, it just can't notify.
This is deliberate: a missing credential file shouldn't crash cron and
turn it into a stderr spammer.

## Design choices worth knowing

**Why a state file instead of re-deriving phase from the API every run?**
Reduces flap risk (one bad API response can't reset progress), makes
"what is this thing currently doing" debuggable via `cat
~/.config/imagineering/<watcher>.state`, and gives the script a clean
place to put cross-cycle context (e.g. the 24h-warned-once flag).

**Why exit 0 on transient errors?** Cron treats non-zero exit as failure
and may email or alert. A transient API error is the *normal* state for
many watchers (rate limits, brief 5xx, network flutters); it shouldn't
look like the script broke. The convention is: log the error, exit 0,
retry next cycle. Real bugs surface as repeated identical errors in the
log file, which is where you'd look anyway.

**Why no locking?** Cron runs are short and `*/15 * * * *` is unlikely
to overlap. The OCI watcher had no lock; if you need one, `flock(1)` is
the right tool — see `scripts/oci-retry-provision.sh` for an example.

**Why HTML and not MarkdownV2 for notifications?** Same reason
`scripts/lib/telegram.sh` chose HTML — MarkdownV2 requires escaping ~16
punctuation characters in *all* dynamic text, and one stray dot from a
hostname or stack frame silently 400s. HTML mode escapes only `&`, `<`,
`>` — much smaller failure surface. Escape dynamic content with
`s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g` if it might contain those
characters.

## Common gotchas

**`pipefail` false positives in piped captures.** `out=$(cmd1 | cmd2 | awk 'NR==1 {...}')` under `set -o pipefail` may report rc=1 even when each stage exits 0 individually and the data flows through correctly. Encountered in `backup-recency-watch.sh`'s `find | sort | awk` pattern; cause appears to be awk's selective-print-without-exit interaction with sort's flush. Workaround: `out=$(... || true)` to ignore the spurious failure when you're sure the data is sound.

**`grep -c '' <<< "$x"`** counts 1 for `$x=""` because heredoc adds a trailing newline. Use a custom `nlines()` helper (`if -z then 0 else awk 'END { print NR }' <<< "$x"`) when you need accurate empty-vs-nonempty line counts.

**Glob expansion in `ssh ... 'sudo rm -f /path/to/foo.*'`** happens in the *local* shell, not on the remote. If the local cwd has no match, `*` is passed literally and the remote rm is a no-op. Use `ssh ... 'sudo bash -c "rm -f /path/to/foo.*"'` to evaluate the glob remotely.

## Candidate watchers

Concrete watches worth building from this template (none are built yet —
listed here so the template has demand-side context):

1. **Disk usage on Sydney.**
   Phase A: `df / | awk 'NR==2 {print $5}'` exceeds 85% — fire 🚨 with top
   5 dirs by size. Phase B: drops back below 75% — fire ✅. Self-disable.
   Single-phase variant if you'd rather alert weekly and re-arm by hand.

2. **TLS cert expiry on imagineering.cc subdomains.**
   Phase A: any cert in `caddy/data/` is <14 days from expiry — fire 🚨.
   Phase B: cert renewed (notAfter advanced) — fire ✅, self-disable.
   Caddy normally auto-renews at 30 days, so this is defense-in-depth
   for "auto-renew silently broke."

3. **OCI quota drift / billing.**
   Phase A: free-tier A1 quota for any tenancy drops below 4 OCPUs (means
   they took capacity back, or PAYG flipped, or something else
   structural). Phase B: returns to 4. Catches both directions of OCI's
   capacity moves.

4. **Backup recency.**
   Phase A: most recent commit on `imagineering-cc/imagineering-backups`
   is older than 25 hours — fire 🚨, the daily 4am backup didn't run.
   Phase B: a fresh commit lands. Self-disable. Useful because backups
   failing silently is the worst kind of failure.

5. **`kanbn/kan` upstream release.**
   Phase A: a new release tag appears containing the migration we patched
   manually for `card_activity.attachmentId` (see CLAUDE.md → kanbn →
   Migration Issue). Phase B: we've upgraded our pinned version.
   Self-disable. Catches "the upstream fix shipped, we can drop our
   manual workaround."

Each of these has the right shape (external state, transitions, want-to-be-notified,
genuinely-stops-mattering-after-resolution). Each is also <50 lines of
phase logic on top of the template. If you build one, link it back here.

## See also

- `template.sh` — the file
- `notify/` (in this repo) — the notify proxy source. Auto-memory note
  at `project_notify_service.md` has full deployment context.
- The co-locate principle — auto-memory note at
  `feedback_co_locate_watcher_with_watched.md`. (Both auto-memory paths
  resolve under `~/.claude/projects/<encoded-cwd>/memory/` — they're
  Claude Code session memory, not repo files.)
- `oci-melbourne-watch.sh` on Sydney at `/home/ubuntu/` — the canonical
  example, frozen at DONE.
