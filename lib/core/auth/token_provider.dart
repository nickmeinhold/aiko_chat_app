import '../../features/auth/domain/auth_models.dart';
import '../../services/session_vault.dart';
import 'credential.dart';

export 'credential.dart';

/// Supplies a fresh access token to the two consumers that need one — the REST
/// auth interceptor (per request) and the WSS connect (per (re)connect) — while
/// guaranteeing **at most one refresh in flight** across both.
abstract interface class TokenProvider {
  /// The session's credential (its access token may be expired). Null if
  /// there's no session for this island.
  Future<Credential?> current();

  /// Refresh [stale], the credential a consumer presented and had refused.
  /// Single-flight: concurrent callers share one in-flight refresh.
  /// - returns the new credential on success;
  /// - returns null if the refresh token was definitively rejected (session is
  ///   now unauthenticated — stored as signed out, onUnauthenticated fired);
  /// - THROWS [SessionSuperseded] if [stale]'s session was replaced or ended:
  ///   the caller's work belongs to it, and must neither log out nor retry;
  /// - THROWS on a transient error (network/timeout/5xx) — caller should retry
  ///   later, NOT log out.
  Future<Credential?> refresh(Credential stale);
}

/// One island's door onto the [SessionVault]. Holds no session state: the
/// vault outlives every door `backendProvider` builds and discards, so two
/// doors can't disagree about the session. A door presents the vault's
/// session only when it was issued by [island], and never writes except on
/// the sign-in and sign-out it is asked for.
///
/// The remote refresh call is injected as [_remoteRefresh] and MUST use a
/// token-less HTTP client (the refresh endpoint is unauthenticated), so this
/// provider never depends on the interceptor-wrapped REST client — avoiding a
/// provider cycle (design 02, finding 6).
class DefaultTokenProvider implements TokenProvider {
  final SessionVault _vault;
  final String island;

  /// refreshToken -> new access token (+ rotated refresh token). Throws
  /// [RefreshRejected] on a definitive rejection.
  final Future<RefreshResult> Function(String refreshToken) _remoteRefresh;

  /// Called when this door's refresh found the session rejected. Wired to
  /// flip auth state → router redirect to login. Every caller that shared the
  /// rejected flight fires it; the auth controller's teardown is idempotent.
  final void Function()? _onUnauthenticated;

  DefaultTokenProvider({
    required SessionVault vault,
    required this.island,
    required Future<RefreshResult> Function(String refreshToken) remoteRefresh,
    void Function()? onUnauthenticated,
  }) : _vault = vault,
       _remoteRefresh = remoteRefresh,
       _onUnauthenticated = onUnauthenticated;

  @override
  Future<Credential?> current() => _vault.present(island);

  /// The access token alone, for code that only asks "is there a session".
  Future<String?> currentAccessToken() async => (await current())?.accessToken;

  @override
  Future<Credential?> refresh(Credential stale) async {
    final fresh = await _vault.refresh(island, stale, _remoteRefresh);
    if (fresh == null) _onUnauthenticated?.call();
    return fresh;
  }

  /// Adopt tokens after a successful login/register.
  Future<void> setTokens(AuthTokens tokens) => _vault.adopt(island, tokens);

  /// Explicit logout.
  Future<void> clearTokens() => _vault.signOut();
}
