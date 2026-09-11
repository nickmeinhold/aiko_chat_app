#!/usr/bin/env python3
"""Send a VoIP push to one device, directly, with no island in the loop.

THE MISSING INSTRUMENT. The 2026-09-09 and 2026-09-11 must-report runs
(claude-tasks#4178) both needed a way to put a chosen payload on a chosen
handset, and both used a sender that lived only in a shell history. The Dart and
Swift halves of that harness are committed; the thing that actually pushed the
bytes was not, so the experiment reads as reproducible and is not. An instrument
only one machine can run is an anecdote.

WHY DIRECT AND NOT THROUGH THE ISLAND. The question under test is a property of
*iOS*, not of the gateway: does `reportCall(with:endedAt:)` satisfy the
must-report rule? Routing through the island would add its ring lease, its
conduct gate, its throttle and its payload renderer to a measurement about
Apple's enforcement — four confounders on a one-bit question. This sends the
payload the experiment names and nothing else.

WHY curl AND NOT A PYTHON CLIENT. APNs is HTTP/2-only. The system python here
has `pyjwt` and `cryptography` but no HTTP/2 client, and the one dependency that
IS present on every macOS is curl with nghttp2. JWT minting stays in python
because that part has a golden-ish check (`probe`); transport is curl's job.

USAGE

    # No delivery to anyone: 64 hex zeros as the token. 400 BadDeviceToken means
    # the key, team and topic are all correct. Run this BEFORE trusting silence.
    tool/voip_push.py probe [--env sandbox|production]

    # The real thing.
    tool/voip_push.py send --token <64-hex> --mode report --tag pos-1
    tool/voip_push.py send --token <64-hex> --mode endlive --tag a-2

`--mode` is carried verbatim into the payload and is what selects the arm inside
`VoipSpike`. The arms live in the PAYLOAD rather than in a build flag on purpose:
one install runs the control and the experiment, so the control cannot drift
from the thing it is controlling.

APNs ENVIRONMENT IS NOT A PREFERENCE. A development-signed build mints a
SANDBOX token, and a sandbox token pushed at the production host returns
`400 BadDeviceToken` — the same string a typo produces. `--env` defaults to
sandbox because that is what `flutter run`/`--debug` installs produce; a
TestFlight or App Store install needs `--env production`.

Credentials, from `reference_apns_key_verification`:
    key  ~/keystores/AuthKey_3NB3877GGX.p8   kid 3NB3877GGX   team SPL85G447K
Override with APNS_KEY_PATH / APNS_KEY_ID / APNS_TEAM_ID.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid

KEY_PATH = os.path.expanduser(
    os.environ.get("APNS_KEY_PATH", "~/keystores/AuthKey_3NB3877GGX.p8")
)
KEY_ID = os.environ.get("APNS_KEY_ID", "3NB3877GGX")
TEAM_ID = os.environ.get("APNS_TEAM_ID", "SPL85G447K")
BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "cc.imagineering.aikoChatApp")

HOSTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}

# A well-formed token that belongs to no device. Apple validates the JWT before
# it looks the token up, so this discriminates credentials from delivery without
# waking anybody's handset.
NOBODY = "0" * 64


def mint_jwt() -> str:
    import jwt  # pyjwt

    with open(KEY_PATH, "r") as handle:
        key = handle.read()
    return jwt.encode(
        {"iss": TEAM_ID, "iat": int(time.time())},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def post(host: str, token: str, payload: dict) -> tuple[int, str, str]:
    """POST one push. Returns (status, apns-id or apns error, raw body).

    stderr is CAPTURED, never discarded: a curl that fails to negotiate HTTP/2
    exits non-zero with an empty body, which is indistinguishable from a silent
    APNs acceptance if you only read stdout.
    """
    body = json.dumps(payload)
    proc = subprocess.run(
        [
            "curl", "--http2", "--silent", "--show-error",
            "--write-out", "\n%{http_code}",
            "--header", f"authorization: bearer {mint_jwt()}",
            "--header", f"apns-topic: {BUNDLE_ID}.voip",
            "--header", "apns-push-type: voip",
            "--header", "apns-priority: 10",
            "--header", f"apns-id: {uuid.uuid4()}",
            "--data", body,
            f"{host}/3/device/{token}",
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return (-1, f"curl failed rc={proc.returncode}: {proc.stderr.strip()}", "")
    out = proc.stdout.rsplit("\n", 1)
    raw = out[0] if len(out) == 2 else ""
    status = int(out[-1]) if out[-1].strip().isdigit() else -1
    reason = ""
    if raw.strip():
        try:
            reason = json.loads(raw).get("reason", raw.strip())
        except json.JSONDecodeError:
            reason = raw.strip()
    return (status, reason, raw)


def cmd_probe(args) -> int:
    host = HOSTS[args.env]
    status, reason, _ = post(host, NOBODY, {"aps": {}, "mode": "probe"})
    print(f"{args.env}: HTTP {status} {reason}")
    if status == 400 and reason == "BadDeviceToken":
        print("PASS — key, team and topic accepted. The JWT is good.")
        return 0
    if reason == "InvalidProviderToken":
        print("FAIL — Apple does not recognise this key/team pair.")
    elif reason == "BadEnvironmentKeyInToken":
        print(f"FAIL — key is recognised but scoped to the other environment.")
    elif status == 403 and "TopicDisallowed" in reason:
        print("FAIL — the .voip topic is not permitted for this App ID.")
    else:
        print("FAIL — unexpected. Read the raw body above before concluding.")
    return 1


def cmd_send(args) -> int:
    host = HOSTS[args.env]
    payload = {"aps": {}, "mode": args.mode, "tag": args.tag}
    status, reason, raw = post(host, args.token, payload)
    label = "accepted" if status == 200 else "REJECTED"
    print(f"[{args.tag}] mode={args.mode} -> HTTP {status} {label} {reason}".rstrip())
    # A 200 is APNs accepting the push for delivery. It is NOT evidence the
    # device received it, and under per-device VoIP denial it is exactly what a
    # blackout looks like — claude-tasks#4178 measured 200s into a deaf handset.
    if status == 200:
        print("       (200 = accepted for delivery. Read the CONTAINER LOG, not this.)")
    return 0 if status == 200 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    # On BOTH the top level and every subcommand, via a parent parser: argparse
    # accepts a parent-level flag only BEFORE the subcommand, and the ordering
    # error it emits ("unrecognized arguments: --env sandbox") reads like the
    # flag does not exist. On a script whose whole job is to make a negative
    # reading trustworthy, an instrument that fails with a misleading message is
    # the one thing it must not be.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--env", choices=list(HOSTS), default="sandbox")
    parser.add_argument("--env", choices=list(HOSTS), default="sandbox")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("probe", parents=[common],
                   help="credential check, delivers to nobody")

    send = sub.add_parser("send", parents=[common],
                          help="push one payload to one device")
    send.add_argument("--token", required=True, help="64-hex PushKit VoIP token")
    send.add_argument("--mode", required=True, help="arm selector read by VoipSpike")
    send.add_argument("--tag", default="-", help="label echoed into the device log")

    args = parser.parse_args()
    if not os.path.exists(KEY_PATH):
        print(f"no APNs key at {KEY_PATH}", file=sys.stderr)
        return 2
    return {"probe": cmd_probe, "send": cmd_send}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
