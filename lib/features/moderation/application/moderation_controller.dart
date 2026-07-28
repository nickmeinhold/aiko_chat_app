/// Moderation application layer (UGC — Apple 1.2 / Google UGC, #7).
///
/// Owns the current account's block list and the block/unblock/report actions.
/// The block enforcement is BACKEND-first (the gateway hides blocked content on
/// read/fanout); this layer adds the client-side effect — once the gateway
/// confirms a block, [blockedUserIdsProvider] updates and already-cached messages
/// from the blocked user vanish on the next frame without waiting for a reload.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_rest_api.dart'
    show AccountSuspended, ChatRestApi, Forbidden;
import '../domain/moderation_models.dart';

/// The account's blocked users (most recent first). Auth-gated via [build] (which
/// watches [authControllerProvider]) so a logout re-runs build → empty list and a
/// re-login reloads fresh: a block list is per-account and must never bleed across
/// sessions. Mirrors [AuthController]'s plain-AsyncNotifier shape.
final blockedUsersProvider =
    AsyncNotifierProvider<BlockedUsersController, List<BlockedUser>>(
      BlockedUsersController.new,
    );

/// The set of blocked user ids, derived from [blockedUsersProvider]. Empty while
/// loading or errored (fail-open on the CLIENT hide — the gateway is the real
/// boundary, so a transient list-load failure must not crash the message list;
/// it just means already-cached blocked rows linger until the next successful
/// load, while the server still refuses to deliver new ones).
final blockedUserIdsProvider = Provider<Set<String>>((ref) {
  return ref
      .watch(blockedUsersProvider)
      .maybeWhen(
        data: (list) => {for (final b in list) b.userId},
        orElse: () => const <String>{},
      );
});

class BlockedUsersController extends AsyncNotifier<List<BlockedUser>> {
  @override
  Future<List<BlockedUser>> build() async {
    final user = ref.watch(authControllerProvider).value;
    if (user == null) return const [];
    return ref.watch(restApiProvider).listBlocks();
  }

  /// Block [userId] (optionally with a known [displayName] so the list renders
  /// without a reload). REST-confirmed THEN local state: the gateway call goes
  /// first, then state is updated so the UI hides the user. On a sustained failure
  /// the future throws and state is unchanged (the caller surfaces the error).
  ///
  /// LOAD-RACE GUARD (cage-match Carnot HIGH): `messagesProvider` lazily kicks off
  /// build()'s listBlocks GET; a block fired before that GET settles would set
  /// state, then be CLOBBERED when the stale in-flight build publishes its
  /// pre-block snapshot — the block silently reappearing. Awaiting `future` first
  /// serializes the mutation AFTER the load completes (instant once loaded), so
  /// build can no longer overwrite it. The load's own error is swallowed here (a
  /// failed initial GET shouldn't block the user from blocking — we proceed from
  /// an empty/last-good state).
  Future<void> block(String userId, {String? displayName}) async {
    try {
      await future;
    } catch (_) {/* initial load failed; proceed from current state */}
    await ref.read(restApiProvider).blockUser(userId);
    final current = state.value ?? const <BlockedUser>[];
    if (current.any((b) => b.userId == userId)) return; // already present
    final entry = BlockedUser(
      userId: userId,
      displayName: displayName ?? 'Blocked user',
      createdAt: DateTime.now().toUtc(),
    );
    state = AsyncData([entry, ...current]);
  }

  /// Unblock [userId]. REST-confirmed then local removal. Same load-race guard as
  /// [block] — settle the initial load before mutating so a concurrent build()
  /// can't clobber the removal.
  Future<void> unblock(String userId) async {
    try {
      await future;
    } catch (_) {/* initial load failed; proceed from current state */}
    await ref.read(restApiProvider).unblockUser(userId);
    final current = state.value ?? const <BlockedUser>[];
    state = AsyncData(current.where((b) => b.userId != userId).toList());
  }

  /// Report [messageId]. No local state — reports feed the gateway ops queue.
  Future<void> report(String messageId, ReportReason reason) =>
      ref.read(restApiProvider).reportMessage(messageId, reason);
}

/// The moderator triage queue (#33/#35). Auth- AND moderator-gated via [build]:
/// a non-moderator (or logged-out) session yields an empty list and NEVER calls
/// the `ModeratorUser`-gated endpoint — so a plain user can't provoke a
/// guaranteed 403. Mirrors [BlockedUsersController]'s REST-confirmed-then-local
/// shape + load-race guard; adds [Forbidden] reconciliation (a mid-session
/// moderator revocation refreshes `/me`, which flips [isModeratorProvider] and
/// gates the operator UI off — WITHOUT logging the user out, per A3).
final pendingReportsProvider =
    AsyncNotifierProvider<PendingReportsController, List<PendingReport>>(
      PendingReportsController.new,
    );

