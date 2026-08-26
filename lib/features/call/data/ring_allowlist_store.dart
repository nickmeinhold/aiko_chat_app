import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/domain/origin_envelope.dart';
import '../domain/ring_consent.dart';

/// The keys THIS USER has consented to be rung by IN A GIVEN CONVERSATION, even
/// though the island does not report them as people.
///
/// PER CONVERSATION (Nick's ruling, 2026-08-26). The first version was one set
/// per user, so a key blessed anywhere could wake you from anywhere — and a
/// resident agent may hold membership in many channels, which is exactly where
/// that difference stops being theoretical.
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
  /// A NEW KEY, and the old one is DELETED rather than migrated.
  ///
  /// The stored shape changed from a list of keys to a map of channel -> keys,
  /// and the two cannot be told apart safely by shape alone. More importantly a
  /// migration would have to invent a scope: a legacy grant says "anywhere",
  /// per-conversation consent has no "anywhere", and silently promoting it into
  /// every channel the user can see is the precise outcome the ruling rejected.
  /// A NARROWING CANNOT BE INFERRED, so it fails closed and the user re-grants.
  ///
  /// The cost is nil in practice: the global version shipped dark, with no UI
  /// that could grant through it, so no consent was ever recorded by a user.
  static const _prefix = 'aiko_ring_consent_';
  static const _legacyPrefix = 'aiko_ring_allowed_keys_';

  final SharedPreferences? _prefs;

  /// Whose consent this is. Namespacing the key by it is the whole fix for the
  /// inherited-consent defect above.
  final String? _userId;

  RingAllowlistStore(this._prefs, this._userId);

  String get _key => '$_prefix$_userId';
  String get _legacyKey => '$_legacyPrefix$_userId';

  /// Remove the global-scope grant this user may still carry.
  ///
  /// Not merely ignored — REMOVED, because a value on disk that nothing reads is
  /// a record of consent that no longer means anything, and the next reader of
  /// this file should not have to work out which of two keys is authoritative.
  ///
  /// CANNOT FAIL, and the guarantee lives HERE rather than at the call site
  /// (cage-match round 1 — Carnot MEDIUM, and Maxwell independently). This is
  /// `async`, so an exception in its body — `_prefs!` on a null store, or a
  /// platform-channel failure inside `remove` — does NOT throw synchronously; it
  /// completes the returned Future with an error. The caller is
  /// `RingAllowlist.build()`, which invokes it fire-and-forget inside a `try`
  /// that can only ever see a synchronous throw, so the rejection escaped as an
  /// UNHANDLED ASYNC ERROR — under `flutter_test` that fails whichever test the
  /// microtask happens to drain into, which is the worst place to debug it.
  ///
  /// The catch is INSIDE rather than a `catchError` at the call site because
  /// there is then no call site that can get it wrong. Hygiene must never be
  /// able to touch the ring path, and the class doc above already promises
  /// exactly that — this method was the one hole in it.
  Future<void> dropLegacyGlobalConsent() async {
    try {
      if (_userId == null || _prefs == null) return;
      if (_prefs.containsKey(_legacyKey)) await _prefs.remove(_legacyKey);
    } catch (e) {
      debugPrint('RingAllowlistStore: legacy consent cleanup failed: $e');
    }
  }

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

  /// Every conversation's consent, as an UNMODIFIABLE map of unmodifiable sets.
  ///
  /// Unmodifiable on EVERY path, deliberately. The first version returned a
  /// growable set on the happy path and `const {}` on the empty and corrupt
  /// ones — so `read()..add(k)` worked while consent existed and threw
  /// `UnsupportedError` on the FIRST grant ever made, which is the one moment
  /// it had to work (cage-match, Tesla). A type that is sometimes mutable is
  /// the trap; making it never mutable turns that class of bug into a failure
  /// at the first call in every test, instead of only in the state no test had.
  /// The nesting doubles the surface, so both levels are frozen.
  ///
  /// A corrupt value reads as EMPTY rather than throwing: losing a ring beats
  /// admitting an unintended ringer, and it must never brick the ring path. A
  /// LEGACY value (the flat list the global version wrote) lands here too, and
  /// reads as empty for the same reason — it names no conversation, so there is
  /// no scope it could honestly be admitted in.
  Map<String, Set<String>> readAll() {
    if (_userId == null) return const {}; // signed out — nobody's consent
    final raw = _prefs!.getString(_key);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return Map<String, Set<String>>.unmodifiable({
        for (final e in decoded.entries)
          e.key: Set<String>.unmodifiable((e.value as List).cast<String>()),
      });
    } catch (_) {
      return const {};
    }
  }

  /// The consent in force for [channelId], as the gate wants it.
  ///
  /// Always carries [channelId] even when the set is empty, so the value is
  /// self-describing at the point the gate re-checks it — an empty consent FOR
  /// this room and a consent for some OTHER room must not be the same object.
  RingConsent read(String channelId) => RingConsent.inChannel(
    channelId: channelId,
    keys: readAll()[channelId] ?? const {},
  );

  /// Consent to be rung by [multikey] IN [channelId]. Returns false if the key
  /// is not a well-formed ed25519 Multikey, if nobody is signed in, or if the
  /// write did not persist.
  ///
  /// CANONICALISED, not merely validated (cage-match, Carnot + Tesla). The first
  /// version validated the input and then stored the INPUT STRING, while the
  /// gate compares against `encodeMultikey(origin.rawPublicKey)` — so any
  /// alternate-but-valid textual form would be written into a register the ring
  /// path never consults, and `revoke` would only remove the exact text. Decode
  /// then re-encode, so what is stored is byte-identical to what is matched.
  Future<bool> allow(String channelId, String multikey) async {
    if (_userId == null) return false;
    final String canonical;
    try {
      canonical = encodeMultikey(decodeMultikey(multikey));
    } on OriginError {
      return false;
    }
    return _serialize(() {
      final all = {...readAll()};
      all[channelId] = {...?all[channelId], canonical};
      return _write(all);
    });
  }

  /// Withdraw consent in [channelId]. Consent that cannot be withdrawn is not
  /// consent, so this is not an optional half of the pair. Canonicalises for the
  /// same reason [allow] does — otherwise a caller could revoke a form that was
  /// never stored.
  ///
  /// SCOPED, like the grant. Revoking here says nothing about other rooms, which
  /// is the direct consequence of consent being per-conversation: a covenant made
  /// four times must be unmade four times, and pretending otherwise would make
  /// "revoke" mean something different from "allow".
  Future<bool> revoke(String channelId, String multikey) async {
    if (_userId == null) return false;
    String canonical = multikey;
    try {
      canonical = encodeMultikey(decodeMultikey(multikey));
    } on OriginError {
      // Not a well-formed key, so it cannot be in a canonical store — but remove
      // the literal anyway rather than refusing, so a store corrupted by hand can
      // still be cleaned up through the front door.
    }
    return _serialize(() {
      final all = {...readAll()};
      final remaining = {...?all[channelId]}..remove(canonical);
      // PRUNE THE EMPTY ROOM. A channel key mapped to an empty list is a record
      // of a covenant that no longer exists, and it would keep the whole map
      // alive on disk after the last consent anywhere was withdrawn — so the
      // "nothing is consented" state would persist as a file rather than as an
      // absence.
      if (remaining.isEmpty) {
        all.remove(channelId);
      } else {
        all[channelId] = remaining;
      }
      return _write(all);
    });
  }

  Future<bool> _write(Map<String, Set<String>> all) => all.isEmpty
      ? _prefs!.remove(_key)
      : _prefs!.setString(
          _key,
          jsonEncode({for (final e in all.entries) e.key: e.value.toList()}),
        );
}
