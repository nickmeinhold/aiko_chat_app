#!/usr/bin/env bash
# Read the device-token pairing rows on EVERY island the app can be signed into.
#
# WHY BOTH, ALWAYS. The single most expensive failure in the push work was not a
# code bug: the handset was signed into chat.enspyr.co while the polling ran
# against chat.imagineering.cc. Both readings were internally consistent, and
# `device_tokens: 0` was a true statement about the wrong database for four
# hours. Querying one island requires you to already KNOW which one the app is
# on — which is device state this script cannot see. Querying both turns that
# assumption into an observation the output hands back.
#
# So a zero here is never reported alone. If both islands read zero the script
# says UNBOUND rather than "no tokens": an instrument that has not been shown to
# read non-zero has told you about itself, not about the world.
#
# Usage:  tool/probe_pairing.sh              # read both islands
#         tool/probe_pairing.sh --watch      # re-read every 3s until interrupted
set -uo pipefail

# host-alias : container : gateway URL : docker-needs-sudo
ISLANDS=(
  "imagineering:aiko-chat-island-1:https://chat.imagineering.cc:no"
  "queen:aiko-chat-island-1:https://chat.enspyr.co:yes"
)

QUERY='
import sqlite3
c = sqlite3.connect("/data/aiko.db")
rows = list(c.execute(
    "select d.user_id, u.username, d.platform, d.token, d.created_at, d.updated_at "
    "from device_tokens d left join users u on u.id = d.user_id "
    "order by d.updated_at desc"))
print("COUNT", len(rows))
for uid, name, plat, tok, created, updated in rows:
    # Prefix only: a push token is a routing secret and this output lands in a
    # transcript. Enough to correlate two readings, never enough to route with.
    print("ROW", name or uid, plat, tok[:12] + "…[%d]" % len(tok), "updated=" + str(updated))
'

read_island() {
  local alias=$1 container=$2 url=$3 sudo_needed=$4
  local prefix=""
  [ "$sudo_needed" = "yes" ] && prefix="sudo -n "
  timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=10 "$alias" \
    "${prefix}docker exec -i $container python -c '$QUERY'" 2>&1
}

probe_once() {
  local total=0 unreachable=0
  echo "=== device_tokens @ $(date '+%H:%M:%S') ==="
  for entry in "${ISLANDS[@]}"; do
    IFS=: read -r alias container scheme host sudo_needed <<< "$entry"
    local url="$scheme:$host"
    local out count
    out=$(read_island "$alias" "$container" "$url" "$sudo_needed")
    count=$(printf '%s\n' "$out" | awk '/^COUNT/ {print $2; found=1} END {if (!found) print "?"}')
    if [ "$count" = "?" ]; then
      # A failed READ is not an empty table. Say which one happened.
      printf '  %-28s UNREACHABLE  %s\n' "$url" "$(printf '%s' "$out" | tail -1)"
      unreachable=$((unreachable + 1))
      continue
    fi
    printf '  %-28s %s row(s)\n' "$url" "$count"
    printf '%s\n' "$out" | sed -n 's/^ROW /      /p'
    total=$((total + count))
  done
  if [ "$unreachable" -gt 0 ]; then
    echo "  -> PARTIAL: $unreachable island(s) could not be read. Any zero below is unproven."
  elif [ "$total" -eq 0 ]; then
    echo "  -> UNBOUND: every island reads zero, and nothing here has been shown to"
    echo "     read non-zero. Sign in on the handset and re-run; the island whose"
    echo "     count moves is the one the app is actually pointed at, and that"
    echo "     reading is this probe's positive control."
  fi
}

if [ "${1:-}" = "--watch" ]; then
  while true; do probe_once; echo; sleep 3; done
else
  probe_once
fi
