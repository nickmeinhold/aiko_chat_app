#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["cryptography"]
# ///
"""App Store Connect driver for aiko_chat_app: query builds, TestFlight state, upload IPAs.

Run it directly (`tool/asc.py builds`) — uv materialises the dependency per-run,
so there is no venv to go stale.

Credentials come from ~/keystores/aiko-asc.env (ASC_KEY_ID / ASC_ISSUER_ID /
ASC_KEY_PATH); nothing secret lives in this repo.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "cc.imagineering.aikoChatApp"
ENV_FILE = Path.home() / "keystores" / "aiko-asc.env"


def load_creds() -> tuple[str, str, Path]:
    env = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    env.update({k: v for k, v in os.environ.items() if k.startswith("ASC_")})
    try:
        key_path = Path(env["ASC_KEY_PATH"]).expanduser()
        return env["ASC_KEY_ID"], env["ASC_ISSUER_ID"], key_path
    except KeyError as exc:
        sys.exit(f"missing {exc} — set it in {ENV_FILE} or the environment")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(key_id: str, issuer_id: str, key_path: Path) -> str:
    """Self-sign a short-lived ES256 JWT. Apple caps the lifetime at 20 minutes."""
    key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{b64url(raw)}"


def get(path: str, token: str) -> dict:
    url = path if path.startswith("http") else f"{API}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.exit(f"HTTP {exc.code} on {url}\n{exc.read().decode()}")


def patch(path: str, token: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(payload).encode(),
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            # Relationship writes answer 204 with no body. An empty response is
            # a successful write here, not a parse failure.
            body = resp.read()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as exc:
        sys.exit(f"HTTP {exc.code} on PATCH {path}\n{exc.read().decode()}")


def find_app(token: str) -> dict:
    data = get(f"/apps?filter[bundleId]={BUNDLE_ID}", token)
    if not data["data"]:
        sys.exit(f"no app record for {BUNDLE_ID}")
    return data["data"][0]


def cmd_app(token: str, _args) -> None:
    app = find_app(token)
    attrs = app["attributes"]
    print(f"{attrs['name']}  id={app['id']}  bundle={attrs['bundleId']}  sku={attrs.get('sku')}")


def cmd_builds(token: str, args) -> None:
    app = find_app(token)
    data = get(
        f"/builds?filter[app]={app['id']}&limit={args.limit}"
        "&sort=-version&include=preReleaseVersion",
        token,
    )
    versions = {
        item["id"]: item["attributes"]["version"]
        for item in data.get("included", [])
        if item["type"] == "preReleaseVersions"
    }
    if not data["data"]:
        print("no builds")
        return
    for build in data["data"]:
        attrs = build["attributes"]
        rel = build["relationships"].get("preReleaseVersion", {}).get("data") or {}
        short = versions.get(rel.get("id"), "?")
        print(
            f"{short} ({attrs['version']})  {attrs['processingState']:<10} "
            f"expired={attrs.get('expired')}  uploaded={attrs.get('uploadedDate')}"
        )


def cmd_testers(token: str, _args) -> None:
    app = find_app(token)
    groups = get(f"/apps/{app['id']}/betaGroups?limit=50", token)
    for group in groups["data"]:
        attrs = group["attributes"]
        kind = "internal" if attrs.get("isInternalGroup") else "external"
        members = get(f"/betaGroups/{group['id']}/betaTesters?limit=50", token)
        print(f"[{kind}] {attrs['name']}  ({len(members['data'])} testers)")
        for tester in members["data"]:
            t = tester["attributes"]
            name = " ".join(filter(None, [t.get("firstName"), t.get("lastName")])) or "—"
            print(f"    {t.get('email')}  {name}  state={t.get('state')}")


def cmd_status(token: str, args) -> None:
    """Answer the only question a release actually asks: can a tester install it yet?

    `processingState=VALID` does NOT mean installable — it means Apple finished
    processing. The terminal observable is the build appearing in a beta group
    with internalBuildState=IN_BETA_TESTING.
    """
    app = find_app(token)
    builds = get(f"/builds?filter[app]={app['id']}&limit=20&sort=-version", token)
    # A build NUMBER is not a unique key: iOS and macOS upload under the same
    # version string, so a lookup that takes the first match can report on the
    # wrong platform's binary. Every match is reported and all must be installable.
    matches = [b for b in builds["data"] if b["attributes"]["version"] == args.build]
    if not matches:
        sys.exit(f"build {args.build} not found (may not have registered yet)")

    groups = get(f"/apps/{app['id']}/betaGroups?limit=50", token)["data"]
    # betaGroups is not GET-able from the build side (CREATE/DELETE only), so
    # membership has to be asked from the group side. That endpoint in turn
    # rejects `sort`, hence the wide limit and a local scan.
    membership = {
        group["id"]: {b["id"] for b in get(f"/betaGroups/{group['id']}/builds?limit=200", token)["data"]}
        for group in groups
    }

    all_installable = True
    for match in matches:
        detail = get(f"/builds/{match['id']}/buildBetaDetail", token)["data"]["attributes"]
        print(f"build {args.build}  id={match['id']}")
        print(f"  processingState    = {match['attributes']['processingState']}")
        print(f"  internalBuildState = {detail.get('internalBuildState')}")
        print(f"  externalBuildState = {detail.get('externalBuildState')}")
        print(f"  autoNotifyEnabled  = {detail.get('autoNotifyEnabled')}")

        installable = False
        for group in groups:
            attrs = group["attributes"]
            kind = "internal" if attrs.get("isInternalGroup") else "external"
            present = match["id"] in membership[group["id"]]
            print(f"  [{kind}] {attrs['name']}: {'YES' if present else 'no'}")
            if present and kind == "internal":
                installable = True
        all_installable &= installable

    n = len(matches)
    plural = f"all {n} binaries" if n > 1 else "binary"
    verdict = (
        f"INSTALLABLE by internal testers ({plural})"
        if all_installable
        else "NOT yet installable"
    )
    print(f"\n=> {verdict}")
    sys.exit(0 if all_installable else 1)


def post(path: str, token: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as exc:
        sys.exit(f"HTTP {exc.code} on POST {path}\n{exc.read().decode()}")


def cmd_release(token: str, args) -> None:
    """Stage an App Store version: create it, attach the build, set the listing.

    Deliberately stops BEFORE submitting for review. Everything here is
    reversible — a staged version can be edited or deleted — whereas submission
    hands the build to Apple. `submit` is the separate, irreversible step.
    """
    app = find_app(token)
    existing = get(f"/apps/{app['id']}/appStoreVersions?limit=20", token)["data"]
    version = next(
        (
            v
            for v in existing
            if v["attributes"]["versionString"] == args.version
            and v["attributes"]["platform"] == args.platform
        ),
        None,
    )
    if version is None:
        version = post(
            "/appStoreVersions",
            token,
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": args.platform,
                        "versionString": args.version,
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app["id"]}}
                    },
                }
            },
        )["data"]
        print(f"created {args.platform} version {args.version}  id={version['id']}")
    else:
        state = version["attributes"].get("appStoreState")
        if state in ("READY_FOR_SALE", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE"):
            sys.exit(
                f"{args.platform} {args.version} is already {state} — refusing to edit it"
            )
        print(f"reusing {args.platform} version {args.version} ({state})  id={version['id']}")

    # The build must be attached to the SAME platform's version. A build number
    # is not unique across platforms, so match on the platform's own build list.
    builds = get(
        f"/builds?filter[app]={app['id']}&limit=40&sort=-version", token
    )["data"]
    candidates = [b for b in builds if b["attributes"]["version"] == args.build]
    if not candidates:
        sys.exit(f"build {args.build} not found")
    chosen = None
    for build in candidates:
        detail = get(f"/builds/{build['id']}", token)["data"]
        if detail["attributes"]["processingState"] != "VALID":
            continue
        chosen = build
        break
    if chosen is None:
        sys.exit(f"build {args.build} is not VALID yet — cannot attach it")

    patch(
        f"/appStoreVersions/{version['id']}/relationships/build",
        token,
        {"data": {"type": "builds", "id": chosen["id"]}},
    )
    print(f"attached build {args.build} ({chosen['id']})")

    locales = get(
        f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=10",
        token,
    )["data"]
    if not locales:
        sys.exit("no localizations on this version — create one in App Store Connect first")

    attrs = {}
    if args.whats_new:
        attrs["whatsNew"] = Path(args.whats_new).read_text().strip()
    if args.support_url:
        attrs["supportUrl"] = args.support_url
    if args.marketing_url:
        attrs["marketingUrl"] = args.marketing_url
    if attrs:
        for loc in locales:
            patch(
                f"/appStoreVersionLocalizations/{loc['id']}",
                token,
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": loc["id"],
                        "attributes": attrs,
                    }
                },
            )
            print(f"updated listing [{loc['attributes']['locale']}]: {', '.join(attrs)}")

    # Readback, because the point is what the listing SAYS, not what the PATCH returned.
    print("\nreadback:")
    fresh = get(f"/appStoreVersions/{version['id']}?include=build", token)
    battrs = (fresh.get("included") or [{}])[0].get("attributes", {})
    print(f"  version   = {fresh['data']['attributes']['versionString']} ({fresh['data']['attributes']['platform']})")
    print(f"  state     = {fresh['data']['attributes']['appStoreState']}")
    print(f"  build     = {battrs.get('version', 'NONE ATTACHED')}")
    for loc in get(
        f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=10", token
    )["data"]:
        la = loc["attributes"]
        print(f"  [{la['locale']}] support={la.get('supportUrl')} marketing={la.get('marketingUrl')}")
    print(f"\nSTAGED — not submitted. Review it, then: asc.py submit --version {args.version} --platform {args.platform} --yes")


def cmd_expire(token: str, args) -> None:
    """Retire builds so they stop appearing in TestFlight.

    TestFlight orders by SHORT VERSION STRING, not upload date, so a stale build
    with a higher version string sits above every newer one and reads as current.
    That is what expiry is for here: the build is not broken, it is misleading.

    Expiry cannot be undone, so this DRY-RUNS unless --yes is passed, and the
    plan it prints is built from what the server returned rather than from the
    numbers on the command line.
    """
    app = find_app(token)
    data = get(
        f"/builds?filter[app]={app['id']}&limit=50&sort=-version"
        "&include=preReleaseVersion",
        token,
    )
    versions = {
        item["id"]: item["attributes"]["version"]
        for item in data.get("included", [])
        if item["type"] == "preReleaseVersions"
    }

    wanted = set(args.build)
    plan = []
    for build in data["data"]:
        rel = build["relationships"].get("preReleaseVersion", {}).get("data") or {}
        short = versions.get(rel.get("id"), "?")
        if build["attributes"]["version"] in wanted:
            plan.append((build, short))

    missing = wanted - {b["attributes"]["version"] for b, _ in plan}
    if missing:
        sys.exit(f"no such build(s): {', '.join(sorted(missing))} — nothing expired")

    for build, short in plan:
        state = "already expired" if build["attributes"].get("expired") else "will expire"
        print(f"  {short} ({build['attributes']['version']})  {state}  id={build['id']}")

    todo = [(b, s) for b, s in plan if not b["attributes"].get("expired")]
    if not todo:
        print("\nnothing to do — every named build is already expired")
        return
    if not args.yes:
        print(f"\nDRY RUN — {len(todo)} build(s) would be expired. Re-run with --yes.")
        return

    for build, short in todo:
        patch(
            f"/builds/{build['id']}",
            token,
            {
                "data": {
                    "type": "builds",
                    "id": build["id"],
                    "attributes": {"expired": True},
                }
            },
        )
        print(f"expired {short} ({build['attributes']['version']})")

    # Read the state back from the server rather than trusting the 200s: the
    # point of the command is what TestFlight shows, not what the PATCH returned.
    print("\nreadback:")
    after = get(
        f"/builds?filter[app]={app['id']}&limit=50&sort=-version", token
    )
    stuck = [
        b["attributes"]["version"]
        for b in after["data"]
        if b["attributes"]["version"] in wanted and not b["attributes"].get("expired")
    ]
    for build in after["data"]:
        if build["attributes"]["version"] in wanted:
            print(f"  build {build['attributes']['version']}: expired={build['attributes']['expired']}")
    if stuck:
        sys.exit(f"\nFAILED — still not expired: {', '.join(stuck)}")
    print("\nall named builds are expired")


def cmd_submit(token: str, args) -> None:
    """Hand a staged version to Apple for review. The irreversible step.

    Success is read back from reviewSubmission.state, NOT appStoreVersion.state:
    the version is a field this side moves, while the submission is the object
    the counterparty advances. A version flipping to WAITING_FOR_REVIEW without
    a submission behind it is our own write reflected back at us.
    """
    app = find_app(token)
    version = next(
        (
            v
            for v in get(f"/apps/{app['id']}/appStoreVersions?limit=20", token)["data"]
            if v["attributes"]["versionString"] == args.version
            and v["attributes"]["platform"] == args.platform
        ),
        None,
    )
    if version is None:
        sys.exit(f"no {args.platform} version {args.version} — run `release` first")

    detail = get(f"/appStoreVersions/{version['id']}?include=build", token)
    build = (detail.get("included") or [{}])[0].get("attributes", {}).get("version")
    if not build:
        sys.exit("no build attached to that version — refusing to submit")

    print(f"{args.platform} {args.version}  build {build}  state={detail['data']['attributes']['appStoreState']}")
    if not args.yes:
        print("\nDRY RUN — this would submit to Apple for review. Re-run with --yes.")
        return

    submission = post(
        "/reviewSubmissions",
        token,
        {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": args.platform},
                "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}},
            }
        },
    )["data"]
    print(f"opened review submission {submission['id']}")

    post(
        "/reviewSubmissionItems",
        token,
        {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": submission["id"]}
                    },
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version["id"]}
                    },
                },
            }
        },
    )
    print("added the version to the submission")

    patch(
        f"/reviewSubmissions/{submission['id']}",
        token,
        {
            "data": {
                "type": "reviewSubmissions",
                "id": submission["id"],
                "attributes": {"submitted": True},
            }
        },
    )

    state = get(f"/reviewSubmissions/{submission['id']}", token)["data"]["attributes"]
    print(f"\nreadback: reviewSubmission.state = {state.get('state')}")
    print(f"          submitted = {state.get('submittedDate')}")
    if state.get("state") in (None, "READY_FOR_REVIEW"):
        sys.exit(
            f"NOT submitted — state is {state.get('state')}; the submission was "
            "created but Apple has not accepted it"
        )
    print("\nSUBMITTED — Apple has the build.")


def cmd_upload(token: str, args) -> None:
    """Binary upload goes through altool, which reads the .p8 from its own key dir."""
    key_id, issuer_id, key_path = load_creds()
    dest = Path.home() / ".appstoreconnect" / "private_keys"
    dest.mkdir(parents=True, exist_ok=True)
    installed = dest / key_path.name
    if not installed.exists():
        installed.write_bytes(key_path.read_bytes())
        installed.chmod(0o600)
        print(f"installed key -> {installed}")
    result = subprocess.run(
        [
            "xcrun", "altool", "--upload-app",
            "--type", "ios",
            "--file", args.ipa,
            "--apiKey", key_id,
            "--apiIssuer", issuer_id,
        ],
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    sys.exit(result.returncode)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("app", help="show the App Store Connect record")
    builds = sub.add_parser("builds", help="list builds and their processing state")
    builds.add_argument("--limit", type=int, default=10)
    sub.add_parser("testers", help="list TestFlight groups and their testers")
    status = sub.add_parser("status", help="can a tester install this build yet?")
    status.add_argument("--build", required=True, help="build number, e.g. 12")
    rel = sub.add_parser("release", help="stage an App Store version (reversible)")
    rel.add_argument("--version", required=True)
    rel.add_argument("--build", required=True)
    rel.add_argument("--platform", default="IOS", choices=["IOS", "MAC_OS"])
    rel.add_argument("--whats-new", help="path to a file holding the release notes")
    rel.add_argument("--support-url")
    rel.add_argument("--marketing-url")
    sb = sub.add_parser("submit", help="hand a staged version to Apple (IRREVERSIBLE)")
    sb.add_argument("--version", required=True)
    sb.add_argument("--platform", default="IOS", choices=["IOS", "MAC_OS"])
    sb.add_argument("--yes", action="store_true", help="actually submit (default: dry run)")
    expire = sub.add_parser("expire", help="retire builds so TestFlight stops showing them")
    expire.add_argument("--build", required=True, nargs="+", help="build number(s), e.g. 1 2 3")
    expire.add_argument("--yes", action="store_true", help="actually expire (default: dry run)")
    upload = sub.add_parser("upload", help="upload an IPA via altool")
    upload.add_argument("--ipa", required=True)
    args = parser.parse_args()

    key_id, issuer_id, key_path = load_creds()
    token = make_token(key_id, issuer_id, key_path)
    {
        "app": cmd_app,
        "builds": cmd_builds,
        "testers": cmd_testers,
        "status": cmd_status,
        "expire": cmd_expire,
        "release": cmd_release,
        "submit": cmd_submit,
        "upload": cmd_upload,
    }[
        args.cmd
    ](token, args)


if __name__ == "__main__":
    main()
