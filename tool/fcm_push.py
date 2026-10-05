#!/usr/bin/env python3
"""Send a call wake to one Android device over FCM, directly, with no island.

The Android counterpart of `tool/voip_push.py`, for the same reason: the
question under test is whether THE HANDSET rings, and routing through the
island would add its ring lease, conduct gate, wake budget and (today) a
transport that does not exist — `transport_not_built` on main, by design 14's
ruling that the sender ships with its receiver. This sends exactly the envelope
the app-side contract names (claude-tasks#4421) and nothing else, so the
receiver can be proven before the island's sender is revived.

THE ENVELOPE IS THE CONTRACT. Data-only, no `notification` block (a display
message gives the app no code execution and cannot ring), `priority: HIGH`
uppercase (lowercase is the decommissioned legacy API's spelling), and `data` is
`map<string,string>`.

USAGE

    # No delivery: validate_only against a fake token. A 400 INVALID_ARGUMENT
    # naming `message.token` means credential, project and envelope are all
    # accepted. Run this BEFORE trusting silence.
    tool/fcm_push.py probe

    tool/fcm_push.py invite --token <fcm> --channel <channel id>
    tool/fcm_push.py end    --token <fcm> --channel <channel id>
    tool/fcm_push.py raw    --token <fcm> --data '{"c":"x","k":"bogus"}'

CREDENTIAL. No service account exists for `aiko-chat-push` and none should be
minted for a test: an OWNER user token can call FCM v1 directly. This uses
`gcloud auth print-access-token` for FCM_ACCOUNT (default admin@enspyr.co, the
account that can see the project). Override with FCM_ACCOUNT / FCM_PROJECT.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

PROJECT = os.environ.get("FCM_PROJECT", "aiko-chat-push")
ACCOUNT = os.environ.get("FCM_ACCOUNT", "admin@enspyr.co")
GCLOUD = os.environ.get("GCLOUD", "gcloud")

# Short on purpose: a ring delivered a minute late is a ring for a call that is
# over. Matches the order of the app's RING_CEILING_MS backstop.
TTL = "30s"


def access_token() -> str:
    return subprocess.check_output(
        [GCLOUD, "auth", "print-access-token", f"--account={ACCOUNT}"],
        text=True,
    ).strip()


def send(token: str, data: dict, validate_only: bool = False,
         quiet: bool = False):
    """Returns the exit code; with `quiet`, returns (status, body) instead."""
    if not all(isinstance(v, str) for v in data.values()):
        sys.exit("data values must all be strings — FCM 400s anything else")
    body = {
        "message": {
            "token": token,
            "data": data,
            "android": {"priority": "HIGH", "ttl": TTL},
        }
    }
    if validate_only:
        body["validate_only"] = True
    req = urllib.request.Request(
        f"https://fcm.googleapis.com/v1/projects/{PROJECT}/messages:send",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {access_token()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            status, text = resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode()
    if quiet:
        return status, text
    print(status, text)
    return 0 if status == 200 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("probe")
    for name in ("invite", "end"):
        p = sub.add_parser(name)
        p.add_argument("--token", required=True)
        p.add_argument("--channel", required=True)
    raw = sub.add_parser("raw")
    raw.add_argument("--token", required=True)
    raw.add_argument("--data", required=True, help="JSON object of strings")
    args = parser.parse_args()

    if args.cmd == "probe":
        # PASS IS ONE SPECIFIC FAILURE: a 400 that names `message.token`. Google
        # only gets as far as judging the token once auth, project and envelope
        # are all accepted. Any other outcome — 401/403 auth, 404 project, a 400
        # about the envelope — is a FAIL, and this used to exit 0 on all of them.
        # (Tesla, PR #210 round 1.)
        code, body = send("not-a-real-token", {"c": "probe", "k": "call_invite"},
                          validate_only=True, quiet=True)
        ok = code == 400 and "message.token" in body
        print("PROBE PASS" if ok else f"PROBE FAIL ({code}): {body[:300]}")
        return 0 if ok else 1
    if args.cmd == "raw":
        return send(args.token, json.loads(args.data))
    kind = "call_invite" if args.cmd == "invite" else "call_end"
    return send(args.token, {"c": args.channel, "k": kind})


if __name__ == "__main__":
    sys.exit(main())
