import '../../auth/data/social_auth_client.dart';
import '../../auth/domain/auth_models.dart';
import '../../auth/domain/auth_provider.dart';
import '../../auth/domain/social_models.dart';
import '../../moderation/domain/moderation_models.dart';
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

/// Thrown by [ChatRestApi.claimHandle] when the requested handle is already
/// taken (the gateway returns 409). The claim UI surfaces this inline ("that
/// handle is taken") rather than as a generic failure.
class HandleTaken implements Exception {
  const HandleTaken();
  @override
  String toString() => 'HandleTaken';
}

/// Thrown by [ChatRestApi.deleteAccount] when the gateway refuses the deletion
/// because the user is the sole admin of one or more channels (409). The
/// settings UI surfaces [message] so the user knows which channels to hand over
/// or leave first, rather than a generic failure.
class SoleAdminDeletionBlocked implements Exception {
  final String message;
  const SoleAdminDeletionBlocked(this.message);
  @override
  String toString() => 'SoleAdminDeletionBlocked($message)';
}

/// The history/auth/media REST seam (plan §B1; media is a later phase). No
/// lifecycle. Riverpod + the repository depend on THIS, never on `dio`.
abstract interface class ChatRestApi {
  /// Verify a provider ID token at the gateway. Returns [Authenticated] for a
  /// known identity (log straight in) or [PendingHandle] for a new one (which
  /// must then call [claimHandle]). [rawNonce] is the un-hashed nonce — the
  /// gateway checks the token's `nonce` claim against `sha256(rawNonce)`.
  /// [name] forwards the provider's display name (Apple only sends it on the
  /// first sign-in, so it may be null).
  Future<SocialOutcome> socialSignIn({
    required SocialProvider provider,
    required String idToken,
    required String rawNonce,
    String? name,
  });

  /// The sign-in providers the gateway offers (native + broker), driving the
  /// dynamic login UI. Empty when social sign-in is disabled at the gateway.
  Future<List<AuthProviderInfo>> listAuthProviders();

  /// Redeem a broker OAuth [code] (the single-use handoff captured from the
  /// `aikochat://auth?code=…` callback) for a session, presenting the app-held
  /// [verifier] that binds the handoff to this app (cage-match #37 — a stolen
  /// code is unredeemable without it). Returns the SAME shape as [socialSignIn]
  /// — [Authenticated] or [PendingHandle] — because both funnel through the
  /// gateway's single identity door.
  Future<SocialOutcome> exchangeOAuth(String code, String verifier);

  /// Complete provisioning for a new social identity by claiming a [handle].
  /// [provisioningToken] comes from the [PendingHandle]. Throws [HandleTaken]
  /// on a 409 conflict.
  Future<AuthSession> claimHandle({
    required String provisioningToken,
    required String handle,
    required String displayName,
  });

  /// Exchange a refresh token for a fresh access token (the refresh token is
  /// NOT rotated by the gateway). Returns the new access token.
  Future<String> refresh(String refreshToken);

  Future<AppUser> me();

  /// Permanently delete the authenticated user's account (Apple 5.1.1(v)).
  /// Succeeds silently (the gateway returns 204). Throws
  /// [SoleAdminDeletionBlocked] on a 409 (sole admin of a channel) and
  /// [Unauthorized] on a terminal auth rejection.
  Future<void> deleteAccount();

  Future<List<Channel>> listChannels();
  /// A page of channel history (ascending). [before] pages older (scroll-up);
  /// [after] pages newer (reconnect catch-up). Mutually exclusive — the gateway
  /// uses `after` if both are given.
  Future<HistoryPage> getHistory(String channelId,
      {String? before, String? after, int limit = 50});

  // --- moderation (UGC — Apple 1.2 / Google UGC, #7) -----------------------

  /// Block [userId] for the current account (mutual: neither sees the other's
  /// messages, nor may reply across the block). Idempotent at the gateway (a
  /// re-block is a 204 no-op). [Unauthorized] on a terminal auth rejection.
  Future<void> blockUser(String userId);

  /// Remove the current account's block of [userId]. Idempotent (204 even if not
  /// blocked).
  Future<void> unblockUser(String userId);

  /// The users the current account has blocked (most recent first) — backs the
  /// Settings "Blocked users" list.
  Future<List<BlockedUser>> listBlocks();

  /// Report [messageId] as objectionable with [reason] (feeds the gateway's ops
  /// queue behind the 24h-action commitment). Idempotent per (message, reporter).
  Future<void> reportMessage(String messageId, ReportReason reason);
}
