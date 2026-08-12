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
import '../data/channel_read_store.dart';
import '../data/chat_repository.dart';
import '../data/chat_rest_api.dart' show NetworkUnavailable, Unauthorized;
import '../data/transport/chat_transport.dart' show ConnectionState;
import '../data/logging_chat_telemetry.dart';
import '../domain/channel.dart';
import '../domain/message.dart';

final _uuid = Uuid();

/// Convenience view of the logged-in user (null while logged out / loading).
final currentUserProvider = Provider<AppUser?>(
  (ref) => ref.watch(authControllerProvider).value,
);

/// `userId → current handle` for a channel's members, from the island roster
/// (`GET /v1/channels/{id}/members`). Lets a message's sender name render the
/// sender's handle AS IT IS NOW rather than the send-time label snapshot — the
/// display half of "identity is the key, the handle is a mutable label" (see
/// [senderDisplayName]). `autoDispose` so it is fetched when a channel is open
/// and released on switch; a fetch failure leaves the map absent and callers
/// fall back to the stored label (never a crash). My OWN rename shows instantly
/// without this — [currentUserProvider] is already current — this covers OTHER
/// members, refreshed on channel (re)open (a peer's mid-view rename lags until
/// the next fetch; acceptable for v1).
final channelRosterProvider =
    FutureProvider.autoDispose.family<Map<String, String>, String>(
  (ref, channelId) async {
    final members = await ref.watch(restApiProvider).listMembers(channelId);
    return {for (final m in members) m.userId: m.handle};
  },
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

/// Last SUCCESSFUL DM list, PER USER, so a transient [dmsProvider] failure can
/// degrade to STALE (keep the section, the subscriptions, and a live DM selection)
/// rather than to `[]` — which the self-heal cannot tell apart from "authoritatively
/// no DMs" and would eject the selection over (cage-match #132). Keyed by user id so
/// a fetch failure right after a user switch can never surface the PREVIOUS user's
/// DMs. Kept alive across [dmsProvider]'s autoDispose churn (a plain, keep-alive
/// Notifier); a closed record is safe state.
class _LastKnownDms extends Notifier<({String userId, List<Channel> dms})?> {
  @override
  ({String userId, List<Channel> dms})? build() => null;

  void remember(String userId, List<Channel> dms) =>
      state = (userId: userId, dms: dms);

  /// The last-known DMs for [userId], or `[]` when nothing is cached for THIS user
  /// (fresh, or the cache belongs to a prior session) — never another user's list.
  List<Channel> forUser(String userId) =>
      (state != null && state!.userId == userId) ? state!.dms : const [];

  /// Union a single just-opened DM (idempotent by id) into [userId]'s cache, so an
  /// authoritatively-minted DM survives even if the refetch meant to surface it
  /// fails soft (see [seedOpenedDm]). Replaces any cache belonging to a different
  /// user, matching [forUser]'s per-user gate.
  void union(String userId, Channel dm) {
    final current = forUser(userId);
    if (current.any((c) => c.id == dm.id)) return;
    state = (userId: userId, dms: [...current, dm]);
  }
}

final _lastKnownDmsProvider =
    NotifierProvider<_LastKnownDms, ({String userId, List<Channel> dms})?>(
        _LastKnownDms.new);

/// Seed a just-opened DM into the DM set so it is navigable + subscribed even if
/// the `GET /v1/dm` refetch that would normally surface it fails soft (cage-match
/// #132, Tesla HIGH): `openDm`'s returned channel is AUTHORITATIVE for that
/// conversation, so its existence must not ride on a fragile full-list refetch —
/// a failed refetch would otherwise return the stale last-known list WITHOUT the
/// new DM, dropping it from the sidebar and the repo's subscription set while a
/// call to that room is already in flight. Unions into last-known FIRST, then
/// invalidates so a successful refetch still overwrites with server truth. No-op
/// when logged out. Idempotent (the caller only seeds a DM not already listed).
void seedOpenedDm(WidgetRef ref, Channel dm) {
  final userId = ref.read(currentUserProvider)?.userId;
  if (userId == null) return;
  ref.read(_lastKnownDmsProvider.notifier).union(userId, dm);
  ref.invalidate(dmsProvider);
}

/// My DM channels (`GET /v1/dm`) — the SEPARATE source feeding the sidebar's DM
/// section (DMs are excluded from [channelsProvider] by island design) AND the
/// repo's subscription set (their ids are merged in [chatRepositoryProvider], so
/// the repo subscribes + fetches history for DMs exactly as for channels).
///
/// FAIL DIRECTIONS (both cage-match-hardened, #132):
///  * terminal auth ([Unauthorized] / its subclass [AccountSuspended]) RETHROWS —
///    a dead session must eject, never be masked as "no DMs" (Carnot HIGH);
///  * every OTHER failure (NetworkUnavailable, 5xx, a poisoned `fromDmJson` row)
///    degrades to the LAST-KNOWN list for this user, NOT `[]`. The repo
///    hard-depends on this future for its subscription set, so a transient error
///    must not reject and take channel chat down with it — and a stale-but-present
///    list keeps the section, the subscriptions, and a live DM selection intact
///    (an empty list is indistinguishable from authoritative-empty to the
///    self-heal, which would then eject the selection). First-ever fetch failure →
///    `[]` (nothing known yet). Watches the device-online edge so it refetches when
///    the network returns.
final dmsProvider = FutureProvider.autoDispose<List<Channel>>((ref) async {
  final user = ref.watch(authControllerProvider).value;
  if (user == null) return const [];
  ref.watch(deviceOnlineProvider);
  try {
    final dms = await ref.watch(restApiProvider).listDms();
    ref.read(_lastKnownDmsProvider.notifier).remember(user.userId, dms);
    return dms;
  } on Unauthorized {
    rethrow;
  } catch (_) {
    return ref.read(_lastKnownDmsProvider.notifier).forUser(user.userId);
  }
});

/// Channels ∪ DMs — every navigable conversation, as ONE list, so the active-
/// channel resolver ([ChatScreen.resolveActive]) and its self-heal treat a
/// selected DM id exactly like a channel id (a DM pick must resolve, not fall
/// back to the first channel). The sidebar still renders the two SOURCES in
/// separate sections; this is only the resolver's combined view.
final navigableChannelsProvider = Provider.autoDispose<List<Channel>>((ref) {
  final channels = ref.watch(channelsProvider).value ?? const <Channel>[];
  final dms = ref.watch(dmsProvider).value ?? const <Channel>[];
  return [...channels, ...dms];
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
  // DMs join the subscription set the same way channels do. Watching this future
  // means opening a brand-new DM (which invalidates [dmsProvider]) rebuilds the
  // repo through the SAME path a reconnect already uses — subscribe + history for
  // the new id — rather than an internal mutable-set path racing the backpressure
  // valve and reconnect epochs (approach A, #2798). Fails soft to [] offline.
  final dms = await ref.watch(dmsProvider.future);

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
    // A set literal (insertion-ordered) dedupes: DMs are excluded from
    // listChannels by island design, so channels ∩ dms is empty TODAY — but a
    // contract drift (a DM leaking into GET /v1/channels) must fail closed to a
    // single subscription, never a double-subscribe (cage-match Tesla).
    subscribedChannelIds: <String>{
      ...channels.map((c) => c.id),
      ...dms.map((d) => d.id),
    }.toList(),
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

/// The channel the user has picked in the app-bar switcher, or null to follow
/// the default (the first channel the gateway returns). Held DELIBERATELY
/// outside [channelsProvider]: that provider refetches on every reconnect and on
/// the offline→online edge (a fresh `listChannels()`), so a selection folded into
/// it would snap the user back to 'general' on a routine socket blip. Keeping the
/// pick here means it survives channel-list refreshes; the UI's resolver falls
/// back to the first channel if the picked id ever leaves the list (a removed or
/// renamed-away channel), so a stale pick self-heals rather than dead-ends.
///
/// EXPLICITLY `.autoDispose` (the file's convention — every sibling provider spells
/// it) so it shares the chat surface's lifecycle: only [ChatScreen] watches it, and
/// that unmounts on logout (router → login), tearing it down and resetting the pick
/// to null. A fresh login therefore starts on the default channel — no cross-session
/// selection leak. A plain (keep-alive) `NotifierProvider` would survive logout in
/// the same `ProviderContainer` and leak the previous user's pick into the next
/// session (cage-match #106, Carnot + Tesla). The base class is a plain [Notifier]:
/// Riverpod 3 removed `AutoDisposeNotifier` (folded into `Notifier`), so disposal
/// rides on the provider's `.autoDispose`, not the notifier type.
final selectedChannelIdProvider =
    NotifierProvider.autoDispose<SelectedChannelId, String?>(SelectedChannelId.new);

class SelectedChannelId extends Notifier<String?> {
  @override
  String? build() => null;

  /// Pick a channel by id. Idempotent.
  void select(String channelId) => state = channelId;

  /// Drop the pick (→ follow the default). Called when the selected channel
  /// leaves the list, so the Notifier and the UI agree rather than the resolver
  /// papering over a stale id that would re-snap the user if the channel returns.
  void clear() => state = null;
}

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
    StreamProvider.autoDispose.family<List<Message>, String>(
        (ref, channelId) => _watchVisibleMessages(ref, channelId));

/// The blocked-filtered, cache-backed message stream for a channel — the shared
/// body of [messagesProvider] and [_unreadMessagesProvider]. Kept as a function
/// (not a shared provider) precisely so the two providers back onto DISTINCT
/// drift streams; see [_unreadMessagesProvider] for why that separation matters.
Stream<List<Message>> _watchVisibleMessages(Ref ref, String channelId) async* {
  final repo = await ref.watch(chatRepositoryProvider.future);
  final blocked = ref.watch(blockedUserIdsProvider);
  yield* repo.watchChannel(channelId).map((msgs) => blocked.isEmpty
      ? msgs
      : msgs.where((m) => !blocked.contains(m.sender.userId)).toList());
}

// --- cross-channel message search (#8, grep tier) --------------------------

/// The current search query. The search screen writes it (debounced) and
/// [messageSearchResultsProvider] reacts. `.autoDispose` so closing the search
/// surface drops both the query and its results. A [Notifier] (not the legacy
/// `StateProvider`) to match the house style ([SelectedChannelId] et al.).
final messageSearchQueryProvider =
    NotifierProvider.autoDispose<MessageSearchQuery, String>(
        MessageSearchQuery.new);

class MessageSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  /// Set the query (already trimmed by the caller). Idempotent.
  void set(String query) => state = query;
}

/// Cross-channel grep results for [messageSearchQueryProvider] — blocked-sender
/// filtered so search obeys the SAME visibility predicate as the message list
/// (concept_visibility_consistency). Retraction is already excluded one layer
/// down (retracted rows are hard-deleted from the cache — see
/// [DriftCache.searchMessages]), so only the block filter is layered here,
/// exactly as [messagesProvider] layers it over the visibility-agnostic
/// [ChatRepository.watchChannel]. An empty/whitespace query short-circuits to an
/// empty list with no scan.
final messageSearchResultsProvider =
    FutureProvider.autoDispose<List<Message>>((ref) async {
  final query = ref.watch(messageSearchQueryProvider).trim();
  if (query.isEmpty) return const [];
  final repo = await ref.watch(chatRepositoryProvider.future);
  final blocked = ref.watch(blockedUserIdsProvider);
  final hits = await repo.searchMessages(query);
  if (blocked.isEmpty) return hits;
  return hits.where((m) => !blocked.contains(m.sender.userId)).toList();
});

// --- per-channel unread (channel-switcher badges) --------------------------

/// The durable per-channel last-read watermark store, over the app-wide
/// [SharedPreferences]. The lightest durable home for read-state (no drift
/// migration on the shared cache); see [ChannelReadStore].
final channelReadStoreProvider = Provider<ChannelReadStore>(
  (ref) => ChannelReadStore(ref.watch(sharedPreferencesProvider)),
);

/// The in-memory, reactive `channelId → newest-read ULID` map — the UI watches
/// this so a switcher badge recomputes the instant a watermark advances, while
/// the [ChannelReadStore] keeps it durable across restarts.
///
/// `.autoDispose`, sharing the chat surface's lifecycle exactly like
/// [selectedChannelIdProvider]: it is torn down on logout (the switcher unmounts)
/// and rebuilt fresh on the next login, which reloads the NEW user's persisted
/// read-state — so a user switch never leaks the previous user's marks.
///
/// The user id is read NON-reactively (`ref.read`, not `ref.watch`): the switcher
/// only builds once a user is authenticated and their channels are loaded, so the
/// id is stable for the surface's life. Watching [currentUserProvider] here would
/// make this provider self-invalidate when a *descendant* (the message list)
/// flushes that (login-dirty) provider mid-build — Riverpod surfaces that as
/// "setState during build".
final channelReadMarksProvider =
    NotifierProvider.autoDispose<ChannelReadMarks, Map<String, String>>(
        ChannelReadMarks.new);

class ChannelReadMarks extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    final userId = ref.read(currentUserProvider)?.userId;
    if (userId == null) return const {};
    return ref.read(channelReadStoreProvider).readAll(userId);
  }

  /// Advance [channelId]'s watermark to [ulid] (the newest message the user has
  /// now seen in that channel). **Monotonic** — a ulid not strictly greater than
  /// the stored one is ignored, so an out-of-order or stale mark can never rewind
  /// read-state and resurrect a badge. Persists through the store.
  void markRead(String channelId, String ulid) {
    if (!ChannelReadStore.isSortableWatermark(ulid)) return; // reject junk id
    final userId = ref.read(currentUserProvider)?.userId; // non-reactive read
    if (userId == null) return;
    final current = state[channelId];
    if (current != null && ulid.compareTo(current) <= 0) return;
    state = {...state, channelId: ulid};
    ref.read(channelReadStoreProvider).setWatermark(userId, channelId, ulid);
  }

  /// Establish the FIRST-SIGHT baseline for a never-observed channel: treat every
  /// message already in the cache as read, so a channel the user has never opened
  /// doesn't flood the switcher with `99+` from pre-existing history — unread means
  /// "since first sight," not "every fossil in the cache." Only writes when the
  /// channel has no watermark yet (idempotent via the presence guard), so it never
  /// clobbers a real read position advanced by [markRead]. [newestUlid] is the
  /// newest server ULID currently cached, or `''` when the channel is empty at
  /// first sight (an empty-string floor below every ULID, so later arrivals still
  /// count — and it persists the "observed" fact so a restart doesn't re-baseline
  /// over messages that landed while away).
  void baseline(String channelId, String newestUlid) {
    if (!ChannelReadStore.isSortableWatermark(newestUlid)) return; // reject junk
    if (state.containsKey(channelId)) return; // already observed / has a mark
    final userId = ref.read(currentUserProvider)?.userId;
    if (userId == null) return;
    state = {...state, channelId: newestUlid};
    ref.read(channelReadStoreProvider).setWatermark(userId, channelId, newestUlid);
  }
}

