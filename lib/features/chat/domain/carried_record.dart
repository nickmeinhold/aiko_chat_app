/// SPIKE (`/ascend` cold-pole build — "The Carried Record", docs/RECOMBINATION.md):
/// a pure, side-effect-free reader that answers ONE falsifiable question —
/// can a subject's locally-cached signed messages be listed and each
/// signature INDEPENDENTLY re-verified from carried bytes alone, with no new
/// schema, no new routes, and no network?
///
/// This deliberately does NOT trust [Message.originCryptoValid] (the cached
/// ingest-time verdict) — it reconstructs [SignedPayload] from the carried
/// [OriginEnvelope] + the message's own content fields and RE-RUNS
/// [verifySignature], because the whole point of a "carried record" is that a
/// third party (or the subject, later, on different data) can verify it
/// without trusting anything the app previously computed.
library;

import 'message.dart';
import 'message_signing.dart' show SignedPayload, verifySignature;

/// The verdict for a single entry in a subject's carried record.
enum CarriedRecordVerdict {
  /// Carried signature material re-verified independently.
  verified,

  /// Carried signature material is present but failed independent
  /// re-verification (tampered content, wrong key, corrupt bytes, ...).
  invalid,

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
  final int unsignedCount;

  const CarriedRecord({
    required this.subjectUserId,
    required this.entries,
    required this.verifiedCount,
    required this.invalidCount,
    required this.unsignedCount,
  });
}

/// Build [subjectUserId]'s carried record from an in-hand list of locally
/// cached [Message]s, independently re-verifying every carried signature.
///
/// Pure reader: takes messages as input rather than reaching into the live
/// repository/cache, so the spike stays hermetic (no DB, no network) and the
/// falsifier is testable in isolation.
Future<CarriedRecord> carriedRecord(
  String subjectUserId,
  List<Message> localMessages,
) async {
  final mine = localMessages.where((m) => m.sender.userId == subjectUserId);

  final entries = <CarriedRecordEntry>[];
  var verified = 0;
  var invalid = 0;
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

    // Reconstruct SignedPayload from the CARRIED envelope (signature
    // material) + the message's own content fields (what the signature
    // authenticates) — the same "verifier-sufficient" split origin_envelope
    // documents, done here as an independent re-derivation rather than a
    // trust of the stored verdict.
    final payload = SignedPayload(
      rawPublicKey: origin.rawPublicKey,
      channelId: m.channelId,
      clientMsgId: origin.clientMsgId,
      signedAtMs: origin.signedAtMs,
      body: m.body,
      replyTo: m.replyToId,
    );

    bool ok;
    try {
      ok = await verifySignature(origin.rawPublicKey, origin.sig, payload);
    } on ArgumentError {
      ok = false; // illegal content field (e.g. empty channelId) -> invalid
    } on Exception {
      ok = false; // crypto-layer failure -> invalid
    }

    entries.add(CarriedRecordEntry(
      id: m.clientTempId,
      body: m.body,
      verdict: ok ? CarriedRecordVerdict.verified : CarriedRecordVerdict.invalid,
      signedAtMs: origin.signedAtMs,
    ));
    if (ok) {
      verified++;
    } else {
      invalid++;
    }
  }

  return CarriedRecord(
    subjectUserId: subjectUserId,
    entries: entries,
    verifiedCount: verified,
    invalidCount: invalid,
    unsignedCount: unsigned,
  );
}
