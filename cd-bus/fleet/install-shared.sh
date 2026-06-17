#!/bin/bash
# One-time (and re-runnable) host install of the shared deploy-bus fleet bits.
# Copies the shared scripts to /opt/cd-bus and the unit TEMPLATES to
# /etc/systemd/system, then daemon-reloads. Idempotent. Per-service enablement
# (and /etc/cd-bus/<svc>.env) is separate — see README.md.
#
# Run FROM this directory on the host (these repo files are hand-managed
# mirrors of the host, like the rest of imagineering-infra's deploy artifacts):
#   scp -r cd-bus/fleet nick@host:/tmp/cd-bus-fleet && \
#     ssh host 'cd /tmp/cd-bus-fleet && sudo ./install-shared.sh'
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT=/opt/cd-bus
UNITS=/etc/systemd/system

[ "$(id -u)" -eq 0 ] || { echo "must run as root (installs to $UNITS)"; exit 1; }

echo "installing shared scripts -> $OPT"
install -d -o root -g root -m 0755 "$OPT"
for s in subscribe.sh deploy.sh subscriber-alert.sh poll-alert.sh; do
  install -o root -g root -m 0755 "$SRC_DIR/$s" "$OPT/$s"
  echo "  $OPT/$s"
done

echo "ensuring /etc/cd-bus exists for per-service env (root:nick 0750)"
install -d -o root -g nick -m 0750 /etc/cd-bus

echo "installing unit templates -> $UNITS"
# Plain files at the top of systemd/, plus the .d drop-in dirs.
find "$SRC_DIR/systemd" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) | while read -r u; do
  install -o root -g root -m 0644 "$u" "$UNITS/$(basename "$u")"
  echo "  $UNITS/$(basename "$u")"
done
# Drop-in directories (e.g. cd-bus-subscriber@.service.d/onfailure.conf).
find "$SRC_DIR/systemd" -mindepth 1 -type d -name '*.d' | while read -r d; do
  dest="$UNITS/$(basename "$d")"
  install -d -o root -g root -m 0755 "$dest"
  for f in "$d"/*; do
    install -o root -g root -m 0644 "$f" "$dest/$(basename "$f")"
    echo "  $dest/$(basename "$f")"
  done
done

echo "daemon-reload"
systemctl daemon-reload
echo "done. Next: /etc/cd-bus/common.env (+ per-service <svc>.env), then"
echo "  systemctl enable --now cd-bus-subscriber@<svc> cd-bus-recover@<svc>.timer cd-poll@<svc>.timer"
