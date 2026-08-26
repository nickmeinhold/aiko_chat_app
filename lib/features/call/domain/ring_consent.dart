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

  /// PRIVATE, so `(channelId: null, keys: {...})` — a consent that names no room
  /// but carries keys — is not constructible. The type's whole argument is that
  /// a mis-scoped consent should be unrepresentable rather than merely refused;
  /// leaving that one state reachable would make the claim mostly-true, which is
  /// the weaker version of it (cage-match round 1, Maxwell's own pass).
  const RingConsent._({required this.channelId, required this.keys});

  /// Consent held in exactly one conversation. [channelId] is non-null HERE even
  /// though the field is nullable — [none] is the only instance without a room.
  RingConsent.inChannel({
    required String this.channelId,
    required Set<String> keys,
    // FROZEN AT CONSTRUCTION (cage-match round 2, Carnot MEDIUM). The field is
    // public and the type is a trust-boundary authority; without this a caller
    // can hold the set it passed in and mutate it afterwards — `final s = {};
    // RingConsent.inChannel(channelId: id, keys: s); s.add(k);` — editing who may
    // wake you AFTER the gate has been handed its answer.
  }) : keys = Set<String>.unmodifiable(keys);

  /// No consent, applicable nowhere. The correct default everywhere, and the
  /// value every failure path degrades to — an unreadable store, a signed-out
  /// session, a corrupt record. Reach is never a gate, but a WIDENING of who may
  /// wake you fails closed.
  static const none = RingConsent._(channelId: null, keys: <String>{});

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

/// Every conversation's consent, with NO WAY TO OBTAIN A BARE KEY SET.
///
/// The third instance of one class, and the reason this type exists rather than a
/// fourth guard (cage-match round 2, Tesla — the deepest finding of the review).
/// Identity-as-mutable-key has now appeared at the disk key (#161 round 1), at the
/// in-memory register (#161 round 2), and here at the PAIR: the notifier used to
/// publish `Map<String, Set<String>>`, so `consentIn` was a SUPPORTED path, not a
/// law. A settings surface that watched the raw map could rebuild the pair by hand
/// and hand the gate room A's label with room B's keys — right label, wrong keys,
/// admitted. That is exactly how #161 shipped a provider that never reached the
/// gate: the blessed path was correct and the type did not make the cursed path
/// impossible.
///
/// Tesla's sharpest line, kept because it names what the RED proof could not do:
/// deleting `channelId != inChannelId` only proves LABEL MISMATCH refuses. You
/// could not write a test that the type rejects right-label/wrong-keys, because it
/// did not. So the fix is subtractive — remove the raw map from the published
/// surface — rather than another check someone must remember to run.
///
/// [consentIn] is now the ONLY way to reach a key set, and it pairs the label and
/// the keys from one lookup. [channels] exists so a settings screen can enumerate
/// what has been granted without ever holding an unpaired set.
class RingConsentBook {
  const RingConsentBook(this._byChannel);

  const RingConsentBook.empty() : _byChannel = const {};

  final Map<String, Set<String>> _byChannel;

  /// The consent in force in [channelId] — label and keys from one lookup, so the
  /// two cannot be mismatched by a caller.
  RingConsent consentIn(String channelId) => RingConsent.inChannel(
    channelId: channelId,
    keys: _byChannel[channelId] ?? const {},
  );

  /// The conversations holding consent, for a UI that lists them. Iterating these
  /// and calling [consentIn] is always correctly paired by construction.
  Iterable<String> get channels => _byChannel.keys;

  bool get isEmpty => _byChannel.isEmpty;
}
