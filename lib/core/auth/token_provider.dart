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

  /// refreshToken -> new access token. Throws on failure (invalid/expired RT).
  final Future<String> Function(String refreshToken) _remoteRefresh;

  /// Called once when the session becomes unauthenticated (refresh failed / no
  /// tokens). Wired to flip auth state → router redirect to login.
  final void Function()? _onUnauthenticated;

  AuthTokens? _cache;
  Future<String?>? _inFlight;

  DefaultTokenProvider({
    required SecureTokenStore store,
    required Future<String> Function(String refreshToken) remoteRefresh,
    void Function()? onUnauthenticated,
  })  : _store = store,
        _remoteRefresh = remoteRefresh,
        _onUnauthenticated = onUnauthenticated;

  @override
  Future<String?> currentAccessToken() async {
    _cache ??= await _store.read();
    return _cache?.accessToken;
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
    _cache ??= await _store.read();
    final refreshToken = _cache?.refreshToken;
    if (refreshToken == null) {
      await _markUnauthenticated();
      return null;
    }
    try {
      final newAccess = await _remoteRefresh(refreshToken);
      final updated = AuthTokens(
          accessToken: newAccess, refreshToken: refreshToken); // RT not rotated
      _cache = updated;
      await _store.write(updated);
      return newAccess;
    } on RefreshRejected {
      // Refresh token genuinely rejected -> logout.
      await _markUnauthenticated();
      return null;
    }
    // Any other error (network/timeout/5xx) propagates: transient, do NOT
    // clear tokens. The caller retries later with the still-valid refresh token.
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
