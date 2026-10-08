#!/usr/bin/env bash
# Android ring hardware harness — the one PR #210 (design 22) was verified with on a
# Pixel 4 against enspyr, 2026-10-08. SOURCE it, then drive steps by hand:
#
#   source tool/hw_ring.sh
#   alive                     # FIRST: is the handset actually reachable?
#   C=$(mint); cold; invite $C; waitlog "ring shown"; tap Answer; island 1m
#
# WHY THIS EXISTS. Each of these traps cost a wrong reading before it was found:
#
#   1. SILENCE IS NOT A RESULT until the handset is online. The first "the push did
#      nothing" was the Pixel off the network (fixed by a hotspot). `alive` pings
#      from the handset before you read anything into a missing ring.
#   2. OVERLAP THE INVITE WITH THE WAKE. `ring_probe.py invite` blocks ~7s waiting
#      for its ack; running it and THEN the FCM push produced a 10.2s-stale invite
#      that `admitRing` (10s freshness) correctly refused. The real island wakes in
#      the same second it persists, so `invite` backgrounds the signed send and
#      fires the wake ~1.5s later. A refused-stale ring here is a harness artifact;
#      the same failure in the field is claude-tasks#4233.
#   3. HOME, THEN `am kill`. `am kill` only kills a backgrounded process; on a
#      foreground app it is a silent no-op and your "cold start" was warm. `cold`
#      prints the pid afterwards — it must be empty.
#   4. EXPAND THE SHADE BEFORE `uiautomator dump`. Notification actions (Answer /
#      Decline) are not in the dump while the shade is collapsed. `tap LABEL shade`.
#
# Needs: adb with one device; ~/.claude/.env providing RING_HOST, RING_A_USER,
# RING_A_PASS (the caller) and FCM creds for tool/fcm_push.py; `ssh enspyr` with
# passwordless `sudo -n docker` for `island`. The handset's FCM token comes from the
# island DB (devices row for the callee) — put it in $HW_STATE/fcm_token.txt or
# export FCM_TOKEN.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HW_STATE="${HW_STATE:-${TMPDIR:-/tmp}/aiko-hw-ring}"
mkdir -p "$HW_STATE"
CH="${RING_CHANNEL:-01M46EANYZ253Z04Y9XR8K4PAV}"   # nicka <-> ringtest DM on enspyr
PKG=cc.imagineering.aiko_chat_app
set -a; source ~/.claude/.env 2>/dev/null; set +a
TOK="${FCM_TOKEN:-$(cat "$HW_STATE/fcm_token.txt" 2>/dev/null)}"
[ -n "$TOK" ] || echo "hw_ring: no FCM token — export FCM_TOKEN or write $HW_STATE/fcm_token.txt" >&2

# alive — trap 1: the handset must reach the network before silence means anything.
alive() { adb shell ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "alive: online" || { echo "alive: OFFLINE — fix the network before reading any result"; return 1; }; }
mint() { (cd "$REPO" && python3 -c "import importlib.util,sys;sys.argv=['x'];s=importlib.util.spec_from_file_location('r','tool/ring_probe.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.mint_call_id())"); }
# cold — trap 3: Home first, or `am kill` does nothing.
cold() { adb shell input keyevent 3; sleep 2; adb shell am kill $PKG; sleep 1; echo "cold: pid=[$(adb shell pidof $PKG)]"; }
_probe() { (cd "$REPO" && AIKO_HOST=$RING_HOST RING_USER=$RING_A_USER RING_PASS=$RING_A_PASS RING_CHANNEL=$CH python3 tool/ring_probe.py "$1" "$2" > "$HW_STATE/$1-$2.log" 2>&1); }
_fcm() { (cd "$REPO" && python3 tool/fcm_push.py "$1" --token "$TOK" --channel $CH --call "$2" > /dev/null 2>&1); }
# invite CALL — trap 2: signed invite in the background, FCM wake ~1.5s later (island order).
invite() { _probe invite "$1" & sleep 1.5; _fcm invite "$1"; echo "invite $1 pushed $(date +%T)"; }
# wake CALL — FCM invite only (no signed message): for native-only steps.
wake() { _fcm invite "$1"; echo "wake $1 pushed $(date +%T)"; }
endc() { _probe end "$1" & sleep 1.5; _fcm end "$1"; echo "end $1 pushed $(date +%T)"; }
endwake() { _fcm end "$1"; echo "end-wake $1 pushed $(date +%T)"; }
# waitlog REGEX [secs] — wait for an AikoRing logcat line.
waitlog() { for i in $(seq 1 "${2:-25}"); do adb logcat -d -s AikoRing | grep -qE "$1" && return 0; sleep 1; done; return 1; }
# tap LABEL [shade] — trap 4: find a node by text/content-desc and tap its centre.
tap() { [ "$2" = shade ] && { adb shell cmd statusbar expand-notifications; sleep 1; }
  for i in $(seq 1 10); do adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml > "$HW_STATE/ui.xml" 2>/dev/null
    B=$(python3 - "$HW_STATE/ui.xml" "$1" <<'PY'
import re,sys
x=open(sys.argv[1],encoding='utf-8',errors='ignore').read(); lab=sys.argv[2]
for m in re.finditer(r'<node [^>]*?(?:text|content-desc)="(?i:%s)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'%re.escape(lab),x):
    a,b,c,d=map(int,m.groups()); print((a+c)//2,(b+d)//2); break
PY
); [ -n "$B" ] && { adb shell input tap $B; echo "tapped $1 at $B $(date +%T)"; return 0; }; sleep 1; done; echo "tap $1: NOT FOUND"; return 1; }
notifs() { adb shell dumpsys notification | grep -c "NotificationRecord(.*$PKG"; }
focus() { adb shell dumpsys window | grep mCurrentFocus | head -1 | sed -E 's/.*u0 //'; }
# island [since] — the join proof: a video-token mint for the callee = joined.
island() { ssh -o ConnectTimeout=10 enspyr "sudo -n docker logs --timestamps --since ${1:-2m} aiko-chat-island-1 2>&1 | grep -E 'video-token|ws connected' | sed -E 's/token=[^ \"]+/token=…/' | tail -6"; }
