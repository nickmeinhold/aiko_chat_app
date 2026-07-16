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
import '../../../core/network/network_status.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../../moderation/application/moderation_controller.dart';
import '../data/chat_repository.dart';
import '../data/chat_rest_api.dart' show NetworkUnavailable;
import '../data/transport/chat_transport.dart' show ConnectionState;
import '../data/logging_chat_telemetry.dart';
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
/// One already-connected retry per fallback episode (Tesla, PR #75): when the
/// fallback arms while the socket is ALREADY live (REST failed but the WSS
/// never dropped), no future `connected` edge is coming, so we retry once —
/// latched, or a persistently-down REST would refetch-loop. Lives OUTSIDE
/// [channelsProvider] because an `invalidateSelf` rebuild would reset any
/// closure-local flag. Reset on every successful fetch.
class _ConnectedRetryLatch {
  bool armed = false;
}

final _connectedRetryLatchProvider =
    Provider<_ConnectedRetryLatch>((_) => _ConnectedRetryLatch());

final channelsProvider = FutureProvider.autoDispose<List<Channel>>((ref) async {
  final user = ref.watch(authControllerProvider).value;
  if (user == null) return const [];
  // Re-run on a connectivity RECOVERY edge so an offline fallback is not sticky:
  // a first-ever offline launch returns [] (→ "No channels yet"), and without
  // this the provider would never refetch when the network returns, stranding
  // the user (repo/socket never mount). Watching the distinct device-online bool
  // rebuilds this provider on the offline→online transition, which retries
  // listChannels() (Carnot, PR #72). `.distinct()` upstream keeps it to real
  // transitions, not every interface swap.
  ref.watch(deviceOnlineProvider);
  final cache = ref.watch(cacheProvider);
  try {
    // Server list is authoritative: fetch, then refresh the offline cache.
    final fresh = await ref.watch(restApiProvider).listChannels();
    await cache.saveChannels(fresh);
    ref.read(_connectedRetryLatchProvider).armed = false;
    return fresh;
  } on NetworkUnavailable {
    // Offline (or gateway unreachable): serve the cached list so a restored
    // user lands in cached chat instead of the "Could not load channels" screen
    // (task #19). Empty on a first-ever offline launch — never a raw error.
    //
    // GATEWAY-recovery refetch (Tesla, PR #72 residual + PR #75 round 2). Armed
    // ONLY while serving the fallback, so a healthy list never watches
    // connection state (no churn on routine socket blips). Two recovery shapes:
    //  - TRUE EDGE (non-connected → connected): the transport's own backoff
    //    reconnect is the recovery signal — refetch, unlatched.
    //  - ALREADY CONNECTED when the listener fires (`fireImmediately`, or a
    //    duplicate emission): no edge is ever coming, so retry ONCE via the
    //    latch — REST-still-down must not self-sustain a refetch loop. Beyond
    //    that single retry, a REST-down-while-socket-up outage self-heals on
    //    the next real edge, device-online edge, or screen re-entry (named
    //    tradeoff: no polling while the socket is healthy).
    ref.listen(connectionStateProvider, fireImmediately: true, (prev, next) {
      if (next.value != ConnectionState.connected) return;
      final prevVal = prev?.value;
      final isTrueEdge =
          prevVal != null && prevVal != ConnectionState.connected;
      if (!isTrueEdge) {
        final latch = ref.read(_connectedRetryLatchProvider);
        if (latch.armed) return;
        latch.armed = true;
      }
      ref.invalidateSelf();
    });
    return cache.readChannels();
  }
});

/// The reconcile engine, fully wired and connected. Construction requires the
/// authenticated [AppUser] (for optimistic "me" rendering) and the fixed
/// subscription set (from [channelsProvider]); it then wires streams once and
/// opens the socket (whose `connected` event drives subscribe→drain→history).
/// The reconcile engine's telemetry sink, injectable so tests (or a future
/// Crashlytics/Sentry sink) can override it. Defaults to the REAL
/// [LoggingChatTelemetry] — never the silent `_NoopTelemetry` — so the
/// must-be-seen signals are surfaced in the shipped app. Making this a first-
/// class dependency (rather than an inline arg) is what lets a unit test pin
/// that production wires a non-no-op sink (cage-match Carnot, PR #45).
final chatTelemetryProvider =
    Provider<ChatTelemetry>((ref) => const LoggingChatTelemetry());

final chatRepositoryProvider = FutureProvider.autoDispose<ChatRepository>((ref) async {
  final user = ref.watch(authControllerProvider).value;
  if (user == null) {
    // Not reachable from the UI (the router shows login when logged out), but
    // make the precondition loud rather than constructing a sessionless repo.
    throw StateError('chatRepository requires an authenticated user');
  }
  final channels = await ref.watch(channelsProvider.future);

  // Load the device sovereign signing key (sovereign-message-signing). Wired
  // here in the PRODUCTION provider — a nullable injectable silently no-ops if
  // the wiring is forgotten, the same DI trap the telemetry sink hit (PR #45),
  // so a provider-default test asserts a real key reaches the repo.
  final signingKey = await ref.watch(sovereignKeyStoreProvider).loadOrCreate();

  final repo = ChatRepository(
    cache: ref.watch(cacheProvider),
    transport: ref.watch(transportProvider),
    rest: ref.watch(restApiProvider),
    me: user,
    subscribedChannelIds: channels.map((c) => c.id).toList(),
    signingKey: signingKey,
    // Wire the REAL telemetry sink (via [chatTelemetryProvider]) so the
    // reconcile engine's must-be-seen events (orphan ack, reconnect failure, the
    // #16 sync fault) actually surface — without this the repo falls back to the
    // silent _NoopTelemetry default and every signal is swallowed in the shipped
    // app (cage-match Carnot HIGH, PR #45).
    telemetry: ref.watch(chatTelemetryProvider),
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
