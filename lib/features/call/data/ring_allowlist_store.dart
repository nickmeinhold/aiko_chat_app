import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/domain/origin_envelope.dart';

/// The keys THIS USER has consented to be rung by, even though the island does
/// not report them as people.
///
/// DEVICE-LOCAL, and that is the design rather than a shortcut. The existing
/// doctrine already splits these: a BLOCK is server-side moderation (the island
/// refuses to deliver), a MUTE is device-local attention (this handset declines
/// to be disturbed). "May this agent wake me at 3am" is attention — a property
/// of the sleeper — so it belongs on the device, alongside mute.
///
/// The alternative was an island-held roster: one list, every device, edited by
/// whoever operates the gateway. Right for an organisation, wrong here — it puts
/// a person's sleep under an operator's control, contradicts ADR-0004's refusal
/// of a central directory, and fails the key test below, since an island-held
/// list would have to be keyed on something the island can rewrite.
///
/// PER USER, NOT PER HANDSET (cage-match, Tesla). The first version keyed on a
/// bare `aiko_ring_allowed_keys`, which is a property of the DEVICE — so user A
/// consents, signs out, and user B inherits the blessing and is woken at 3am for
/// a covenant they never made. Identity-as-mutable-key, with a per-user mute key
/// sitting six inches away in the same preferences file. The user id is in the
/// key now, matching `aiko_muted_<userId>` and `aiko_channel_lastread_<userId>`.
///
/// KEYED ON THE MULTIKEY, never on a user id or a display name. `signingBytes`
/// covers the public key; `sender.userId` and `sender.label` are server-supplied
/// metadata OUTSIDE the signature (#3166). A list keyed on either is a list the
/// island can edit by relabelling a row, which would let it nominate who may
/// wake you. The key cannot be forged without the private half.
class RingAllowlistStore {
  static const _prefix = 'aiko_ring_allowed_keys_';

  final SharedPreferences? _prefs;

  /// Whose consent this is. Namespacing the key by it is the whole fix for the
  /// inherited-consent defect above.
  final String? _userId;

  RingAllowlistStore(this._prefs, this._userId);

  String get _key => '$_prefix$_userId';

  /// Serializes read-modify-write, exactly as [PendingUnregisterStore] does and
  /// for exactly the same reason — a precedent twenty lines away in this repo
  /// that this class failed to reuse until a reviewer found the bug it prevents.
  ///
  /// Every mutation below is read → mutate → write, and the write awaits. Two
  /// overlapping mutations therefore interleave: revoke snapshots {A,B}, allow
  /// snapshots {A,B}, revoke persists {B}, allow persists {A,B,C} — and A, which
  /// was just revoked, is back. A withdrawal that loses a race is not a
  /// withdrawal. Chaining removes the interleaving rather than guarding it
  /// (cage-match round 2, Tesla).
  ///
  /// SCOPED HONESTLY: defence in depth, not a fix for a reachable bug.
  /// `SharedPreferences.setString` updates its in-memory cache SYNCHRONOUSLY
  /// before the returned Future completes — measured with a probe, not assumed —
  /// so a later `read()` already sees the write and the window above does not
  /// currently open. The chain earns its place against a future async-backed
  /// store; the test covering it says plainly that it cannot go red today.
  Future<void> _writes = Future<void>.value();

  Future<bool> _serialize(Future<bool> Function() mutate) {
    final result = _writes.then((_) => mutate());
    // The chain must not break on an error, or every later mutation is dropped.
    _writes = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Every consented key, as an UNMODIFIABLE set.
  ///
  /// Unmodifiable on EVERY path, deliberately. The first version returned a
  /// growable set on the happy path and `const {}` on the empty and corrupt
  /// ones — so `read()..add(k)` worked while consent existed and threw
  /// `UnsupportedError` on the FIRST grant ever made, which is the one moment
  /// it had to work (cage-match, Tesla). A type that is sometimes mutable is
  /// the trap; making it never mutable turns that class of bug into a failure
  /// at the first call in every test, instead of only in the state no test had.
  ///
  /// A corrupt value reads as EMPTY rather than throwing: losing a ring beats
  /// admitting an unintended ringer, and it must never brick the ring path.
  Set<String> read() {
    if (_userId == null) return const {}; // signed out — nobody's consent
    final raw = _prefs!.getString(_key);
    if (raw == null) return const {};
    try {
      return Set<String>.unmodifiable((jsonDecode(raw) as List).cast<String>());
    } catch (_) {
      return const {};
    }
  }

  /// Consent to be rung by [multikey]. Returns false if it is not a well-formed
  /// ed25519 Multikey, if nobody is signed in, or if the write did not persist.
  ///
  /// CANONICALISED, not merely validated (cage-match, Carnot + Tesla). The first
  /// version validated the input and then stored the INPUT STRING, while
  /// `admitRing` compares against `encodeMultikey(origin.rawPublicKey)` — so any
  /// alternate-but-valid textual form would be written into a register the ring
  /// path never consults, and `revoke` would only remove the exact text. Decode
  /// then re-encode, so what is stored is byte-identical to what is matched.
  Future<bool> allow(String multikey) async {
    if (_userId == null) return false;
    final String canonical;
    try {
      canonical = encodeMultikey(decodeMultikey(multikey));
    } on OriginError {
      return false;
    }
    return _serialize(() => _write({...read(), canonical}));
  }

  /// Withdraw consent. Consent that cannot be withdrawn is not consent, so this
  /// is not an optional half of the pair. Canonicalises for the same reason
  /// [allow] does — otherwise a caller could revoke a form that was never stored.
  Future<bool> revoke(String multikey) async {
    if (_userId == null) return false;
    String canonical = multikey;
    try {
      canonical = encodeMultikey(decodeMultikey(multikey));
    } on OriginError {
      // Not a well-formed key, so it cannot be in a canonical store — but remove
      // the literal anyway rather than refusing, so a store corrupted by hand can
      // still be cleaned up through the front door.
    }
    return _serialize(() => _write({...read()}..remove(canonical)));
  }

  Future<bool> _write(Set<String> keys) => keys.isEmpty
      ? _prefs!.remove(_key)
      : _prefs!.setString(_key, jsonEncode(keys.toList()));
}
