/// The conversation rail (Slack/Element style): a server switcher at the top,
/// the channel list in the middle, and a settings/sign-out footer at the bottom.
/// Wide screens show it inline; narrow screens mount the same rail in the app
/// drawer, so both layouts pick from the same two sections.
///
/// A custom widget (NOT `NavigationRail`) because channels are text names +
/// unread badges, not icons. Channel selection routes through
/// `selectedChannelIdProvider.notifier.select`, and per-channel unread reads
/// `channelUnreadCountProvider` (the distinct unread stream), so both invariants
/// that shipped through cage-matches #106/#109 hold verbatim.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/island_mark.dart';
import '../../settings/application/island_manifest_provider.dart';
import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../application/chat_providers.dart';
import '../application/mute_controller.dart';
import '../domain/channel.dart';
import '../domain/channel_member.dart';
import 'chat_screen.dart';

/// Rows are inset from the rail edge so a selected tile reads as a raised pill
/// rather than a full-bleed band.
const kSidebarTileInset = 6.0;

/// The selected row's background, chosen HERE — next to the rail's own
/// `surfaceContainerLow` — because the two must be picked together. The theme's
/// default `selectedTileColor` is the same maritime panel the rail uses, so a
/// themed `selected: true` tinted only the label and left the row invisible
/// against its background. Stepping selection UP one container level is what
/// makes it legible; the cyan label from `listTileTheme.selectedColor` rides on
/// top.
Color _selectedTileColor(ColorScheme scheme) => scheme.surfaceContainerHigh;

const _tileShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
);

void _selectConversation(BuildContext context, WidgetRef ref, String id) {
  ref.read(selectedChannelIdProvider.notifier).select(id);
  final navigator = Navigator.of(context);
  if (navigator.canPop()) navigator.pop();
}

/// Wraps a sidebar row with the mute affordance: long-press on touch,
/// right-click on desktop — the two gestures that mean "more options" on the
/// platforms this app ships to, both landing on the same menu so neither is a
/// second implementation of the first.
///
/// Both gestures fire on POINTER-UP (`onLongPressEnd` / `onSecondaryTapUp`),
/// never on pointer-down. Opening a one-item menu at the press point while the
/// finger is STILL DOWN means the item materialises under that finger and
/// selects itself the moment it lifts — a conversation muting itself with no
/// deliberate act (cage-match #135, Tesla HIGH). The widget test cannot see this:
/// `WidgetTester.longPress` releases the pointer before the menu route is in the
/// hit tree and then taps the item as a separate, polite act, so a
/// pointer-down trigger stays green in the harness and fails on a real thumb.
/// The menu is also nudged clear of the press point so it never opens under the
/// finger that summoned it.
/// PUBLIC because the phone needs it too. The narrow layout has no sidebar, so
/// there is no row to long-press — the app bar's conversation title wraps this
/// instead, which is what lets mute leave the action strip entirely.
class MuteGesture extends ConsumerWidget {
  const MuteGesture({super.key, required this.mute, required this.child});

  /// The row's full mute state — conversation AND peer. The menu acts on
  /// whatever is actually causing the silence, so the glyph and the control can
  /// never disagree (see [ConversationMute]).
  final ConversationMute mute;
  final Widget child;

