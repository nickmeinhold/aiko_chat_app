/// Sovereign per-message signing (sovereign-message-signing crucible).
///
/// This file is the **interop contract**: the exact bytes a signature is
/// computed over. Any future verifier — gateway-side or peer-side — MUST
/// reproduce [signingBytes] byte-for-byte, so it is pinned by golden vectors
/// (see `docs/crucible/sovereign-message-signing/SIGNING-SPEC.md`) and must
/// never change under a version without bumping the domain tag.
///
/// SCOPE (Temper bright line): this produces + self-verifies signatures for
/// LOCAL verifiable history. It does NOT emit anything on the wire and makes NO
/// authorship claim beyond "the holder of this key signed these bytes" — binding
/// the key to a human/account is federation's job (#1760), explicitly deferred.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../../services/sovereign_key_store.dart';

/// The domain-separation tag. Binds BOTH the app + a fixed algorithm INTO the
/// signed bytes, so a signature can't be replayed against another structure and
/// an attacker can't downgrade the interpretation by swapping a wire `alg`
/// field. Changing the field set or algorithm ⇒ a new `v2` tag, never a silent
/// edit.
const String kSigningDomainTag = 'aikochat:msg:v1:EdDSA';

/// The tuple a signature authenticates. Every field a receiver acts on lives
/// here; omitting one would silently leave it unauthenticated.
class SignedPayload {
  final Uint8List rawPublicKey; // 32-byte Ed25519 key — included ⇒ key-substitution defence
  final String channelId; // else a sig replays into another channel
  final String clientMsgId; // the stable, verifier-reconstructable message id
  final int signedAtMs; // compose-time, fixed once; persisted separate from createdAt
  final String body;
  final String? replyTo;

  const SignedPayload({
    required this.rawPublicKey,
    required this.channelId,
    required this.clientMsgId,
    required this.signedAtMs,
    required this.body,
    this.replyTo,
  });
}

/// A produced signature plus the material a verifier needs alongside it.
class MessageSignature {
  final Uint8List sig; // raw 64-byte Ed25519 (R‖S), no DER
  final Uint8List rawPublicKey;
  final int signedAtMs;
  final int keyVersion;

  const MessageSignature({
    required this.sig,
    required this.rawPublicKey,
    required this.signedAtMs,
    required this.keyVersion,
  });
}

/// The pinned canonical serialization: hand-built, length-prefixed, and
/// domain-separated. Every variable-length field is prefixed with a fixed-width
/// big-endian u32 length so no two field boundaries can be reinterpreted
/// (`"ab"‖"c"` ≠ `"a"‖"bc"`). Transmit/verify these EXACT bytes — never
/// deserialize→reserialize before verifying (the Briar 2023 malleability bug).
Uint8List signingBytes(SignedPayload p) {
  // Fail LOUD at the cryptographic boundary (cage-match: Carnot). A signature is
  // only meaningful over well-formed inputs, and these invariants are what a
  // future verifier will assume.
  if (p.rawPublicKey.length != 32) {
    throw ArgumentError('sender public key must be 32 bytes (Ed25519), '
        'got ${p.rawPublicKey.length}');
  }
  if (p.channelId.isEmpty) throw ArgumentError('channelId must not be empty');
  if (p.clientMsgId.isEmpty) throw ArgumentError('clientMsgId must not be empty');
  if (p.signedAtMs < 0) throw ArgumentError('signedAtMs must be non-negative');
  // Absent (null) and present-empty ('') reply_to would serialize identically via
  // `?? ''`, breaking injectivity if a verifier distinguishes them. Forbid the
  // empty string so `null` is the ONLY "no reply" encoding (cage-match: Carnot).
  if (p.replyTo != null && p.replyTo!.isEmpty) {
    throw ArgumentError('replyTo must be null or non-empty, never "" '
        '(absent must not collide with present-empty)');
  }
  final out = BytesBuilder(copy: false);
  void lengthPrefixed(List<int> field) {
    final len = ByteData(4)..setUint32(0, field.length, Endian.big);
    out.add(len.buffer.asUint8List());
    out.add(field);
  }

  lengthPrefixed(utf8.encode(kSigningDomainTag));
  lengthPrefixed(p.rawPublicKey);
  lengthPrefixed(utf8.encode(p.channelId));
  lengthPrefixed(utf8.encode(p.clientMsgId));
  final ts = ByteData(8)..setUint64(0, p.signedAtMs, Endian.big);
  out.add(ts.buffer.asUint8List());
  lengthPrefixed(utf8.encode(p.body));
  lengthPrefixed(utf8.encode(p.replyTo ?? ''));
  return out.toBytes();
}

final Ed25519 _ed25519 = Ed25519();

/// Sign [p] with the device key, then IMMEDIATELY round-trip verify in
/// production. A self-verify failure THROWS rather than persisting a
/// wrong-forever signature (deferring recipient verify is disciplined; shipping
/// a broken sender signature is how you mint history that is invalid forever).
Future<MessageSignature> sign(SovereignKey key, SignedPayload p) async {
  // Slam the single door: the payload's pubkey MUST be the signing key's own.
  // Otherwise self-verify (below) could pass while the RETURNED/persisted pubkey
  // can't verify the sig — the exact wrong-forever class this self-check exists
  // to prevent (cage-match consensus: Carnot + Tesla).
  if (!_bytesEqual(p.rawPublicKey, key.rawPublicKey)) {
    throw ArgumentError('SignedPayload.rawPublicKey must equal the signing '
        "key's own public key");
  }
  final signature = await _ed25519.sign(signingBytes(p), keyPair: key.keyPair);
  final sig = Uint8List.fromList(signature.bytes);
  // Self-verify through the SAME path a future verifier uses — proving the
  // returned (pubkey, sig) pair verifies, not merely that the keypair signed.
  final ok = await verifySignature(p.rawPublicKey, sig, p);
  if (!ok) {
    throw StateError('sovereign self-verify failed — refusing to emit a signature');
  }
  return MessageSignature(
    sig: sig,
    rawPublicKey: p.rawPublicKey,
    signedAtMs: p.signedAtMs,
    keyVersion: key.keyVersion,
  );
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Verify a detached signature over [p]. Shipped now for the sender self-check;
/// the recipient path that calls this over inbound history is deferred (gated on
/// gateway carriage + a trust root), but the primitive is not.
Future<bool> verifySignature(
  Uint8List rawPublicKey,
  Uint8List sig,
  SignedPayload p,
) async {
  final publicKey = SimplePublicKey(rawPublicKey, type: KeyPairType.ed25519);
  return _ed25519.verify(
    signingBytes(p),
    signature: Signature(sig, publicKey: publicKey),
  );
}
