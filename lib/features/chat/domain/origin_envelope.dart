/// The **wire carriage** for a sovereign message signature (wire-half crucible,
/// `docs/crucible/sovereign-message-signing/wire-half/`).
///
/// [message_signing.dart] produces the signature over [signingBytes]; THIS file
/// is the `origin` envelope that carries it across the wire and the SINGLE
/// admission gate ([validateOrigin]) that both:
///   * the OUTBOUND path asserts through before emit (never emit a malformed
///     envelope — the gateway's `_REQUIRED_KEYS` is an exact set, so an extra key
///     is silently dropped today but `bad_origin`-rejected once carriage deploys),
///   * the INBOUND path admits through before persist (governing law of the
///     temper: *delivered ≠ carried/authenticated* — the transport hands us the
///     echo, it does NOT vouch for it; a stale/hostile/federated gateway can inject
///     unbounded or malformed JSON, so we re-validate at the boundary where we
///     consume it, never trusting that "the gateway already checked").
///
/// This is a byte-for-byte mirror of the gateway carrier's `validate_origin`
/// (aiko-chat-island `src/aiko_gateway/domain/signing.py`, PR #66) — the two are
/// pinned to the same golden vector so app-emit and gateway-admit can never drift.
///
/// SCOPE: shape validation only. This NEVER checks the signature (that is
/// [verifySignature], run on ingest by the inbound persist step) and NEVER binds
/// `sender_pubkey` to an account (echo ≠ identity — the pubkey→account binding is
/// peer PR B; until it lands, no "verified sender" UI, see wire-half DESIGN.md
/// named tradeoff #1).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'message_signing.dart'
    show MessageSignature, SignedPayload, verifySignature;

/// EdDSA is the ONLY accepted algorithm — allowlisted, never read from the
/// envelope's own claim (JWT alg-confusion class).
const String kOriginAlg = 'EdDSA';

/// The frozen v1 envelope discriminator. A field-set change is a `v2`, never a
/// silent add.
const int kOriginVersion = 1;

/// The frozen v1 key set — EXACTLY these, no more, no fewer. Mirrors the
/// gateway's `_REQUIRED_KEYS`.
const Set<String> _kRequiredKeys = {
  'v',
  'alg',
  'key_version',
  'sender_pubkey',
  'client_msg_id',
  'signed_at_ms',
  'sig',
};

// ed25519 Multikey: multibase `z` (base58btc) over multicodec `0xed01` ‖ raw-32.
const List<int> _kMulticodecEd25519 = [0xed, 0x01];
const int _kPubkeyRawLen = 32;
const int _kSigRawLen = 64;

// Field caps — untrusted client input on a wire boundary. Generous but finite; a
// Multikey pubkey is ~48 chars, a raw-64 sig ~86 base64url chars. Mirrors the
// gateway caps so the two boundaries reject the identical set of oversize inputs.
const int _kMaxPubkeyStr = 128;
const int _kMaxSigStr = 128;
const int _kMaxClientMsgId = 64; // matches the messages.client_msg_id column width
const int _kMaxSignedAtMs = 1 << 62; // sane u64-ish upper bound, well past any real clock
const int _kMaxB58Str = 128; // decodeMultikey input cap (defense-in-depth for the bigint loop)

/// base58btc alphabet — the gateway's exact `_B58_ALPHABET` (Bitcoin ordering).
const String _kB58Alphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Unpadded base64url charset. The spec pins `sig` to base64url-unpadded, so we
/// reject `=` padding and any non-`[A-Za-z0-9_-]` byte BEFORE decoding — Dart's
/// `base64Url.decode` (like Python's) is permissive enough that a length check
/// alone would let a non-canonical string decode to 64 bytes and be echoed
/// verbatim across the trust boundary. Charset-gate first.
final RegExp _kB64UrlUnpadded = RegExp(r'^[A-Za-z0-9_-]+$');

/// A malformed/inconsistent signing `origin` envelope. Mirrors the gateway's
/// `OriginError`. The inbound caller drops the origin (keeping the message,
/// marked unverified); the outbound caller must never emit — a throw here means a
/// bug in our own construction.
class OriginError implements Exception {
  final String message;
  const OriginError(this.message);
  @override
  String toString() => 'OriginError: $message';
}