/// A per-channel message stream used ONLY for unread accounting — deliberately
/// SEPARATE from [messagesProvider] even though both stream the same cache slice.
///
/// The channel switcher lives in the AppBar (an ANCESTOR of the message list) and
/// watches unread for the non-active channels. If it and [MessageList] shared one
/// `messagesProvider` family entry, the list mounting for a channel the switcher
/// is watching would flush that shared StreamProvider mid-build and synchronously
/// notify the switcher — Riverpod surfaces that as "setState during build". This
/// happens on an active-channel switch (the old non-active channel becomes
/// active). Backing the two onto distinct drift streams removes the shared node,
/// so a list mount never rebuilds the switcher mid-build. (The extra stream is one
/// cheap cache query per visible channel — the repo already subscribes to all.)
final _unreadMessagesProvider =
    StreamProvider.autoDispose.family<List<Message>, String>(
        (ref, channelId) => _watchVisibleMessages(ref, channelId));

/// The unread count for [channelId]: cached messages strictly newer (by server
/// ULID) than the channel's last-read watermark, EXCLUDING the current user's
/// own messages (you don't have unread from yourself) and any message not yet
/// carrying a server ULID (an un-acked optimistic send — always your own).
///
/// The per-channel history-sync fence, made reactive — non-null (including the
/// `''` empty-channel sentinel) means history has SETTLED for the channel, so a
/// first-sight baseline may be taken against a complete picture. Watching this
/// (rather than trusting the message stream's first emission) is what closes the
/// baseline-during-load window: a cache-backed stream legitimately emits an empty
/// or partial list BEFORE the reconcile engine's history sync upserts a channel's
/// messages, and baselining then (to `''`) would let every fossil sort above the
/// floor and flood the switcher once history lands (cage-match #109 closure,
/// Carnot + Tesla). A DISTINCT stream from the message/display providers, same
/// isolation rationale as [_unreadMessagesProvider].
final _historyFenceProvider =
    StreamProvider.autoDispose.family<String?, String>((ref, channelId) =>
        ref.watch(cacheProvider).watchHistoryContiguousThrough(channelId));

