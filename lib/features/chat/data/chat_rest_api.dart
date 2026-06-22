import '../../auth/domain/auth_models.dart';
import '../domain/channel.dart';
import '../domain/message.dart';

/// A page of history (always ascending). Carries both cursors so either
/// direction can page:
/// [nextBefore] = the gateway's `next_before` (oldest id in this batch) — pass as
///   the next `before` to page OLDER (UI scroll-up). Null when no older history.
/// [nextAfter] = the gateway's `next_after` (newest id in this batch) — pass as
///   the next `after` to page NEWER (B4 reconnect catch-up). Null on an empty page.
class HistoryPage {
  final String channelId;
  final List<Message> messages;
  final String? nextBefore;
  final String? nextAfter;
  const HistoryPage(
      {required this.channelId,
      required this.messages,
      this.nextBefore,
      this.nextAfter});
}

/// Thrown by an authenticated REST call when the request is *terminally*
/// rejected for auth reasons — a 401 that survived the interceptor's
/// single-flight refresh-and-retry, or a 403. Distinct from a transient
/// network/timeout/5xx error (which propagates as-is and must NOT trigger a
/// logout — design 02). The reconcile engine recognises THIS type to route a
/// reconnect to the unauthenticated state instead of a transient redrain,
/// **without depending on `dio`** (the layering invariant below: the repository
/// depends on this seam, never the HTTP client). The REST impl translates the
/// transport-level [DioException] into this at the boundary.
class Unauthorized implements Exception {
  /// The HTTP status that triggered it (401 or 403), for telemetry/debugging.
  final int? statusCode;
  const Unauthorized([this.statusCode]);
  @override
  String toString() => 'Unauthorized(statusCode: $statusCode)';
}

/// The history/auth/media REST seam (plan §B1; media is a later phase). No
/// lifecycle. Riverpod + the repository depend on THIS, never on `dio`.
abstract interface class ChatRestApi {
  Future<AuthSession> login(String username, String password);
  Future<AuthSession> register(
      String username, String displayName, String password);

  /// Exchange a refresh token for a fresh access token (the refresh token is
  /// NOT rotated by the gateway). Returns the new access token.
  Future<String> refresh(String refreshToken);

  Future<AppUser> me();
  Future<List<Channel>> listChannels();
  /// A page of channel history (ascending). [before] pages older (scroll-up);
  /// [after] pages newer (reconnect catch-up). Mutually exclusive — the gateway
  /// uses `after` if both are given.
  Future<HistoryPage> getHistory(String channelId,
      {String? before, String? after, int limit = 50});
}