/// The validated, canonical projection of a wire `origin` envelope. Holds the
/// signature material in DECODED form (raw pubkey, raw sig) so a verifier can feed
/// it straight into [signingBytes] field #2 and [verifySignature]. The content
/// fields a verifier also needs (channel_id, body, reply_to) live on the MESSAGE,
/// not here — the envelope carries only what authenticates, the message carries
/// what is authenticated, stitched by [clientMsgId].
class OriginEnvelope {
  final int keyVersion;
  final Uint8List rawPublicKey; // decoded raw-32 (Multikey stripped)
  final String clientMsgId; // == the frame's client_msg_id (bound at validate)
  final int signedAtMs;
  final Uint8List sig; // decoded raw-64

  const OriginEnvelope({
    required this.keyVersion,
    required this.rawPublicKey,
    required this.clientMsgId,
    required this.signedAtMs,
    required this.sig,
  });

  /// Build the OUTBOUND envelope from an in-hand [MessageSignature] (available at
  /// send time, threaded through — never re-fetched from cache). [clientMsgId]
  /// MUST be the same id the send frame carries (identical by construction in the
  /// app: one `clientTempId` feeds both the SignedPayload and the SendFrame).
  factory OriginEnvelope.fromSignature(
    MessageSignature s, {
    required String clientMsgId,
  }) =>
      OriginEnvelope(
        keyVersion: s.keyVersion,
        rawPublicKey: s.rawPublicKey,
        clientMsgId: clientMsgId,
        signedAtMs: s.signedAtMs,
        sig: s.sig,
      );

  /// The exact 7-key wire object — no extra keys (the gateway rejects unknowns).
  /// Encodes `sender_pubkey` as a Multikey and `sig` as unpadded base64url on the
  /// way out; both are decoded back on the way in by [validateOrigin].
  Map<String, dynamic> toWire() => {
        'v': kOriginVersion,
        'alg': kOriginAlg,
        'key_version': keyVersion,
        'sender_pubkey': encodeMultikey(rawPublicKey),
        'client_msg_id': clientMsgId,
        'signed_at_ms': signedAtMs,
        'sig': base64UrlUnpadded(sig),
      };

}

// NOTE on persistence (wire-half TEMPER T3, resolved): there is deliberately NO
// `toJson`/`toCanonicalJson` here. The cache persists the signature material as
// the existing TYPED drift columns (sig / senderPubkey / signedAtMs / keyVersion)
// — the framework serializes them, and a verifier reconstructs [signingBytes]
// from those fields, never from a stored JSON string. Storing the wire JSON would
// re-serialize (Map→encode is not byte-identical) AND is unnecessary: [toWire]
// regenerates a valid envelope from fields on demand for re-emit/forward.

/// Encode a raw-32 ed25519 public key as a multibase-base58btc Multikey
/// (`'z' + base58btc(0xed01 ‖ raw32)`). Reverse of [decodeMultikey]; the two
/// round-trip, pinned by the golden-vector test against the gateway's decoder.
String encodeMultikey(Uint8List raw32) {
  if (raw32.length != _kPubkeyRawLen) {
    throw OriginError(
        'public key must be $_kPubkeyRawLen raw bytes, got ${raw32.length}');
  }
  final full = Uint8List(_kMulticodecEd25519.length + _kPubkeyRawLen)
    ..setRange(0, _kMulticodecEd25519.length, _kMulticodecEd25519)
    ..setRange(_kMulticodecEd25519.length, _kMulticodecEd25519.length + _kPubkeyRawLen, raw32);
  return 'z${_b58encode(full)}';
}