class PendingReportsController extends AsyncNotifier<List<PendingReport>> {
  @override
  Future<List<PendingReport>> build() async {
    final user = ref.watch(authControllerProvider).value;
    if (user == null || !user.isModerator) return const [];
    try {
      return await ref.watch(restApiProvider).listPendingReports();
    } on Forbidden {
      // Flag revoked → schedule a /me refresh to flip isModeratorProvider off.
      _scheduleAuthAction((a) => a.refreshUser());
      // RETHROW — do NOT publish success-empty. An empty AsyncData is the wrong
      // carrier for "you were denied": until (and unless) the /me refresh lands
      // and flips the flag, a returned `[]` would paint "the queue is clear" with
      // the Reports tile still lit — a demotion masquerading as an empty queue,
      // and a permanent lie if the refresh fails transiently (cage-match Tesla +
      // Carnot round 2). Surfacing the error keeps the screen honest ("couldn't
      // load") until the flag-flip gates it off.
      rethrow;
    } on AccountSuspended {
      // The operator's own account was BANNED — the FIRST load 403s with the ban
      // body, not just an action (seal both doors on the load path too — Tesla
      // round 3). The load response IS the terminal ban signal, so settle
      // suspension DIRECTLY (no second /me round-trip — Tesla round 4); rethrow so
      // the queue is an honest error, not a false-empty, until the router leaves.
      _scheduleAuthAction((a) => a.settleBan());
      rethrow;
    }
  }

  /// Run an [AuthController] reconcile action OUTSIDE this build (it mutates the
  /// watched authControllerProvider — awaiting it in-build orphans build's own
  /// future). Guarded on `ref.mounted`: if the screen is navigated away before the
  /// microtask runs, the notifier is disposed and `ref.read` would throw / drop
  /// the reconcile (cage-match Tesla round 3).
  void _scheduleAuthAction(Future<void> Function(AuthController) action) {
    Future.microtask(() {
      if (!ref.mounted) return;
      action(ref.read(authControllerProvider.notifier));
    });
  }

  /// Take the reported message down (soft-delete + the island's forward
  /// retraction) and drop the report from the queue. REST-confirmed then local.
  Future<void> resolve(String reportId) =>
      _actThenRemove(reportId, () => _rest.resolveReport(reportId));

  /// Dismiss the report as not-actionable and drop it from the queue.
  Future<void> dismiss(String reportId) =>
      _actThenRemove(reportId, () => _rest.dismissReport(reportId));

  /// Ban [userId] from the island. Does NOT remove any report tile — a ban is a
  /// distinct action from resolving the triggering report (the island keeps the
  /// report pending); the moderator still resolves/dismisses it explicitly.
  Future<void> ban(String userId) => _reconcileAuthThenRethrow(() => _rest.banUser(userId));

  ChatRestApi get _rest => ref.read(restApiProvider);

  /// Run a report action, then remove that report from local state on success.
  /// Same load-race guard as [BlockedUsersController.block]: settle the initial
  /// load before mutating so a still-in-flight build() can't clobber the removal
  /// with its pre-action snapshot.
  Future<void> _actThenRemove(String reportId, Future<void> Function() act) =>
      _reconcileAuthThenRethrow(() async {
        try {
          await future;
        } catch (_) {/* initial load failed; proceed from current state */}
        await act();
        final current = state.value ?? const <PendingReport>[];
        state = AsyncData(
          current.where((r) => r.reportId != reportId).toList(),
        );
      });

  /// Run an operator action and reconcile the A3 auth taxonomy on BOTH doors of
  /// the 403 it can produce (seal both, not one — cage-match Tesla):
  ///   - [Forbidden] → the moderator flag was revoked; `refreshUser()` re-reads
  ///     `/me`, flips [isModeratorProvider] false, the UI gates off. NOT a logout.
  ///   - [AccountSuspended] → the operator's own account was BANNED mid-session;
  ///     `refreshUser()`'s `/me` re-hits the ban and settles through the single
  ///     suspended door → `/suspended` (NOT a generic "action failed", and NOT a
  ///     logout loop).
  /// Either way we rethrow so the caller can surface/suppress copy; the reconcile
  /// runs first so the router/gate already reflect the settled world. A plain
  /// [Unauthorized] (terminal authN) is left to propagate — the REST interceptor's
  /// onUnauthenticated path is its reaper.
  Future<void> _reconcileAuthThenRethrow(
      Future<void> Function() action) async {
    try {
      await action();
    } on Forbidden {
      // Flag revoked — re-read /me to flip isModeratorProvider off.
      await ref.read(authControllerProvider.notifier).refreshUser();
      rethrow;
    } on AccountSuspended {
      // The account is banned — the action's response IS the terminal signal, so
      // settle suspension DIRECTLY (→ /suspended) rather than re-confirming via a
      // second /me that could fail transiently and strand the banned moderator
      // (cage-match Carnot + Tesla round 4).
      await ref.read(authControllerProvider.notifier).settleBan();
      rethrow;
    }
  }
}
