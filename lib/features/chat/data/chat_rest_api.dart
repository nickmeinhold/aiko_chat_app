import '../../auth/domain/auth_models.dart';
import '../../auth/domain/identity_models.dart';
import '../../moderation/domain/moderation_models.dart';
import '../domain/channel.dart';
import '../domain/gateway_capabilities.dart';
import '../domain/message.dart';
import '../domain/retraction.dart';

/// One item on a history page. HETEROGENEOUS since island #104: `get_history`
/// interleaves ordinary messages with forward-ULID retractions (moderator
/// takedowns), merged into one ascending stream by id. Sealed so the pager's
/// `switch` is compiler-forced to handle every arm — a new item type the island
/// ADDS later becomes a compile error here, not a silent drop.
///
/// [id] is the item's cursor id (message → `msg_id`; retraction → the retraction
/// ULID). The pager advances its watermark from `items.last.id` regardless of
/// type — the island's `next_after = rows[-1].id` is computed across both types,
/// so either kind of trailing item yields the correct next cursor.
sealed class HistoryItem {
  const HistoryItem();

  /// The cursor id for this item (see class doc).
  String get id;
}

/// An ordinary history message.
class MessageHistoryItem extends HistoryItem {
  final Message message;
  const MessageHistoryItem(this.message);

  /// A history/inbound message always carries a server ULID (`Message.fromView`
  /// sets `id = msg_id`), so the non-null assertion is safe here.
  @override
  String get id => message.id!;
}

/// A moderator takedown interleaved into history.
class RetractionHistoryItem extends HistoryItem {
  final Retraction retraction;
  const RetractionHistoryItem(this.retraction);

  @override
  String get id => retraction.id;
}

/// A history item of a type this client doesn't understand yet (a future island
/// event kind). INERT — the pager applies no effect for it — but it carries the
/// row's [id] so the watermark still advances THROUGH it. Without this, a skipped
/// unknown that trails the last KNOWN item (or a page of only unknowns) would
/// leave the cursor below the real page end, and catch-up would refetch — or, if
/// the unknown is the newest row at the fence, WEDGE — forever (cage-match Carnot
/// HIGH, PR #102). The forward stream (island #104) is expected to grow item
/// types; carrying them inertly keeps catch-up monotonic across that evolution.
class UnknownHistoryItem extends HistoryItem {
  @override
  final String id;
  const UnknownHistoryItem(this.id);
}

/// A page of history (always ascending). Carries both cursors so either
/// direction can page:
/// [nextBefore] = the gateway's `next_before` (oldest id in this batch) — pass as
///   the next `before` to page OLDER (UI scroll-up). Null when no older history.
/// [nextAfter] = the gateway's `next_after` (newest id in this batch) — pass as
///   the next `after` to page NEWER (B4 reconnect catch-up). Null on an empty page.
///
/// [items] is HETEROGENEOUS (messages + retractions) since island #104. Most
/// callers only produce messages — use [HistoryPage.ofMessages] for that case.
class HistoryPage {
  final String channelId;
  final List<HistoryItem> items;
  final String? nextBefore;
  final String? nextAfter;
  const HistoryPage(
      {required this.channelId,
      required this.items,
      this.nextBefore,
      this.nextAfter});

  /// Convenience for a message-only page (the common case, and every caller that
  /// predates retractions): wraps each [Message] as a [MessageHistoryItem].
  factory HistoryPage.ofMessages({
    required String channelId,
    required List<Message> messages,
    String? nextBefore,
    String? nextAfter,
  }) =>
      HistoryPage(
        channelId: channelId,
        items: messages.map<HistoryItem>(MessageHistoryItem.new).toList(),
        nextBefore: nextBefore,
        nextAfter: nextAfter,
      );
}

/// A passkey ceremony's `start` response: the gateway's WebAuthn `options`
/// (opaque JSON the device authenticator consumes) plus an opaque [state] token
/// that binds the issued challenge server-side. The app round-trips [state]
/// untouched to the matching `finish` call — a server-side-nonce binding, so a
/// challenge can only be completed by the flow that started it.
typedef PasskeyChallenge = ({String state, String optionsJson});

/// Thrown by an authenticated REST call when the request is *terminally*
/// rejected for authentication reasons — a 401 that survived the interceptor's
/// single-flight refresh-and-retry, or the ban-403 (via the [AccountSuspended]
/// refinement). A plain, non-suspended 403 is authoriZation, not authentication,
/// and maps to [Forbidden] on the AUTHED path (`_authedCall`, NOT terminal — see
/// there). Door-dependent: on the token-less login/claim door
/// (`_throwIfAuthTerminal`), a plain 403 is STILL terminal `Unauthorized` — a
/// rejected/expired provisioning token there IS an authN failure, and no operator
/// endpoint uses that door. Distinct from a transient
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

