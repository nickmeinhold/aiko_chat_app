import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../call/domain/call_invite.dart';
import '../../../core/widgets/island_mark.dart';
import '../../../app/theme/maritime_theme.dart';
import '../../../core/mark/mark_avatar.dart';
import '../../moderation/presentation/message_actions.dart';
import '../application/chat_providers.dart';
import '../application/mute_controller.dart';
import '../domain/channel.dart';
import '../domain/channel_member.dart';
import '../domain/message.dart';
import 'channel_sidebar.dart';
import 'chat_message_pane.dart';
import 'emoji_shortcodes.dart';

/// At or above this logical width the chat surface shows the Slack/Element-style
/// left rail ([ChatSidebar]); below it collapses to the phone app-bar dropdown.
const double kWideLayoutBreakpoint = 720;

/// The fixed width of the wide-layout channel rail.
const double kSidebarWidth = 268;

/// The chat surface: a conversation switcher + logout in the app bar, a thin
/// connection banner, the message list, and the composer. The default is the
/// first conversation the gateway returns; when more than one NAVIGABLE
/// CONVERSATION exists — channels ∪ DMs, [navigableChannelsProvider] — the title
/// becomes a dropdown to switch among them.
///
/// "Navigable conversation", never "channel": the island excludes DMs from
/// `GET /v1/channels`, so anything scoped to [channelsProvider] here silently
/// strands DMs on a phone (#2798 task #12).
///
/// Switching is a pure DISPLAY change — the repository subscribes to EVERY
/// channel at construction and syncs each one's history on connect
/// (chat_repository `_subscribedChannelIds`), so every channel's messages are
/// already in the cache. Picking another channel just re-points [MessageList] /
/// [Composer] at a different cache slice; there is no re-subscribe or history
/// fetch on switch. (Named tradeoff: subscribe-to-all is simplest and gives
/// instant switching at this channel count; a large channel set would want lazy
/// per-channel subscription instead — future work, not Phase-1.)
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  /// The channel to display: the user's pick if it is still in the list, else
  /// the first channel (the default, and the self-heal when a pick disappears).
  /// Public so the shared [ChatMessagePane] and [ChatSidebar] resolve the active
  /// channel with the SAME pure rule (single source of truth for "which channel").
  static Channel? resolveActive(List<Channel> channels, String? selectedId) =>
      channels.where((c) => c.id == selectedId).firstOrNull ??
      channels.firstOrNull;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedChannelIdProvider);
    // Resolve the active conversation over channels ∪ DMs so a selected DM stays
    // active (a DM id is never in channelsProvider — DMs are a separate source,
    // #2798). The narrow app-bar switcher below lists the SAME combined list, so
    // "what can be active" and "what can be picked" are one set, not two.
    final navigable = ref.watch(navigableChannelsProvider);
    final active = resolveActive(navigable, selectedId);

    // The switcher's sections come from the SAME provider that composes
    // `navigable`, already partitioned — so every id that can be active has
    // exactly one item, which is what `DropdownButton`'s value contract requires.
    // Re-deriving the split here (from `kind`, or from another provider) is what
    // breaks that contract in one direction or the other (cage-match #136).
    final sections = ref.watch(conversationSectionsProvider);
    final rooms = sections.rooms;
    final dms = sections.dms;
    // "Both lists have settled" — the ONE readiness predicate for every surface
    // that names a conversation. [chatRepositoryProvider] awaits both, so its
    // having a value is exactly that condition, and the pane gates on the same
    // thing. See the AppBar title below for what half a gate cost.
    final ready = ref.watch(chatRepositoryProvider).hasValue;

    // If the picked conversation leaves the list (removed / renamed-away on a
    // refetch), clear the pick so the Notifier and the UI agree. Without this the
    // resolver heals only the DISPLAY (falls back to first) while the stale id
    // lingers, so a channel that later reappears would snap the user back to a
    // selection they never re-made (cage-match #106, Tesla). ref.listen fires
    // outside build, so mutating the selection notifier here is safe.
    //
    // Heal over channels ∪ DMs, and ONLY once BOTH sources have settled: a DM id
    // is absent from channelsProvider, so healing against channels alone would
    // clear every DM pick, and healing against the combined list mid-load (channels
    // resolved, DMs still arriving) would clear a valid DM in the gap (#2798 — the
    // self-heal must know about DMs, first-arrival-before-init included).
    ref.listen(navigableChannelsProvider, (_, next) {
      final sel = ref.read(selectedChannelIdProvider);
      if (sel == null) return;
      final channelsState = ref.read(channelsProvider);
      final dmsState = ref.read(dmsProvider);
      if (!channelsState.hasValue || !dmsState.hasValue) {
        return; // don't heal until both sources have loaded at least once
      }
      // ...and don't heal off a value that is merely the LAST one while a
      // refresh is in flight. `hasValue` stays true through an invalidate
      // (Riverpod hands listeners the previous data), so it answers "has this
      // ever loaded", not "is this settled" — and the gap between those two is a
      // real ejection: opening a DM seeds it and invalidates [dmsProvider], and
      // the pre-refresh list does NOT contain the DM you just opened, so healing
      // there clears the selection the user made a frame ago (#2798). The same
      // window sits under the call path's seed; it only hides there because Call
      // navigates by route rather than by selection.
      if (channelsState.isLoading || dmsState.isLoading) return;
      if (!next.any((c) => c.id == sel)) {
        ref.read(selectedChannelIdProvider.notifier).clear();
      }
    });

    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;

    return Scaffold(
      // Wide: NO app bar — the sidebar owns the chrome (server switcher, channels,
      // settings/logout) and the message pane carries its own slim channel header
      // (the redundant full-width bar sat below the native macOS title bar). Narrow:
      // the app bar — the dropdown switcher when there is more than one NAVIGABLE
      // CONVERSATION (channels ∪ DMs, never channels alone), plus the mute,
      // search, settings and sign-out actions.
      appBar: isWide
          ? null
          : AppBar(
              // Listing channels ∪ DMs is what makes a DM REACHABLE on a phone at
              // all: the narrow layout has no sidebar, so this dropdown is the
              // whole navigation surface, and a channels-only item list left
              // `openDm` able to strand you in a conversation you could neither
              // return to nor leave (#2798, task #12).
              //
              // It also retires the DM gate that used to hide this switcher: that
              // gate existed because a DM id in `DropdownButton.value` with no
              // matching item asserts (cage-match #106). The item list now covers
              // every id that can be active, so the crash is unreachable rather
              // than dodged — and the gate WAS the trap.
              // The bar rides the SAME settled predicate as the pane. Gating only
              // the pane closed the floor and left the doorbell wired to the wrong
              // house: with one DM in and the channel list still in flight,
              // `navigable.length == 1` titled the bar "Alice" and lit her mute
              // button over a spinner. One tap conversation-muted a thread the
              // user had never entered — and then the channels landed, the
              // implicit default moved to the first room, and the mute stayed
              // behind on a conversation they never picked (cage-match #136,
              // Tesla). A conversation control must not exist before the
              // conversation it names is settled.
              title: !ready
                  ? const Text('Chat')
                  : active == null
                  ? _ConversationTitle(active: active)
                  // Long-press the title for the mute menu — the phone's
                  // replacement for the sidebar row gesture it has no sidebar
                  // to host.
                  : ConversationTitleMuteGesture(
                      conversation: active,
                      child: navigable.length > 1
                          ? _ConversationSwitcher(
                              rooms: rooms,
                              dms: dms,
                              activeId: active.id,
                            )
                          : _ConversationTitle(active: active),
                    ),
              actions: [
                // Narrow has no sidebar, so the row long-press that mutes a
                // conversation on wide does not exist here. Without this the
                // capability would be wide-only — mutable on the desktop, invisible
                // on the phone, which is where a noisy channel is actually felt.
                // Mute moved OFF the strip: long-press the conversation title.
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: () => context.push('/search'),
                ),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings),
                  onPressed: () => context.push('/settings'),
                ),
                // Sign out lives in Settings now. It is a once-a-year action and
                // it was holding a permanent seat in the four-icon strip you
                // look at all day, one slip away from ending your session.
              ],
            ),
      // Option A — no state loss across the breakpoint. The body is ALWAYS a Row
      // whose LAST child is `Expanded(ChatMessagePane(...))`. Narrow is a
      // one-child Row; wide inserts `[sidebar, divider]` before it. Because the
      // pane stays the LAST Row child (same type + key) across a resize, Flutter's
      // bottom-up child matching reuses its Element + State — so the message
      // list's scroll position and the composer's draft survive the crossing. The
      // NetworkStatusBanner lives INSIDE the pane so it renders in both layouts.
      body: Row(
        children: [
          if (isWide) ...[const ChatSidebar(), const VerticalDivider(width: 1)],
          const Expanded(
            child: ChatMessagePane(key: ValueKey('chat-message-pane')),
          ),
        ],
      ),
    );
  }
}

