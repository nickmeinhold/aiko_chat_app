/// The AUTHORSHIP-half reader for "The Carried Record" (docs/RECOMBINATION.md):
/// a pure, side-effect-free reader that lists a subject's locally-cached signed
/// messages and INDEPENDENTLY re-verifies each one — from the carried bytes
/// alone, with no network and no trust in the cached ingest-time verdict.
///
/// TRUST MODEL — read before touching. An Ed25519 signature proves possession
/// of the private key for `origin.rawPublicKey`; it does NOT prove that key is
/// the subject's. The signed payload carries no userId, so `sender.userId` (a
/// cache-supplied, non-crypto field) cannot be trusted to bind a message to the
/// subject. A forged/cached row with `sender.userId == me` carrying a VALID
/// signature from ANY attacker's key would otherwise read as "provably yours".
///
/// So [carriedRecord] binds the [CarriedRecordVerdict.verified] verdict to the
/// subject's KNOWN public key ([subjectPublicKey] — v1: this device's sovereign
/// key). A message is `verified` only if its signature is valid AND its carried
/// public key byte-equals the subject's key. A valid signature under a DIFFERENT
/// key is [CarriedRecordVerdict.foreignKey] (another device of yours — multi-
/// device is not yet supported — or someone else entirely); it is never claimed
/// as yours.
library;

import 'dart:typed_data';

import 'message.dart';
import 'message_signing.dart' show SignedPayload, verifySignature;

/// The verdict for a single entry in a subject's carried record.
enum CarriedRecordVerdict {
  /// Signature re-verified independently AND signed by the subject's own key.
  verified,

  /// Signature material is present but failed independent re-verification
  /// (tampered content, corrupt bytes, ...). Never claimed as the subject's.
  invalid,

  /// Signature is cryptographically VALID but under a public key that is NOT
  /// the subject's known key. Provably signed by *someone* holding that key —
  /// another device of yours (multi-device is not yet supported) or another
  /// person — so it must never be claimed as "yours".
  foreignKey,

  /// No signature material was carried for this message (pre-feature history,
  /// or the sender never signed). Absence is not evidence of dishonesty.
  unsigned,
}

class CarriedRecordEntry {
  final String id;
  final String body;
  final CarriedRecordVerdict verdict;
  final int? signedAtMs;

  const CarriedRecordEntry({
    required this.id,
    required this.body,
    required this.verdict,
    this.signedAtMs,
  });
}

class CarriedRecord {
  final String subjectUserId;
  final List<CarriedRecordEntry> entries;
  final int verifiedCount;
  final int invalidCount;
  final int foreignKeyCount;
  final int unsignedCount;

  const CarriedRecord({
    required this.subjectUserId,
    required this.entries,
    required this.verifiedCount,
    required this.invalidCount,
    required this.foreignKeyCount,
    required this.unsignedCount,
  });

  static const empty = CarriedRecord(
    subjectUserId: '',
    entries: [],
    verifiedCount: 0,
    invalidCount: 0,
    foreignKeyCount: 0,
    unsignedCount: 0,
  );
}

/// Build [subjectUserId]'s carried record from an in-hand list of locally
/// cached [Message]s, independently re-verifying every carried signature and
/// binding the `verified` verdict to [subjectPublicKey] (the subject's known
/// public key — v1: this device's sovereign key).
///
/// Pure reader: takes messages + the subject key as input rather than reaching
/// into the live repository/key store, so it stays hermetic (no DB, no network)
/// and the security guarantee is testable in isolation.
///
/// Fails CLOSED: with no subject id or no subject key there is nothing to bind
/// ownership to, so the result is empty rather than a list that could
/// mis-attribute anything.
Future<CarriedRecord> carriedRecord(
  String subjectUserId,
  List<Message> localMessages, {
  required Uint8List subjectPublicKey,
}) async {
  if (subjectUserId.isEmpty || subjectPublicKey.isEmpty) {
    return CarriedRecord.empty;
  }

  final mine = localMessages.where((m) => m.sender.userId == subjectUserId);

  final entries = <CarriedRecordEntry>[];
  var verified = 0;
  var invalid = 0;
  var foreignKey = 0;
  var unsigned = 0;

  for (final m in mine) {
    final origin = m.origin;
    if (origin == null) {
      entries.add(CarriedRecordEntry(
        id: m.clientTempId,
        body: m.body,
        verdict: CarriedRecordVerdict.unsigned,
      ));
      unsigned++;
      continue;
    }

    // Reconstruct SignedPayload from the CARRIED envelope (signature material)
    // + the message's own content fields (what the signature authenticates) —
    // an independent re-derivation, not a trust of any stored verdict.
    final payload = SignedPayload(
      rawPublicKey: origin.rawPublicKey,
      channelId: m.channelId,
      clientMsgId: origin.clientMsgId,
      signedAtMs: origin.signedAtMs,
      body: m.body,
      replyTo: m.replyToId,
    );

    bool sigOk;
    try {
      sigOk = await verifySignature(origin.rawPublicKey, origin.sig, payload);
    } on Object {
      // Fail CLOSED at the verify boundary: ANY throwable (Exception, Error,
      // TypeError from the crypto layer, an illegal content field) → invalid,
      // never verified. Catching only Exception here would let a non-Exception
      // Error escape to the error UI instead of classifying as invalid.
      sigOk = false;
    }

    final CarriedRecordVerdict verdict;
    if (!sigOk) {
      verdict = CarriedRecordVerdict.invalid;
      invalid++;
    } else if (!_bytesEqual(origin.rawPublicKey, subjectPublicKey)) {
      // Valid signature, but under a key that is NOT the subject's. Provably
      // signed by *someone* — but not provably the subject. Never "yours".
      verdict = CarriedRecordVerdict.foreignKey;
      foreignKey++;
    } else {
      verdict = CarriedRecordVerdict.verified;
      verified++;
    }

    entries.add(CarriedRecordEntry(
      id: m.clientTempId,
      body: m.body,
      verdict: verdict,
      signedAtMs: origin.signedAtMs,
    ));
  }

  return CarriedRecord(
    subjectUserId: subjectUserId,
    entries: entries,
    verifiedCount: verified,
    invalidCount: invalid,
    foreignKeyCount: foreignKey,
    unsignedCount: unsigned,
  );
}

/// Plain byte-equality for public keys. Public keys are not secret, so no
/// constant-time comparison is needed (timing leaks nothing an observer can't
/// already read off the wire).
bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