  /// [container] is captured by the CALLER, before the menu is awaited, and the
  /// notifier is re-read from it AFTER — never captured across the gap.
  ///
  /// A `WidgetRef` is only valid while its consumer is mounted, and this menu
  /// stays open for an unbounded human-scale interval during which the row can
  /// vanish (a DM retired by a refetch, a gateway switch tearing down the rail,
  /// logout). Holding the NOTIFIER instead is no better and was the first fix's
  /// mistake: `mutesProvider` is `.autoDispose`, so a notifier handle is not a
  /// keep-alive — once the last unread watcher leaves the tree it is disposed,
  /// and its very first statement reads `ref`, which now throws (cage-match
  /// #135 round 2, Carnot HIGH + Tesla).
  ///
  /// The `ProviderContainer` is app-scoped and outlives every widget here, and
  /// re-reading an autoDispose provider through it simply rebuilds it (rehydrating
  /// from the store) before applying the change. So the write lands whether or not
  /// the chat surface is still alive — the lifetime question stops existing rather
  /// than being guarded.
  Future<void> _show(
    BuildContext context,
    ProviderContainer container, {
    required String? expectUserId,
    required Offset at,
  }) => showConversationMuteMenu(
    context,
    container,
    mute: mute,
    expectUserId: expectUserId,
    at: at,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final container = ProviderScope.containerOf(context, listen: false);
    // Bound HERE, before the menu can be opened, so a pick that lands after a
    // logout/user-switch is dropped rather than written into another account
    // (cage-match #135 round 3, Tesla).
    final expectUserId = ref.watch(currentUserProvider)?.userId;
    void open(Offset at) =>
        _show(context, container, expectUserId: expectUserId, at: at);

    // RawGestureDetector, for one reason: the slop tolerance (see
    // [_HoldRecognizer]). `GestureDetector` builds a LongPressGestureRecognizer
    // whose pre-accept slop is fixed at kTouchSlop and offers no way to widen it.
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        _HoldRecognizer: GestureRecognizerFactoryWithHandlers<_HoldRecognizer>(
          () => _HoldRecognizer(debugOwner: this),
          (_HoldRecognizer instance) =>
              instance.onLongPressEnd = (d) => open(d.globalPosition),
        ),
        if (!kIsWeb)
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(debugOwner: this),
                (TapGestureRecognizer instance) =>
                    instance.onSecondaryTapUp = (d) => open(d.globalPosition),
              ),
      },
      child: child,
    );
  }
}

/// A long press that tolerates a real hand.
///
/// [LongPressGestureRecognizer] inherits `preAcceptSlopTolerance` = `kTouchSlop`
/// (18 logical px) and does NOT forward that parameter through its constructor,
/// so it cannot be widened. Drift more than 18px in ANY direction before the
/// deadline and [PrimaryPointerGestureRecognizer.handleEvent] resolves the
/// gesture REJECTED and stops tracking: no long press ever happens, so nothing
/// fires on pointer-up either and the control is simply dead.
///
/// Nick found this holding an iPhone in LANDSCAPE — the worst case, arm out and
/// thumb reaching across. He long-pressed a channel and nothing happened at all,
/// including after lifting.
///
/// Every long-press test in this repo was green throughout, because
/// `WidgetTester.longPress` moves exactly zero pixels: it performs a gesture no
/// human hand can. The tests were not weak, they were measuring a different act
/// than the user's. `mute_test` now drives a DRIFTING hold beside the still one,
/// and the drifting arm was RED before this class existed.
///
/// Rather than reimplement a recognizer whose deadline, arena and pointer-up
/// semantics are load-bearing here (the menu opens on LIFT — cage-match #135,
/// Tesla HIGH — because one opened under a finger still down selects itself),
/// this subclass only FILTERS what the base sees: a move within [_thumbSlop] is
/// swallowed, so the base never gets an event it would call a slop violation.
/// Everything past that threshold is forwarded untouched and still rejects
/// normally, which is what keeps a real drag a drag.
///
/// Diagnosis note, because it rules out the usual suspect: the sidebar scrolls
/// VERTICALLY, and a purely HORIZONTAL drift killed the press too. So this was
/// never the scrollable's drag winning the arena — it was the long press
/// rejecting itself on its own radial slop.
class _HoldRecognizer extends LongPressGestureRecognizer {
  _HoldRecognizer({super.debugOwner}) : super(duration: _holdDeadline);