/// Mute/unmute the conversation you are currently reading — the narrow-layout
/// twin of the sidebar row's long-press menu. One toggle rather than a menu: the
/// action is instant, reversible, and entirely private, so a confirmation step
/// would cost more than the mistake it prevents. The icon carries the state, so
/// a muted conversation announces itself from the bar you are already looking at.
// A long-press gesture on the dropdown ROWS lived here briefly. Removed at
// Nick's call: pressing a row in an already-open menu to get a SECOND menu is a
// menu inside a menu, and the interaction it replaced (long-press the title) is
// both simpler and already working. The rows are for picking a conversation;
// that is all they do.

/// Long-press the conversation title to reach the same mute menu the sidebar
/// rows offer.
///
/// This is what let mute leave the app-bar action strip. The gesture already
/// existed for sidebar rows, but the phone has no sidebar — so the capability
/// was wide-only and a button was added to compensate. Putting the gesture on
/// the title makes "long-press a conversation" true on BOTH layouts and gives
/// the crowded action strip a seat back.
///
/// The mute state is derived by the same peer-aware path the button used, so
/// the two surfaces cannot disagree about the same conversation.
class ConversationTitleMuteGesture extends ConsumerWidget {
  const ConversationTitleMuteGesture({
    super.key,
    required this.conversation,
    required this.child,
  });

  final Channel conversation;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDm = ref.watch(dmConversationIdsProvider).contains(conversation.id);
    final mute = watchConversationMute(
      ref,
      conversation.id,
      peerId: isDm
          ? dmPeerId(
              ref.watch(channelRosterProvider(conversation.id)).value,
              ref.watch(currentUserProvider)?.userId,
            )
          : null,
      hasPeer: isDm,
    );
    return MuteGesture(
      // A CONSTANT key, deliberately NOT keyed by conversation — the opposite of
      // the sidebar rows, and for the opposite reason. Rows key by id because
      // they have siblings that reorder, so slot-matching could hand a
      // recognizer the wrong conversation. A title has exactly one slot and no
      // siblings; keying it by id instead makes the key CHANGE whenever you
      // switch conversation, remounting this subtree — including an open
      // DropdownButton, whose overlay is holding the snapshot the user is
      // currently choosing from. Same pattern, different structure, opposite
      // correct answer.
      key: const Key('mute-gesture-title'),
      mute: mute,
      // A muted conversation must still ANNOUNCE itself. The retired app-bar
      // bell carried that state permanently; a long-press menu only says it once
      // you have already opened the menu, so removing the button would have left
      // a silent conversation on a phone looking exactly like a quiet one — the
      // precise confusion the sidebar's own mute glyph exists to prevent.
      child: mute.isMuted
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: child),
                const SizedBox(width: 6),
                Icon(
                  Icons.notifications_off,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            )
          : child,
    );
  }
}

// The app-bar mute BUTTON lived here. It existed only because the long-press
// menu had nowhere to live on a phone — no sidebar, no row to press. The title
// carries that gesture now (see ConversationTitleMuteGesture), so the button is
// gone and the action strip is one icon lighter.

