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
class _MuteGesture extends ConsumerWidget {
  const _MuteGesture({
    super.key,
    required this.mute,
    required this.child,
  });

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
  }) async {
    final muted = mute.isMuted;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
          (at + const Offset(8, 8)) & Size.zero, Offset.zero & overlay.size),
      items: [
        PopupMenuItem<bool>(
          value: !muted,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(muted
                ? Icons.notifications_none
                : Icons.notifications_off_outlined),
            title: Text(muted ? 'Unmute' : 'Mute'),
            // Say WHICH silence this undoes when it is the person rather than
            // the conversation — otherwise "Unmute" on a peer-muted DM looks
            // like it did nothing to the conversation the user was thinking of.
            subtitle: Text(muted
                ? (mute.byPeer && !mute.byConversation
                    ? 'This person is muted everywhere — unmute them'
                    : 'Show unread again')
                : 'No unread badge'),
          ),
        ),
      ],
    );
    // An absolute target state (`!muted` captured at open time), never a
    // toggle: if the mute changed while the menu was open, this write is an
    // idempotent no-op rather than an inversion of someone else's change.
    if (picked == null) return;
    mute.apply(container.read(mutesProvider.notifier),
        muted: picked, expectUserId: expectUserId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final container = ProviderScope.containerOf(context, listen: false);
    // Bound HERE, before the menu can be opened, so a pick that lands after a
    // logout/user-switch is dropped rather than written into another account
    // (cage-match #135 round 3, Tesla).
    final expectUserId = ref.watch(currentUserProvider)?.userId;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressEnd: (d) => _show(context, container,
          expectUserId: expectUserId, at: d.globalPosition),
      // Pointer-UP for the same reason as the long-press. NOTE for Flutter web
      // (cage-match #135, Tesla): the browser raises its own context menu on
      // right-click, so on web this can double up until that default is
      // suppressed — harmless (two menus, one intent) and the app's shipping
      // targets are macOS/iOS/Android.
      onSecondaryTapUp: (d) => _show(context, container,
          expectUserId: expectUserId, at: d.globalPosition),
      child: child,
    );
  }
}

/// The trailing slot of a sidebar row: an unread badge, or — when the row is
/// muted — a quiet mute glyph, so a silent conversation reads as *muted* rather
/// than as *nothing happening*. The badge is never shown for a muted row because
/// [channelUnreadCountProvider] already reports 0 there; this only makes the
/// reason legible.
Widget? _rowTrailing(
  BuildContext context, {
  required String id,
  required int unread,
  required bool muted,
}) {
  if (muted) {
    // A BELL, not a speaker. This app ships 1:1 LiveKit calls, where a
    // speaker-with-slash is the universal glyph for muting call audio — a
    // different verb entirely from "stop badging this conversation". The
    // notification glyph is what Slack and Discord use for exactly this.
    return Icon(Icons.notifications_off_outlined,
        key: Key('sidebar-muted-$id'),
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant);
  }
  return unread > 0
      ? UnreadBadge(key: Key('sidebar-unread-$id'), count: unread)
      : null;
}

class ChatSidebar extends ConsumerWidget {
  const ChatSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final channelsAsync = ref.watch(channelsProvider);
    final channels = channelsAsync.value ?? const <Channel>[];
    final dms = ref.watch(visibleDmsProvider);
    final selectedId = ref.watch(selectedChannelIdProvider);
    final active =
        ChatScreen.resolveActive(ref.watch(navigableChannelsProvider), selectedId);

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
                    // Empty only when BOTH sources are empty — a user with no
                    // channels but open DMs still sees their DM section (#2798).
                    if (channels.isEmpty && dms.isEmpty) {
                      return const Center(child: Text('No channels yet.'));
                    }
                    // Channels and DMs share ONE scrollable list (the DM section
                    // sits below the channel list, per the design anchor) so a long
                    // combined list scrolls as a unit rather than overflowing a
                    // fixed slot.
                    return ListView(
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: kSidebarTileInset),
                      children: [
                        for (final c in channels)
                          _SidebarChannelTile(
                            channel: c,
                            selected: c.id == active?.id,
                          ),
                        if (dms.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
                            child: Text(
                              'Direct messages',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          for (final d in dms)
                            _SidebarDmTile(dm: d, selected: d.id == active?.id),
                        ],
                      ],
                    );
                  },
                ),
              ),
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
    // No peer: a group channel is silenced only by its own mute.
    final mute = watchConversationMute(ref, channel.id);
    return _MuteGesture(
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
            : () =>
                ref.read(selectedChannelIdProvider.notifier).select(channel.id),
      ),
    );
  }
}

/// One DM row in the Direct-messages section. A DM has no server `name`
/// (identity=key, ADR-0004: a DM's title IS the peer), so the label is the peer's
/// CURRENT handle, resolved from the channel roster the SAME way message sender
/// names resolve ([channelRosterProvider], PR #127) — a rename retitles the row.
/// Selection routes through the SAME mutator as channels and the dropdown. A
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
    final mute = watchConversationMute(ref, dm.id, peerId: dmPeerId(roster, myId));
    return _MuteGesture(
      key: Key('mute-gesture-${dm.id}'), // see _SidebarChannelTile — slot vs identity
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
            : () => ref.read(selectedChannelIdProvider.notifier).select(dm.id),
      ),
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
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
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
