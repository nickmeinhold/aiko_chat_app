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
import 'mute_controller.dart';

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
final channelRosterProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>((ref, channelId) async {
      final members = await ref.watch(restApiProvider).listMembers(channelId);
      return {for (final m in members) m.userId: m.handle};
    });

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

final _connectedRetryLatchProvider = Provider<_ConnectedRetryLatch>(
  (_) => _ConnectedRetryLatch(),
);

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
  ///
  /// Returns whether the cache actually CHANGED, so [seedOpenedDm] can skip a
  /// refetch that has nothing to surface (cage-match #133, Carnot + Tesla).
  bool union(String userId, Channel dm) {
    final current = forUser(userId);
    if (state?.userId == userId && current.any((c) => c.id == dm.id)) {
      return false;
    }
    state = (userId: userId, dms: [...current, dm]);
    return true;
  }
}

final _lastKnownDmsProvider =
    NotifierProvider<_LastKnownDms, ({String userId, List<Channel> dms})?>(
      _LastKnownDms.new,
    );

/// DMs the island has AUTHORITATIVELY minted (`POST /v1/dm` returned them),
/// held visible until a DM-list fetch that started AFTER the mint has had its
/// say — then retired in favour of fromIsland truth.
///
/// Distinct from [_LastKnownDms] on purpose, and the distinction is the fix for
/// a bug cluster rather than a taste call. Last-known is a *fallback*: it only
/// surfaces when a fetch FAILS. A just-opened DM is not a fallback — it is a
/// fact, and it has to be visible on the SUCCESS path too, because that is the
/// path the user is standing on when they select it. Conflating the two meant
/// (a) `navigableChannelsProvider` could not see a DM the user had just opened
/// until a refetch confirmed it, so `resolveActive` fell through to the first
/// CHANNEL and the composer would have sent there (cage-match #133, Tesla), and
/// (b) any successful fetch — including one already in flight before the mint —
/// erased the DM entirely.
///
/// Retirement is watermarked, not immediate: a fetch retires only the seeds
/// taken BEFORE it started. This is where the read-your-write assumption on the
/// island's find-or-create lives, stated instead of implied — we trust a fetch
/// that began after our write to reflect it, and we never trust one that began
/// before (task #2947 covers verifying the island half).
class _SeededDms
    extends Notifier<({String userId, List<({Channel dm, int gen})> items})?> {
  @override
  ({String userId, List<({Channel dm, int gen})> items})? build() => null;

  // NOT cleared on logout, deliberately (cage-match #133, Carnot raised it; the
  // clear was written, regressed two logout tests, and was withdrawn rather than
  // worked around). Two reasons, in order of importance:
  //
  //  1. It is not a leak worth a mechanism. The per-user gate on [forUser] and
  //     [add] already makes a seed unreadable by a DIFFERENT user. What survives
  //     is a same-user re-login seeing a DM that the island genuinely minted for
  //     them — a real conversation, shown slightly before the first fetch
  //     confirms it, and retired by that fetch (its generation is below any
  //     newly-taken ticket). Showing a real DM early is not the failure the
  //     clear would be defending against.
  //  2. The clear cannot be written here safely. Mutating this notifier from a
  //     `ref.listen` on the auth state fires inside a dependent's build and trips
  //     Riverpod's notification assertion — the same "setState during build"
  //     trap [channelReadMarksProvider] documents and reads non-reactively to
  //     avoid.

  /// Monotonic ticket taken by every DM-list fetch WHEN IT STARTS — the
  /// watermark separating "this fetch could have observed my write" from "this
  /// fetch was already in the air when I wrote", which is the only question
  /// that tells a legitimate deletion apart from a stale or lagging read.
  ///
  /// Deliberately a plain field, NOT Notifier state: the ticket is taken during
  /// [dmsProvider]'s synchronous build phase, and mutating provider state there
  /// trips Riverpod's `_debugCurrentlyBuildingElement` assertion. Nothing should
  /// rebuild when a fetch starts, so reactive state would be wrong anyway.
  int _gen = 0;

  /// Take the next ticket. Called at fetch START, never after the await.
  int takeFetchGen() => ++_gen;

  bool isLatestFetch(int gen) => _gen == gen;

  /// The ticket a seed minted *now* carries: strictly below any fetch that has
  /// not yet started, so a fetch already in the air cannot retire it.
  int get currentGen => _gen;

  /// Record [dm] as minted at [gen]. Returns whether anything changed, so a
  /// re-seed of a DM already held costs no refetch (cage-match #133).
  bool add(String userId, Channel dm, int gen) {
    final current = (state != null && state!.userId == userId)
        ? state!.items
        : const <({Channel dm, int gen})>[];
    if (current.any((e) => e.dm.id == dm.id)) return false;
    state = (userId: userId, items: [...current, (dm: dm, gen: gen)]);
    return true;
  }

  List<Channel> forUser(String userId) =>
      (state != null && state!.userId == userId)
      ? state!.items.map((e) => e.dm).toList()
      : const [];

  /// Retire the seeds [fromIsland] has CONFIRMED — the ones it now lists itself.
  ///
  /// Retirement is on confirmation, not on opportunity. The earlier rule retired
  /// any seed a fetch *could* have observed (one ticketed after the mint), which
  /// quietly encoded a guarantee we have never checked: that a `GET /v1/dm`
  /// issued after `POST /v1/dm` returns must already list it. If the island lags
  /// that write by even one request, the retiring fetch omits the DM, the seed
  /// goes, `navigableChannelsProvider` drops it and the self-heal ejects the user
  /// from the conversation they just opened — the exact failure this whole seed
  /// mechanism exists to prevent, reached through eventual consistency instead of
  /// a stale refresh (cage-match #133, Carnot HIGH). Waiting for the fromIsland to
  /// name the DM needs no assumption at all.
  ///
  /// Residual, named rather than mechanised: a DM the island stops listing
  /// WITHOUT ever having listed it stays in the sidebar for the rest of the
  /// session. That costs a visible row for a conversation the user really did
  /// create; the alternative costs them the conversation. `_gen` still governs
  /// which fetch may PUBLISH — that guard is about ordering, which we observe
  /// directly, not about an island promise.
  void retireConfirmed(String userId, List<Channel> fromIsland) {
    if (state == null || state!.userId != userId) return;
    final confirmed = fromIsland.map((c) => c.id).toSet();
    final kept = state!.items
        .where((e) => !confirmed.contains(e.dm.id))
        .toList();
    if (kept.length == state!.items.length) return;
    state = kept.isEmpty ? null : (userId: userId, items: kept);
  }

  void clear() => state = null;
}