  Offset? _origin;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // The base keeps its origin private, so keep our own to measure against.
    _origin = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origin;
    if (origin != null &&
        event is PointerMoveEvent &&
        (event.position - origin).distance <= _thumbSlop) {
      return;
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _origin = null;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'hold (thumb-tolerant long press)';
}

/// How far a finger may wander and still count as holding still.
///
/// `kTouchSlop` (18) is Flutter's threshold for "is this a scroll" — a question
/// about INTENT TO MOVE. "Is this hand holding still" is a different question
/// and deserves a different number. 48 fits a real thumb and is still far short
/// of a deliberate drag.
const double _thumbSlop = 48.0;

/// How long the finger must rest before the hold claims the gesture.
///
/// The slop widening alone was not enough, and the reason is the ARENA rather
/// than this recognizer. A scrollable's vertical drag accepts the instant travel
/// passes `kTouchSlop`; our hold only accepts at its deadline. A drifting thumb
/// crosses 18px well inside 500ms, so the drag wins first — and because the
/// sidebar list does not overflow, it wins and then has nothing to scroll. The
/// gesture is eaten by a scroll that cannot happen, which is exactly what a dead
/// control feels like.
///
/// So the lever is WHEN we accept, not how much drift we forgive.
///
/// 400ms, and the number is MEASURED rather than reasoned — the first attempt at
/// this said 250ms and that was a regression. At 250ms a deliberate 300ms press
/// opened the mute menu and left `selectedChannelId` NULL, taking the row's
/// PRIMARY action away from anyone who taps slowly; a 50 px/s scroll begun on a
/// row also stopped scrolling entirely. Both restored at 400ms with the drift
/// arm still green, which is the frontier: 300/350/400 all pass the drift arm,
/// and 400 is the largest, so it concedes the least. It is also Android's own
/// long-press timeout.
///
/// STATED LIMIT: the drift arm's synthetic thumb travels 50 px/s and crosses
/// kTouchSlop at ~440ms, so the suite cannot distinguish 400 from anything up to
/// that. If a real thumb drifts FASTER than ~45 px/s this will be green here and
/// still dead on the handset. Only the phone settles it.
const Duration _holdDeadline = Duration(milliseconds: 400);

/// Open the conversation mute menu at global position [at].
///
/// PUBLIC because row-level mute is shared UI, and callers should not rederive
/// the menu wording or lifetime rules when another row-like surface appears.
/// The phone's primary mute path is the conversation details switch; this menu
/// remains the row accelerator.
///
/// [container] is captured by the CALLER before the menu is awaited, and the
/// notifier re-read from it AFTER — never held across the gap. See [MuteGesture]
/// for why a WidgetRef and a held notifier both break here.
Future<void> showConversationMuteMenu(
  BuildContext context,
  ProviderContainer container, {
  required ConversationMute mute,
  required String? expectUserId,
  required Offset at,
}) async {
  {
    final muted = mute.isMuted;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    // TRANSFORM, don't assume. `at` is a GLOBAL position and the container rect
    // below is the overlay's own space; those coincide only while the overlay's
    // origin is the view's, which is true of a full-screen phone overlay and not
    // guaranteed on desktop or an embedded view — and the harness would never
    // show the difference (cage-match #135 round 13, Tesla). The +8 nudge keeps
    // the menu clear of the finger that summoned it; it is not a coordinate
    // conversion, so do the conversion too.
    final local = overlay.globalToLocal(at) + const Offset(8, 8);
    final picked = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        local & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<bool>(
          value: !muted,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              muted
                  ? Icons.notifications_none
                  : Icons.notifications_off_outlined,
            ),
            title: Text(mute.actionLabel),
            // The sentence is a pure getter on ConversationMute, shared with
            // every other surface that offers this control.
            subtitle: Text(mute.actionDetail),
          ),
        ),
      ],
    );
    // An absolute target state (`!muted` captured at open time), never a
    // toggle: if the mute changed while the menu was open, this write is an
    // idempotent no-op rather than an inversion of someone else's change.
    if (picked == null) return;
    mute.apply(
      container.read(mutesProvider.notifier),
      muted: picked,
      expectUserId: expectUserId,
    );
  }
}

