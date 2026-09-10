import 'dart:async';
import 'dart:convert';

import '../application/push_telemetry.dart';
import '../domain/token_kind.dart';

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
/// deleted at island Y — after `switchIsland` the REST client already points at
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
  /// Cap per island PER KIND, not per island.
  ///
  /// RE-ARGUED rather than inherited when the second kind arrived (design 16 v2
  /// §5 asked for exactly that). The NUMBER survives; its SCOPE changes. With
  /// one shared list, eviction is oldest-first and kind-blind, so a burst of
  /// alert-token churn would evict the VoIP debt — and the two are not equally
  /// valuable. A dropped alert debt is a stray banner. A dropped VoIP debt is a
  /// routable row for a signed-out user, which under CallKit is a STRANGER'S
  /// HANDSET RINGING FULL-SCREEN for the previous owner.
  ///
  /// Worst case doubles to 32 tokens per island, a few KB. That is not a cost.
  static const _maxPerKind = 16;

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

  PendingUnregisterStore(this._prefs, {this.telemetry = PushTelemetry.noop});

  /// Public and final rather than private: a test asserting that an eviction is
  /// ANNOUNCED needs to inject a capturing facade, and an eviction going
  /// unannounced is the exact failure this class's own doc says must never
  /// happen quietly.
  final PushTelemetry telemetry;

  /// The tokens owed to [islandBaseUrl]; empty if nothing is outstanding.
  ///
  /// Synchronous: the read is off already-loaded SharedPreferences, so the drain
  /// adds no await to the sign-in path. A corrupt value reads as "nothing owed"
  /// rather than throwing — an unpayable debt must never brick a sign-in.
  List<String> read(String islandBaseUrl, TokenKind kind) =>
      List.unmodifiable(_all()[islandBaseUrl]?[kind] ?? const <String>[]);

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
  Future<bool> remember(
    String islandBaseUrl,
    TokenKind kind,
    String token,
  ) => _mutate((all) {
    final owed = all
        .putIfAbsent(islandBaseUrl, () => <TokenKind, List<String>>{})
        .putIfAbsent(kind, () => <String>[]);
    if (owed.contains(token)) return false; // already owed — nothing to write
    owed.add(token);
    while (owed.length > _maxPerKind) {
      final dropped = owed.removeAt(0);
      // REDACTED (cage-match, Tesla). A push token is a routing secret — the
      // REST layer keeps it out of URLs so it never reaches an access log or a
      // proxy trace. This was the one path that dumped a whole token, and it is
      // the path that already admits it is dropping a debt nobody can retry.
      //
      // The hand-rolled truncation that used to sit here is gone: the facade
      // takes a short ref by signature and `RedactingLogSink` cuts anything
      // secret-shaped that reaches a sink regardless. What was one site's
      // vigilance is now the type plus a scrubber that fails differently.
      telemetry.debtDropped(
        islandBaseUrl,
        PushTelemetry.ref(dropped),
        _maxPerKind,
      );
    }
    return true;
  });

  /// Discharge [token]'s debt to [islandBaseUrl], leaving any others intact.
  ///
  /// Removes only the named token — never the island's whole entry. A drain can
  /// be in flight while a fresh unpair records a NEWER token for the same island,
  /// and clearing the entry wholesale would discharge a debt that was never paid.
  Future<bool> forget(String islandBaseUrl, TokenKind kind, String token) =>
      _mutate((all) {
        final byKind = all[islandBaseUrl];
        final owed = byKind?[kind];
        if (owed == null || !owed.remove(token))
          return false; // nothing to write
        if (owed.isEmpty) byKind!.remove(kind);
        if (byKind!.isEmpty) all.remove(islandBaseUrl);
        return true;
      });

  /// Run [change] against the stored map under the write chain, persisting only
  /// if it reports an actual change. Returns the persistence flag (`true` when
  /// there was nothing to write — the desired state already holds).
  Future<bool> _mutate(
    bool Function(Map<String, Map<TokenKind, List<String>>>) change,
  ) {
    final result = _writes.then((_) async {
      final all = _all();
      if (!change(all)) return true;
      return _write(all);
    });
    // The chain must not break on an error, or every later mutation is dropped.
    _writes = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Decode the ledger, TOTALLY, over BOTH shapes.
  ///
  /// **A LEGACY ENTRY IS AN ALERT ENTRY, and that is measured rather than
  /// assumed.** No build has ever minted a VoIP token, so a kindless list can
  /// only ever have held alert tokens. It is the same fact the island's
  /// `server_default='alert'` rests on.
  ///
  /// This totality is the sharp edge of the whole change. `read`'s contract is
  /// that "a corrupt value reads as nothing owed" — so a format change that
  /// made every live ledger unreadable would SILENTLY DISCHARGE EVERY
  /// OUTSTANDING DEBT, leaving island rows that nothing will ever clear. That
  /// is the one failure this class exists to prevent, caused by the migration
  /// meant to strengthen it.
  ///
  /// Tolerance is PER ISLAND ENTRY, not per file: one unreadable entry drops one
  /// island, where the old whole-map `catch` emptied the ledger.
  Map<String, Map<TokenKind, List<String>>> _all() {
    final raw = _prefs!.getString(_key);
    if (raw == null) return {};
    final Map<String, dynamic> decoded;
    try {
      decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
    final out = <String, Map<TokenKind, List<String>>>{};
    for (final entry in decoded.entries) {
      try {
        final value = entry.value;
        if (value is List) {
          // LEGACY: island -> [tokens]. Alert by construction.
          out[entry.key] = {TokenKind.alert: value.cast<String>().toList()};
        } else if (value is Map) {
          final byKind = <TokenKind, List<String>>{};
          for (final k in value.entries) {
            // MERGE, NEVER ASSIGN (Tesla, round 1). `fromWire` is TOTAL — every
            // name it cannot speak becomes `alert` — and that totality is right
            // where it was designed to be used, decoding a value, because a
            // throw there would read as "nothing owed" and discharge every
            // obligation. Used to MINT A MAP KEY it is the opposite fail
            // direction: a ledger written by a later build that knows a third
            // kind gives `{"alert": [a], "critical": [c]}`, both keys fold to
            // `alert`, and a plain assign DROPS whichever came first. The alert
            // drain then deletes only the survivor and the other row is leaked
            // forever — the exact kind-blind-drain bug cc43303 removed,
            // reopened for the kind nobody has added yet.
            //
            // Merging keeps every token and lets the alert drain DELETE them,
            // which is this store's stated fail direction: an over-delete
            // degrades reach, an under-delete leaks a routable row nothing can
            // clear. The island's DELETE matches on (user_id, token) and never
            // on kind, so a token drained under the wrong kind is still the
            // right row removed.
            (byKind[TokenKind.fromWire(k.key as String)] ??= <String>[]).addAll(
              (k.value as List).cast<String>(),
            );
          }
          out[entry.key] = byKind;
        }
      } catch (_) {
        continue; // one island unreadable, the rest still owed
      }
    }
    return out;
  }

  Future<bool> _write(Map<String, Map<TokenKind, List<String>>> all) =>
      all.isEmpty
      ? _prefs!.remove(_key)
      : _prefs!.setString(
          _key,
          jsonEncode(
            all.map(
              (island, byKind) => MapEntry(
                island,
                byKind.map((kind, tokens) => MapEntry(kind.wire, tokens)),
              ),
            ),
          ),
        );
}
