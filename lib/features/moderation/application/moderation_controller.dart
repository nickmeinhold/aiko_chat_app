/// Moderation application layer (UGC — Apple 1.2 / Google UGC, #7).
///
/// Owns the current account's block list and the block/unblock/report actions.
/// The block enforcement is BACKEND-first (the gateway hides blocked content on
/// read/fanout); this layer adds the INSTANT client-side effect — an optimistic
/// block updates [blockedUserIdsProvider] immediately, so already-cached messages
/// from the blocked user vanish on the next frame without waiting for a reload.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
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
  /// without a reload). Optimistic: the gateway call goes first, then state is
  /// updated so the UI hides the user instantly. On a sustained failure the
  /// future throws and state is unchanged (the caller surfaces the error).
  Future<void> block(String userId, {String? displayName}) async {
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

  /// Unblock [userId]. Optimistic removal after the gateway confirms.
  Future<void> unblock(String userId) async {
    await ref.read(restApiProvider).unblockUser(userId);
    final current = state.value ?? const <BlockedUser>[];
    state = AsyncData(current.where((b) => b.userId != userId).toList());
  }

  /// Report [messageId]. No local state — reports feed the gateway ops queue.
  Future<void> report(String messageId, ReportReason reason) =>
      ref.read(restApiProvider).reportMessage(messageId, reason);
}
