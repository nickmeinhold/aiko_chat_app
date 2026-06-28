/// The chat-layer providers — everything downstream of an authenticated user.
///
/// The repository is the one component that calls [ChatRepository.start] (wires
/// the transport streams ONCE — it throws on a second call, chat_repository:87)
/// and kicks the realtime connect. It is rebuilt when auth changes: a new login
/// builds a fresh repo (fresh `start()`), and the previous one is disposed via
/// `ref.onDispose` so its stream subscriptions never leak across sessions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../../moderation/application/moderation_controller.dart';
import '../data/chat_repository.dart';
import '../domain/channel.dart';
import '../domain/message.dart';

final _uuid = Uuid();

/// Convenience view of the logged-in user (null while logged out / loading).
final currentUserProvider = Provider<AppUser?>(
  (ref) => ref.watch(authControllerProvider).value,
);

/// The channels the user can see. Gated on auth: empty when logged out so the
/// repository (which derives its subscription set from this) never tries to
/// subscribe with no session.
///
/// `autoDispose`: while logged out (login screen) nothing watches the chat
/// providers, so they tear down — `repo.dispose()` cancels the transport subs —
/// and a re-login builds them FRESH rather than flushing stale cross-logout
/// state (which crashed with "setState during build") and never leaves two
/// repos racing on the one transport singleton (Carnot C2).
final channelsProvider = FutureProvider.autoDispose<List<Channel>>((ref) async {
  final user = ref.watch(authControllerProvider).value;
  if (user == null) return const [];
  return ref.watch(restApiProvider).listChannels();
});

/// The reconcile engine, fully wired and connected. Construction requires the
/// authenticated [AppUser] (for optimistic "me" rendering) and the fixed
/// subscription set (from [channelsProvider]); it then wires streams once and
/// opens the socket (whose `connected` event drives subscribe→drain→history).
final chatRepositoryProvider = FutureProvider.autoDispose<ChatRepository>((ref) async {
  final user = ref.watch(authControllerProvider).value;
  if (user == null) {
    // Not reachable from the UI (the router shows login when logged out), but
    // make the precondition loud rather than constructing a sessionless repo.
    throw StateError('chatRepository requires an authenticated user');
  }
  final channels = await ref.watch(channelsProvider.future);

  final repo = ChatRepository(
    cache: ref.watch(cacheProvider),
    transport: ref.watch(transportProvider),
    rest: ref.watch(restApiProvider),
    me: user,
    subscribedChannelIds: channels.map((c) => c.id).toList(),
    newTempId: () => _uuid.v4(),
  );
  ref.onDispose(repo.dispose); // tear down on logout/rebuild — no leaked subs

  repo.start(); // wire transport streams ONCE (B-live)
  await ref.watch(transportProvider).connect(); // `connected` → choreography
  return repo;
});

/// The reactive, ordered message list for a channel. Awaits the repository, then
/// forwards its cache-backed stream — each [MessageTile] watches the narrowest
/// slice (this family entry) rather than the whole repo.
/// CLIENT-SIDE BLOCK HIDE (#7): messages from a blocked user are filtered out
/// here, the instant complement to the gateway's server-side hide. The gateway is
/// the real boundary (it never delivers/returns a blocked user's NEW content), but
/// already-cached rows from before the block would otherwise linger until the next
/// reconnect; this filter removes them on the next frame. Watching
/// [blockedUserIdsProvider] means a fresh block rebuilds this provider and
/// re-filters immediately. A null `sender.userId` (external actor) is never in the
/// set, so bot/LLM messages are always kept.
final messagesProvider =
    StreamProvider.autoDispose.family<List<Message>, String>((ref, channelId) async* {
  final repo = await ref.watch(chatRepositoryProvider.future);
  final blocked = ref.watch(blockedUserIdsProvider);
  yield* repo.watchChannel(channelId).map((msgs) => blocked.isEmpty
      ? msgs
      : msgs.where((m) => !blocked.contains(m.sender.userId)).toList());
});
