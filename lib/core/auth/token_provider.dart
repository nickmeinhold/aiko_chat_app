import '../../features/auth/domain/auth_models.dart';
import '../../services/secure_token_store.dart';

/// Thrown by a remote-refresh function when the refresh token is *definitively
/// rejected* (HTTP 401/403) — i.e. the session is truly unauthenticated. Any
/// OTHER error (network/timeout/5xx) must propagate as-is so it's treated as
/// transient (retry later), NOT a logout. This distinction is what stops a
/// network blip from logging the user out (design 02).
class RefreshRejected implements Exception {
  const RefreshRejected();
}

/// A successful `/v1/auth/refresh`. [refreshToken] is the rotated token when
/// the island rotates (island #420), or null from an island that predates
/// rotation — in which case the token we presented stays current.
class RefreshResult {
  final String accessToken;
  final String? refreshToken;

  const RefreshResult(this.accessToken, {this.refreshToken});

  factory RefreshResult.fromJson(Map<String, dynamic> j) => RefreshResult(
    j['access_token'] as String,
    refreshToken: j['refresh_token'] as String?,
  );
}

/// Supplies a fresh access token to the two consumers that need one — the REST
/// auth interceptor (per request) and the WSS connect (per (re)connect) — while
/// guaranteeing **at most one refresh in flight** across both.
abstract interface class TokenProvider {
  /// The cached access token (may be expired). Null if logged out.
  Future<String?> currentAccessToken();

  /// Refresh the access token. Single-flight: concurrent callers share one
  /// in-flight refresh.
  /// - returns the new access token on success;
  /// - returns null if the refresh token was definitively rejected (session is
  ///   now unauthenticated — store cleared, onUnauthenticated fired);
  /// - THROWS on a transient error (network/timeout/5xx) — caller should retry
  ///   later, NOT log out.
  Future<String?> refreshAccessToken();
}

/// The ONE session behind a [SecureTokenStore]. `backendProvider` rebuilds
/// [DefaultTokenProvider] (island switch, config change) while the store, and
/// so the Keychain session, stays the same. Instances that each kept their own
/// cache and their own single-flight were several authorities over one
/// session: one could rotate while another still presented the old token,
/// which the island reads as two holders and ends (island #420). So every
/// instance over a store shares this: one cache, one refresh in flight, and
/// one lane through which every change to the session commits.
class _Session {
  AuthTokens? cache;

  /// Whether [cache] has been loaded from the store yet. Kept apart from
  /// `cache == null`, which also means "logged out": a read that started
  /// before a logout must not reinstall the tokens the logout just removed.
  var loaded = false;
  Future<String?>? inFlight;
  Future<void> _lane = Future<void>.value();

  /// Run [change] after every change queued before it, so a refresh's commit,
  /// a sign-in and a logout can never interleave their reads and writes.
  Future<T> commit<T>(Future<T> Function() change) {
    final run = _lane.then((_) => change());
    _lane = run.then<void>((_) {}, onError: (_) {});
    return run;
  }
}

/// Default impl. The remote refresh call is injected as [_remoteRefresh] and
/// MUST use a token-less HTTP client (the refresh endpoint is unauthenticated),
/// so this provider never depends on the interceptor-wrapped REST client —
/// avoiding a provider cycle (design 02, finding 6).
class DefaultTokenProvider implements TokenProvider {
  final SecureTokenStore _store;
  final _Session _session;

  static final _sessions = Expando<_Session>('session');

  /// refreshToken -> new access token (+ rotated refresh token). Throws on
  /// failure (invalid/expired RT).
  final Future<RefreshResult> Function(String refreshToken) _remoteRefresh;

  /// Called once when the session becomes unauthenticated (refresh failed / no
  /// tokens). Wired to flip auth state → router redirect to login.
  final void Function()? _onUnauthenticated;

  DefaultTokenProvider({
    required SecureTokenStore store,
    required Future<RefreshResult> Function(String refreshToken) remoteRefresh,
    void Function()? onUnauthenticated,
  }) : _store = store,
       _session = _sessions[store] ??= _Session(),
       _remoteRefresh = remoteRefresh,
       _onUnauthenticated = onUnauthenticated;

  @override
  Future<String?> currentAccessToken() async {
    await _warm();
    return _session.cache?.accessToken;
  }

