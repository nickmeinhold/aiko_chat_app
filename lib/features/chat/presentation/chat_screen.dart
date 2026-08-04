import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/mark/mark_avatar.dart';
import '../../auth/application/auth_controller.dart';
import '../../moderation/presentation/message_actions.dart';
import '../application/chat_providers.dart';
import '../domain/channel.dart';
import '../domain/message.dart';
import 'channel_sidebar.dart';
import 'chat_message_pane.dart';

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
    final active = resolveActive(channels, selectedId);

    // If the picked channel leaves the list (removed / renamed-away on a refetch),
    // clear the pick so the Notifier and the UI agree. Without this the resolver
    // heals only the DISPLAY (falls back to first) while the stale id lingers, so a
    // channel that later reappears would snap the user back to a selection they
    // never re-made (cage-match #106, Tesla). ref.listen fires outside build, so
    // mutating the selection notifier here is safe. Runs in BOTH layouts (it's
    // above the width fork).
    ref.listen(channelsProvider, (_, next) {
      final ids = next.value?.map((c) => c.id).toSet();
      final sel = ref.read(selectedChannelIdProvider);
      if (sel != null && ids != null && !ids.contains(sel)) {
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
              title: channels.length > 1 && active != null
                  ? _ChannelSwitcher(channels: channels, activeId: active.id)
                  : Text(active?.name ?? 'Chat'),
              actions: [
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
    return Row(
      children: [
        Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
        if (unread > 0) ...[
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
            return MessageTile(message: m, isMine: m.sender.userId == myUserId);
          },
        );
      },
    );
  }
}

/// One message bubble: sender + body, right-aligned when it's mine, with a
/// delivery indicator and an inline Retry when a send failed (W5).
class MessageTile extends ConsumerWidget {
  const MessageTile({super.key, required this.message, required this.isMine});

  final Message message;
  final bool isMine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isMine ? scheme.primaryContainer : scheme.surfaceContainerHighest;

    // Moderation affordance (#7): long-press ANOTHER human's message to
    // report/block. Gated to a non-mine message with a real account behind it —
    // you can't block yourself or an external actor (LLM/robot have no userId).
    final canModerate = !isMine && message.sender.userId != null;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress:
            canModerate ? () => showMessageActions(context, ref, message) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(12),
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
                      message.sender.displayLabel,
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
                    style: Theme.of(context).textTheme.labelSmall,
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
        return const Icon(Icons.check, size: 14);
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty) return;
    _controller.clear(); // optimistic: clear immediately, the row is durable
    final repo = await ref.read(chatRepositoryProvider.future);
    await repo.sendMessage(widget.channelId, body);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
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
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
