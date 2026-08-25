#!/usr/bin/env bash
# Read the handset's OWN state: which island it is signed into, and what
# device-token unregisters it still owes.
#
# The island probe (tool/probe_pairing.sh) reads a CONSEQUENCE — a row that
# exists or does not. This reads the MECHANISM: the durable debt ledger the
# teardown writes and the next sign-in drains. They fail differently, which is
# the point of having both.
#
# It also answers the question no server-side probe can: `aiko_gateway_base_url`
# is which island this app actually talks to. Reading it costs a second; assuming
# it cost four hours on 2026-08-24.
#
# FRESHNESS CAVEAT, and it is load-bearing. This reads the FLUSHED plist.
# NSUserDefaults writes back periodically and on suspend, not on every set — so
# a read taken seconds after an in-app action can legitimately show the previous
# state. Background the app (or give it a few seconds) before trusting a reading
# taken right after a sign-in or sign-out. A stale read here is indistinguishable
# from "the write never happened", which is exactly the confusion this whole
# exercise exists to stop making.
set -uo pipefail

UDID="${AIKO_UDID:-00008120-000428CE1EB8201E}"
BUNDLE="cc.imagineering.aikoChatApp"
DEST="$(mktemp -d)/prefs.plist"

xcrun devicectl device copy from \
  --device "$UDID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --user mobile \
  --source "Library/Preferences/$BUNDLE.plist" \
  --destination "$DEST" >/dev/null 2>&1 || {
    echo "COULD NOT READ the app container. That is a failed read, NOT an empty ledger."
    exit 1
  }

mtime=$(stat -f '%Sm' -t '%d/%m %H:%M:%S' "$DEST")
echo "=== handset state (plist last flushed $mtime) ==="

gw=$(plutil -extract 'flutter\.aiko_gateway_base_url' raw -o - "$DEST" 2>/dev/null)
echo "  signed into : ${gw:-<unset — no gateway chosen>}"

# Redact: a push token is a routing secret and this output lands in a transcript.
debt=$(plutil -extract 'flutter\.aiko_pending_device_unregisters' raw -o - "$DEST" 2>/dev/null)
if [ -z "$debt" ]; then
  # POSITIVE-CONTROL THE EXTRACTION before reading absence as a fact. Every key
  # here is prefixed "flutter." and `.` is a keypath separator, so one missing
  # backslash makes every lookup report a confident, plausible ABSENT. A key
  # known to exist must resolve, or this instrument has described itself.
  if ! plutil -extract 'flutter\.aiko_eula_accepted_v1' raw -o - "$DEST" >/dev/null 2>&1; then
    echo "  owed        : UNKNOWN — the extraction control failed, so absence here"
    echo "                proves nothing about the ledger. Fix the query, re-run."
    exit 1
  fi
  echo "  owed        : nothing (key absent, and the extraction control passed)"
else
  echo "  owed        :"
  printf '%s' "$debt" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("      UNPARSEABLE:", e); raise SystemExit
for island, toks in d.items():
    for t in toks:
        print("      %s  %s…[%d]" % (island, t[:12], len(t)))
'
fi
