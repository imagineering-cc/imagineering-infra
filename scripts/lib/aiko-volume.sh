#!/bin/bash
# Shared discovery of the LIVE aiko-chat-island SQLite volume + container.
#
# WHY THIS FILE EXISTS: the island cutover renamed the DB volume (compose
# project aiko-chat-gateway + volume aiko-chat-gateway_aiko_gateway_data  ->
# project aiko + external volume aiko_data). Hardcoding the old name silently
# operates on a frozen GHOST volume the live island never mounts — caught
# 2026-07-07 when Sydney's daily dump had passkey_credentials=0 while the live
# DB had 1. So backup AND restore MUST derive the volume from the RUNNING
# container: that follows the cutover automatically and works on BOTH islands
# (Melbourne still runs the pre-cutover name). This snippet used to be
# copy-pasted into each script, and only the backup copies got the fix — so
# restore.sh drifted and kept the ghost name (aiko_chat_gateway#1759). One home
# for the invariant = the copies can't drift apart again.
#
# Usage — source this file, then:
#   cid=$(aiko_island_container) || return 1
#   vol=$(aiko_island_volume "$cid") || return 1
#
# Each function prints its result on stdout and returns non-zero (with a
# message on stderr) on failure, so callers can `|| return` / `|| exit`.

# The running island container. Match the image tag, tolerating island|gateway
# because Melbourne (pre-cutover) still runs aiko-chat-gateway:*. First match
# wins — a box runs exactly one island.
aiko_island_container() {
  local cid
  cid=$(docker ps --format '{{.Names}}\t{{.Image}}' \
    | awk -F'\t' '$2 ~ /^aiko-chat-(island|gateway):/ {print $1; exit}')
  if [ -z "$cid" ]; then
    echo "aiko-volume: no running island container (image aiko-chat-island|gateway:*)" >&2
    return 1
  fi
  printf '%s\n' "$cid"
}

# The docker volume backing /data in the given container. This is the SINGLE
# source of truth for "which volume holds aiko.db" — never hardcode the name.
aiko_island_volume() {
  local cid=$1 vol
  if [ -z "$cid" ]; then
    echo "aiko-volume: aiko_island_volume requires a container id/name" >&2
    return 1
  fi
  vol=$(docker inspect "$cid" \
    --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
  if [ -z "$vol" ]; then
    echo "aiko-volume: container $cid has no /data volume mount" >&2
    return 1
  fi
  printf '%s\n' "$vol"
}
