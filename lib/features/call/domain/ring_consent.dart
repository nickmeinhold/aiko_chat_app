import 'dart:typed_data';

import '../../chat/domain/origin_envelope.dart';

/// Consent to be rung, SCOPED TO ONE CONVERSATION.
///
/// Nick's ruling, 2026-08-26. The first version was global-per-user: a key you
/// blessed anywhere could wake you from anywhere. Consent granted to a principal
/// in one room is not consent to be woken from every other room it can reach —
/// and on an island where a resident agent may hold membership in many channels,
/// the difference is the whole feature.
///
/// CARRIES ITS OWN SCOPE, and that is the point of the type existing at all
/// rather than passing a bare `Set<String>` sliced by the caller. This exact
/// feature produced the identity-as-mutable-key defect TWICE in one cage-match —
/// at the storage layer in round 1, then again at the provider layer in round 2,
/// which is the tell that the first fix was an instance and not the class. The
/// slice now has TWO scoping dimensions (whose consent, and where), and a bare
/// set describes neither: a gate handed the wrong conversation's keys would
/// admit the ring and nothing anywhere could notice.
///
/// So the gate re-checks the scope it was handed against the message it is
/// judging ([permits]), instead of trusting the caller to have sliced correctly.
/// The check fails differently from the thing it checks, which is the only
/// arrangement that catches a bug in the slicing itself.
class RingConsent {
  /// The conversation these keys were consented in, or null for "no consent is
  /// in scope here" — which every path that cannot name a conversation gets.
  final String? channelId;

  /// The canonical Multikey (`z…`) forms consented to IN [channelId].
  ///
  /// Multikeys, never user ids or labels: `signingBytes` covers the public key,
  /// while `sender.userId` and `sender.label` are server-supplied metadata
  /// outside the signature (#3166). A list keyed on either is a list the island
  /// can edit by relabelling a row, which would let it nominate who may wake you.
  final Set<String> keys;

  const RingConsent({required this.channelId, required this.keys});

  /// No consent, applicable nowhere. The correct default everywhere, and the
  /// value every failure path degrades to — an unreadable store, a signed-out
  /// session, a corrupt record. Reach is never a gate, but a WIDENING of who may
  /// wake you fails closed.
  static const none = RingConsent(channelId: null, keys: <String>{});

  /// Does this consent admit [rawPublicKey] ringing in [inChannelId]?
  ///
  /// The channel comparison is the load-bearing half. A caller that slices the
  /// wrong conversation, or forgets to re-slice when the message changed, gets a
  /// refusal here rather than an admission — the failure direction that costs a
  /// missed ring instead of an unconsented 3am wake-up.
  bool permits(String inChannelId, Uint8List rawPublicKey) {
    if (channelId == null || channelId != inChannelId) return false;
    if (keys.isEmpty) return false; // the overwhelmingly common path
    return keys.contains(encodeMultikey(rawPublicKey));
  }
}
