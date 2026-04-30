# downstream-server ops bits

This directory holds the host-side ops wiring for the `downstream-server`
guest service. The service itself (Dart + Drift on SQLite) lives in the
[downstream monorepo](https://github.com/nickmeinhold/downstream); this
directory only owns things that run on the OCI box *around* the container.

## Nightly reconciler cron

`bin/reconcile_b2.dart` (in the downstream-server source) probes every DB
row marked `available` against B2/CDN reality:

1. DB row says `status=available`.
2. The CDN object responds 200 with non-zero content-length.
3. The MP4 has a `moov` atom near the start of the file (faststart).

It mutates nothing. The point is to catch drift between the DB and B2 (Fight
Club / Housemaid manifest-ghost incidents, `movie_9323` with no moov atom)
proactively rather than at playback time. See the script's header comment
for full semantics and exit codes.

### What runs when

A cron file at `cron/reconcile-downstream` schedules a nightly run at
**04:15 server time** — staggered 15 minutes after the 04:00 backup cron
(`scripts/deploy-to.sh::deploy_backups`) so they don't collide on the
SQLite snapshot path or load the box simultaneously.

The cron invokes `/opt/scripts/reconcile-downstream.sh`, which:

1. Snapshots the live DB via `sqlite3 .backup` (WAL-aware; the live DB is
   held open by the running container, so a plain copy isn't safe).
2. Runs the Dart script inside a one-shot `dart:stable` container with the
   rsynced server source tree mounted, the snapshot mounted read-only, and
   a persistent named volume (`downstream-reconcile-pub-cache`) so we don't
   re-fetch 65 packages every night.
3. Cleans up the snapshot.

Output is appended to `/home/nick/logs/reconcile-downstream.log` and rotated
weekly (8 weeks retained, gzipped) by `/etc/logrotate.d/reconcile-downstream`.

### Why a one-shot dart container instead of `docker exec`

The production runtime image (`debian:bookworm-slim` with the AOT-compiled
`server` binary) doesn't ship a Dart runtime — `docker exec
img-downstream-server dart …` fails with `dart: not found`. The options
were:

- **Bake reconcile into the prod image** (add a second `dart compile exe`
  in the Dockerfile). Cleanest at runtime, but requires an image rebuild
  for every change to the script, and a deferred PR in another repo touched
  the file. Skipped for scope.
- **Install Dart on the host.** Adds a host-level dependency and another
  thing to upgrade.
- **One-shot dart:stable container, source mounted.** Chosen. Slightly
  slower first run; with the persistent pub-cache volume, subsequent runs
  reuse the resolved deps. No host-level state.

### Manual ad-hoc run

```bash
# default: full reconcile against all `available` rows
ssh imagineering /opt/scripts/reconcile-downstream.sh

# pass extra args to the Dart script
ssh imagineering "RECONCILE_ARGS='--limit 20 --verbose' /opt/scripts/reconcile-downstream.sh"

# strict mode (transient probe failures become exit 1)
ssh imagineering "RECONCILE_ARGS='--strict' /opt/scripts/reconcile-downstream.sh"
```

### Checking the latest results

```bash
# tail the log
ssh imagineering tail -50 /home/nick/logs/reconcile-downstream.log

# just the most recent run's summary
ssh imagineering "awk '/^=== reconcile-downstream/{block=\"\"} {block=block ORS \$0} END{print block}' /home/nick/logs/reconcile-downstream.log"

# count data issues found in the last 7 days (after rotation)
ssh imagineering "zgrep -c 'Data issues:' /home/nick/logs/reconcile-downstream.log* 2>/dev/null"
```

### Deploy

```bash
# Deploys the cron-invoked script (in /opt/scripts/) and any other
# imagineering-infra scripts.
./scripts/deploy-to.sh 149.118.69.221 scripts

# Deploys only the cron + logrotate files (idempotent, no scripts touched).
./scripts/deploy-to.sh 149.118.69.221 downstream-reconciler
```

The first command is the one that needs to run after edits to
`scripts/reconcile-downstream.sh`. The second is a fast path when only the
cron schedule or logrotate policy changes.