/// Decode an ed25519 Multikey (`z` + base58btc(`0xed01` ‖ 32 raw bytes)) to the
/// raw 32-byte public key — what a verifier feeds into [signingBytes] field #2.
/// Mirror of the gateway's `decode_multikey`. Throws [OriginError] on any
/// malformation.
Uint8List decodeMultikey(String s) {
  if (s.isEmpty || s[0] != 'z') {
    throw const OriginError(
        'sender_pubkey must be a multibase-base58btc Multikey (z…)');
  }
  // Length-guard before the O(n^2) bigint decode — defense in depth even if a
  // caller forgets the field cap.
  if (s.length > _kMaxB58Str) {
    throw const OriginError('sender_pubkey too long');
  }
  final decoded = _b58decode(s.substring(1));
  if (decoded.length < _kMulticodecEd25519.length ||
      decoded[0] != _kMulticodecEd25519[0] ||
      decoded[1] != _kMulticodecEd25519[1]) {
    throw const OriginError(
        'sender_pubkey is not an ed25519 Multikey (bad multicodec)');
  }
  final raw = decoded.sublist(_kMulticodecEd25519.length);
  if (raw.length != _kPubkeyRawLen) {
    throw OriginError(
        'sender_pubkey raw length ${raw.length} != $_kPubkeyRawLen');
  }
  return Uint8List.fromList(raw);
}

/// Encode raw bytes as UNPADDED base64url (`[A-Za-z0-9_-]`, no `=`).
String base64UrlUnpadded(Uint8List raw) {
  final s = base64Url.encode(raw);
  final pad = s.indexOf('=');
  return pad == -1 ? s : s.substring(0, pad);
}

/// Strictly decode UNPADDED base64url and assert an exact decoded length.
/// Charset-gate BEFORE decoding (Dart's decoder tolerates padding / is lenient),
/// so a padded or standard-alphabet string can't decode to the right length and
/// slip across the boundary as if canonical. Mirror of the gateway's `_b64url_raw`.
Uint8List _b64urlRaw(String s, {required int expectLen, required String field}) {
  if (!_kB64UrlUnpadded.hasMatch(s)) {
    throw OriginError("$field must be unpadded base64url ([A-Za-z0-9_-], no '=')");
  }
  final Uint8List raw;
  try {
    raw = base64Url.decode(base64Url.normalize(s));
  } on FormatException catch (e) {
    throw OriginError('$field is not valid base64url: ${e.message}');
  }
  if (raw.length != expectLen) {
    throw OriginError('$field decoded length ${raw.length} != $expectLen');
  }
  return raw;
}

/// Validate a wire `origin` envelope at a trust boundary and return the canonical
/// [OriginEnvelope], or `null` when the origin is absent (an unsigned message —
/// legal; unsigned history predates the feature). Throws [OriginError] on any
/// malformation. **Shape only — the signature is NOT verified here.**
///
/// Byte-for-byte mirror of the gateway's `validate_origin`, so the app admits
/// exactly what the gateway carries and vice versa. Used BOTH as the outbound
/// self-assert (build → validate → emit) AND the inbound admission gate
/// (receive → validate → persist), which is why it lives with the primitive and
/// not the transport.
OriginEnvelope? validateOrigin(
  Object? raw, {
  required String frameClientMsgId,
}) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw const OriginError('origin must be a JSON object');
  }
  final keys = raw.keys.map((k) => k.toString()).toSet();
  if (keys.length != raw.length || !_setEquals(keys, _kRequiredKeys)) {
    final missing = _kRequiredKeys.difference(keys).toList()..sort();
    final extra = keys.difference(_kRequiredKeys).toList()..sort();
    throw OriginError('origin key set invalid (missing=$missing, unexpected=$extra)');
  }

  // `v`: frozen discriminator. In Dart a JSON `true`/`false` decodes to `bool`,
  // which `is! int` already rejects — but we keep the intent explicit to match
  // the frozen contract.
  final v = raw['v'];
  if (v is! int || v is bool || v != kOriginVersion) {
    throw OriginError('origin.v ${_show(v)} unsupported (expected int $kOriginVersion)');
  }
  if (raw['alg'] != kOriginAlg) {
    throw OriginError('origin.alg ${_show(raw['alg'])} not allowed (only "$kOriginAlg")');
  }
  final kv = raw['key_version'];
  if (kv is! int || kv is bool || kv < 1) {
    throw const OriginError('origin.key_version must be an integer >= 1');
  }

  final pubkey = raw['sender_pubkey'];
  if (pubkey is! String || pubkey.length > _kMaxPubkeyStr) {
    throw const OriginError('origin.sender_pubkey must be a string within the size cap');
  }
  final rawPublicKey = decodeMultikey(pubkey); // throws if not a well-formed Multikey

  final cmid = raw['client_msg_id'];
  if (cmid is! String || cmid.length > _kMaxClientMsgId) {
    throw const OriginError('origin.client_msg_id must be a string within the size cap');
  }
  if (cmid != frameClientMsgId) {
    throw const OriginError('origin.client_msg_id does not match the frame client_msg_id');
  }

  final ts = raw['signed_at_ms'];
  if (ts is! int || ts is bool || ts < 0 || ts > _kMaxSignedAtMs) {
    throw const OriginError('origin.signed_at_ms must be a sane non-negative integer');
  }

  final sig = raw['sig'];
  if (sig is! String || sig.length > _kMaxSigStr) {
    throw const OriginError('origin.sig must be a string within the size cap');
  }
  final rawSig = _b64urlRaw(sig, expectLen: _kSigRawLen, field: 'origin.sig');

  return OriginEnvelope(
    keyVersion: kv,
    rawPublicKey: rawPublicKey,
    clientMsgId: cmid,
    signedAtMs: ts,
    sig: rawSig,
  );
}

