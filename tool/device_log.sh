#!/usr/bin/env bash
# Pull this app's own markers out of the iPhone's log — WITHOUT root.
#
# `sudo log collect --device-udid` needs a password every time, which put a
# human in the loop on every measurement. `idevicesyslog archive` asks the
# device for the same logarchive over the USB pairing and needs no privilege at
# all, so the whole read is automatable.
#
# The markers are `os_log` on a named subsystem, NOT NSLog: the unified log
# redacts an NSLog message BODY, so every native marker used to come back as
# `(Foundation) <private>` — present, timestamped and unreadable.
#
#   tool/device_log.sh [minutes] [udid]
set -euo pipefail

MINUTES="${1:-10}"
UDID="${2:-00008120-000428CE1EB8201E}"
OUT="${TMPDIR:-/tmp}/aiko-device-log.$$"
mkdir -p "$OUT"

echo "requesting ${MINUTES}m of device log from $UDID …" >&2
idevicesyslog -u "$UDID" archive --age-limit $((MINUTES * 60)) "$OUT/dev.tar" >/dev/null
mkdir -p "$OUT/dev.logarchive"
tar xf "$OUT/dev.tar" -C "$OUT/dev.logarchive"

/usr/bin/log show --archive "$OUT/dev.logarchive" --style compact \
  --predicate 'subsystem == "cc.imagineering.aikoChatApp"'

echo "archive kept at $OUT/dev.logarchive" >&2
