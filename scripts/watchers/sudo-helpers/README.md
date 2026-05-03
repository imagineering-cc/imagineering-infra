# Watcher diagnostic sudo helpers

Read-only wrapper scripts that watcher diagnose.sh helpers can invoke
via narrow `sudoers` NOPASSWD entries. Deployed to `/usr/local/bin/`
on Sydney; sudoers entry at `/etc/sudoers.d/watcher-diag`.

## Why wrappers (not raw commands in sudoers)

Three reasons:

1. **Audit signal**: a compromised root that wanted to expand `ubuntu`'s
   capabilities would have to modify these files (whose mtime is
   trivially monitorable), not the sudoers config.
2. **Argument constraint**: sudoers allows globbing args; these scripts
   take *no* args, eliminating any "what if a watcher passes the wrong
   flag" failure mode.
3. **Single dispatch point**: future enrichments add a new wrapper +
   one sudoers line, rather than expanding an existing entry.

All wrappers are read-only operations. They produce diagnostic output
and exit. They never modify state, never accept user input, never
shell out to user-controllable paths.

## Install (manual — not part of any deploy script today)

```bash
# 1. Copy wrappers to /usr/local/bin (root-owned, mode 0755)
sudo install -m 0755 -o root -g root scripts/watchers/sudo-helpers/watcher-diag-* /usr/local/bin/

# 2. Install sudoers entry (root-owned, mode 0440)
sudo install -m 0440 -o root -g root scripts/watchers/sudo-helpers/sudoers.watcher-diag /etc/sudoers.d/watcher-diag

# 3. Validate
sudo visudo -c
sudo -n -l -U ubuntu | grep watcher-diag

# 4. Smoke-test as ubuntu
sudo -n /usr/local/bin/watcher-diag-docker-df | head -3
sudo -n /usr/local/bin/watcher-diag-backup-tail | tail -3
sudo -n /usr/local/bin/watcher-diag-caddy-logs | tail -3
```

## Wrappers

| Script | What | Used by |
|---|---|---|
| `watcher-diag-backup-tail` | Last 50 lines of `/home/nick/logs/backup.log` | `backup-recency-watch.sh` |
| `watcher-diag-docker-df` | `docker system df` summary | `disk-usage-watch.sh` |
| `watcher-diag-caddy-logs` | Last 100 lines of `docker logs caddy`, grepped for cert/renew | `cert-expiry-watch.sh` |

To add a new wrapper: drop a new script here, add a corresponding
NOPASSWD line in `sudoers.watcher-diag`, re-install both.
