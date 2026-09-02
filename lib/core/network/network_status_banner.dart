import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/maritime_theme.dart';
import 'network_status.dart';

/// A slim, full-width banner that appears ONLY when the network is in trouble —
/// red when the device is offline, amber when on a network but the gateway is
/// unreachable — and renders nothing when online. Driven by the streaming
/// [networkStatusProvider], so it updates live on every connectivity/socket
/// change. Mounted on both the login screen (pre-auth) and chat screen
/// (post-auth); the provider picks the right reachability source for each.
class NetworkStatusBanner extends ConsumerWidget {
  const NetworkStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(networkStatusProvider);
    // Theme-aware status tints: the scheme's error (maritime signal-red / the
    // light theme's red) for offline, beacon-amber for a reachable-but-degraded
    // gateway — so the banner reads correctly in both light and dark.
    final errorColor = Theme.of(context).colorScheme.error;
    final (String label, Color color)? banner = switch (status) {
      NetworkStatus.online => null, // healthy → no chrome
      NetworkStatus.offline => ("You're offline", errorColor),
      NetworkStatus.serverUnreachable => (
        "Can't reach the island",
        kMaritimeBeaconAmber,
      ),
    };
    if (banner == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: banner.$2.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Text(banner.$1, textAlign: TextAlign.center),
    );
  }
}
