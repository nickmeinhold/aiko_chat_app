import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/domain/origin_envelope.dart';

/// The keys this handset has consented to be rung by, even though the island
/// does not report them as people.
///
/// DEVICE-LOCAL, and that is the design rather than an implementation shortcut.
/// The existing doctrine already splits these two: a BLOCK is server-side
/// moderation (the island refuses to deliver), a MUTE is device-local attention
/// (this handset declines to be disturbed). "May this agent wake me at 3am" is
/// squarely attention — it is a property of the sleeper, not of the network —
/// so it belongs on the device, alongside mute.
///
/// The alternative was an island-held list: one roster, every device, edited by
/// whoever operates the gateway. That is the right shape for an organisation and
/// the wrong shape here, because it puts a person's sleep under an operator's
/// control and it contradicts ADR-0004's refusal of a central directory. It also
/// fails the key test below: an island-held list would have to be keyed on
/// something the island can rewrite.
///
/// KEYED ON THE MULTIKEY, never on a user id or a display name. `signingBytes`
/// covers the public key; `sender.userId` and `sender.label` are server-supplied
/// metadata OUTSIDE the signature (#3166). A list keyed on either is a list the
/// island can edit by relabelling a row, which would let it nominate the caller
/// allowed to wake you. The key cannot be forged without the private half.
///
/// Stored as a JSON array of `z…` strings — the same canonical form the wire
/// carries, so a stored entry and a live envelope compare as plain strings with
/// no re-encoding step to get wrong.
class RingAllowlistStore {
  static const _key = 'aiko_ring_allowed_keys';

  // Nullable so a test double can subclass without a real SharedPreferences,
  // mirroring [PendingUnregisterStore] and [CachedUserStore].
  final SharedPreferences? _prefs;

  const RingAllowlistStore(this._prefs);

  /// Every consented key. A corrupt value reads as EMPTY rather than throwing:
  /// the failure direction that loses a ring is strictly better than the one
  /// that admits an unintended ringer, and it must never brick the ring path.
  Set<String> read() {
    final raw = _prefs!.getString(_key);
    if (raw == null) return const {};
    try {
      return {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {
      return const {};
    }
  }

  /// Consent to be rung by [multikey].
  ///
  /// VALIDATED, not trusted. The string is round-tripped through the real
  /// decoder before it is stored, so a typo, a truncated paste or a
  /// wrong-alphabet lookalike is refused at the moment of consent rather than
  /// sitting in the list forever silently matching nothing. Returns false if the
  /// key is not a well-formed ed25519 Multikey, or if the write did not persist.
  Future<bool> allow(String multikey) async {
    try {
      decodeMultikey(multikey);
    } on OriginError {
      return false;
    }
    final next = read()..add(multikey);
    return _write(next);
  }

  /// Withdraw consent. Consent that cannot be withdrawn is not consent, so this
  /// is not an optional half of the pair.
  Future<bool> revoke(String multikey) async {
    final next = read()..remove(multikey);
    return _write(next);
  }

  Future<bool> _write(Set<String> keys) => keys.isEmpty
      ? _prefs!.remove(_key)
      : _prefs!.setString(_key, jsonEncode(keys.toList()));
}
