#!/usr/bin/env python3
"""The OTHER party in the live ring test — an INDEPENDENT signer.

`test/live/ring_live_test.dart` drives this script as a separate process, a
separate account and, most importantly, a SEPARATE IMPLEMENTATION of the
signing contract. That separation is the whole value of the harness: the app's
own sign->verify round trip cannot tell a correct codec from a self-consistently
wrong one, so the only thing that can is a second implementation that never
shared a line of code with the first.

This file was rebuilt from `docs/crucible/sovereign-message-signing/SIGNING-SPEC.md`
after the original lived only in /tmp and evaporated — which left the Dart half
of the harness committed, tagged, and unrunnable, while the record described the
instrument as complete. It is committed HERE so that cannot recur: an instrument
that only one machine can run is not an instrument, it is an anecdote.

Conformance is pinned against the spec's published GOLDEN VECTOR rather than
against this file's own output, and `selftest` runs that check before any
network call. A codec verified only against itself is self-consistently wrong
exactly as often as it is right.

Usage (driven by the Dart test; env vars documented in its header):
    python3 tool/ring_probe.py selftest        # golden vector, no network
    python3 tool/ring_probe.py vector [reply_to]  # emit a signed frame, no network
    python3 tool/ring_probe.py invite          # ring the other party
    python3 tool/ring_probe.py end <server_id> # hang up on the call it names

Requires: pynacl, websockets, requests. base58btc is implemented inline rather
than imported, to keep the second implementation second.
"""

import asyncio
import base64
import json
import os
import struct
import sys
import time

import requests
import websockets
from nacl.signing import SigningKey

# --- the interop contract, transcribed from SIGNING-SPEC.md -------------------

DOMAIN_TAG = b"aikochat:msg:v1:EdDSA"
MULTICODEC_ED25519 = bytes([0xED, 0x01])
B58_ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# The two pinned sentinels. Signed and durable — never edit (call_invite.dart).
CALL_INVITE_BODY = "aiko:call/1 · 📞 started a call"
CALL_END_BODY = "aiko:call/1 · 📞 ended the call"


def _len_prefixed(field: bytes) -> bytes:
    """u32 big-endian length ‖ bytes. Without this, ('ab','c') and ('a','bc')
    would sign identical bytes — the spec calls the prefixing load-bearing."""
    return struct.pack(">I", len(field)) + field


def signing_bytes(
    raw_public_key: bytes,
    channel_id: str,
    client_msg_id: str,
    signed_at_ms: int,
    body: str,
    reply_to: str | None,
) -> bytes:
    """Field order is fixed by the spec: tag, pubkey, channel, msg id, ts, body,
    reply_to. `signed_at_ms` is a bare u64 with NO length prefix (it is fixed
    width); every other field carries one. Absent reply_to encodes as empty."""
    if len(raw_public_key) != 32:
        raise ValueError(f"pubkey must be 32 raw bytes, got {len(raw_public_key)}")
    if not channel_id:
        raise ValueError("channel_id must not be empty")
    if not client_msg_id:
        raise ValueError("client_msg_id must not be empty")
    if signed_at_ms < 0:
        raise ValueError("signed_at_ms must be non-negative")
    if reply_to is not None and reply_to == "":
        raise ValueError('reply_to must be null or non-empty, never ""')
    return b"".join(
        [
            _len_prefixed(DOMAIN_TAG),
            _len_prefixed(raw_public_key),
            _len_prefixed(channel_id.encode("utf-8")),
            _len_prefixed(client_msg_id.encode("utf-8")),
            struct.pack(">Q", signed_at_ms),
            _len_prefixed(body.encode("utf-8")),
            _len_prefixed((reply_to or "").encode("utf-8")),
        ]
    )


def b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    out = bytearray()
    while n:
        n, rem = divmod(n, 58)
        out.append(B58_ALPHABET[rem])
    for byte in data:  # leading zero bytes map to leading '1's
        if byte:
            break
        out.append(B58_ALPHABET[0])
    return bytes(reversed(out)).decode()


def multikey(raw32: bytes) -> str:
    """Wire form of the public key: multibase 'z' ‖ base58btc(0xed01 ‖ raw32).
    The SIGNED bytes never contain this string — a verifier strips the prefix
    and feeds the raw 32 back into field #2."""
    return "z" + b58encode(MULTICODEC_ED25519 + raw32)