class _ConversationTitle extends ConsumerWidget {
  const _ConversationTitle({required this.active});

  final Channel? active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = active;
    if (a == null) return const Text('Chat');
    // By SOURCE, through the one door (#136) — a DM whose `kind` says otherwise
    // would otherwise render `a.name`, which for a DM is the empty string.
    if (!ref.watch(dmConversationIdsProvider).contains(a.id))
      return Text(a.name);
    final myId = ref.watch(currentUserProvider)?.userId;
    final roster = ref.watch(channelRosterProvider(a.id)).value;
    return Text(dmPeerTitle(roster, myId));
  }
}

/// The app-bar conversation picker — the narrow layout's ENTIRE navigation
/// surface, and therefore the phone's equivalent of [ChatSidebar]. Shown when more
/// than one conversation exists. Renders the active one with a dropdown of the
/// rest; picking one writes [selectedChannelIdProvider], which re-points the
/// message surface.
///
/// Lists rooms AND DMs, in that order, under a section header — the same two
/// sections the wide sidebar draws, collapsed into one menu because a phone app
/// bar has room for exactly one control. Both are already in the repo's
/// subscription set, so switching stays a pure display change with no fetch.
///
/// [rooms] and [dms] MUST partition [navigableChannelsProvider]: a correctness
/// requirement, not a convention (see [ChatScreen.build]).
class _ConversationSwitcher extends ConsumerWidget {
  const _ConversationSwitcher({
    required this.rooms,
    required this.dms,
    required this.activeId,
  });

  final List<Channel> rooms;
  final List<Channel> dms;
  final String activeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Aggregate unread across every NON-active conversation, so the collapsed
    // app-bar switcher carries an at-a-glance "there's unread elsewhere" dot even
    // before the user opens the menu (the closed DropdownButton only shows the
    // active conversation's own item, which is always badge-free). Opening the
    // menu then reveals which one and how many via the per-item counts below.
    //
    // DMs are counted here too. They have to be: on narrow this dot is the ONLY
    // signal that a DM is waiting, since there is no sidebar row to badge — an
    // aggregate that quietly excluded them would make a message from a person
    // less visible than one from a room.
    final otherUnread = [...rooms, ...dms]
        .where((c) => c.id != activeId)
        .fold<int>(
          0,
          (sum, c) => sum + ref.watch(channelUnreadCountProvider(c.id)),
        );

    return Row(
      children: [
        // The caret sits to the LEFT of the name, outside the DropdownButton.
        // Drawing it here rather than as the button's own `icon` is what makes
        // "on the left" a one-line change instead of a rebuild of how the
        // collapsed state is composed.
        const Icon(Icons.arrow_drop_down),
        const SizedBox(width: 2),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: activeId,
              isDense: true,
              // isExpanded so the button is bounded by the AppBar title width and
              // a long channel name ellipsizes instead of overflowing the bar (a
              // channel named like a legal entity would otherwise clip —
              // cage-match #106, Tesla).
              isExpanded: true,
              borderRadius: BorderRadius.circular(8),
              // NO trailing caret — the arrow is drawn to the LEFT of this
              // button by the Row below.
              //
              // The first attempt moved it with `selectedItemBuilder`, which
              // works but changes how the collapsed state is BUILT: it hands
              // DropdownButton a parallel list of widgets for every item. A
              // committed probe in narrow_dm_navigation_test proves only the
              // ACTIVE row is built when collapsed — a property a phone's data
              // budget depends on — and routing through selectedItemBuilder put
              // that at risk to move a caret 40 pixels. Not a trade worth making.
              icon: const SizedBox.shrink(),
              // M3 AppBar foreground is onSurface, and the menu opens on a
              // surface background — so the inherited onSurface text reads
              // correctly in both the collapsed bar and the open menu.
              items: [
                for (final c in rooms)
                  DropdownMenuItem<String>(
                    value: c.id,
                    child: _ChannelMenuItem(
                      channelId: c.id,
                      name: c.name,
                      isActive: c.id == activeId,
                    ),
                  ),
                // Section header, not a destination: `enabled: false` keeps it out
                // of the selectable set and a null value keeps it out of the
                // one-item-matches-`value` assertion. `Semantics(header: true)`
                // because a disabled menu item still ANNOUNCES as an item, which
                // would offer a screen reader a dead destination in the only
                // navigation control a phone has (cage-match #136, Tesla).
                // Drawn only when there is a boundary to mark.
                if (dms.isNotEmpty && rooms.isNotEmpty)
                  DropdownMenuItem<String>(
                    enabled: false,
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Direct messages',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                for (final d in dms)
                  DropdownMenuItem<String>(
                    value: d.id,
                    child: _DmMenuItem(dm: d, isActive: d.id == activeId),
                  ),
              ],
              onChanged: (id) {
                if (id == null) return;
                // FAIL CLOSED on an id the list no longer holds. The overlay
                // route snapshots its items when the menu OPENS and keeps
                // offering them; if a conversation retires while the menu is up,
                // tapping its leftover row would write a dead id into the
                // selection. Display would look fine — `resolveActive` falls back
                // — but the Notifier stays poisoned, and `ref.listen`'s self-heal
                // never fires because the list did not change again. When that id
                // came back the user would be yanked into a conversation they
                // never re-picked: the exact #106 snap-back this file already
                // guards, re-entered through the overlay (cage-match #136, Tesla).
                if (!rooms.any((c) => c.id == id) &&
                    !dms.any((c) => c.id == id)) {
                  return;
                }
                ref.read(selectedChannelIdProvider.notifier).select(id);
              },
            ),
          ),
        ),
        if (otherUnread > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: UnreadBadge(
              key: const Key('unread-aggregate'),
              count: otherUnread,
            ),
          ),
      ],
    );
  }
}

/// One row of the channel dropdown: the channel name plus, for a NON-active
/// channel with unread messages, a trailing count badge. The active channel is
/// never badged — it is the one you are reading, so it has no unread — which also
/// keeps the collapsed DropdownButton (which renders the active item) badge-free.
class _ChannelMenuItem extends ConsumerWidget {
  const _ChannelMenuItem({
    required this.channelId,
    required this.name,
    required this.isActive,
  });