/// The trailing slot of a sidebar row: an unread badge, or — when the row is
/// muted — a quiet mute glyph, so a silent conversation reads as *muted* rather
/// than as *nothing happening*. The badge is never shown for a muted row because
/// [channelUnreadCountProvider] already reports 0 there; this only makes the
/// reason legible.
///
/// SCOPE OF THAT CLAIM, stated rather than implied (cage-match #135 round 11,
/// Carnot + Tesla). A zero badge has THREE possible causes and the glyph speaks
/// for two: this conversation is muted, or (in a 1:1 DM) its named peer is. The
/// third — every unread sender in a GROUP channel happens to be account-muted —
/// deliberately shows nothing, because that channel is NOT muted: other members
/// still badge it, and a bell there would offer to unmute a conversation that was
/// never muted, which is the inverse of the lie this glyph exists to prevent.
/// The honest fix for that case is an inventory of who you have silenced (task
/// #29), not a glyph on a room. Same for a DM whose peer cannot be named
/// (`indeterminate`): unknown is not muted, and we do not draw a claim we cannot
/// support.
Widget? _rowTrailing(
  BuildContext context, {
  required String id,
  required int unread,
  required bool muted,
}) {
  // ATTENTION FIRST. An earlier version preferred the glyph, on the stated law
  // that a muted row can never have unread because the provider already returns
  // 0. That law holds for CONVERSATION mute (which returns 0 for the whole row)
  // and is FALSE for a peer mute, which filters per MESSAGE: a 1:1 DM whose peer
  // is muted still counts anyone else who posts there — an LLM/robot sender
  // (`userId == null`, never account-muteable), a system actor, a third id that
  // was never in the two-person roster. The glyph then won and threw a real
  // badge away: the row looked deliberately quiet while something had actually
  // happened, and nothing on screen said so (cage-match #135 round 12, Tesla).
  if (unread > 0) {
    return UnreadBadge(key: Key('sidebar-unread-$id'), count: unread);
  }
  if (muted) {
    // A BELL, not a speaker. This app ships 1:1 LiveKit calls, where a
    // speaker-with-slash is the universal glyph for muting call audio — a
    // different verb entirely from "stop badging this conversation". The
    // notification glyph is what Slack and Discord use for exactly this.
    return Icon(
      Icons.notifications_off_outlined,
      key: Key('sidebar-muted-$id'),
      size: 16,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
  return null;
}

class ChatSidebar extends ConsumerWidget {
  const ChatSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Rows and resolver read ONE provider. This build used to take its rows from
    // `channelsProvider` + `visibleDmsProvider` while resolving `active` from
    // `navigableChannelsProvider` — two routes to one fact, in a single method.
    // The narrow switcher's version of that was a crash; here it is quieter (a
    // conversation the island listed through both endpoints paints twice), which
    // is exactly why it would have survived (cage-match #136, Tesla).
    //
    final repoAsync = ref.watch(chatRepositoryProvider);
    final sections = ref.watch(conversationSectionsProvider);
    final channels = sections.rooms;
    final dms = sections.dms;
    final selectedId = ref.watch(selectedChannelIdProvider);
    final active = ChatScreen.resolveActive(
      ref.watch(navigableChannelsProvider),
      selectedId,
    );

    // Tinted a step off the pane's surface so the rail reads as chrome, not
    // content.
    return SizedBox(
      width: kSidebarWidth,
      child: Material(
        color: scheme.surfaceContainerLow,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              const _IslandCrown(),
              Expanded(
                // The SAME readiness predicate as the app bar and the pane: the
                // repository has a value. Two earlier cuts of this gate were each
                // wrong in one direction (cage-match #136, Tesla ×3):
                //  * `channelsAsync.when` blanked the DM rows behind "Could not
                //    load channels" even though `dmsProvider` fails soft and had
                //    them — while the phone drawer listed those same DMs;
                //  * content-first-on-any-section then painted a row SELECTED
                //    during the window where DMs have arrived and channels have
                //    not, so the highlight jumped to the first room when they
                //    landed — the implicit default walking under the user.
                // `hasValue` is true only once BOTH lists have settled, and stays
                // true through later reloads and refresh errors, so the rail shows
                // what it can, when it can honestly claim it.
                child: repoAsync.hasValue
                    ? (channels.isEmpty && dms.isEmpty
                          ? const Center(child: Text('No conversations yet.'))
                          : _conversationList(
                              context,
                              ref,
                              channels: channels,
                              dms: dms,
                              active: active,
                            ))
                    : repoAsync.hasError
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Could not load conversations.\n${repoAsync.error}',
                        ),
                      )
                    : const Center(child: CircularProgressIndicator()),
              ),
              const Divider(height: 1),
              const _SidebarFooter(),
            ],
          ),
        ),
      ),
    );
  }

  /// Channels and DMs in ONE scrollable list (the DM section sits below the
  /// channel list, per the design anchor) so a long combined list scrolls as a
  /// unit rather than overflowing a fixed slot.
  Widget _conversationList(
    BuildContext context,
    WidgetRef ref, {
    required List<Channel> channels,
    required List<Channel> dms,
    required Channel? active,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.symmetric(
        vertical: 4,
        horizontal: kSidebarTileInset,
      ),
      children: [
        for (final c in channels)
          _SidebarChannelTile(channel: c, selected: c.id == active?.id),
        if (dms.isNotEmpty) ...[
          if (channels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
              child: Text(
                'Direct messages',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final d in dms)
            _SidebarDmTile(dm: d, selected: d.id == active?.id),
        ],
      ],
    );
  }
}