def b64url_unpadded(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def origin_wire(key: SigningKey, client_msg_id: str, signed_at_ms: int, sig: bytes):
    return {
        "v": 1,
        "alg": "EdDSA",
        "key_version": 1,
        "sender_pubkey": multikey(bytes(key.verify_key)),
        "client_msg_id": client_msg_id,
        "signed_at_ms": signed_at_ms,
        "sig": b64url_unpadded(sig),
    }


# --- the golden vector: an EXTERNAL known answer, not our own output ----------

GOLDEN_HEX = (
    "0000001561696b6f636861743a6d73673a76313a4564445341"
    "00000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    "000000066368616e2d3100000007746d702d616263"
    "0000019077fd3000"
    "0000000b68656c6c6f20776f726c64"
    "00000000"
)


def selftest() -> None:
    got = signing_bytes(
        raw_public_key=bytes(range(32)),
        channel_id="chan-1",
        client_msg_id="tmp-abc",
        signed_at_ms=1720000000000,
        body="hello world",
        reply_to=None,
    ).hex()
    want = GOLDEN_HEX
    if got != want:
        print("GOLDEN VECTOR MISMATCH — this signer is NON-CONFORMANT", file=sys.stderr)
        print(f"  want {want}", file=sys.stderr)
        print(f"  got  {got}", file=sys.stderr)
        raise SystemExit(2)
    print("selftest OK — signing bytes match the spec's golden vector")


# --- the network half ---------------------------------------------------------


def env(k: str) -> str:
    v = os.environ.get(k)
    if not v:
        raise SystemExit(f"{k} is required — see test/live/ring_live_test.dart")
    return v


def login(host: str, user: str, password: str) -> str:
    r = requests.post(
        f"https://{host}/v1/auth/login",
        json={"username": user, "password": password},
        timeout=20,
    )
    if r.status_code != 200:
        raise SystemExit(f"login failed {r.status_code}: {r.text}")
    return r.json()["access_token"]


async def send_signed(body: str, reply_to: str | None) -> str:
    host = env("AIKO_HOST")
    channel_id = env("RING_CHANNEL")
    token = login(host, env("RING_USER"), env("RING_PASS"))

    # A deterministic identity, so the app sees the SAME peer across runs.
    seed = env("RING_KEY_SEED").encode("utf-8")
    key = SigningKey(seed.ljust(32, b"\0")[:32])

    client_msg_id = f"probe-{int(time.time() * 1000):x}"
    signed_at_ms = int(time.time() * 1000)
    payload = signing_bytes(
        raw_public_key=bytes(key.verify_key),
        channel_id=channel_id,
        client_msg_id=client_msg_id,
        signed_at_ms=signed_at_ms,
        body=body,
        reply_to=reply_to,
    )
    sig = key.sign(payload).signature

    frame = {
        "type": "send",
        "client_msg_id": client_msg_id,
        "channel_id": channel_id,
        "body": body,
        "origin": origin_wire(key, client_msg_id, signed_at_ms, sig),
    }
    if reply_to is not None:
        frame["reply_to"] = reply_to

    async with websockets.connect(f"wss://{host}/v1/ws?token={token}") as ws:
        # SUBSCRIBE BEFORE SEND. The gateway routes acks and fanout to the
        # channels this socket has subscribed to, so a send on a cold socket can
        # be accepted while its ack goes nowhere — which would look identical to
        # a refusal from here, and would make the "no ack in 15s" exit below lie
        # about which half failed.
        await ws.send(
            json.dumps({"type": "subscribe", "channel_ids": [channel_id]})
        )
        await ws.send(json.dumps(frame))
        # Wait for the island's ack so a REFUSAL is loud rather than a silent
        # no-op. `reply_to` is an FK onto messages.id: naming a client id here
        # gets the whole frame rejected with `no_reply_target`, and a probe that
        # exits 0 on that would report a passing test for a hangup that never
        # left the process.
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=deadline - time.time())
            except asyncio.TimeoutError:
                break
            msg = json.loads(raw)
            if msg.get("type") == "error":
                raise SystemExit(f"island refused the frame: {raw}")
            if msg.get("client_msg_id") == client_msg_id:
                return json.dumps(
                    {"client_msg_id": client_msg_id, "ack": msg}, ensure_ascii=False
                )
    raise SystemExit(f"no ack for {client_msg_id} within 15s — nothing was sent")


def emit_vector(reply_to: str | None) -> str:
    """A signed frame, printed rather than sent — the whole conformance check
    minus the network.

    This exists because the live harness needs an island, two accounts and a
    password, so it runs approximately never, and an instrument that runs never
    is the one that quietly rots (this file spent a round existing only in
    /tmp). The interesting half of that test — does a signature from an
    INDEPENDENT implementation verify against the app's own verifier — needs
    none of those things. `test/features/chat/probe_conformance_test.dart` runs
    this command and feeds the result through `validateOrigin` + `verifyOrigin`,
    so the cross-implementation check runs on every ordinary `flutter test`.

    Deterministic seed and timestamp, so the output is a fixed vector rather
    than a fresh sample: a conformance test that generates new input each run
    tells you about today's input, not about the contract.
    """
    key = SigningKey(b"probe-conformance-seed".ljust(32, b"\0")[:32])
    channel_id = "01M0GS7FDWBVQ31950B1PTV2D0"
    client_msg_id = "probe-conformance-1"
    signed_at_ms = 1720000000000
    body = CALL_END_BODY if reply_to else CALL_INVITE_BODY
    sig = key.sign(
        signing_bytes(
            raw_public_key=bytes(key.verify_key),
            channel_id=channel_id,
            client_msg_id=client_msg_id,
            signed_at_ms=signed_at_ms,
            body=body,
            reply_to=reply_to,
        )
    ).signature
    frame = {
        "type": "send",
        "client_msg_id": client_msg_id,
        "channel_id": channel_id,
        "body": body,
        "origin": origin_wire(key, client_msg_id, signed_at_ms, sig),
    }
    if reply_to is not None:
        frame["reply_to"] = reply_to
    return json.dumps(frame, ensure_ascii=False)


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd = sys.argv[1]
    selftest()  # ALWAYS — never sign on the wire with an unpinned codec.
    if cmd == "selftest":
        return
    if cmd == "vector":
        print(emit_vector(sys.argv[2] if len(sys.argv) > 2 else None))
        return
    if cmd == "invite":
        print(asyncio.run(send_signed(CALL_INVITE_BODY, None)))
    elif cmd == "end":
        if len(sys.argv) < 3:
            raise SystemExit("end requires the SERVER ULID of the invitation")
        print(asyncio.run(send_signed(CALL_END_BODY, sys.argv[2])))
    else:
        raise SystemExit(f"unknown command {cmd!r}")


if __name__ == "__main__":
    main()