final _seededDmsProvider =
    NotifierProvider<
      _SeededDms,
      ({String userId, List<({Channel dm, int gen})> items})?
    >(_SeededDms.new);

/// [fromIsland] plus any still-unretired seed it does not already contain, in a
/// stable order (island truth first). Ids dedupe, so a confirmed seed appears
/// exactly once.
List<Channel> _withSeeds(List<Channel> fromIsland, List<Channel> seeds) {
  final ids = fromIsland.map((c) => c.id).toSet();
  final extra = seeds.where((s) => !ids.contains(s.id));
  return extra.isEmpty ? fromIsland : [...fromIsland, ...extra];
}

/// Seed a just-opened DM into the DM set so it is navigable + subscribed even if
/// the `GET /v1/dm` refetch that would normally surface it fails soft (cage-match
/// #132, Tesla HIGH): `openDm`'s returned channel is AUTHORITATIVE for that
/// conversation, so its existence must not ride on a fragile full-list refetch —
/// a failed refetch would otherwise return the stale last-known list WITHOUT the
/// new DM, dropping it from the sidebar and the repo's subscription set while a
/// call to that room is already in flight. Unions into last-known FIRST, then
/// invalidates so a successful refetch still overwrites with fromIsland truth. No-op
/// when logged out.
///
/// Idempotent in the STRONG sense: a seed that changes nothing also invalidates
/// nothing. The caller only seeds a DM absent from [dmsProvider]'s current value,
/// but that value reads `null → []` while the provider is mid-refresh, so two
/// racing taps — or one tap during a refresh — both see "not listed" and both
/// seed. Union-only idempotency stopped the duplicate ROW but not the duplicate
/// INVALIDATE, and each invalidate rebuilds the repository
/// (dispose → reconnect → resubscribe-all) for a conversation that was already
/// there. Gating the refetch on a real cache change removes the race rather than
/// asking every caller to guard it (cage-match #133, Carnot + Tesla).
void seedOpenedDm(WidgetRef ref, Channel dm) {
  final userId = ref.read(currentUserProvider)?.userId;
  if (userId == null) return;
  // Stamp the seed with the CURRENT fetch generation: any fetch that starts
  // after this (including the one the invalidate below kicks off) carries a
  // higher ticket and may retire it; anything already in the air may not.
  final seeds = ref.read(_seededDmsProvider.notifier);
  if (!seeds.add(userId, dm, seeds.currentGen)) return;
  // Also union into last-known so the fail-soft path keeps the DM even after
  // the seed is legitimately retired.
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
  // Take the ticket BEFORE the await — the watermark has to record when this
  // fetch started, not when it finished.
  final seeds = ref.read(_seededDmsProvider.notifier);
  final gen = seeds.takeFetchGen();
  try {
    final dms = await ref.watch(restApiProvider).listDms();
    // A superseded run's RETURN value is discarded by Riverpod, but its SIDE
    // EFFECTS are not — a Dart Future cannot be cancelled, so an older fetch
    // that was mid-flight when a seed invalidated us will still arrive here and
    // would otherwise `remember` a list predating the seed, wiping it (and, once
    // nothing is loading, letting the self-heal eject the selection). Only the
    // newest started run is allowed to publish (cage-match #133, Tesla HIGH).
    if (!seeds.isLatestFetch(gen)) {
      return _withSeeds(dms, seeds.forUser(user.userId));
    }
    ref.read(_lastKnownDmsProvider.notifier).remember(user.userId, dms);
    seeds.retireConfirmed(user.userId, dms);
    return _withSeeds(dms, seeds.forUser(user.userId));
  } on Unauthorized {
    rethrow;
  } catch (_) {
    return _withSeeds(
      ref.read(_lastKnownDmsProvider.notifier).forUser(user.userId),
      seeds.forUser(user.userId),
    );
  }
});

