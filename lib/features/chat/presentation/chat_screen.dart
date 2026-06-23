import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../application/chat_providers.dart';
import '../data/transport/chat_transport.dart';
import '../domain/message.dart';

/// The single-channel Phase-1 chat surface: channel header + logout, a thin
/// connection banner, the message list, and the composer. The default channel
/// is the first one the gateway returns (a single seeded "general" in Phase 1).
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(channelsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(channelsAsync.value?.firstOrNull?.name ?? 'Chat'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: channelsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load channels.\n$e')),
        data: (channels) {
          final channel = channels.firstOrNull;
          if (channel == null) {
            return const Center(child: Text('No channels yet.'));
          }
          return Column(
            children: [
              const ConnectionBanner(),
              Expanded(child: MessageList(channelId: channel.id)),
              Composer(channelId: channel.id),
            ],
          );
        },
      ),
    );
  }
}

/// A thin status strip shown only while the realtime link is not `connected`.
/// `unauthenticated` is intentionally NOT surfaced here — the auth controller
/// turns that into a logout, so the router has already left this screen.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectionStateProvider).value;
    final (String label, Color color)? banner = switch (state) {
      ConnectionState.connecting => ('Connecting…', Colors.orange),
      ConnectionState.disconnected => ('Offline — reconnecting…', Colors.grey),
      _ => null, // connected / unauthenticated / null → no banner
    };
    if (banner == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: banner.$2.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(banner.$1, textAlign: TextAlign.center),
    );
  }
}

/// The reactive message list for [channelId]. Rows are ascending (oldest first);
/// the list sits at the bottom (newest) since chat reads bottom-up.
class MessageList extends ConsumerWidget {
  const MessageList({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(messagesProvider(channelId));
    final myUserId = ref.watch(currentUserProvider)?.userId;

    return messagesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load messages.\n$e')),
      data: (messages) {
        if (messages.isEmpty) {
          return const Center(child: Text('No messages yet. Say hello!'));
        }
        return ListView.builder(
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

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
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
            Text(
              message.sender.displayLabel,
              style: Theme.of(context).textTheme.labelSmall,
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
    );
  }

  static String _formatTime(DateTime t) {
    final l = t.toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '$h:$m';
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
