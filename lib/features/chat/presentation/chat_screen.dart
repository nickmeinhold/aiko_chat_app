import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/maritime_theme.dart';
import '../../../core/mark/mark_avatar.dart';
import '../../auth/application/auth_controller.dart';
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

/// The chat surface: a channel switcher + logout in the app bar, a thin
/// connection banner, the message list, and the composer. The default channel is
/// the first one the gateway returns; when more than one channel exists the title
/// becomes a dropdown to switch among them (the app already fetches the full list
/// via [channelsProvider]).
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
    final channelsAsync = ref.watch(channelsProvider);
    final selectedId = ref.watch(selectedChannelIdProvider);
    final channels = channelsAsync.value ?? const <Channel>[];
    // Resolve the active conversation over channels ∪ DMs so a selected DM stays
    // active (a DM id is never in channelsProvider — DMs are a separate source,
    // #2798). The narrow app-bar switcher below still lists `channels` only; the
    // wide sidebar is the DM entry point.
    final active = resolveActive(ref.watch(navigableChannelsProvider), selectedId);

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
      // the CURRENT app bar — the dropdown switcher when >1 channel, plus the
      // settings + sign-out actions — unchanged.
      appBar: isWide
          ? null
          : AppBar(
              // Gate the channel switcher to a NON-DM active channel: its
              // DropdownButton uses activeId as `value`, and a DM id is never in
              // the channels-only item list → Flutter asserts. A DM (selected on
              // wide, then resized to narrow) renders a title instead of the
              // switcher (cage-match Carnot+Tesla — this crashed at the fork).
              title: channels.length > 1 &&
                      active != null &&
                      active.kind != ChannelKind.dm
                  ? _ChannelSwitcher(channels: channels, activeId: active.id)
                  : _ConversationTitle(active: active),
              actions: [
                // Narrow has no sidebar, so the row long-press that mutes a
                // conversation on wide does not exist here. Without this the
                // capability would be wide-only — mutable on the desktop, invisible
                // on the phone, which is where a noisy channel is actually felt.
                if (active != null) _MuteConversationAction(conversation: active),
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
                IconButton(
                  tooltip: 'Sign out',
                  icon: const Icon(Icons.logout),
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).logout(),
                ),
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
          if (isWide) ...[
            const ChatSidebar(),
            const VerticalDivider(width: 1),
          ],
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
class _MuteConversationAction extends ConsumerWidget {
  const _MuteConversationAction({required this.conversation});

  final Channel conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Peer-aware, exactly like the sidebar row: a peer-muted DM resized onto a
    // phone was showing "not muted" while its badge was already dead — two
    // surfaces disagreeing about the same conversation, which is the drift this
    // feature's own comments forbid (cage-match #135 round 3, Tesla).
    final mute = watchConversationMute(
      ref,
      conversation.id,
      peerId: conversation.kind == ChannelKind.dm
          ? dmPeerId(ref.watch(channelRosterProvider(conversation.id)).value,
              ref.watch(currentUserProvider)?.userId)
          : null,
    );
    final muted = mute.isMuted;
    // SCOPE DISCLOSURE. When the silence comes from the PERSON rather than this
    // conversation, undoing it makes them audible in every room — a global
    // preference change behind a control captioned "this conversation". The
    // sidebar menu confesses that in its subtitle; this one-tap button had no
    // room to, so it silently performed the bigger act (cage-match #135 round 4,
    // Carnot MEDIUM + Tesla). Here it asks first: the tap surfaces the real scope
    // and the user chooses.
    // Confess whenever a PERSON is one of the causes — not only when they are
    // the sole cause. Gating on `byPeer && !byConversation` left the both-muted
    // case saying "Unmute this conversation" while also restoring that account in
    // every room (cage-match #135 round 5, Tesla). Any unmute that would clear an
    // account mute has to say so.
    final clearsPerson = muted && mute.byPeer;
    return IconButton(
      key: const Key('appbar-mute-conversation'),
      tooltip: muted
          ? (clearsPerson
              ? 'This person is muted everywhere'
              : 'Unmute this conversation')
          : 'Mute this conversation',
      // Bell, not speaker: this app ships 1:1 A/V calls, where a speaker glyph
      // in the chrome reads as "mute the call", a different verb entirely
      // (cage-match #135, Maxwell).
      icon: Icon(muted ? Icons.notifications_off : Icons.notifications_none),
      onPressed: () {
        if (clearsPerson) {
          // BIND BOTH BEFORE THE GAP — the container (not the autoDispose
          // notifier) and the acting principal. This SnackBar lives on the
          // messenger ABOVE the chat surface, so its action can be tapped after
          // Settings, a sign-out, or a user switch. Reading the notifier or the
          // user INSIDE the callback is the very mistake rounds 2-3 removed from
          // the other two doors, reintroduced here when this control was added in
          // round 4 (cage-match #135 round 5, Carnot + Tesla). Late-binding the
          // principal is worse than useless: it compares the new user to the new
          // user, passes, and then dumps the OLD in-memory map onto the NEW
          // user's key.
          final container = ProviderScope.containerOf(context, listen: false);
          final actingUserId = container.read(currentUserProvider)?.userId;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            // Say what the button DOES, not the narrower thing it sounds like:
            // unmuting clears every cause of this row's silence, which includes
            // the account mute that applies in every conversation (cage-match
            // #135 round 6, Carnot — the UI admitted one state change and
            // performed two).
            content: const Text(
                'This person is muted in every conversation. Unmuting affects '
                'all of them.'),
            action: SnackBarAction(
              label: 'Unmute',
              onPressed: () => mute.apply(
                  container.read(mutesProvider.notifier),
                  muted: false,
                  expectUserId: actingUserId),
            ),
          ));
          return;
        }
        // Otherwise synchronous — no async gap, so the write lands in the same
        // frame as the tap and needs no principal binding.
        mute.apply(ref.read(mutesProvider.notifier), muted: !muted);
      },
    );
  }
}