/// On FIRST SIGHT of a channel (no watermark yet) it reports 0 and, ONCE HISTORY
/// HAS SETTLED for the channel, lazily baselines it to the newest cached message
/// so pre-existing history never floods the switcher ("since first sight," not
/// "every fossil"). Thereafter unread is messages strictly newer than the
/// baseline/last-read mark. The active channel is advanced on view (see
/// `MessageList`), so it settles to 0; the switcher additionally never badges the
/// active channel.
///
/// Reads the same blocked-filtered slice the UI shows (so unread matches what's
/// visible) — but via [_unreadMessagesProvider], a stream DISTINCT from
/// [messagesProvider], so the switcher and the message list never share one
/// StreamProvider family entry.
final channelUnreadCountProvider =
    Provider.autoDispose.family<int, String>((ref, channelId) {
  final messages =
      ref.watch(_unreadMessagesProvider(channelId)).value ?? const <Message>[];
  final marks = ref.watch(channelReadMarksProvider);
  // Non-reactive: watching currentUserProvider here would self-invalidate this
  // provider when the message list flushes that (login-dirty) provider mid-build.
  // The unread chain is autoDispose + rebuilt per session, so a read suffices.
  final myUserId = ref.read(currentUserProvider)?.userId;
  final watermark = marks[channelId];

  if (watermark == null) {
    // Never observed → report 0 (NEVER flood) until history has SETTLED for this
    // channel, then baseline to THE FENCE VALUE ITSELF — the exact ULID
    // `watchHistoryContiguousThrough` yields (`''` for an empty channel, a real
    // ULID otherwise). The baseline is NEVER computed from the message stream: the
    // fence is the single authoritative "synced through" mark, and deriving the
    // baseline from `messages` raced both live arrivals (a live msg > fence that
    // arrived before settle got marked read) and stream-settle timing (an empty
    // stream mis-baselined to ''). Baseline = fence dissolves both by construction;
    // `messages` is used ONLY to count unread (ULID > watermark) below. Deferred to
    // a microtask so we never mutate provider state during a build; the notifier is
    // captured so it stays valid if this entry disposes.
    final fence = ref.watch(_historyFenceProvider(channelId)).value;
    if (fence != null) {
      final notifier = ref.read(channelReadMarksProvider.notifier);
      Future.microtask(() {
        try {
          notifier.baseline(channelId, fence);
        } catch (_) {
          // The chain disposed (logout) before the microtask ran — a missed
          // baseline is benign; it re-establishes on the next session.
        }
      });
    }
    return 0;
  }

  return messages.where((m) {
    final id = m.id;
    if (id == null) return false; // un-acked own send — never unread
    if (m.sender.userId == myUserId) return false; // my own message
    return id.compareTo(watermark) > 0;
  }).length;
});
