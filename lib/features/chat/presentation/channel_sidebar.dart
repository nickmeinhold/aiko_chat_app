/// The wide-layout left rail (Slack/Element style): a server switcher at the
/// top, the channel list in the middle, and a settings/sign-out footer at the
/// bottom. Shown ONLY on wide screens ([ChatScreen] forks on width); the narrow
/// phone layout keeps its app-bar dropdown, unchanged.
///
/// A custom widget (NOT `NavigationRail`) because channels are text names +
/// unread badges, not icons. Channel selection routes through the EXACT same
/// mutator the dropdown uses (`selectedChannelIdProvider.notifier.select`), and
/// per-channel unread reads `channelUnreadCountProvider` (the distinct unread
/// stream), so both invariants that shipped through cage-matches #106/#109 hold
/// verbatim.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../settings/application/gateway_directory_provider.dart';
import '../../settings/data/gateway_directory_client.dart';
import '../../settings/presentation/gateway_switch_action.dart';
import '../application/chat_providers.dart';
import '../domain/channel.dart';
import 'chat_screen.dart';

class ChatSidebar extends ConsumerWidget {
  const ChatSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final channelsAsync = ref.watch(channelsProvider);
    final channels = channelsAsync.value ?? const <Channel>[];
    final selectedId = ref.watch(selectedChannelIdProvider);
    final active = ChatScreen.resolveActive(channels, selectedId);

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
              const _ServerSwitcher(),
              const Divider(height: 1),
              Expanded(
                child: channelsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Could not load channels.\n$e'),
                  ),
                  data: (_) {
                    if (channels.isEmpty) {
                      return const Center(child: Text('No channels yet.'));
                    }
                    return ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        for (final c in channels)
                          _SidebarChannelTile(
                            channel: c,
                            selected: c.id == active?.id,
                          ),
                      ],
                    );
                  },
                ),
              ),
              // DMs slot (deferred): a direct-messages section will mount here,
              // below the channel list and above the footer. Intentionally no
              // dead UI shipped — only this anchor.
              const Divider(height: 1),
              const _SidebarFooter(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One channel row. Selection calls the SAME mutator as the app-bar dropdown
/// (`selectedChannelIdProvider.notifier.select`), and unread reads
/// `channelUnreadCountProvider` (never `messagesProvider`) — the active channel
/// is never badged, mirroring `_ChannelMenuItem`.
class _SidebarChannelTile extends ConsumerWidget {
  const _SidebarChannelTile({required this.channel, required this.selected});

  final Channel channel;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread =
        selected ? 0 : ref.watch(channelUnreadCountProvider(channel.id));
    return ListTile(
      key: Key('sidebar-channel-${channel.id}'),
      selected: selected,
      dense: true,
      leading: const Icon(Icons.tag, size: 20),
      title: Text(channel.name, overflow: TextOverflow.ellipsis),
      trailing: unread > 0
          ? UnreadBadge(key: Key('sidebar-unread-${channel.id}'), count: unread)
          : null,
      onTap: selected
          ? null
          : () =>
              ref.read(selectedChannelIdProvider.notifier).select(channel.id),
    );
  }
}

/// The top-of-rail server switcher. Shows the current gateway; opens a menu of
/// `knownGatewaysProvider` ∪ `gatewayDirectoryProvider` (same source as the
/// picker), plus a "Custom / other servers…" escape to the full picker. A
/// different selection routes through the shared [confirmAndSwitchGateway] so the
/// confirm dialog can't drift from the picker's.
class _ServerSwitcher extends ConsumerWidget {
  const _ServerSwitcher();

  static const _customValue = '__custom__';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = ref.watch(configProvider).httpBaseUrl;
    // Seed-first: render the known set immediately, overlay the live directory
    // once it lands — identical to the picker so the two lists agree.
    final known = ref.watch(knownGatewaysProvider);
    final servers = ref.watch(gatewayDirectoryProvider).maybeWhen(
          data: (directory) => mergeDirectory(
            directory,
            known,
            normalize: (url) => GatewayConfig.normalized(url).httpBaseUrl,
          ),
          orElse: () => known,
        );
    final currentEntry = servers
        .where((e) =>
            GatewayConfig.normalized(e.httpBaseUrl).httpBaseUrl == current)
        .firstOrNull;
    final currentLabel = currentEntry?.label ?? _hostOf(current);

    return PopupMenuButton<String>(
      tooltip: 'Switch server',
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == _customValue) {
          context.push('/settings/gateway');
          return;
        }
        final entry = servers
            .where((e) => e.httpBaseUrl == value)
            .firstOrNull;
        if (entry == null) return;
        confirmAndSwitchGateway(context, ref,
            url: entry.httpBaseUrl, label: entry.label);
      },
      itemBuilder: (context) => [
        for (final e in servers)
          CheckedPopupMenuItem<String>(
            value: e.httpBaseUrl,
            checked:
                GatewayConfig.normalized(e.httpBaseUrl).httpBaseUrl == current,
            child: Text(e.label, overflow: TextOverflow.ellipsis),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: _customValue,
          child: Text('Custom / other servers…'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Icon(Icons.dns_outlined,
                size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Server',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  Text(currentLabel,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  /// The host for the fallback label when the current gateway isn't a named
  /// entry — parsed defensively, falling back to the raw value.
  static String _hostOf(String httpBaseUrl) {
    final host = Uri.tryParse(httpBaseUrl)?.host;
    return (host == null || host.isEmpty) ? httpBaseUrl : host;
  }
}

/// The rail footer: Settings + Sign out — the actions that live in the app bar
/// on narrow, moved here off the wide app bar.
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
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }
}
