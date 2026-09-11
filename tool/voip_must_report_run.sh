#!/usr/bin/env bash
# The must-report run, as a script rather than as a sequence of pasted commands.
#
# claude-tasks#4278, arms (a) `endlive` and (b) `reportend`. #4178 answered the
# STALE case (`reportCall(endedAt:)` for a UUID iOS has never seen) and left
# these two. The harness lives in `ios/Runner/AppDelegate.swift` on
# `spike/voip-must-report-endlive`; the sender is `tool/voip_push.py`.
#
# WHY A SCRIPT. The observable is a SEQUENCE — "did the pid change, did the push
# counter restart at 1" — and the interval between pushes is part of the
# experiment: arm (a) is only arm (a) if the end lands while CallKit is still
# ringing. Typed by hand, the gap between two pushes is whatever the operator's
# shell history felt like, which is a free variable in a one-bit measurement.
#
# WHAT THIS CANNOT DO, and it is why the run is not fully automated: it cannot
# put the app in the SUSPENDED state. must-report governs waking a suspended
# app, `devicectl … --console` holds a usage assertion that prevents suspension,
# and that is precisely what VOIDED the 2026-09-09 run. A human backgrounds the
# phone and waits. This script refuses to start until told that has happened.
#
# ARM ORDER IS DELIBERATE AND THE DESTRUCTIVE ARM IS LAST:
#   pos-1   report    MUST ring.  Proves delivery works on THIS install.
#   a-2     endlive   The experiment: end the ring pos-1 started.
#   pos-3   report    Did #2 get us terminated? pid churn / counter reset says.
#   a-4     endlive   Again — single-violation termination and repeated-denial
#   pos-5   report    are different effects and only repetition separates them.
#   neg-6/7/8 silent  NEGATIVE CONTROL, LAST because it is the one that costs a
#                     reinstall. If this does NOT produce enforcement, the
#                     instrument is blind on this OS build and NO conclusion may
#                     be drawn from a-2/a-4. Pre-registered, inherited from #4178.
#
# Usage:  tool/voip_must_report_run.sh <voip-token> [arm]
#         arm: a (default) | b | neg
set -euo pipefail

TOKEN="${1:?usage: voip_must_report_run.sh <64-hex voip token> [a|b|neg]}"
ARM="${2:-a}"
DEVICE="${SPIKE_DEVICE:-D7C473B3-1454-509B-BBB1-B2C6799462F9}"
BUNDLE="cc.imagineering.aikoChatApp"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SPIKE_OUT:-/tmp/voip-spike}"
mkdir -p "$OUT"

push() { "$HERE/tool/voip_push.py" send --env sandbox --token "$TOKEN" --mode "$1" --tag "$2"; }

pull() {
  # Read the CONTAINER FILE, not the system log: `log collect --device-udid`
  # needs root, `idevicesyslog` relays zero bytes here, and `log` is a zsh
  # builtin shadowing /usr/bin/log. The container file needs none of that and,
  # unlike a console, survives the termination we are trying to observe.
  rm -f "$OUT/spike.log"
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Documents/spike.log --destination "$OUT/spike.log" >/dev/null 2>&1 || true
  cat "$OUT/spike.log" 2>/dev/null || echo "(container log unreadable)"
}

echo "=== arm '$ARM' against $TOKEN"
echo "=== the app MUST be backgrounded and suspended. No console attached."
echo

case "$ARM" in
  a)
    push report  pos-1 ; sleep 6
    push endlive a-2   ; sleep 6
    push report  pos-3 ; sleep 6
    push endlive a-4   ; sleep 6
    push report  pos-5 ; sleep 8
    ;;
  b)
    # 4+ consecutive: the interesting threshold is the escalation, not the push.
    push report    pos-1 ; sleep 6
    for i in 1 2 3 4 5; do push reportend "b-$i"; sleep 5; done
    push report    pos-7 ; sleep 8
    ;;
  neg)
    # MUST be punished. If it is not, everything above is void.
    for i in 1 2 3; do push silent "neg-$i"; sleep 5; done
    push report pos-after-neg ; sleep 8
    ;;
  *) echo "unknown arm '$ARM'" >&2; exit 2 ;;
esac

echo
echo "=== device log ==="
pull
echo
echo "READ IT AS A SEQUENCE: a 'pid=' that changes, or a 'push #' that restarts"
echo "at 1, is iOS having terminated the app. A missing push line with an APNs"
echo "200 beside it is per-device VoIP denial, which APNs never reports."
