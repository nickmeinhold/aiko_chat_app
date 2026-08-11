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
import '../../call/presentation/call_screen.dart' show pushCall;
import '../application/chat_providers.dart';
import '../domain/channel.dart';
import 'chat_screen.dart';

class ChatMessagePane extends ConsumerWidget {
  const ChatMessagePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(channelsProvider);
    final selectedId = ref.watch(selectedChannelIdProvider);
    final channels = channelsAsync.value ?? const <Channel>[];
    final active = ChatScreen.resolveActive(channels, selectedId);

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
                  // A/V call header — renders in BOTH layouts (the wide layout
                  // has no AppBar). The call affordance itself is gated to DM
                  // channels (#19): the island only mints a video token for a
                  // private DM (kind == dm), so offering it on a standard channel
                  // just 503s. Non-DM channels still get the header (the name),
                  // minus the videocam.
                  _CallHeader(
                    channelId: active.id,
                    channelName: active.name,
                    canCall: active.kind == ChannelKind.dm,
                  ),
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

/// A slim header above the message list carrying the channel name and the A/V
/// call affordance. Present in both responsive layouts (the wide layout has no
/// AppBar). Tapping the camera pushes the full-screen [CallScreen] for this
/// channel (the LiveKit room == the channel id, handoff #2726).
class _CallHeader extends StatelessWidget {
  const _CallHeader({
    required this.channelId,
    required this.channelName,
    required this.canCall,
  });

  final String channelId;
  final String channelName;

  /// Whether to show the video-call affordance. Gated to DM channels (#19) —
  /// the island refuses a video token on anything but a private DM.
  final bool canCall;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    channelName,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (canCall)
                  IconButton(
                    icon: const Icon(Icons.videocam_outlined),
                    tooltip: 'Start a video call',
                    // Single-door guard against duplicate CallScreen mounts (#18).
                    onPressed: () => pushCall(context, channelId),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
