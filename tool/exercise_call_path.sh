#!/usr/bin/env bash
# Exercise the CallKit paths the 2026-09-20 cage-match changed, on a real handset.
#
# WHY THIS EXISTS. Ten defects were found in that panel BY READING and zero by
# running. Every one of them is a claim about what iOS does with a payload we can
# send ourselves, so leaving them unexercised leaves ten readings where there could
# be ten measurements. `tool/voip_push.py --payload` already puts the island's exact
# shape on a chosen handset with no gateway in the loop; this drives it through the
# specific sequences the panel argued about, and names the reading that would
# distinguish the competing predictions BEFORE the push goes out.
#
# Pre-registering the predictions is the point. A measurement read after the fact
# agrees with whatever you already believed — and three rounds of this cage-match
# were spent on a false "this will not compile" that six assertions never dislodged.
#
#   tool/exercise_call_path.sh <64-hex-voip-token> [env] [channel]
#
# `env` is production for an ad-hoc/TestFlight install, sandbox for `flutter run`.
# Read the DEVICE LOG afterwards (tool/device_log.sh), never this script's output:
# a 200 from APNs is acceptance for delivery and is exactly what per-device VoIP
# denial also looks like.
set -euo pipefail

TOKEN="${1:?usage: exercise_call_path.sh <64-hex-voip-token> [env] [channel]}"
ENVIRONMENT="${2:-production}"
CHANNEL="${3:-01KZEXERCISE0000000000000}"
CHANNEL_B="${CHANNEL%?}9"
PUSH="$(dirname "$0")/voip_push.py"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "E1 — THE DUPLICATE FLASH  (task #2; Carnot raised this in all three rounds)"
cat <<'E1'
  Two identical call_invite pushes for one channel, back to back — the shape this
  handset produces naturally, because it carries a live AND a stale VoIP token on
  the island, so one call fans out as two pushes.

  The duplicate arm calls reportAndEndImmediately while a call is already live, and
  maximumCallsPerCallGroup = 1. Two predictions, and they differ in ONE log line:

    H1  report LANDS      "duplicate invite for a ring already live on <ch>"
                          and NO "report REFUSED" line.
                          => must-report SATISFIED. There IS a second call UI /
                             buzz, and that is what Nick has been seeing.

    H2  report REFUSED    both the duplicate line AND
                          "reportAndEndImmediately — report REFUSED,
                           must-report NOT satisfied: <reason>"
                          => must-report NOT satisfied on this path. No buzz.
                             The comment's stated cost AND stated benefit are both
                             wrong, and repeated duplicates accrue violations.

  Also read, on the handset itself: did a spurious MISSED CALL land in Recents?
  includesCallsInRecents = true and the throwaway is ended .remoteEnded, so one
  bogus entry per real call would be its own defect.
E1
read -rp "  press enter to send the pair… "
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag dup-1 \
  --payload "{\"c\":\"$CHANNEL\",\"k\":\"call_invite\"}"
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag dup-2 \
  --payload "{\"c\":\"$CHANNEL\",\"k\":\"call_invite\"}"

say "E2 — TWO CHANNELS, ONE GLOBAL AUDIO SESSION  (R3-A: Maxwell + Carnot)"
cat <<'E2'
  disarm() is process-wide; reportEnd and endSystemCall are driven by a CHANNEL id,
  and the map is written per channel while maximumCallsPerCallGroup limits CallKit,
  not this dictionary. Before the round-3 fix, ending channel B tore the audio
  session out from under a live call on channel A.

  Ring A, ring B, then end B. The fix speaks for itself in the log:

    FIXED     "[audio] disarm withheld — 1 call mapping(s) still live"
    REGRESSED "[audio] disarm — back to automatic management"  while A is live
              (and, on the handset, A goes silent mid-call)
E2
read -rp "  press enter to ring A, ring B, then end B… "
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag two-A \
  --payload "{\"c\":\"$CHANNEL\",\"k\":\"call_invite\"}"
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag two-B \
  --payload "{\"c\":\"$CHANNEL_B\",\"k\":\"call_invite\"}"
read -rp "  answer A on the handset, then press enter to end B… "
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag two-endB \
  --payload "{\"c\":\"$CHANNEL_B\",\"k\":\"call_end\"}"

say "E3 — THE TOTAL FUNCTION ON k  (unchanged code, never exercised on a handset)"
cat <<'E3'
  Three malformed shapes that must each report-and-end and NEVER sustain a ring:
    missing c   an invite that cannot be answered
    empty c     the worse one — `if let` accepts "", so it used to MAP, and
                answering FULFILLED into a call with nobody on the wire
    unknown k   a third WakeKind added island-side must not ring an older build
  Every one should end immediately. A ring that STAYS is the defect.
E3
read -rp "  press enter to send all three… "
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag bad-missing --payload "{\"k\":\"call_invite\"}"
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag bad-empty   --payload "{\"c\":\"\",\"k\":\"call_invite\"}"
"$PUSH" send --env "$ENVIRONMENT" --token "$TOKEN" --tag bad-kind    --payload "{\"c\":\"$CHANNEL\",\"k\":\"call_carrier_pigeon\"}"

say "NOW READ THE DEVICE LOG — this script's 200s prove only that APNs accepted."
cat <<'DONE'
    tool/device_log.sh 15 | grep -E '\[callkit\]|\[audio\]'

  E4 is the one no script can send, and it is Tesla's finding — the whole reason
  disarm() moved. Do it by hand:
    1. answer a pushed call and confirm audio (look for "[audio] didActivate")
    2. hang up FROM INSIDE THE APP, not from the CallKit UI
    3. place an IN-APP call
  Before the fix, step 3 was silent forever — the app had been left in manual mode
  with audio disabled, and nothing reported it.
DONE
