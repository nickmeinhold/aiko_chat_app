import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The handle a new account chose BEFORE its passkey existed, and still owes
/// the island (#436: handle-first sign-up, Nick 2026-10-28).
///
/// The island creates every passkey account with an auto-assigned `aiko-…`
/// handle (its Design 04: a handle is a profile edit, never a gate on account
/// creation), so the app applies the chosen one with `PATCH /v1/me` right
/// after. A record is written as a device [OwedHandles.draft] before the
/// ceremony, bound to the new account the moment the island answers, and
/// removed only once the island has the handle. While one is owed by the
/// signed-in account, the router keeps that account out of chat.
class OwedHandle {
  const OwedHandle({
    required this.handle,
    required this.displayName,
    this.userId,
    this.failure,
  });

  final String handle;
  final String displayName;

  /// The account that owes it. Null for a draft: the ceremony hasn't made an
  /// account, or its answer was lost. A draft is never a gate.
  final String? userId;

  /// Why the island last refused it (taken, no network). In memory only: after
  /// a relaunch the screen simply asks again.
  final Object? failure;

  OwedHandle bindTo(String userId) =>
      OwedHandle(handle: handle, displayName: displayName, userId: userId);

  OwedHandle refusedWith(Object failure) => OwedHandle(
    handle: handle,
    displayName: displayName,
    userId: userId,
    failure: failure,
  );

  Map<String, dynamic> toJson() => {
    'handle': handle,
    'display_name': displayName,
    if (userId != null) 'user_id': userId,
  };

  static OwedHandle? fromJson(Object? j) {
    if (j is! Map) return null;
    final handle = j['handle'];
    final displayName = j['display_name'];
    final userId = j['user_id'];
    if (handle is! String || displayName is! String) return null;
    return OwedHandle(
      handle: handle,
      displayName: displayName,
      userId: userId is String ? userId : null,
    );
  }
}

/// Everything owed on this device: at most one [draft] for a sign-up in
/// progress, and the [debts] of accounts that exist, by account id.
///
/// TWO PLACES, NOT ONE SLOT (cage-match #440 round 2: Noether, Carnot and
/// Tesla). One slot held both, so a second person's sign-up on this device
/// overwrote, and a cancelled one cleared, a debt the first account still
/// owed. On an island that doesn't send `handle_auto` that debt is that
/// account's only gate. The ceremony now writes and clears only [draft], so
/// nothing it does can reach an account's debt.
class OwedHandles {
  const OwedHandles({this.draft, this.debts = const {}});

  static const empty = OwedHandles();

  final OwedHandle? draft;
  final Map<String, OwedHandle> debts;

  /// The debt [userId] owes, if any. Null for a null id: nobody signed in
  /// owes nothing.
  OwedHandle? forAccount(String? userId) =>
      userId == null ? null : debts[userId];

  OwedHandles withDraft(OwedHandle? draft) =>
      OwedHandles(draft: draft, debts: debts);

  OwedHandles withDebt(String userId, OwedHandle? debt) {
    final next = Map<String, OwedHandle>.of(debts);
    if (debt == null) {
      next.remove(userId);
    } else {
      next[userId] = debt.userId == userId ? debt : debt.bindTo(userId);
    }
    return OwedHandles(draft: draft, debts: Map.unmodifiable(next));
  }

  Map<String, dynamic> toJson() => {
    if (draft != null) 'draft': draft!.toJson(),
    'debts': {for (final e in debts.entries) e.key: e.value.toJson()},
  };

  static OwedHandles fromJson(Object? j) {
    if (j is! Map) return empty;
    final draft = OwedHandle.fromJson(j['draft']);
    final raw = j['debts'];
    final debts = <String, OwedHandle>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final debt = OwedHandle.fromJson(e.value);
        if (e.key is String && debt != null) {
          debts[e.key as String] = debt.bindTo(e.key as String);
        }
      }
    }
    return OwedHandles(
      // A draft is unbound by definition, whatever was written.
      draft: draft == null
          ? null
          : OwedHandle(handle: draft.handle, displayName: draft.displayName),
      debts: Map.unmodifiable(debts),
    );
  }
}

/// Persistence for [OwedHandles]. Nullable prefs so a test container without
/// them still runs, in memory: like the passkey hint, this must never be able
/// to fail a sign-in.
class OwedHandleStore {
  static const _key = 'aiko_owed_handles';

  final SharedPreferences? _prefs;

  OwedHandleStore(this._prefs);

  /// What is persisted, or [OwedHandles.empty] if nothing or unreadable. A
  /// corrupt value is "nothing owed" rather than a throw: a bad record must
  /// never brick launch.
  OwedHandles read() {
    final raw = _prefs?.getString(_key);
    if (raw == null) return OwedHandles.empty;
    try {
      return OwedHandles.fromJson(jsonDecode(raw));
    } catch (_) {
      return OwedHandles.empty;
    }
  }

  /// The result is not checked by callers, on purpose: the in-memory state is
  /// what the router reads, so a failed write costs at most being asked again
  /// on the next launch, never a sign-in.
  Future<bool> write(OwedHandles owed) =>
      _prefs?.setString(_key, jsonEncode(owed.toJson())) ?? Future.value(false);
}
