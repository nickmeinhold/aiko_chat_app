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
    upload = sub.add_parser("upload", help="upload an IPA via altool")
    upload.add_argument("--ipa", required=True)
    args = parser.parse_args()

    key_id, issuer_id, key_path = load_creds()
    token = make_token(key_id, issuer_id, key_path)
    {"app": cmd_app, "builds": cmd_builds, "testers": cmd_testers, "upload": cmd_upload}[
        args.cmd
    ](token, args)


if __name__ == "__main__":
    main()