/// Channels ∪ DMs — every navigable conversation, as ONE list, so the active-
/// channel resolver ([ChatScreen.resolveActive]) and its self-heal treat a
/// selected DM id exactly like a channel id (a DM pick must resolve, not fall
/// back to the first channel). The sidebar still renders the two SOURCES in
/// separate sections; this is only the resolver's combined view.
/// Every DM the client knows exists: fromIsland truth UNIONED with any seed the
/// fromIsland has not confirmed yet.
///
/// The single answer to "which DMs are there", so the sidebar and the active
/// conversation resolver cannot disagree. They did: the sidebar read
/// `dmsProvider` directly while the resolver went through
/// [navigableChannelsProvider], so across a refresh window the message pane
/// showed a just-opened DM that the sidebar had no row for. Two readers deriving
/// the same fact by different routes is drift waiting for a witness.
final visibleDmsProvider = Provider.autoDispose<List<Channel>>((ref) {
  final dms = ref.watch(dmsProvider).value ?? const <Channel>[];
  // Union the unretired seeds HERE, not only inside [dmsProvider]'s result. A
  // provider mid-refresh hands its listeners the PREVIOUS value, and the value
  // preceding a seed is by definition the one that predates the DM we just
  // opened — so a consumer reading `dmsProvider.value` across that window sees a
  // list without it. That window is a full round-trip wide, and everything
  // downstream keys off this list: `resolveActive` would fall through to the
  // first CHANNEL while `selectedChannelIdProvider` held the DM, which means the
  // composer would have sent the user's message to the wrong conversation
  // (cage-match #133, Tesla). Seeds retire once the fromIsland names them, so this
  // union is self-limiting, never a resurrection.
  final seedState = ref.watch(_seededDmsProvider);
  final myId = ref.watch(currentUserProvider)?.userId;
  final seeds = (seedState != null && seedState.userId == myId)
      ? seedState.items.map((e) => e.dm).toList()
      : const <Channel>[];
  return _withSeeds(dms, seeds);
});