/// Verify a validated inbound [OriginEnvelope] against the MESSAGE's own content
/// fields. The envelope carries the signature material ([rawPublicKey], [sig],
/// signed [clientMsgId], [signedAtMs]); the content it authenticates
/// ([channelId], [body], [replyTo]) comes from the message itself — this is the
/// "verifier-sufficient" reconstruction. Returns the verdict; NEVER throws — a
/// reconstruction/verify error (e.g. a signed field that trips [signingBytes]'
/// domain bounds) is `false` (carried-but-invalid), not a crash at ingest.
Future<bool> verifyOrigin(
  OriginEnvelope o, {
  required String channelId,
  required String body,
  String? replyTo,
}) async {
  try {
    final payload = SignedPayload(
      rawPublicKey: o.rawPublicKey,
      channelId: channelId,
      clientMsgId: o.clientMsgId,
      signedAtMs: o.signedAtMs,
      body: body,
      replyTo: replyTo,
    );
    return await verifySignature(o.rawPublicKey, o.sig, payload);
  } catch (_) {
    return false;
  }
}

// --- base58btc (no external dep; BigInt-backed, mirrors the gateway) ---

String _b58encode(Uint8List input) {
  var zeros = 0;
  while (zeros < input.length && input[zeros] == 0) {
    zeros++;
  }
  var num = BigInt.zero;
  final b256 = BigInt.from(256);
  for (final b in input) {
    num = num * b256 + BigInt.from(b);
  }
  final b58 = BigInt.from(58);
  final digits = <int>[];
  while (num > BigInt.zero) {
    digits.add((num % b58).toInt());
    num = num ~/ b58;
  }
  final sb = StringBuffer();
  for (var i = 0; i < zeros; i++) {
    sb.write(_kB58Alphabet[0]); // leading zero byte → '1'
  }
  for (var i = digits.length - 1; i >= 0; i--) {
    sb.write(_kB58Alphabet[digits[i]]);
  }
  return sb.toString();
}

Uint8List _b58decode(String s) {
  var num = BigInt.zero;
  final b58 = BigInt.from(58);
  for (final ch in s.split('')) {
    final idx = _kB58Alphabet.indexOf(ch);
    if (idx < 0) {
      throw const OriginError('sender_pubkey is not valid base58btc');
    }
    num = num * b58 + BigInt.from(idx);
  }
  // big-endian bytes, preserving leading-zero ('1') bytes
  final body = <int>[];
  var n = num;
  final b256 = BigInt.from(256);
  while (n > BigInt.zero) {
    body.insert(0, (n % b256).toInt());
    n = n ~/ b256;
  }
  var pad = 0;
  while (pad < s.length && s[pad] == '1') {
    pad++;
  }
  return Uint8List.fromList([...List.filled(pad, 0), ...body]);
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

String _show(Object? v) => v is String ? '"$v"' : '$v';
