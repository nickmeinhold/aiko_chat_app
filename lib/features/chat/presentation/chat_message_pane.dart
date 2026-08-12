/// The shared message pane: the connection banner, the message list, and the
/// composer for the active channel. Hosted by BOTH responsive branches (narrow
/// phone layout and wide sidebar layout) as the LAST child of a `Row`, so the
/// pane's Element + State (`_MessageListState._scrollController`,
/// `_ComposerState._controller`) survive a resize across the breakpoint — see
/// [ChatScreen] for the Option-A crossing rationale.
///
/// The load-bearing ValueKeys — `MessageList(key: ValueKey(active.id))` and
/// `Composer(key: ValueKey('composer-${active.id}'))` — force a dispose→recreate
/// per channel so scroll position resets and drafts don't bleed on a switch
/// (cage-match #106). The `NetworkStatusBanner` sits ABOVE the `when(...)` branch
/// so it stays visible in every state — including the offline empty-cache case
/// ("No channels yet"), where it's the only thing explaining WHY the workspace
/// looks empty (Carnot, PR #72).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/network_status_banner.dart';
import '../application/chat_providers.dart';
import 'chat_screen.dart';

class ChatMessagePane extends ConsumerWidget {
  const ChatMessagePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(channelsProvider);
    final selectedId = ref.watch(selectedChannelIdProvider);
    // Active over channels ∪ DMs so a selected DM renders (#2798); the channel
    // load/error gating below still keys off channelsProvider.
    final active =
        ChatScreen.resolveActive(ref.watch(navigableChannelsProvider), selectedId);

    return Column(
      children: [
        const NetworkStatusBanner(),
        Expanded(
          child: channelsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                Center(child: Text('Could not load channels.\n$e')),
            data: (_) {
              if (active == null) {
                return const Center(child: Text('No channels yet.'));
              }
              return Column(
                children: [
                  // No channel header in the wide layout (the sidebar already
                  // names + switches channels) nor the narrow layout (its AppBar
                  // does). The redundant per-pane bar is gone; the A/V call
                  // affordance lives on the message long-press action sheet
                  // (message_actions.dart → "Call <name>", #2758).
                  // Key by channel id so a switch gives MessageList a FRESH
                  // State (dispose→recreate) — otherwise the old channel's
                  // ScrollController carries over and lands the new channel at a
                  // stale offset (cage-match #106).
                  Expanded(
                    child: MessageList(
                      key: ValueKey(active.id),
                      channelId: active.id,
                    ),
                  ),
                  // Keyed like MessageList so each channel gets its OWN composer
                  // state — without this a draft typed in one channel rides into
                  // the next (and sends there) (cage-match #106).
                  Composer(
                    key: ValueKey('composer-${active.id}'),
                    channelId: active.id,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
