import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/auth/credential.dart';
import '../features/auth/domain/auth_models.dart';

/// The Keychain (Android: encrypted storage) as string slots. The one seam
/// tests replace, so a test can fail or crash any single read, write or delete.
abstract interface class SecretSlots {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeychainSlots implements SecretSlots {
  final FlutterSecureStorage _storage;

  KeychainSlots([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// What the vault holds: exactly one of these (design 26 §2a).
sealed class StoredSession {
  const StoredSession();
}

/// Nothing stored at all, in either format.
final class NoSession extends StoredSession {
  const NoSession();
}

/// A session, and the island that issued it. Presented to that island only.
final class SessionRecord extends StoredSession {
  final String island;
  final AuthTokens tokens;
  const SessionRecord(this.island, this.tokens);
}

/// A session an older build stored without its island, where nothing could
/// say which island that was. Never presented, never refreshed; a sign-in or a
/// sign-out may discard it, and its own `exp` ends it within 30 days.
final class OwnerUnknown extends StoredSession {
  final AuthTokens tokens;
  const OwnerUnknown(this.tokens);
}

/// A sign-out, written down. It retires the legacy pair as durably as a record.
final class SignedOut extends StoredSession {
  const SignedOut();
}

/// Present, but not something this build can parse: corrupt, or written by a
/// newer build. Never presented; a sign-in may replace it.
final class UnreadableData extends StoredSession {
  const UnreadableData();
}

/// The ONE owner of the session: loading it, presenting it, refreshing it,
/// storing it, and ending it.
///
/// Before this, the session lived in each `DefaultTokenProvider`, and
/// `backendProvider` builds a new one on every island-config change, so the
/// cache, the single refresh in flight and the ordering of writes each needed
/// a way to make several instances act as one. PR #452 found a new seam
/// between them in each of three cage-match rounds. Here they are one object
/// that is never rebuilt, and a provider is a door that holds nothing.
///
/// **Two slots, and why.** The session is one record, so a write can't tear it
/// in two. But `flutter_secure_storage_darwin` (0.3.2,
/// `FlutterSecureStorage.swift:560-573`) overwrites an item by
/// `SecItemUpdate`, and when the update fails, for instance on a locked phone,
/// it DELETES the item and then tries `SecItemAdd`, which fails the same way.
/// Overwriting the live record in place could therefore erase it. So a write
/// never touches the live slot. It writes the new record to the OTHER slot
/// with the next sequence number, and only then retires the old one. A
/// failure or a crash at any step leaves the live record readable, and a read
/// takes the higher sequence number when both survive.
///
/// **The lease.** Every [Credential] carries the lease it was issued under. A
/// sign-in or an end advances it, and work stamped with an old lease loses its
/// effect: a refresh that was out when the session changed commits nothing and
/// returns nothing (design 26 §2c).
class SessionVault {
  static const _slotKeys = ['aiko_session.0', 'aiko_session.1'];

  /// The format every build before this one wrote, and what it read. Read
  /// only when neither slot exists, and retired by any write.
  static const legacyAccessKey = 'aiko_access_token';
  static const legacyRefreshKey = 'aiko_refresh_token';

  /// Written only by PR #439's unmerged branch, so present only on a dev
  /// device that ran it. Placement rule 1.
  static const legacyIslandKey = 'aiko_tokens_island';

  static const _legacyKeys = [
    legacyAccessKey,
    legacyRefreshKey,
    legacyIslandKey,
  ];

  final SecretSlots _slots;

  /// Which island a legacy pair belongs to, or null when nothing can say
  /// (placement rules 2-4, design 26 §2b). Asked only when a legacy pair is
  /// found, so it never runs on an install this build has already written.
  final String? Function() _placeLegacy;

  /// Something worth knowing went wrong that the user can't see: unreadable
  /// data replaced, a retirement that failed. Never a token.
  final void Function(String event)? _report;

  SessionVault(
    this._slots, {
    required String? Function() placeLegacy,
    void Function(String event)? report,
  }) : _placeLegacy = placeLegacy,
       _report = report;

  /// Null until the first read that the Keychain answered.
  StoredSession? _state;

  /// The slot holding [_state] on disk (null: neither), and its sequence.
  /// Meaningful only once [_layoutKnown]: until the slots are read, a null
  /// [_liveSlot] means "not read", not "empty".
  int? _liveSlot;
  int _seq = 0;
  bool _layoutKnown = false;

  int _lease = 0;
  Future<Credential?>? _flight;
  Future<void> _lane = Future<void>.value();
  final _ended = StreamController<SessionEnded>.broadcast();

  /// The session's lease now: a sign-in reads it before its first network
  /// call, and every commit after that call is checked against it.
  int get lease => _lease;

  /// Ends the vault made on its own: a refresh token the island rejected.
  /// Ends something in the app asked for are never announced here; the asker
  /// settles them. Each event is added after the lane has moved on.
  Stream<SessionEnded> get ended => _ended.stream;

  /// Run [change] after every change queued before it, so a sign-in, a
  /// refresh's commit and an end can never interleave their reads and writes.
  Future<T> _serial<T>(Future<T> Function() change) {
    final run = _lane.then((_) => change());
    _lane = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// The session's credential for [island], or null when the vault holds none
  /// for it. Throws when the Keychain refuses the first read (a locked phone):
  /// that is "not known yet", not "signed out".
  Future<Credential?> present(String island) async {
    if (_state == null) await _serial(_load);
    // Read after the await, not from the load's result: a sign-out queued
    // behind the load runs before this resumes, and the load's record would
    // then go out stamped with the sign-out's lease.
    final s = _state;
    return s is SessionRecord && s.island == island
        ? Credential(s.tokens.accessToken, _lease)
        : null;
  }

  /// Refresh [stale], which a consumer presented to [island] and had refused.
  ///
  /// - the new credential on success;
  /// - another consumer's newer credential for the same session, without a
  ///   network call, when [stale] has already been replaced;
  /// - null when the island rejected the refresh token: the session is ended
  ///   and stored as signed out;
  /// - throws [SessionSuperseded] when [stale]'s session ended or was replaced,
  ///   before or during the refresh;
  /// - throws anything else [remote] throws: transient, nothing changes.
  ///
  /// NOT async: the in-flight slot is checked and assigned in one synchronous
  /// step, so a second caller can't start a second refresh (design 02,
  /// finding 2). Under rotation that matters twice over: two refreshes from
  /// one token read to the island as two holders.
  Future<Credential?> refresh(
    String island,
    Credential stale,
    Future<RefreshResult> Function(String refreshToken) remote,
  ) {
    final s = _state;
    if (stale.lease != _lease || s is! SessionRecord || s.island != island) {
      return Future.error(const SessionSuperseded());
    }
    if (s.tokens.accessToken != stale.accessToken) {
      return Future.value(Credential(s.tokens.accessToken, _lease));
    }
    // A flight is always this lease's: a sign-in or an end empties the slot.
    final joined = _flight;
    if (joined != null) return joined;

    late final Future<Credential?> flight;
    flight = _fly(s, _lease, remote).whenComplete(() {
      if (identical(_flight, flight)) _flight = null;
    });
    return _flight = flight;
  }

  Future<Credential?> _fly(
    SessionRecord presented,
    int lease,
    Future<RefreshResult> Function(String refreshToken) remote,
  ) async {
    final RefreshResult result;
    try {
      result = await remote(presented.tokens.refreshToken);
    } on RefreshRejected {
      final ended = await _serial(() async {
        // A rejection of a session that is no longer ours must not end the
        // one that replaced it.
        if (lease != _lease) throw const SessionSuperseded();
        final gone = Credential(presented.tokens.accessToken, lease);
        await _end();
        return SessionEnded(_lease, gone);
      });
      _ended.add(ended);
      return null;
    }
    // Any other error propagates: transient, the session stands.

    return _serial(() async {
      // Writing these back after a sign-in or an end would revert the new
      // session to the old one, or resurrect one the user just left.
      if (lease != _lease) throw const SessionSuperseded();
      final rotated = SessionRecord(
        presented.island,
        AuthTokens(
          accessToken: result.accessToken,
          // An island that predates rotation omits the field: keep ours.
          refreshToken: result.refreshToken ?? presented.tokens.refreshToken,
        ),
      );
      // Store FIRST, adopt SECOND (island #420: presenting anything but
      // CURRENT or PREVIOUS ends the session). A write that fails left the
      // live slot as it was, so disk holds [presented]'s refresh token, which
      // the island now takes as PREVIOUS: a retry. Adopting the rotated token
      // in memory instead would rotate again from a token the disk never got,
      // and a restart would present one the island has discarded.
      try {
        await _put(rotated);
        _state = rotated;
      } catch (_) {
        _report?.call('vault.rotation_unsaved');
        _state = SessionRecord(
          presented.island,
          presented.tokens.withRefreshedAccess(result.accessToken),
        );
      }
      return Credential(result.accessToken, _lease);
    });
  }

  /// Adopt a new session for [island] after a sign-in.
  ///
  /// Stored first: if the write throws, the sign-in fails visibly instead of
  /// leaving memory holding a session the disk never took. Replaces an empty
  /// vault, a sign-out, an owner-unknown or unreadable session, or [island]'s
  /// own; a live session for another island throws [SessionHeldElsewhere].
  /// Returns the new session's lease. Throws [SessionSuperseded] when the
  /// lease has moved since [since], the lease the sign-in read before its
  /// first network call: someone signed out, switched or signed in meanwhile.
  Future<int> adopt(String island, AuthTokens tokens, {required int since}) =>
      _serial(() async {
        if (since != _lease) throw const SessionSuperseded();
        final s = _state ?? await _load();
        if (s is SessionRecord && s.island != island) {
          throw const SessionHeldElsewhere();
        }
        if (s is UnreadableData) _report?.call('vault.unreadable_replaced');
        final record = SessionRecord(island, tokens);
        await _put(record);
        _state = record;
        _advance();
        return _lease;
      });

  /// The person's own sign-out, or a switch: ends whatever is here now.
  /// [ended] is the credential it ended (null when nothing was signed in).
  ///
  /// It ends in memory whatever the disk does, so nothing in this process
  /// presents it again. [saved] is false when the end didn't reach the disk:
  /// the next launch would restore the session, so the caller says so.
  Future<({Credential? ended, bool saved})> signOut() => _serial(() async {
    final gone = _presented();
    final saved = await _end();
    return (ended: gone, saved: saved);
  });

  /// End the session only if [presented] is still what the vault would
  /// present: the same lease and the same access token. For a 401, which is
  /// about the token: one a refresh has since replaced ends nothing.
  Future<Credential?> endIf(Credential presented) => _serial(() async {
    final gone = _presented();
    if (gone == null ||
        gone.lease != presented.lease ||
        gone.accessToken != presented.accessToken) {
      return null;
    }
    await _end();
    return gone;
  });

  /// End the session only if [lease] is still current, whatever its access
  /// token is now. For a ban or a deletion, which are about the account: a
  /// refresh keeps the account, and only a new session or an end changes it.
  Future<Credential?> endIfLease(int lease) => _serial(() async {
    final gone = _presented();
    if (gone == null || lease != _lease) return null;
    await _end();
    return gone;
  });

  Credential? _presented() {
    final s = _state;
    return s is SessionRecord ? Credential(s.tokens.accessToken, _lease) : null;
  }

  /// Ends the session in memory, then on disk. Returns whether the end
  /// reached the disk.
  Future<bool> _end() async {
    _state = const SignedOut();
    _advance();
    try {
      await _put(const SignedOut());
      return true;
    } catch (_) {
      // v3.1 requirement 1. Couldn't write the sign-out, so remove what it
      // would have replaced: the legacy pair FIRST, then the slots, the stale
      // one before the live one. A crash part-way then leaves the newest
      // record readable (the allowed failure: still signed in), never a legacy
      // pair or an older record that the next launch would read as current.
      // With the slots unread there is no telling stale from live, so they
      // are left alone: the same allowed failure, reached without a gamble.
      try {
        for (final k in _legacyKeys) {
          await _slots.delete(k);
        }
        if (!_layoutKnown) throw StateError('vault unread');
        final live = _liveSlot;
        for (final i in live == null ? [0, 1] : [1 - live, live]) {
          await _slots.delete(_slotKeys[i]);
        }
        _liveSlot = null;
        return true;
      } catch (_) {
        // A rejected session left on disk is read back on the next launch and
        // rejected again by its first refresh. Not silent for a sign-out.
        _report?.call('vault.end_unsaved');
        return false;
      }
    }
  }

  void _advance() {
    _lease++;
    _flight = null;
  }

  /// The first read. Runs in the lane; leaves [_state] null if the Keychain
  /// throws, so a later call reads again.
  Future<StoredSession> _load() async {
    final cached = _state;
    if (cached != null) return cached;

    final found = await _readSlots();
    if (found != null) return _state = found;

    // Neither slot exists: this build has never written here. The legacy
    // pair is read now, once, and whatever it says is written as a slot
    // before anything presents it, so it is never read again (design 26 §2b).
    final access = await _slots.read(legacyAccessKey);
    final refresh = await _slots.read(legacyRefreshKey);
    if (access == null || refresh == null) return _state = const NoSession();
    final tokens = AuthTokens(accessToken: access, refreshToken: refresh);
    final island = await _slots.read(legacyIslandKey) ?? _placeLegacy();
    final placed = island == null
        ? OwnerUnknown(tokens)
        : SessionRecord(island, tokens);
    // A placement write that fails leaves the vault unloaded, and the next
    // read places it again from the same inputs (v3.1 requirement 2).
    await _put(placed);
    return _state = placed;
  }

  /// The newer of the two slots, or null when neither exists.
  Future<StoredSession?> _readSlots() async {
    final raw = [
      await _slots.read(_slotKeys[0]),
      await _slots.read(_slotKeys[1]),
    ];
    final parsed = [for (final r in raw) r == null ? null : _Parsed.of(r)];
    int? best;
    for (var i = 0; i < 2; i++) {
      final p = parsed[i];
      if (p == null) continue;
      if (best == null || p.seq > parsed[best]!.seq) best = i;
    }
    _liveSlot = best;
    _seq = [for (final p in parsed) ?p?.seq].fold(0, (a, b) => a > b ? a : b);
    _layoutKnown = true;
    if (best == null) return null;
    final winner = parsed[best]!.session;
    if (winner is UnreadableData) _report?.call('vault.unreadable');
    return winner;
  }

  /// Write [session] without touching the live slot, then retire what it
  /// replaced. Throws only if the new record may not have landed.
  ///
  /// Learns the slot layout itself when nothing has read it yet: a write
  /// that guessed would land beside a record it can't see, under a sequence
  /// that record may beat on the next launch.
  Future<void> _put(StoredSession session) async {
    if (!_layoutKnown) await _readSlots();
    final target = _liveSlot == 0 ? 1 : 0;
    final seq = _seq + 1;
    // The target holds nothing live: empty, or a record the live one replaced
    // whose retirement failed. So the plugin deleting it on a failed update
    // costs nothing.
    await _slots.write(_slotKeys[target], _encode(session, seq));
    final previous = _liveSlot;
    _liveSlot = target;
    _seq = seq;
    await _retire([if (previous != null) _slotKeys[previous], ..._legacyKeys]);
  }

  // Best effort: a stale slot loses to the newer sequence number, and the
  // legacy pair is never read while a slot exists.
  Future<void> _retire(List<String> keys) async {
    for (final k in keys) {
      try {
        await _slots.delete(k);
      } catch (_) {
        _report?.call('vault.retire_failed');
      }
    }
  }

  static String _encode(StoredSession s, int seq) => jsonEncode({
    'v': 1,
    'seq': seq,
    ...switch (s) {
      SessionRecord(:final island, :final tokens) => {
        'island': island,
        'access': tokens.accessToken,
        'refresh': tokens.refreshToken,
      },
      OwnerUnknown(:final tokens) => {
        'owner': 'unknown',
        'access': tokens.accessToken,
        'refresh': tokens.refreshToken,
      },
      SignedOut() => {'signedOut': true},
      NoSession() || UnreadableData() => throw ArgumentError.value(s),
    },
  });
}

/// One slot's content. Unknown keys are ignored, so a later field (the
/// refresh attempt id of island #452) can join version 1 without a bump.
class _Parsed {
  final int seq;
  final StoredSession session;
  _Parsed(this.seq, this.session);

  factory _Parsed.of(String raw) {
    final Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      // Not even JSON: loses to any slot that is.
      return _Parsed(-1, const UnreadableData());
    }
    if (j is! Map) return _Parsed(-1, const UnreadableData());
    final seq = j['seq'] is int ? j['seq'] as int : -1;
    // Another version wins by its sequence like any write, and is unreadable
    // HERE: a rollback must not fall back to the older record it replaced.
    if (j['v'] != 1) return _Parsed(seq, const UnreadableData());
    final access = j['access'];
    final refresh = j['refresh'];
    final tokens = access is String && refresh is String
        ? AuthTokens(accessToken: access, refreshToken: refresh)
        : null;
    final island = j['island'];
    if (j['signedOut'] == true) return _Parsed(seq, const SignedOut());
    if (tokens != null && island is String) {
      return _Parsed(seq, SessionRecord(island, tokens));
    }
    if (tokens != null && j['owner'] == 'unknown') {
      return _Parsed(seq, OwnerUnknown(tokens));
    }
    return _Parsed(seq, const UnreadableData());
  }
}