/// The narrow-layout AppBar title for whatever conversation is active when the
/// channel switcher is NOT shown (≤1 channel, or a DM is active). A channel shows
/// its name; a DM shows the peer's handle (roster-resolved, like the sidebar row),
/// since a DM has no name. This exists so a DM id never reaches [_ChannelSwitcher]'s
/// DropdownButton `value` (no matching item → assertion) — narrow DM *entry* stays
/// deferred (#2798 Inc 1); this only titles an already-active DM sanely.
class _ConversationTitle extends ConsumerWidget {
  const _ConversationTitle({required this.active});

  final Channel? active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = active;
    if (a == null) return const Text('Chat');
    if (a.kind != ChannelKind.dm) return Text(a.name);
    final myId = ref.watch(currentUserProvider)?.userId;
    final roster = ref.watch(channelRosterProvider(a.id)).value;
    return Text(dmPeerTitle(roster, myId));
  }
}

/// The app-bar channel picker, shown only when more than one channel exists.
/// Renders the active channel's name with a dropdown of the rest; picking one
/// writes [selectedChannelIdProvider], which re-points the message surface. Menu
/// items decode from the same [channelsProvider] list the repo subscribed to, so
/// every listed channel is already synced and switching is instant.
class _ChannelSwitcher extends ConsumerWidget {
  const _ChannelSwitcher({required this.channels, required this.activeId});

  final List<Channel> channels;
  final String activeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Aggregate unread across every NON-active channel, so the collapsed app-bar
    // switcher carries an at-a-glance "there's unread elsewhere" dot even before
    // the user opens the menu (the closed DropdownButton only shows the active
    // channel's own item, which is always badge-free). Opening the menu then
    // reveals which channel and how many via the per-item counts below.
    final otherUnread = channels
        .where((c) => c.id != activeId)
        .fold<int>(0, (sum, c) => sum + ref.watch(channelUnreadCountProvider(c.id)));

    return Row(
      children: [
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
              icon: const Icon(Icons.arrow_drop_down),
              // M3 AppBar foreground is onSurface, and the menu opens on a
              // surface background — so the inherited onSurface text reads
              // correctly in both the collapsed bar and the open menu.
              items: [
                for (final c in channels)
                  DropdownMenuItem<String>(
                    value: c.id,
                    child: _ChannelMenuItem(
                      channelId: c.id,
                      name: c.name,
                      isActive: c.id == activeId,
                    ),
                  ),
              ],
              onChanged: (id) {
                if (id != null) {
                  ref.read(selectedChannelIdProvider.notifier).select(id);
                }
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
    final unread = isActive ? 0 : ref.watch(channelUnreadCountProvider(channelId));
    // A muted row must say WHY it is quiet here too. `channelUnreadCountProvider`
    // reports 0 for a muted channel, so without this the dropdown renders muted
    // and idle identically — two unread surfaces drawing different conclusions
    // from the same mute state, which is exactly the drift the sidebar glyph was
    // added to prevent (cage-match #135, Carnot HIGH + Tesla).
    final muted = ref.watch(mutedChannelIdsProvider).contains(channelId);
    return Row(
      children: [
        Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
        if (muted) ...[
          const SizedBox(width: 8),
          Icon(Icons.notifications_off_outlined,
              key: Key('muted-item-$channelId'),
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ] else if (unread > 0) ...[
          const SizedBox(width: 8),
          UnreadBadge(key: Key('unread-item-$channelId'), count: unread),
        ],
      ],
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
    final bubbleColor = isMine ? scheme.primaryContainer : scheme.surfaceContainerHighest;

    // Render the sender's CURRENT handle (my own from the live user, others from
    // the channel roster), falling back to the send-time label — so a rename
    // retitles past messages, matching the key-derived avatar below.
    final senderName = senderDisplayName(
      message.sender,
      isMine: isMine,
      myHandle: ref.watch(currentUserProvider)?.username,
      roster: ref.watch(channelRosterProvider(channelId)).value,
    );

    // Sender-action affordance: long-press ANOTHER human's message for the
    // action sheet — call them (#2758), report, or block (#7). Gated to a
    // non-mine message with a real account behind it — you can't call/block
    // yourself or an external actor (LLM/robot have no userId).
    final canActOnSender = !isMine && message.sender.userId != null;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress:
            canActOnSender ? () => showMessageActions(context, ref, message) : null,
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
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
              Icon(Icons.error_outline,
                  size: 14, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 2),
              Text('Retry',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.error)),
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
  const Composer({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();

  /// Active `:shortcode` autocomplete suggestions (#12). Empty ⇒ picker closed.
  List<MapEntry<String, String>> _suggestions = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateSuggestions);
  }

  @override
  void dispose() {
    _controller.removeListener(_updateSuggestions);
    _controller.dispose();
    super.dispose();
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
    final changed = next.length != _suggestions.length ||
        [for (var i = 0; i < next.length; i++) next[i].key != _suggestions[i].key]
            .any((d) => d);
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
            padding: const EdgeInsets.all(8),
            child: Row(
          children: [
            Expanded(
              child: Focus(
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
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            // Keyboard-first composer: physical-keyboard platforms send on Enter
            // (see the Focus onKeyEvent above), so the send button is redundant
            // chrome and is dropped. Touch platforms keep it — a thumb has no
            // reachable Enter-to-send, and the soft keyboard's action key alone
            // isn't a discoverable send affordance.
            if (_showSendButton) ...[
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                icon: const Icon(Icons.send),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontFamily: 'monospace'),
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
