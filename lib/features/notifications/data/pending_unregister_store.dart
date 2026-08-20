import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// The device-token unregisters this app still OWES an island.
///
/// It exists so that ending a session never has to choose between two things
/// that cannot both be true. `DELETE /v1/devices` is authenticated, so it wants
/// to run before the credential is cleared; but nothing slow may sit ahead of
/// that clear, because a re-login inside the window writes fresh tokens the
/// trailing clear then stomps. Every attempt to satisfy both at once produced a
/// guard, and every guard moved the contradiction somewhere else.
///
/// A debt record dissolves the conflict rather than arbitrating it. The
/// credential clear becomes unconditional and immediate; the unregister becomes
/// an obligation that outlives the session, is written durably before anything
/// is attempted, and is paid off at the next opportunity. There is no window to
/// guard because the two operations are no longer racing for the same instant.
///
/// KEYED BY ISLAND, deliberately. A token registered with island X must never be
/// deleted at island Y — after `switchGateway` the REST client already points at
/// the new island, and an un-keyed debt would send X's DELETE to Y (a 204 that
/// deletes nothing while reporting success, leaving X routing forever).
///
/// A SET PER ISLAND, NOT A SINGLE SLOT — and the single slot was a real bug
/// (cage-match round 3, Carnot). An earlier version justified one debt per island
/// with "the device token is stable per install, so a newer debt supersedes the
/// older one". That premise is contradicted by the file next door:
/// [DeviceRegistrar.start] explicitly handles ROTATION, because tokens reissue on
/// reinstall and restore-from-backup. So: sign out offline owing `tok-1`, let the
/// platform rotate to `tok-2`, sign out offline again — and `remember` overwrote
/// `tok-1`, whose row on the island could then never be drained by this client.
/// A ledger that silently drops entries is not a ledger.
///
/// SharedPreferences rather than the drift cache, and the reason is lifecycle:
/// the cache is per-session and cleared on logout, which is the exact moment this
/// record is written. A debt stored somewhere that logout empties is not a debt
/// record.
class PendingUnregisterStore {
  static const _key = 'aiko_pending_device_unregisters';

  /// Most debts to keep per island before the oldest is dropped.
  ///
  /// A bound rather than unbounded growth: each entry is added on a sign-out
  /// whose DELETE failed and removed when it is finally paid, so the set only
  /// grows across repeated OFFLINE sign-outs with a rotation between each. That
  /// is rare, but "rare" is not "bounded", and this is durable storage. An
  /// eviction is LOGGED rather than silent — dropping a debt means an island row
  /// this client can no longer clean up, which is exactly the thing the class
  /// exists to prevent, so it must never happen quietly.
  static const _maxPerIsland = 16;

  // Nullable so a test double can subclass and override the methods without a
  // real SharedPreferences (mirrors [CachedUserStore]). The real store is always
  // constructed by its provider with a non-null instance.
  final SharedPreferences? _prefs;

  /// Serializes read-modify-write. Every mutation below is
  /// read-map → mutate → write-map, and two overlapping mutations (an in-flight
  /// settle discharging one token while a fresh unpair records another) would
  /// otherwise interleave and lose an update — silently, in the ledger whose
  /// entire job is not to lose things. Chaining removes the interleaving rather
  /// than guarding against it.
  Future<void> _writes = Future<void>.value();

  PendingUnregisterStore(this._prefs);

  /// The tokens owed to [islandBaseUrl]; empty if nothing is outstanding.
  ///
  /// Synchronous: the read is off already-loaded SharedPreferences, so the drain
  /// adds no await to the sign-in path. A corrupt value reads as "nothing owed"
  /// rather than throwing — an unpayable debt must never brick a sign-in.
  List<String> read(String islandBaseUrl) =>
      List.unmodifiable(_all()[islandBaseUrl] ?? const <String>[]);

  /// Record that [islandBaseUrl] is owed a DELETE for [token].
  ///
  /// Written BEFORE any attempt, never after. The failures this exists to
  /// survive — offline sign-out, the app being killed mid-flight — are precisely
  /// the ones that never reach an "on failure, record it" line.
  ///
  /// Returns SharedPreferences' success flag. `false` is a persistence failure
  /// that does NOT throw, and callers must act on it: a debt that did not persist
  /// is a backstop that does not exist, which is indistinguishable from success
  /// unless somebody looks.
  Future<bool> remember(String islandBaseUrl, String token) => _mutate((all) {
    final owed = all.putIfAbsent(islandBaseUrl, () => <String>[]);
    if (owed.contains(token)) return false; // already owed — nothing to write
    owed.add(token);
    while (owed.length > _maxPerIsland) {
      final dropped = owed.removeAt(0);
      debugPrint(
        'PendingUnregisterStore: DROPPING owed token $dropped for '
        '$islandBaseUrl — more than $_maxPerIsland debts outstanding. That '
        "island keeps a routable row this client can no longer clear.",
      );
    }
    return true;
  });

  /// Discharge [token]'s debt to [islandBaseUrl], leaving any others intact.
  ///
  /// Removes only the named token — never the island's whole entry. A drain can
  /// be in flight while a fresh unpair records a NEWER token for the same island,
  /// and clearing the entry wholesale would discharge a debt that was never paid.
  Future<bool> forget(String islandBaseUrl, String token) => _mutate((all) {
    final owed = all[islandBaseUrl];
    if (owed == null || !owed.remove(token)) return false; // nothing to write
    if (owed.isEmpty) all.remove(islandBaseUrl);
    return true;
  });

  /// Run [change] against the stored map under the write chain, persisting only
  /// if it reports an actual change. Returns the persistence flag (`true` when
  /// there was nothing to write — the desired state already holds).
  Future<bool> _mutate(bool Function(Map<String, List<String>>) change) {
    final result = _writes.then((_) async {
      final all = _all();
      if (!change(all)) return true;
      return _write(all);
    });
    // The chain must not break on an error, or every later mutation is dropped.
    _writes = result.then((_) {}, onError: (_) {});
    return result;
  }

  Map<String, List<String>> _all() {
    final raw = _prefs!.getString(_key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map(
        (k, v) => MapEntry(k as String, (v as List).cast<String>().toList()),
      );
    } catch (_) {
      return {};
    }
  }

  Future<bool> _write(Map<String, List<String>> all) => all.isEmpty
      ? _prefs!.remove(_key)
      : _prefs!.setString(_key, jsonEncode(all));
}