/// The island BANNED this account — the gateway's `403 {"detail":"account
/// suspended"}`, emitted at every ingress (handoff 2026-07-27, island #1914).
/// A *refinement* of [Unauthorized]: it IS a terminal-auth rejection (so it
/// reuses every existing router — reconcile's `_isAuthError`, the WS
/// `unauthenticated` path — that already treats a 403 as terminal), but it is
/// NOT "re-authenticate." A ban is per-island and reversible, so the honest
/// message is "this account is suspended on this island," never "your session
/// expired, sign in again" (which loops: a re-auth attempt 403s again).
/// Consumers that want the distinct copy match `case AccountSuspended()` BEFORE
/// `case Unauthorized()` (specific pattern wins); routers matching the base type
/// keep working unchanged. Only surfaced at the two direct REST boundaries where
/// the 403 body is in hand — the refresh ingress leaves it as a generic terminal
/// rejection (→ logout → login), where the re-login attempt re-surfaces it.
///
/// NAMED TRADEOFF (do NOT "fix" this into the interceptor's `catch (_)`): a ban
/// arriving mid-session on a REFRESH (access token already expired) shows one
/// hop of "session expired" before the honest suspended copy lands on re-login.
/// That one-hop is the deliberate price of NOT threading `AccountSuspended`
/// through the refresh taxonomy — where a broad catch would risk mislabelling it
/// `auth_transient` (a network blip), the exact failure design-02 exists to
/// prevent. A passive suspended banner that closes the one-hop is tracked
/// separately (app task #29), NOT via the interceptor.
class AccountSuspended extends Unauthorized {
  const AccountSuspended() : super(403);
  @override
  String toString() => 'AccountSuspended';
}

/// The gateway ANSWERED and refused this specific action for an **authorization**
/// reason — a plain `403` whose body is NOT the ban phrase (e.g. the island's
/// `ModeratorUser` gate on an operator endpoint, `deps.py:63 "not a moderator"`,
/// or a channel-admin-only mutation, `members.py:99`). Deliberately NOT a subtype
/// of [Unauthorized]: authz ≠ authn. Holding a valid session and being denied one
/// action must NOT log the user out — the two terminal-auth routers
/// (`chat_repository._isAuthError`, `auth_controller`'s `on Unauthorized`) match
/// [Unauthorized] and so never fire for a [Forbidden]. The caller that expects a
/// denial (the operator seat) catches THIS to react locally — e.g. refresh
/// `/v1/me` to reconcile a stale moderator flag — instead of ejecting the user.
///
/// PREMISE (verify before widening — cage-match, 2026-07-28): today NO
/// app-reachable *authed* endpoint returns a non-suspended 403. The ban-403 is
/// peeled off first (`_isSuspended` → [AccountSuspended]); the island's other
/// authed 403s (member-admin, moderator-gate) are unreachable from the app until
/// the operator seat lands. So splitting a plain 403 out of [Unauthorized] has
/// zero blast radius on current flows — the first real producer is the operator
/// UI, which handles it. If a future endpoint starts 403ing, its caller owns the
/// [Forbidden] handling (an unhandled [Forbidden] surfaces as an error, never a
/// silent logout — the safer failure).
class Forbidden implements Exception {
  /// The action/endpoint that was denied, for telemetry + caller-side copy.
  final String? context;
  const Forbidden([this.context]);
  @override
  String toString() => 'Forbidden(context: $context)';
}

/// The gateway could not be REACHED — a connection/DNS/timeout-class transport
/// failure, as opposed to a server that answered (even with an error). The REST
/// impl maps the connection-class [DioException] into this at the boundary so
/// callers can distinguish "the network is down" from "the server said no"
/// **without depending on `dio`**. Used by offline-first session restore
/// (auth_controller) to decide when an optimistic restore is safe — a reachable
/// server that returned a non-auth error is NOT this, and must not be treated as
/// a benign network blip.
class NetworkUnavailable implements Exception {
  final Object? cause;
  const NetworkUnavailable([this.cause]);
  @override
  String toString() => 'NetworkUnavailable($cause)';
}

/// Thrown by [ChatRestApi.claimHandle] when the requested handle is already
/// taken (the gateway returns 409). The claim UI surfaces this inline ("that
/// handle is taken") rather than as a generic failure.
class HandleTaken implements Exception {
  const HandleTaken();
  @override
  String toString() => 'HandleTaken';
}