  final String channelId;
  final String name;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = isActive
        ? 0
        : ref.watch(channelUnreadCountProvider(channelId));
    // A muted row must say WHY it is quiet here too. `channelUnreadCountProvider`
    // reports 0 for a muted channel, so without this the dropdown renders muted
    // and idle identically — two unread surfaces drawing different conclusions
    // from the same mute state, which is exactly the drift the sidebar glyph was
    // added to prevent (cage-match #135, Carnot HIGH + Tesla).
    //
    // Through the SAME door as every other surface, not a second derivation of
    // its own — no peer here because a CHANNEL has none; the DM half of this menu
    // passes one (see [_DmMenuItem]). That day has now arrived: this comment used
    // to say `mutedChannelIdsProvider` would answer identically "by accident of
    // topology, not by law", and the law is what held once DMs joined the list.
    final muted = watchConversationMute(ref, channelId).isMuted;
    return _MenuItemRow(
      conversationId: channelId,
      name: name,
      unread: unread,
      muted: muted,
      isActive: isActive,
    );
  }
}

/// One DM row of the conversation dropdown. Same row shape as a channel's, but
/// both of its facts are resolved differently, which is why it is a separate
/// widget rather than a flag on [_ChannelMenuItem]:
///
///  * the LABEL is the peer, not a server `name` — a DM has none (identity=key,
///    ADR-0004: a DM's title IS the other person), so it comes from the roster
///    via [dmPeerTitle], exactly as [ChatSidebar]'s DM tile resolves it;
///  * the MUTE is peer-aware — a 1:1 DM is silenced by two independent causes,
///    this conversation being muted or its PERSON being muted account-wide, and
///    only the peer-aware call sees the second. Passing `hasPeer: true` is what
///    the [_ChannelMenuItem] comment was holding this seat open for: without it
///    a peer-muted DM would render idle in the one menu that never learned about
///    peers (cage-match #135 round 7, Tesla).
class _DmMenuItem extends ConsumerWidget {
  const _DmMenuItem({required this.dm, required this.isActive});

  final Channel dm;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myId = ref.watch(currentUserProvider)?.userId;
    final roster = ref.watch(channelRosterProvider(dm.id)).value;
    final unread = isActive ? 0 : ref.watch(channelUnreadCountProvider(dm.id));
    final muted = watchConversationMute(
      ref,
      dm.id,
      peerId: dmPeerId(roster, myId),
      hasPeer: true,
    ).isMuted;
    return _MenuItemRow(
      conversationId: dm.id,
      name: dmPeerTitle(roster, myId),
      unread: unread,
      muted: muted,
      isActive: isActive,
    );
  }
}

/// The shared row body for both kinds of dropdown item: label, then ONE trailing
/// marker. Shared on purpose — the unread-vs-muted fork below is a decision the
/// mute cage-match landed twice already, and a channel row and a DM row drawing
/// it from two copies is precisely the two-readers-one-fact drift this file's
/// providers were restructured to remove.
class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({
    required this.conversationId,
    required this.name,
    required this.unread,
    required this.muted,
    required this.isActive,
  });

  final String conversationId;
  final String name;
  final int unread;
  final bool muted;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    // The ACTIVE row carries no marker. The collapsed DropdownButton renders it
    // inside the app bar, inches from _MuteConversationAction — which states the
    // same mute AND is the control that changes it, so a glyph here is a second
    // bell that only opens a menu (cage-match #136).
    if (isActive) {
      return Text(name, overflow: TextOverflow.ellipsis);
    }
    return Row(
      children: [
        Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
        // Attention first, same polarity as the sidebar row: a peer mute filters
        // per MESSAGE, so a muted-looking row can still have a real count from
        // someone else, and the glyph must never swallow it (cage-match #135
        // round 12, Tesla).
        if (unread > 0) ...[
          const SizedBox(width: 8),
          UnreadBadge(key: Key('unread-item-$conversationId'), count: unread),
        ] else if (muted) ...[
          const SizedBox(width: 8),
          Icon(
            Icons.notifications_off_outlined,
            key: Key('muted-item-$conversationId'),
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ],
    );
  }
}

/// How long the composer's state changes take. Short enough to feel like a
/// response to the keystroke, long enough to read as a light coming on rather
/// than a repaint.
const Duration _kComposerFade = Duration(milliseconds: 220);