/// One channel row. Selection calls the shared conversation mutator, and unread
/// reads `channelUnreadCountProvider` (never `messagesProvider`) — the active
/// channel is never badged.
class _SidebarChannelTile extends ConsumerWidget {
  const _SidebarChannelTile({required this.channel, required this.selected});

  final Channel channel;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = selected
        ? 0
        : ref.watch(channelUnreadCountProvider(channel.id));
    // No peer: a group channel is silenced only by its own mute.
    final mute = watchConversationMute(ref, channel.id);
    return MuteGesture(
      // KEYED BY CONVERSATION. The key used to live only on the child ListTile,
      // leaving this gesture wrapper matched by SLOT — so a reorder (a DM seed, a
      // channel-list refetch) could update the element in place and hand the
      // recognizer a new child while the in-flight gesture still carried the OLD
      // conversation id. Identity as position, which is precisely how a mute
      // lands on the wrong row (cage-match #135 round 2, Tesla).
      key: Key('mute-gesture-${channel.id}'),
      mute: mute,
      child: ListTile(
        key: Key('sidebar-channel-${channel.id}'),
        selected: selected,
        selectedTileColor: _selectedTileColor(Theme.of(context).colorScheme),
        shape: _tileShape,
        dense: true,
        leading: const Icon(Icons.tag, size: 20),
        title: Text(channel.name, overflow: TextOverflow.ellipsis),
        trailing: _rowTrailing(
          context,
          id: channel.id,
          unread: unread,
          muted: mute.isMuted,
        ),
        onTap: selected
            ? null
            : () => _selectConversation(context, ref, channel.id),
      ),
    );
  }
}

