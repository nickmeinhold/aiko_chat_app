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

/// Default impl. The remote refresh call is injected as [_remoteRefresh] and
/// MUST use a token-less HTTP client (the refresh endpoint is unauthenticated),
/// so this provider never depends on the interceptor-wrapped REST client —
/// avoiding a provider cycle (design 02, finding 6).
class DefaultTokenProvider implements TokenProvider {
  final SecureTokenStore _store;

  /// refreshToken -> new access token (+ rotated refresh token). Throws on
  /// failure (invalid/expired RT).
  final Future<RefreshResult> Function(String refreshToken) _remoteRefresh;

  /// Called once when the session becomes unauthenticated (refresh failed / no
  /// tokens). Wired to flip auth state → router redirect to login.
  final void Function()? _onUnauthenticated;

  AuthTokens? _cache;
  Future<String?>? _inFlight;

  // Every refresh is numbered as it is SENT, process-wide: `backendProvider`
  // rebuilds this provider, and an old instance's refresh can still be out
  // when the new one sends. Two retries of PREVIOUS more than 30 s apart get
  // DIFFERENT currents from the island, and storing the older response last
  // would present a token that is neither — session ended. So only the
  // newest-sent response that has come back may be stored; an older one is
  // dropped even when it succeeded. Single-flight already orders refreshes
  // within one instance; this orders them across instances.
  static var _sent = 0;
  static var _newestAnswered = 0;

  DefaultTokenProvider({
    required SecureTokenStore store,
    required Future<RefreshResult> Function(String refreshToken) remoteRefresh,
    void Function()? onUnauthenticated,
  }) : _store = store,
       _remoteRefresh = remoteRefresh,
       _onUnauthenticated = onUnauthenticated;

  @override
  Future<String?> currentAccessToken() async {
    await _warm();
    return _cache?.accessToken;
  }

  // Read into a local, then `??=`: `_cache ??= await _store.read()` tests
  // `_cache` BEFORE the await and assigns AFTER it, so a sign-in landing
  // during the Keychain read would be overwritten by the old tokens.
  Future<void> _warm() async {
    if (_cache != null) return;
    final stored = await _store.read();
    _cache ??= stored;
  }

  @override
  // NOT async: `??=` assigns the in-flight future in the SAME synchronous step
  // as the null-check, before any await — so a second caller arriving during
  // the refresh cannot start a second one (design 02, finding 2). The slot is
  // cleared on BOTH success and failure so a failed refresh doesn't pin a dead
  // future forever.
  Future<String?> refreshAccessToken() =>
      _inFlight ??= _doRefresh().whenComplete(() => _inFlight = null);

  Future<String?> _doRefresh() async {
    await _warm();
    final presented = _cache;
    final refreshToken = presented?.refreshToken;
    if (refreshToken == null) {
      await _markUnauthenticated();
      return null;
    }
    final seq = ++_sent;
    final RefreshResult result;
    try {
      result = await _remoteRefresh(refreshToken);
    } on RefreshRejected {
      // A sign-in or logout landed while this refresh was out: the rejection
      // belongs to a session that is no longer ours, so it must not end the
      // new one.
      if (!identical(_cache, presented)) return _cache?.accessToken;
      // Refresh token genuinely rejected -> logout.
      await _markUnauthenticated();
      return null;
    }
    // Any other error (network/timeout/5xx) propagates: transient, do NOT
    // clear tokens. The caller retries later with the still-valid refresh token.

    // Same check on success: writing these back would revert a fresh sign-in
    // to the old session, or resurrect one the user just logged out of.
    if (!identical(_cache, presented)) return _cache?.accessToken;

    // A newer refresh (from a rebuilt provider) already answered: what it
    // stored, or kept, is the token the island expects next. Adopt the store.
    if (seq < _newestAnswered) {
      _cache = await _store.read();
      return _cache?.accessToken;
    }
    _newestAnswered = seq;

    final rotated = AuthTokens(
      accessToken: result.accessToken,
      // An island that predates rotation omits the field: keep ours.
      refreshToken: result.refreshToken ?? refreshToken,
    );
    // Store FIRST, adopt SECOND (island #420's rule: presenting anything older
    // than the previous token ends the session). If the write fails — the
    // Keychain is WhenUnlocked, so a locked phone throws — keep presenting the
    // STORED token: the island treats previous as a retry. Adopting the
    // rotated one in memory instead would rotate again from an unwritten
    // token, and a restart before unlock would present a token two
    // generations back.
    try {
      await _store.write(rotated);
      _cache = rotated;
    } catch (_) {
      _cache = presented!.withRefreshedAccess(result.accessToken);
    }
    return result.accessToken;
  }

  Future<void> _markUnauthenticated() async {
    await _store.clear();
    _cache = null;
    _onUnauthenticated?.call();
  }

  /// Adopt tokens after a successful login/register.
  Future<void> setTokens(AuthTokens tokens) async {
    _cache = tokens;
    await _store.write(tokens);
  }

  /// Explicit logout.
  Future<void> clearTokens() async {
    _cache = null;
    await _store.clear();
  }
}