/// Honour the platform's reduce-motion setting: the composer's affordances are
/// carried by COLOUR and PRESENCE, so collapsing their duration to zero loses
/// nothing but the movement (which is exactly what the setting asks for).
Duration _fadeFor(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : _kComposerFade;

/// The hairline under the composer, which ignites in `colorScheme.primary` from
/// the left when the field takes focus.
///
/// This is the composer's entire container. The base rule is always drawn (so
/// there is a visible "you can type here" edge at rest — a borderless field with
/// no rule would be a blank patch of ground), and the lit rule grows over it.
class _Waterline extends StatelessWidget {
  const _Waterline({required this.lit});

  final bool lit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 1.5,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.outlineVariant),
          Align(
            alignment: Alignment.centerLeft,
            child: AnimatedFractionallySizedBox(
              duration: _fadeFor(context),
              curve: Curves.easeOutCubic,
              widthFactor: lit ? 1.0 : 0.0,
              // heightFactor is NOT optional here, though nothing complains if
              // it is missing. `Align` loosens the Stack's tight 1.5px height;
              // a null heightFactor passes that loose 0..1.5 straight through;
              // and a childless `ColoredBox` then takes `constraints.smallest`
              // — so the lit rule laid out 431px wide and ZERO px tall and had
              // never once been visible, in either theme, since it shipped.
              heightFactor: 1.0,
              alignment: Alignment.centerLeft,
              child: ColoredBox(color: scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

// The signing seal that used to live here is gone: it announced "this will be
// signed at birth" by animating on the first and last keystroke, which is an
// automatic and non-actionable fact restated on a loop. Its slot in the composer
// now carries the ISLAND MARK (`lib/core/widgets/island_mark.dart`), because in a
// federated app "which island am I on" is the question that actually changes.
// Signing is still stated where it can be read at leisure: Settings → Carried
// Record.

/// The send control as a signal lamp: greyed at rest, full accent once there is
/// a message to send.
///
/// The two states are ONE ink at two emphases, not two palette roles. The first
/// cut used `onSurfaceVariant` → `secondary`, which is dim → amber in maritime
/// but **#49454E → #635B70 in light** — a dark charcoal becoming a *lighter*
/// purple. The lamp went OUT when you armed it, because those tokens encode role
/// rather than emphasis and their relative luminance flips between themes
/// (caught on-device: "can't the send button be greyed out in light mode?").
///
/// Going from a recessive rest to a full accent is monotonic by construction:
/// whatever the theme, armed always has more presence than rest.
///
/// Rest is [ColorScheme.outlineVariant] — the SAME ink as [_SealMark] at rest,
/// so the two marks bracketing the line are one dim, not two. It is genuinely
/// faint (1.62:1 in light, 1.50:1 in maritime), and that is the point rather
/// than an oversight: an earlier cut held it at 0.55 opacity arguing an enabled
/// control must stay visible, which does not survive contact with what the state
/// MEANS. The resting lamp is the state where there is nothing to send. The
/// instant there is, it goes to full accent — so the contrast belongs on the
/// armed state, where the control actually has to be found, and the keyboard's
/// own return key sends regardless.
class _SendLamp extends StatelessWidget {
  const _SendLamp({super.key, required this.armed, required this.onPressed});

  final bool armed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      duration: _fadeFor(context),
      curve: Curves.easeOut,
      tween: Tween(begin: 0, end: armed ? 1 : 0),
      builder: (context, t, _) => IconButton(
        onPressed: onPressed,
        tooltip: 'Send',
        // IconButton's default 48×48 target is kept — the glyph is faint, the
        // thumb target is not, and it stays enabled at rest.
        color: Color.lerp(scheme.outlineVariant, scheme.secondary, t),
        icon: const Icon(Icons.send_outlined),
      ),
    );
  }
}

/// A compact unread-count pill. Caps the display at `99+` so a noisy channel
/// never widens the app bar. Uses the M3 error/​primary container colours so it
/// reads as a notification marker in both light and dark themes.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The reactive message list for [channelId]. Rows are ascending (oldest first);
/// the list sits at the bottom (newest) since chat reads bottom-up.
///
/// Auto-scrolls to the newest message when new data arrives — but only when the
/// user is already pinned near the bottom. If they've scrolled UP to read
/// history, we leave them there rather than yanking them down on every message.
class MessageList extends ConsumerStatefulWidget {
  const MessageList({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<MessageList> {
  final _scrollController = ScrollController();

  /// How close (in logical pixels) to the bottom counts as "pinned to newest".
  /// A small slack absorbs the partial last row / fractional offsets.
  static const _bottomThreshold = 80.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Whether the viewport is currently at (or near) the bottom — i.e. the user
  /// is reading the live tail rather than scrolled up into history. Returns true
  /// before the first layout (no clients yet) so the initial render lands at the
  /// newest message.
  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= _bottomThreshold;
  }

  void _scrollToBottom({required bool animate}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(widget.channelId));
    final myUserId = ref.watch(currentUserProvider)?.userId;

    return messagesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load messages.\n$e')),
      data: (messages) {
        if (messages.isEmpty) {
          return const Center(child: Text('No messages yet. Say hello!'));
        }
        // Decide BEFORE the new frame lays out: were we pinned to the tail? If
        // so, follow the new message down once layout (and thus the new
        // maxScrollExtent) is in place. Animate on subsequent updates; jump on
        // the first paint so we open at the newest message without a visible
        // scroll.
        final wasNearBottom = _isNearBottom;
        final hadClients = _scrollController.hasClients;
        if (wasNearBottom) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _scrollToBottom(animate: hadClients);
          });
        }
        // Viewing this channel marks it read: advance its last-read watermark to
        // the newest server ULID currently loaded. Fires on mount (a channel
        // switch rebuilds this keyed widget, and `_isNearBottom` is true before the
        // first layout, so opening a channel marks it read) and on a new inbound
        // ONLY WHILE the reader is at/near the tail. If they've scrolled UP into
        // history, a tail-arrival must NOT jump the watermark past a message they
        // never saw — that would falsely mark the channel read (Tesla, PR #109).
        // `wasNearBottom` is the exact same signal that gates the auto-scroll above.
        // Uses the max non-null id (own un-acked sends carry none and never gate
        // unread). markRead is monotonic, so a post-frame re-mark never rewinds.
        String? newestReadId;
        for (final m in messages) {
          final id = m.id;
          if (id != null &&
              (newestReadId == null || id.compareTo(newestReadId) > 0)) {
            newestReadId = id;
          }
        }
        if (newestReadId != null && wasNearBottom) {
          final markId = newestReadId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref
                .read(channelReadMarksProvider.notifier)
                .markRead(widget.channelId, markId);
          });
        }
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          itemCount: messages.length,
          itemBuilder: (_, i) {
            final m = messages[i];
            return MessageTile(
              message: m,
              isMine: m.sender.userId == myUserId,
              channelId: widget.channelId,
            );
          },
        );
      },
    );
  }
}