/// Every navigable conversation, split into the two sections the UI draws, each
/// conversation appearing exactly ONCE across both.
///
/// The split is by SOURCE, not by `kind`. Which endpoint listed a conversation
/// is the island's own answer to "is this a DM" — it serves DMs only through
/// `GET /v1/dm` and excludes them from `GET /v1/channels` — so re-deriving the
/// sections from `Channel.kind` downstream asks a question we already hold the
/// answer to, and gets a different one whenever a decode default, a new island
/// variant or a group-shaped row carries an unexpected kind. That row would then
/// render as a ROOM: its (empty) DM name, its mute read with no peer, and no
/// "Direct messages" header above it (cage-match #136, Tesla).
///
/// Deduping here rather than in each consumer matters because every consumer
/// needs the same answer and one of them turns a repeat into a crash: the narrow
/// app-bar switcher feeds these ids to `DropdownButton`, which asserts that
/// exactly one item matches its `value`. Deduping in that one widget left
/// `resolveActive`, the sidebar and the switcher each deciding for themselves
/// what "the conversation list" is — the two-readers-one-fact drift
/// [visibleDmsProvider] exists to prevent, one layer up (cage-match #136,
/// Kelvin). A repeat is a contract violation rather than an expected state; when
/// it happens the DM entry wins, for the same reason the split is by source.
typedef ConversationSections = ({List<Channel> rooms, List<Channel> dms});

final conversationSectionsProvider = Provider.autoDispose<ConversationSections>(
  (ref) {
    final channels = ref.watch(channelsProvider).value ?? const <Channel>[];
    final dms = ref.watch(visibleDmsProvider);
    final dmIds = {for (final d in dms) d.id};
    final seen = <String>{};
    return (
      rooms: [
        for (final c in channels)
          if (!dmIds.contains(c.id) && seen.add(c.id)) c,
      ],
      dms: [
        for (final d in dms)
          if (seen.add(d.id)) d,
      ],
    );
  },
);

/// The two sections flattened — rooms then DMs. The resolver's view; the UI reads
/// [conversationSectionsProvider] so its rows and this list cannot disagree.
final navigableChannelsProvider = Provider.autoDispose<List<Channel>>((ref) {
  final sections = ref.watch(conversationSectionsProvider);
  return [...sections.rooms, ...sections.dms];
});

/// The ONE answer to "is this conversation a DM", for every surface that needs to
/// branch on it — the peer-aware mute read, the conversation title, the "Message"
/// entry point.
///
/// Those all used to ask `channel.kind == ChannelKind.dm` individually, which is
/// the same re-derivation [conversationSectionsProvider] removed from the row
/// lists, still live on three other call sites: a row from `GET /v1/dm` carrying
/// an unexpected kind sat in the DM section and was peer-titled in the dropdown,
/// then lost its title and its peer-aware mute the moment it became active
/// (cage-match #136, Tesla + Carnot, converging independently).
///
/// An id ABSENT here reads as "not a DM", which is the right fail direction for
/// all three: a conversation not yet in the navigable set gets room treatment
/// (a name, a conversation-scoped mute) rather than a peer lookup that cannot
/// resolve.
final dmConversationIdsProvider = Provider.autoDispose<Set<String>>(
  (ref) => {for (final d in ref.watch(conversationSectionsProvider).dms) d.id},
);

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
final chatTelemetryProvider = Provider<ChatTelemetry>(
  (ref) => const LoggingChatTelemetry(),
);