/// One DM row in the Direct-messages section. A DM has no server `name`
/// (identity=key, ADR-0004: a DM's title IS the peer), so the label is the peer's
/// CURRENT handle, resolved from the channel roster the SAME way message sender
/// names resolve ([channelRosterProvider], PR #127) — a rename retitles the row.
/// Selection routes through the SAME mutator as channels. A
/// self-DM (notes-to-self) shows "Notes to self"; an unresolved roster falls back
/// to a neutral label rather than leaking the opaque key. Unread reads the SAME
/// [channelUnreadCountProvider] a channel row does — a DM sits in the repo's
/// subscription set (#2798 Inc 1), so its messages are cached and its history
/// fence settles identically; nothing in the unread accounting is DM-specific.
///
/// Named tradeoff: this watches one roster per visible DM (a `GET /members` each),
/// fine at the current handful-of-DMs scale; batch or fold the peer handle into
/// GET /v1/dm if the DM list grows.
class _SidebarDmTile extends ConsumerWidget {
  const _SidebarDmTile({required this.dm, required this.selected});

  final Channel dm;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myId = ref.watch(currentUserProvider)?.userId;
    final roster = ref.watch(channelRosterProvider(dm.id)).value;
    final unread = selected ? 0 : ref.watch(channelUnreadCountProvider(dm.id));
    // A DM has exactly one other party, so muting that ACCOUNT silences this row
    // as completely as muting the conversation — the row must say so, and its
    // menu must be able to undo THAT rather than offering a mute the user
    // already has (see [ConversationMute]).
    final mute = watchConversationMute(
      ref,
      dm.id,
      peerId: dmPeerId(roster, myId),
      hasPeer: true,
    );
    return MuteGesture(
      key: Key(
        'mute-gesture-${dm.id}',
      ), // see _SidebarChannelTile — slot vs identity
      mute: mute,
      child: ListTile(
        key: Key('sidebar-dm-${dm.id}'),
        selected: selected,
        selectedTileColor: _selectedTileColor(Theme.of(context).colorScheme),
        shape: _tileShape,
        dense: true,
        leading: const Icon(Icons.alternate_email, size: 20),
        title: Text(dmPeerTitle(roster, myId), overflow: TextOverflow.ellipsis),
        trailing: _rowTrailing(
          context,
          id: dm.id,
          unread: unread,
          muted: mute.isMuted,
        ),
        onTap: selected
            ? null
            : () => _selectConversation(context, ref, dm.id),
      ),
    );
  }
}

/// The head of the rail: the island you are on, as its own mark and nothing else.
///
/// This replaced a row that drew a GENERIC `dns_outlined` glyph, the word
/// "Island", and the island's name — three elements where the name carried all
/// of the identity and the icon carried none of it. Nick, seeing it in
/// landscape: "we don't need the island name in the side bar, we have the icon."
/// The icon he meant is this one, which was living at 18px beside the composer.
///
/// It can carry the identity because it is DERIVED from it: hue and silhouette
/// grow out of the island's pubkey (or its URL until the manifest lands), so the
/// mark cannot disagree with the island it names the way a hand-set logo could.
///
/// Sized for a rail rather than a text run. The tap goes where the composer's
/// mark goes — where am I, so, can I go elsewhere.
///
/// Presence belongs here too, beneath the mark: who is aboard this island right
/// now (Nick picked it in the same breath). It is not built because the island
/// has none to give — 57 paths on the live schema, no presence among them, only
/// a note in `realtime/envelopes.py` that typing/presence "extend it later".
/// Tracked as claude-tasks#3885; this column is where those marks land.
class _IslandCrown extends ConsumerWidget {
  const _IslandCrown();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseUrl = ref.watch(configProvider).httpBaseUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: IslandMark(
          baseUrl: baseUrl,
          islandPubkey: ref.watch(islandPubkeyProvider(baseUrl)),
          size: 44,
          onTap: () => context.push('/settings/island'),
          hitPadding: const EdgeInsets.all(6),
        ),
      ),
    );
  }
}

class _SidebarFooter extends ConsumerWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              icon: const Icon(Icons.settings, size: 20),
              label: const Text('Settings'),
              style: TextButton.styleFrom(alignment: Alignment.centerLeft),
              onPressed: () => context.push('/settings'),
            ),
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }
}