/// One message bubble: sender + body, right-aligned when it's mine, with a
/// delivery indicator and an inline Retry when a send failed (W5).
class MessageTile extends ConsumerWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isMine,
    required this.channelId,
  });

  final Message message;
  final bool isMine;

  /// The channel this message is shown in — scopes the roster lookup that
  /// resolves the sender's CURRENT handle (see [senderDisplayName]).
  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isMine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;

    // Render the sender's CURRENT handle (my own from the live user, others from
    // the channel roster), falling back to the send-time label — so a rename
    // retitles past messages, matching the key-derived avatar below.
    final senderName = senderDisplayName(
      message.sender,
      isMine: isMine,
      myHandle: ref.watch(currentUserProvider)?.username,
      roster: ref.watch(channelRosterProvider(channelId)).value,
    );

    // A CALL INVITATION IS AN EVENT, NOT A REMARK.
    //
    // The wire body is `aiko:call/1 · 📞 started a call` — a signed, permanent
    // row, worded so a client that predates the feature degrades to a readable
    // line instead of breaking. This client never learned to render it, so it
    // showed the machine anchor verbatim inside a normal speech bubble, with the
    // caller's name floating on a separate line above the avatar. Nick, reading
    // it: "the sender and 'started a call' being on separate lines with
    // something in between is confusing."
    //
    // So it renders as one sentence — WHO did WHAT — centred, unbubbled, in the
    // register of a thing that happened rather than a thing someone said. Only
    // the RENDERING changes: [kCallInviteBody] is inside signatures already sent
    // to a live island and is a one-way door.
    //
    // THE HANGUP RENDERS THROUGH THE SAME ARM, and shipping it any other way
    // would have undone this. `kCallEndBody` is worded the same way — machine
    // anchor first so an old client degrades to a readable line — so a hangup
    // that only touched the wire would have put `aiko:call/1 · 📞 ended the
    // call` straight back into a speech bubble, which is the precise thing this
    // block was added to stop. Two sentinels, one arm.
    //
    // AND THE HANGUP ARM CARRIES THE ADMISSION RULE THE RING ALREADY APPLIES.
    // `admitCallEnd` refuses a stop that "names no call — a stop with no
    // replyTo is about everything or nothing"; the render arm matched on the
    // body alone, so a message that the RING would refuse still drew a centred,
    // unbubbled system line reading "X ended the call" for a call that never
    // existed (cage-match round 6, Carnot). Signing does not help here and it is
    // worth being clear why: this app signs at birth, so a sentinel somebody
    // TYPES is signed exactly like one the call screen generates. The signature
    // proves authorship of the bytes, never that they were machine-authored — so
    // the discriminator has to be the reply binding, which the composer cannot
    // aim at an arbitrary message without actually replying to it.
    //
    // The invitation arm needs no such clause, and the asymmetry is real rather
    // than an oversight: a typed invitation IS an invitation. It passes
    // `admitRing`, it rings the peer, and Answer joins the channel's room —
    // which is precisely what pressing Call would have done. Rendering it as an
    // event is therefore honest. A stop is different because a stop makes a
    // claim about a PRIOR event, and that claim is checkable.
    final isInvite = isCallInviteBody(message.body);
    final isCallEnd = isCallEndBody(message.body) && message.replyToId != null;
    if (isInvite || isCallEnd) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isInvite ? Icons.phone_in_talk_outlined : Icons.call_end_outlined,
              size: 15,
              // The end is a settled fact, not an invitation to act, so it does
              // not take the accent the ring does.
              color: isInvite ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                // "You" reads better than your own handle for your own act.
                isInvite
                    ? (isMine
                          ? 'You started a call'
                          : '$senderName started a call')
                    : (isMine
                          ? 'You ended the call'
                          : '$senderName ended the call'),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatTime(message.createdAt),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFamily: kMaritimeMono,
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // Sender-action affordance: long-press ANOTHER human's message for the
    // action sheet — call them (#2758), report, or block (#7). Gated to a
    // non-mine message with a real account behind it — you can't call/block
    // yourself or an external actor (LLM/robot have no userId).
    final canActOnSender = !isMine && message.sender.userId != null;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: canActOnSender
            ? () => showMessageActions(context, ref, message)
            : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(12),
            // Maritime texture: a sea-panel separated by a hairline, not by
            // Material elevation/shadow.
            border: Border.all(
              color: Theme.of(context).colorScheme.outline,
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Key-derived Blockie mark (identity v1): the signed sender key
                  // when present, else a stable seed from the user id so every
                  // sender still gets a deterministic face.
                  MarkAvatar(
                    publicKey: message.origin?.rawPublicKey,
                    seed: message.sender.userId ?? message.sender.displayLabel,
                    size: 20,
                    radius: 6,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      senderName,
                      style: Theme.of(context).textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Non-human senders (LLM/robot/generic actor — e.g. an agent
                  // the island stamps from User.kind) get a participant badge so
                  // a reader can tell a bot from a person. Humans get nothing.
                  if (message.sender.kind.isExternalActor) ...[
                    const SizedBox(width: 4),
                    _SenderBadge(kind: message.sender.kind),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(message.body),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(message.createdAt),
                    // Ids/timestamps speak in the mono instrument voice.
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontFamily: kMaritimeMono,
                      fontSize: 11,
                    ),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: 6),
                    _DeliveryIndicator(message: message),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final l = t.toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// A small "who/what" chip shown beside a non-human sender's label so an
/// agent/bot message is visually distinguishable from a person's. Driven by
/// [SenderKind.isExternalActor]; never shown for [SenderKind.human]. Any
/// unrecognized island sender_kind decodes to [SenderKind.actor] → "Bot".
class _SenderBadge extends StatelessWidget {
  const _SenderBadge({required this.kind});

  final SenderKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy, size: 10, color: scheme.onSecondaryContainer),
          const SizedBox(width: 3),
          Text(
            _label(kind),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  static String _label(SenderKind kind) {
    switch (kind) {
      case SenderKind.llm:
        return 'AI';
      case SenderKind.robot:
        return 'Robot';
      case SenderKind.human:
      case SenderKind.actor:
        return 'Bot';
    }
  }
}

/// Renders the [DeliveryState] of an outgoing message; offers Retry on failure.
class _DeliveryIndicator extends ConsumerWidget {
  const _DeliveryIndicator({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (message.deliveryState) {
      case DeliveryState.sending:
        return const Icon(Icons.schedule, size: 14);
      case DeliveryState.failed:
        return InkWell(
          onTap: () async {
            final repo = await ref.read(chatRepositoryProvider.future);
            await repo.retry(message.clientTempId);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 14,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 2),
              Text(
                'Retry',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        );
      case DeliveryState.sent:
      case DeliveryState.delivered:
      case DeliveryState.read:
        // No persistent glyph once sent: a checkmark is the read-receipt
        // signifier (WhatsApp/Signal), and this app has no read receipts — the
        // `read` state is never even set. The adjacent timestamp already means
        // "sent at HH:MM", so a terminal-state message just shows the time. Only
        // the in-flight `sending` clock and the `failed` Retry remain as trailing
        // affordances — the absence of the clock IS "sent" (iMessage/Telegram).
        return const SizedBox.shrink();
    }
  }
}

/// The text composer. Sends through the repository's optimistic [sendMessage]
/// (W1: the row is committed before the wire send), then clears the field.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.channelId,
    this.islandBaseUrl,
    this.islandPubkey,
  });

  /// The island this composer is writing into, for the island mark.
  ///
  /// Passed DOWN rather than read from `configProvider` here. A composer that
  /// reached for app-wide config would fail to build wherever that config is not
  /// wired — which is most unit tests, and would make an 18px decoration a
  /// precondition for the text field working at all. Null simply means no mark.
  final String? islandBaseUrl;

  /// The island's Ed25519 public key, when known — the mark's preferred
  /// identity source. Null falls back to the base URL.
  final String? islandPubkey;

  final String channelId;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();

  /// Active `:shortcode` autocomplete suggestions (#12). Empty ⇒ picker closed.
  List<MapEntry<String, String>> _suggestions = const [];
  int _selected = 0;

  /// Is there something to send? Drives the seal and the send lamp together —
  /// they are two readings of one fact, so they must never disagree.
  bool _armed = false;

  /// Is the composer focused? Lights the waterline.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateSuggestions);
    _controller.addListener(_updateArmed);
  }

  @override
  void dispose() {
    _controller.removeListener(_updateSuggestions);
    _controller.removeListener(_updateArmed);
    _controller.dispose();
    super.dispose();
  }

  /// Own listener rather than folding into [_updateSuggestions]: both are
  /// per-keystroke, and each guards its OWN transition so ordinary typing
  /// rebuilds nothing. `_armed` flips at most twice per message.
  void _updateArmed() {
    final armed = _controller.text.trim().isNotEmpty;
    if (armed != _armed) setState(() => _armed = armed);
  }

  /// The caret offset when it is a valid, collapsed cursor; else -1 (a range
  /// selection or no focus has no single insertion point to complete against).
  int get _caret {
    final sel = _controller.selection;
    return (sel.isValid && sel.isCollapsed) ? sel.baseOffset : -1;
  }

  /// Recompute suggestions from the token under the caret. Only calls setState
  /// when the visible list actually changes, so ordinary typing doesn't churn
  /// the tree on every keystroke.
  void _updateSuggestions() {
    final tok = activeShortcodeToken(_controller.text, _caret);
    final next = tok == null
        ? const <MapEntry<String, String>>[]
        : filterEmojiShortcodes(tok.query);
    final changed =
        next.length != _suggestions.length ||
        [
          for (var i = 0; i < next.length; i++)
            next[i].key != _suggestions[i].key,
        ].any((d) => d);
    if (changed) {
      setState(() {
        _suggestions = next;
        _selected = 0;
      });
    }
  }

  void _closeSuggestions() {
    if (_suggestions.isNotEmpty) {
      setState(() {
        _suggestions = const [];
        _selected = 0;
      });
    }
  }

  /// Replace the active `:token` with the chosen emoji and close the picker.
  void _acceptSuggestion(MapEntry<String, String> s) {
    final tok = activeShortcodeToken(_controller.text, _caret);
    if (tok == null) return;
    final text = _controller.text;
    _controller.value = TextEditingValue(
      text: text.replaceRange(tok.start, _caret, s.value),
      selection: TextSelection.collapsed(offset: tok.start + s.value.length),
    );
    _closeSuggestions();
  }

  void _moveSelection(int delta) {
    if (_suggestions.isEmpty) return;
    setState(() {
      _selected = (_selected + delta) % _suggestions.length;
      if (_selected < 0) _selected += _suggestions.length;
    });
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty) return;
    _controller.clear(); // optimistic: clear immediately, the row is durable
    final repo = await ref.read(chatRepositoryProvider.future);
    await repo.sendMessage(widget.channelId, body);
  }

  /// Touch platforms keep the send button (no reachable Enter-to-send for a
  /// thumb); physical-keyboard platforms (desktop, web) send on Enter and drop
  /// the button as chrome. Emoji has no button on any platform — `:shortcode`
  /// autocomplete and the soft keyboard's own emoji key are the paths.
  bool get _showSendButton =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Insert [s] at the caret (replacing any selection) and collapse the caret
  /// after it. Shared by the emoji picker and the Shift+Enter newline (a field
  /// with no caret yet has an invalid -1 selection → append at the end).
  void _insertAtCursor(String s) {
    final sel = _controller.selection;
    final text = _controller.text;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, s),
      selection: TextSelection.collapsed(offset: start + s.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_suggestions.isNotEmpty) _buildSuggestions(context),
          Padding(
            // Left padding is 0 because the ISLAND MARK now draws it, inside its
            // tap target (see hitPadding below) — that is what lets a press land
            // in the gutter right up to the screen edge. The bottom 8 stays: it
            // spaces the whole row, including the text field.
            padding: const EdgeInsets.fromLTRB(0, 4, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // The island mark — WHICH ISLAND AM I ON, answered quietly and
                // permanently, in the slot the signing seal used to occupy.
                //
                // The seal was replaced deliberately. It animated on every first and
                // last keystroke to say "this will be signed", which is true of
                // every message that has ever been sent from here: an automatic,
                // non-actionable fact, restated on a loop. Signing is still stated
                // where it can be read at leisure (Settings → Carried Record). In a
                // FEDERATED app "where am I" is the live question, and it deserves
                // the pixel more.
                //
                // Static by construction — it takes no composer state at all, so it
                // cannot flicker while you type.
                if (widget.islandBaseUrl != null)
                  IslandMark(
                    baseUrl: widget.islandBaseUrl!,
                    islandPubkey: widget.islandPubkey,
                    // Where am I → can I go elsewhere. The picker owns the
                    // session-teardown ceremony a gateway switch requires, so
                    // this only has to open it.
                    onTap: () => context.push('/settings/gateway'),
                    // THE MARK'S SURROUNDING SPACE IS THE TAP TARGET.
                    //
                    // These are not new pixels: the Row used to draw a 12px left
                    // gutter and a 10px gap after the mark, and the mark sat 9px
                    // off the bottom. All of that now lives INSIDE the gesture,
                    // and the Row's own left/bottom padding drops to match — so
                    // the glyph is in exactly the same place and the space
                    // around it has simply started accepting presses, out to the
                    // screen edge on the left.
                    //
                    // A previous attempt gave the mark a 44x44 box instead. It
                    // was reachable and it MOVED THINGS: the box took real
                    // layout width, so the composer shifted. Padding-inside-the
                    // gesture is the version that costs nothing on screen.
                    //
                    // The 20px top is free: the Row is as tall as the text
                    // field, and `crossAxisAlignment.end` bottom-aligns this, so
                    // a taller-but-still-shorter-than-the-field box changes no
                    // layout at all.
                    hitPadding: const EdgeInsets.only(
                      left: 12,
                      top: 20,
                      right: 10,
                      bottom: 9,
                    ),
                  )
                else
                  // No island to mark (tests, and any caller that does not pass
                  // one) — the Row's left gutter moved into the mark's tap
                  // target, so without the mark it has to come back or the text
                  // field sits flush against the screen edge.
                  const SizedBox(width: 12),
                Expanded(
                  child: Focus(
                    onFocusChange: (has) {
                      if (has != _focused) setState(() => _focused = has);
                    },
                    // Physical keyboard: Enter sends, Shift+Enter inserts a newline.
                    // Scoped to hardware key events, so mobile soft keyboards keep
                    // their existing newline + send-button behaviour untouched.
                    onKeyEvent: (node, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      final key = event.logicalKey;
                      // When the shortcode picker is open it captures the navigation
                      // keys, so Enter/Tab commit the highlighted emoji instead of
                      // sending the message and the arrows move the highlight.
                      if (_suggestions.isNotEmpty) {
                        if (key == LogicalKeyboardKey.enter &&
                                !HardwareKeyboard.instance.isShiftPressed ||
                            key == LogicalKeyboardKey.tab) {
                          _acceptSuggestion(_suggestions[_selected]);
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.arrowDown) {
                          _moveSelection(1);
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.arrowUp) {
                          _moveSelection(-1);
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.escape) {
                          _closeSuggestions();
                          return KeyEventResult.handled;
                        }
                      }
                      if (key == LogicalKeyboardKey.enter) {
                        if (HardwareKeyboard.instance.isShiftPressed) {
                          // Shift+Enter → newline. Flutter's DefaultTextEditingShortcuts
                          // map only PLAIN Enter to a newline in a multiline field, and
                          // the composer reassigns bare Enter to "send" — so Shift+Enter
                          // has no default handler and the newline must be inserted
                          // explicitly here (#113 follow-up; was a silent no-op before).
                          _insertAtCursor('\n');
                        } else {
                          _send();
                        }
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _controller,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          decoration: InputDecoration(
                            // An invitation, not a label. "Message" reads as a field
                            // NAME on a form; the ellipsis and the verb say a
                            // sentence goes here. Dimmer than default so it recedes
                            // behind what you type.
                            hintText: 'Write a message…',
                            hintStyle: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(alpha: 0.6),
                            ),
                            // NO container. This file's theme states its own law —
                            // "no shadows — separation is by hairline" — and the
                            // composer was the last component still wearing a box.
                            // `isCollapsed` also strips Material's ~48px minimum
                            // field height, so the text sits on the ground the way
                            // the message bubbles do. The affordance moves to the
                            // waterline below.
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isCollapsed: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                        _Waterline(lit: _focused),
                      ],
                    ),
                  ),
                ),
                // Keyboard-first composer: physical-keyboard platforms send on Enter
                // (see the Focus onKeyEvent above), so the send button is redundant
                // chrome and is dropped. Touch platforms keep it — a thumb has no
                // reachable Enter-to-send, and the soft keyboard's action key alone
                // isn't a discoverable send affordance.
                if (_showSendButton) ...[
                  const SizedBox(width: 4),
                  // The lamp. Glyph only — no fill, no border — and it LIGHTS rather
                  // than appears: dim while there is nothing to send, beacon amber
                  // (`colorScheme.secondary`) once there is. A signal lamp is the
                  // right metaphor for a maritime skin, and `secondary` was a colour
                  // the palette defined and almost never spent.
                  //
                  // Always ENABLED, never disabled-on-empty: a control that vanishes
                  // from the accessibility tree between keystrokes is worse than one
                  // that no-ops, and `_send` already returns early on an empty body.
                  // So the colour is a hint about state, not a gate on the action.
                  _SendLamp(
                    // Keyed so the tests target the CONTROL, not its glyph — finding
                    // it by `Icons.send` is what made a pure restyle a 9-test edit.
                    key: const Key('composer-send'),
                    armed: _armed,
                    onPressed: _send,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The `:shortcode` autocomplete panel shown above the input while a token is
  /// being typed. Theme-driven (no hardcoded colours) so it rides whatever skin
  /// is active. The highlighted row is what Enter/Tab commits.
  Widget _buildSuggestions(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        constraints: const BoxConstraints(maxHeight: 220, maxWidth: 340),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _suggestions.length,
          itemBuilder: (context, i) {
            final s = _suggestions[i];
            final selected = i == _selected;
            return InkWell(
              onTap: () => _acceptSuggestion(s),
              child: Container(
                color: selected ? theme.colorScheme.primaryContainer : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(s.value, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    // Flexible + ellipsis: a long shortcode (e.g.
                    // `:smiling_face_with_three_hearts:`) must clip to the panel
                    // width, not overflow the bounded row.
                    Flexible(
                      child: Text(
                        ':${s.key}:',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
