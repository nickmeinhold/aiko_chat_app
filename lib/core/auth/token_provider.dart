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
  /// - returns null if the refresh token was definitively rejected: the vault
  ///   has ended the session and announced it on [SessionVault.ended];
  /// - THROWS [SessionSuperseded] if [stale]'s session was replaced or ended:
  ///   the caller's work belongs to it, and must neither log out nor retry;
  /// - THROWS on a transient error (network/timeout/5xx) — caller should retry
  ///   later, NOT log out.
  Future<Credential?> refresh(Credential stale);
}

/// One island's door onto the [SessionVault]. Holds no session state, and
/// can neither start nor end a session: sign-ins and ends go to the vault
/// itself, through the auth controller.
///
/// The remote refresh call is injected as [_remoteRefresh] and MUST use a
/// token-less HTTP client (the refresh endpoint is unauthenticated), so this
/// provider never depends on the interceptor-wrapped REST client — avoiding a
/// provider cycle (design 02, finding 6).
class DefaultTokenProvider implements TokenProvider {
  /// The vault this door presents. The auth controller reaches the vault
  /// through here, so the two can never be looking at different ones.
  final SessionVault vault;
  final String island;

  /// refreshToken -> new access token (+ rotated refresh token). Throws
  /// [RefreshRejected] on a definitive rejection.
  final Future<RefreshResult> Function(String refreshToken) _remoteRefresh;

  DefaultTokenProvider({
    required this.vault,
    required this.island,
    required Future<RefreshResult> Function(String refreshToken) remoteRefresh,
  }) : _remoteRefresh = remoteRefresh;

  @override
  Future<Credential?> current() => vault.present(island);

  @override
  Future<Credential?> refresh(Credential stale) =>
      vault.refresh(island, stale, _remoteRefresh);
}