  // The first read of the store goes through the lane like every other
  // change, so a sign-in or logout queued during it lands after it, and once
  // anything has set the session, the store is never read over it again.
  Future<void> _warm() async {
    if (_session.loaded) return;
    await _session.commit(() async {
      if (_session.loaded) return;
      _session.cache = await _store.read();
      _session.loaded = true;
    });
  }

  @override
  // NOT async: `??=` assigns the in-flight future in the SAME synchronous step
  // as the null-check, before any await — so a second caller arriving during
  // the refresh cannot start a second one (design 02, finding 2). The slot is
  // the SESSION's, so this holds across rebuilt providers too. It is cleared
  // on BOTH success and failure so a failed refresh doesn't pin a dead future.
  Future<String?> refreshAccessToken() => _session.inFlight ??= _doRefresh()
      .whenComplete(() => _session.inFlight = null);

  Future<String?> _doRefresh() async {
    await _warm();
    final presented = _session.cache;
    final refreshToken = presented?.refreshToken;
    if (refreshToken == null) {
      await _session.commit(_markUnauthenticated);
      return null;
    }
    final RefreshResult result;
    try {
      result = await _remoteRefresh(refreshToken);
    } on RefreshRejected {
      return _session.commit(() async {
        // A sign-in or logout landed while this refresh was out: the
        // rejection belongs to a session that is no longer ours, so it must
        // not end the new one.
        if (!identical(_session.cache, presented)) {
          return _session.cache?.accessToken;
        }
        // Refresh token genuinely rejected -> logout.
        await _markUnauthenticated();
        return null;
      });
    }
    // Any other error (network/timeout/5xx) propagates: transient, do NOT
    // clear tokens. The caller retries later with the still-valid refresh token.

    return _session.commit(() async {
      // Writing these back after a sign-in or logout would revert the fresh
      // session to the old one, or resurrect one the user just logged out of.
      if (!identical(_session.cache, presented)) {
        return _session.cache?.accessToken;
      }
      final rotated = AuthTokens(
        accessToken: result.accessToken,
        // An island that predates rotation omits the field: keep ours.
        refreshToken: result.refreshToken ?? refreshToken,
      );
      // Store FIRST, adopt SECOND (island #420: presenting anything but
      // CURRENT or PREVIOUS ends the session). If the write fails — the
      // Keychain is WhenUnlocked, so a locked phone throws — present what is
      // ACTUALLY on disk: the island treats PREVIOUS as a retry. Adopting the
      // rotated token in memory instead would rotate again from an unwritten
      // token, and a restart before unlock would present one the island has
      // already discarded.
      try {
        await _store.write(rotated);
        _session.cache = rotated;
      } catch (_) {
        _session.cache = (await _readOrNull() ?? presented!)
            .withRefreshedAccess(result.accessToken);
      }
      return result.accessToken;
    });
  }

  // A write can die halfway (access token written, refresh token not), so
  // after a failed write the disk, not [presented], says what the island
  // will see after a restart. A locked Keychain may refuse the read too.
  Future<AuthTokens?> _readOrNull() async {
    try {
      return await _store.read();
    } catch (_) {
      return null;
    }
  }

  // The island has ended this session; the app ends it too, even when a
  // locked Keychain refuses the delete. A throw here would reach the caller as
  // a TRANSIENT error, and the rejected tokens, still on disk, would be read
  // back and rejected again until unlock. The next sign-in overwrites them.
  Future<void> _markUnauthenticated() async {
    _session.cache = null;
    _session.loaded = true;
    try {
      await _store.clear();
    } catch (_) {
      // Left on disk: rejected tokens the next sign-in overwrites.
    }
    _onUnauthenticated?.call();
  }

  /// Adopt tokens after a successful login/register. Stored first, like a
  /// rotation: if the write throws, the sign-in fails visibly instead of
  /// leaving memory holding a session the disk never took.
  Future<void> setTokens(AuthTokens tokens) => _session.commit(() async {
    await _store.write(tokens);
    _session.cache = tokens;
    _session.loaded = true;
  });

  /// Explicit logout.
  Future<void> clearTokens() => _session.commit(() async {
    _session.cache = null;
    _session.loaded = true;
    await _store.clear();
  });
}
