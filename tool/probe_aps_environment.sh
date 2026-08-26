#!/usr/bin/env bash
# What APNs environment does a BUILT artifact actually declare?
#
# The question this answers cannot be answered from the repo. `Runner.entitlements`
# statically says `development`, and Xcode REWRITES `aps-environment` at export
# time from the signing profile — so reading the checked-in file returns the debug
# answer on every distribution build, confidently and silently.
#
# This is the BUILD-MACHINE half of the instrument. The runtime half lives in
# `ApnsTokenChannel.pushEnvironment()` (ios/Runner/AppDelegate.swift) and reads
# the same key from the same file, from inside the running app. Run this against
# an archive before submitting to confirm the two agree — a disagreement means the
# app is telling the island something the binary contradicts.
#
#   ./tool/probe_aps_environment.sh build/ios/iphoneos/Runner.app
#   ./tool/probe_aps_environment.sh build/ios/ipa/aiko_chat_app.ipa
#
# Exits non-zero when no profile is readable, because "absent" and "development"
# must never print the same way — the whole failure class here is a missing
# answer that reads as an answer.
set -euo pipefail

target="${1:-build/ios/iphoneos/Runner.app}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

case "$target" in
  *.ipa)
    unzip -q "$target" -d "$scratch"
    app="$(find "$scratch/Payload" -maxdepth 1 -name '*.app' -print -quit)"
    ;;
  *) app="$target" ;;
esac

if [ ! -d "$app" ]; then
  echo "no .app at: $target" >&2
  exit 2
fi

profile="$app/embedded.mobileprovision"
if [ ! -f "$profile" ]; then
  # NOT a fallback to a guess. The runtime code falls back to the build
  # configuration on purpose; this instrument must not, or it would report the
  # same string whether it read the artifact or not.
  echo "no embedded.mobileprovision in $app — this probe cannot answer" >&2
  exit 3
fi

# CMS-signed DER with the plist as payload, so it needs decoding before any
# plist tool will open it. Same slice the Swift does, by a different route.
plist="$scratch/profile.plist"
security cms -D -i "$profile" > "$plist"

aps="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$plist" 2>/dev/null || true)"
name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist" 2>/dev/null || echo '?')"

if [ -z "$aps" ]; then
  echo "profile '$name' declares NO aps-environment — push is not entitled" >&2
  exit 4
fi

echo "artifact:      $app"
echo "profile:       $name"
echo "aps-environment: $aps"
echo
case "$aps" in
  production)
    echo "-> tokens are valid against api.push.apple.com ONLY."
    echo "   The app must register with push_environment=production, and an island"
    echo "   running APNS_USE_SANDBOX=true will answer 400 BadDeviceToken forever."
    ;;
  development)
    echo "-> tokens are valid against api.sandbox.push.apple.com ONLY."
    echo "   Correct for a locally-signed build; WRONG for anything going to"
    echo "   TestFlight or the App Store."
    ;;
  *) echo "-> unrecognised value; the island's enum will 422 this." ;;
esac