final chatRepositoryProvider = FutureProvider.autoDispose<ChatRepository>((
  ref,
) async {
  final user = ref.watch(authControllerProvider).value;
  if (user == null) {
    // Not reachable from the UI (the router shows login when logged out), but
    // make the precondition loud rather than constructing a sessionless repo.
    throw StateError('chatRepository requires an authenticated user');
  }
  // EVERY `ref.watch` is taken HERE, in the synchronous phase, before any await.
  // A `ref` does not outlive the provider, and each await is a chance for this
  // autoDispose provider to be disposed mid-build — after which `ref.watch`
  // throws `UnmountedRefException` as an unhandled async error. This build has
  // three awaits and used to watch across all of them; hoisting the watches
  // removes the hazard structurally instead of sprinkling `ref.mounted` checks
  // that every future edit would have to remember (cage-match #133 — the same
  // class as the post-await ref use in `conversation_actions.dart`, found when a
  // slow channel fetch widened the window enough to hit it).
  //
  // DMs join the subscription set the same way channels do. Watching that future
  // means opening a brand-new DM (which invalidates [dmsProvider]) rebuilds the
  // repo through the SAME path a reconnect already uses — subscribe + history for
  // the new id — rather than an internal mutable-set path racing the backpressure
  // valve and reconnect epochs (approach A, #2798). Fails soft to [] offline.
  //
  // The two lists are also awaited TOGETHER rather than in series: they are
  // independent fetches, and the old sequential form paid both round-trips
  // end-to-end on every repo build.
  final channelsFuture = ref.watch(channelsProvider.future);
  final dmsFuture = ref.watch(dmsProvider.future);
  // The device sovereign signing key (sovereign-message-signing). Wired here in
  // the PRODUCTION provider — a nullable injectable silently no-ops if the
  // wiring is forgotten, the same DI trap the telemetry sink hit (PR #45), so a
  // provider-default test asserts a real key reaches the repo.
  final keyStore = ref.watch(sovereignKeyStoreProvider);
  final cache = ref.watch(cacheProvider);
  final transport = ref.watch(transportProvider);
  final rest = ref.watch(restApiProvider);
  final telemetry = ref.watch(chatTelemetryProvider);

  // Register the teardown BEFORE the awaits, against a holder the build fills in
  // later. `ref.onDispose` is itself a ref use, so calling it after an await
  // throws on an already-disposed provider — and that failure LEAKS: the
  // repository we just built keeps its transport subscriptions forever because
  // nothing is left to tear it down. `disposed` covers the opposite order too (we
  // were disposed before the holder was filled), so the repo is disposed exactly
  // once whichever side wins (cage-match #133).
  ChatRepository? built;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    built?.dispose();
  });

  final lists = await Future.wait([channelsFuture, dmsFuture]);
  final channels = lists[0];
  final dms = lists[1];
  final signingKey = await keyStore.loadOrCreate();

  final repo = ChatRepository(
    cache: cache,
    transport: transport,
    rest: rest,
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
    telemetry: telemetry,
    newTempId: () => _uuid.v4(),
  );
  built = repo; // tear down on logout/rebuild — no leaked subs
  if (disposed) {
    // Disposed while we were building. Nothing will ever observe this repo, but
    // it exists and owns resources, so it is ours to close.
    repo.dispose();
    return repo;
  }

  repo.start(); // wire transport streams ONCE (B-live)
  await transport.connect(); // `connected` → choreography
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
    NotifierProvider.autoDispose<SelectedChannelId, String?>(
      SelectedChannelId.new,
    );

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
/// here, the instant complement to the gateway's fromIsland-side hide. The gateway is
/// the real boundary (it never delivers/returns a blocked user's NEW content), but
/// already-cached rows from before the block would otherwise linger until the next
/// reconnect; this filter removes them on the next frame. Watching
/// [blockedUserIdsProvider] means a fresh block rebuilds this provider and
/// re-filters immediately. A null `sender.userId` (external actor) is never in the
/// set, so bot/LLM messages are always kept.
final messagesProvider = StreamProvider.autoDispose
    .family<List<Message>, String>(
      (ref, channelId) => _watchVisibleMessages(ref, channelId),
    );

/// The blocked-filtered, cache-backed message stream for a channel — the shared
/// body of [messagesProvider] and [_unreadMessagesProvider]. Kept as a function
/// (not a shared provider) precisely so the two providers back onto DISTINCT
/// drift streams; see [_unreadMessagesProvider] for why that separation matters.
Stream<List<Message>> _watchVisibleMessages(Ref ref, String channelId) async* {
  final repo = await ref.watch(chatRepositoryProvider.future);
  // The repository future is an async gap, and this provider is autoDispose in a
  // family — a rebuild of anything upstream (or a channel switch) can dispose it
  // WHILE that await is pending. The `ref.watch` below would then throw
  // `UnmountedRefException` as an unhandled async error. Same class as the
  // post-await ref use in `conversation_actions.dart`: a ref does not outlive the
  // thing that owns it, and an await is where that gets forgotten (cage-match
  // #133 — latent before, reachable once the navigable set started rebuilding on
  // seed changes).
  if (!ref.mounted) return;
  final blocked = ref.watch(blockedUserIdsProvider);
  yield* repo
      .watchChannel(channelId)
      .map(
        (msgs) => blocked.isEmpty
            ? msgs
            : msgs.where((m) => !blocked.contains(m.sender.userId)).toList(),
      );
}

// --- cross-channel message search (#8, grep tier) --------------------------