/// Thrown by [ChatRestApi.addPasskey] when the gateway rejects the credential as
/// already registered (409) — a given passkey can be linked once. The 409 means
/// the credential is registered to THIS or another account, so the settings UI
/// surfaces it as a neutral "already registered" (never asserting it's on the
/// current account) rather than a generic failure.
class PasskeyAlreadyRegistered implements Exception {
  const PasskeyAlreadyRegistered();
  @override
  String toString() => 'PasskeyAlreadyRegistered';
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
///
/// Auth-rejection contract for every authed method here: a terminal authN
/// failure throws [Unauthorized] (→ logout), a ban throws its [AccountSuspended]
/// refinement, and a plain authoriZation denial throws [Forbidden] (NOT terminal
/// — the session stays valid; the caller handles it locally, e.g. an operator
/// endpoint refreshing `/v1/me`). Callers that can provoke a 403 (moderator/
/// admin actions) should catch [Forbidden] rather than let it surface as a
/// generic error.
abstract interface class ChatRestApi {
  /// Begin passkey REGISTRATION (first-passkey-creates-account). Returns the
  /// WebAuthn creation options + a binding [PasskeyChallenge.state]. No prior
  /// session is required — the matching [finishPasskeyRegistration] mints the
  /// account.
  Future<PasskeyChallenge> startPasskeyRegistration();

  /// Complete registration: hand back the device's attestation [credentialJson]
  /// with the [state] from [startPasskeyRegistration]. Returns an
  /// [IdentityOutcome] from the gateway's single identity door —
  /// [Authenticated] for a straight-in mint, or [PendingHandle] when the gateway
  /// still needs a handle.
  Future<IdentityOutcome> finishPasskeyRegistration(
      String state, String credentialJson);

  /// Begin passkey AUTHENTICATION (usernameless / discoverable credential).
  /// Returns the WebAuthn request options + a binding [PasskeyChallenge.state].
  Future<PasskeyChallenge> startPasskeyAuthentication();

  /// Complete authentication: hand back the device's assertion [credentialJson]
  /// with the [state] from [startPasskeyAuthentication]. Returns the shared
  /// [IdentityOutcome] (verified signature → tokens).
  Future<IdentityOutcome> finishPasskeyAuthentication(
      String state, String credentialJson);

  /// Link a NEW passkey to the CURRENTLY authenticated account (add-to-existing,
  /// #1727). Unlike [finishPasskeyRegistration] — which MINTS a new account and
  /// then needs a handle claim — this runs against the live session's bearer: the
  /// gateway reads the caller's identity from the token and stores the fresh
  /// credential against THAT user (no new account, no claim). It reuses
  /// [startPasskeyRegistration] for the identity-agnostic creation challenge;
  /// only the finish differs.
  ///
  /// Returns the (unchanged) [AppUser] — the gateway echoes a BARE user view with
  /// NO tokens, because the caller is already authenticated. So this does NOT
  /// share the [IdentityOutcome] resolver the other finishes use (that resolver
  /// requires an access_token or provisioning_token and would throw on the bare
  /// body). Throws [PasskeyAlreadyRegistered] on a 409 (this credential is already
  /// registered — to this or another account) and [Unauthorized] on a terminal
  /// auth rejection.
  Future<AppUser> addPasskey(String state, String credentialJson);

  /// Complete provisioning for a new identity by claiming a [handle].
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

  /// Fetch the gateway's advertised capabilities from the public `GET
  /// /capabilities` endpoint (task #1896). Returns `null` when the endpoint is
  /// absent (404) or unreachable — the caller treats null as "unknown" and falls
  /// back to the transitional carriage allowlist, never flipping a known host
  /// off. Token-less: capability discovery must work before/without a session.
  Future<GatewayCapabilities?> getCapabilities();

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

  // --- operator / moderator actions (#33/#35, ModeratorUser-gated) ----------
  // Every method below is gated server-side by `require_moderator`; a caller
  // whose moderator flag is stale gets a plain 403 → [Forbidden] (authZ, NOT a
  // logout — the A3 taxonomy). Consumers should catch [Forbidden] and reconcile
  // the flag (refresh `/v1/me`) rather than treat it as a terminal auth failure.

  /// The moderator triage queue — unresolved reports, newest first
  /// (`GET /v1/reports?status=pending`). Throws [Forbidden] for a non-moderator.
  Future<List<PendingReport>> listPendingReports();

  /// Act on a report by taking the reported message DOWN (soft-delete + the
  /// forward-ULID retraction the island fans to clients). Idempotent; the island
  /// 404s an unknown report. Throws [Forbidden] for a non-moderator.
  Future<void> resolveReport(String reportId);

  /// Dismiss a report as not-actionable (no takedown). Idempotent. Throws
  /// [Forbidden] for a non-moderator.
  Future<void> dismissReport(String reportId);

  /// Ban [userId] from this island (per-island, reversible, forward-looking;
  /// active-disconnects their live sockets). Throws [Forbidden] for a
  /// non-moderator. The island 400s a self-ban / a ban of another moderator.
  Future<void> banUser(String userId);
}