/// The current search query. The search screen writes it (debounced) and
/// [messageSearchResultsProvider] reacts. `.autoDispose` so closing the search
/// surface drops both the query and its results. A [Notifier] (not the legacy
/// `StateProvider`) to match the house style ([SelectedChannelId] et al.).
final messageSearchQueryProvider =
    NotifierProvider.autoDispose<MessageSearchQuery, String>(
      MessageSearchQuery.new,
    );

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
final messageSearchResultsProvider = FutureProvider.autoDispose<List<Message>>((
  ref,
) async {
  final query = ref.watch(messageSearchQueryProvider).trim();
  if (query.isEmpty) return const [];
  final repo = await ref.watch(chatRepositoryProvider.future);
  // Same class as `_watchVisibleMessages`: a debounced query rebuilds this
  // autoDispose provider constantly, so the previous run is routinely still
  // parked on the repository future when it is disposed (cage-match #133).
  if (!ref.mounted) return const [];
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
      ChannelReadMarks.new,
    );

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
  /// newest fromIsland ULID currently cached, or `''` when the channel is empty at
  /// first sight (an empty-string floor below every ULID, so later arrivals still
  /// count — and it persists the "observed" fact so a restart doesn't re-baseline
  /// over messages that landed while away).
  void baseline(String channelId, String newestUlid) {
    if (!ChannelReadStore.isSortableWatermark(newestUlid))
      return; // reject junk
    if (state.containsKey(channelId)) return; // already observed / has a mark
    final userId = ref.read(currentUserProvider)?.userId;
    if (userId == null) return;
    state = {...state, channelId: newestUlid};
    ref
        .read(channelReadStoreProvider)
        .setWatermark(userId, channelId, newestUlid);
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
final _unreadMessagesProvider = StreamProvider.autoDispose
    .family<List<Message>, String>(
      (ref, channelId) => _watchVisibleMessages(ref, channelId),
    );

/// The unread count for [channelId]: cached messages strictly newer (by fromIsland
/// ULID) than the channel's last-read watermark, EXCLUDING the current user's
/// own messages (you don't have unread from yourself) and any message not yet
/// carrying a fromIsland ULID (an un-acked optimistic send — always your own).
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
final _historyFenceProvider = StreamProvider.autoDispose
    .family<String?, String>(
      (ref, channelId) =>
          ref.watch(cacheProvider).watchHistoryContiguousThrough(channelId),
    );

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
///
/// MUTE lands HERE, in the one provider every unread surface already reads
/// (sidebar rows, DM rows, the narrow app-bar aggregate), rather than at each
/// call site — a badge that appears on one surface and not another would be the
/// same fact derived two ways. A mute suppresses only this COUNT: the messages
/// themselves stay in [messagesProvider] and on screen, which is the whole
/// difference between muting and blocking.
final channelUnreadCountProvider = Provider.autoDispose.family<int, String>((
  ref,
  channelId,
) {
  final messages =
      ref.watch(_unreadMessagesProvider(channelId)).value ?? const <Message>[];
  final marks = ref.watch(channelReadMarksProvider);
  // Non-reactive: watching currentUserProvider here would self-invalidate this
  // provider when the message list flushes that (login-dirty) provider mid-build.
  // The unread chain is autoDispose + rebuilt per session, so a read suffices.
  final myUserId = ref.read(currentUserProvider)?.userId;
  final watermark = marks[channelId];
  // Watched UNCONDITIONALLY, above the first-sight branch below, even though
  // neither is read on that path: a `ref.watch` reached only on some branches
  // makes this provider's dependency set depend on its own state, so a later
  // edit (a third mute target, a watermark that can rewind) would silently
  // desync which providers it rebuilds for. Watch everything, then branch on
  // the values (cage-match #135, Tesla).
  final mutedChannels = ref.watch(mutedChannelIdsProvider);
  final mutedSenders = ref.watch(mutedUserIdsProvider);

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

  // A muted conversation reports 0 — but only AFTER the baseline block above has
  // had its chance to run. Skipping straight past it would leave a never-observed
  // muted channel with no watermark at all, so unmuting would flood the badge
  // with every fossil in the cache (the exact failure first-sight baselining
  // exists to prevent).
  if (mutedChannels.contains(channelId)) return 0;

  return messages.where((m) {
    final id = m.id;
    if (id == null) return false; // un-acked own send — never unread
    final senderId = m.sender.userId;
    if (senderId == myUserId) return false; // my own message
    // A muted ACCOUNT is quiet everywhere, so this is filtered per-message rather
    // than per-channel. Their messages still render — only the badge goes quiet.
    if (senderId != null && mutedSenders.contains(senderId)) return false;
    return id.compareTo(watermark) > 0;
  }).length;
});
