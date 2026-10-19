import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/network/network_status.dart';

/// Tells the transport the moment the network has probably just become usable,
/// so it connects now instead of sleeping out its backoff (#384, #392).
///
/// Backoff only knows time. In Doze every attempt is refused before a socket
/// exists, so it climbs to its 30s ceiling — and then a push lifts the block,
/// the user answers, and the transport is still asleep. Measured on a Pixel
/// 2026-10-19: 11.6s of a 30s answer window lost on one ring, the whole window
/// on the next.
///
/// Two of the three moments live here: the app RESUMING (unlocking after an
/// Answer brings it to the front) and the device coming back ONLINE. The third,
/// a native Answer, is kicked from `SystemCallNavigator._onAction` — the system
/// call action stream is a single-listener EventChannel underneath, and a
/// second subscription here would steal it from the answer path.
///
/// Watched at the root (main.dart) so its lifetime is the app's.
final transportWakeProvider = Provider<void>((ref) {
  void kick(String reason) => ref.read(transportProvider).reconnectNow(reason);

  final lifecycle = AppLifecycleListener(onResume: () => kick('resume'));
  ref.onDispose(lifecycle.dispose);

  // Only the offline → online EDGE. The seed value (null → anything) is not a
  // transition, and online → online never reaches here (`.distinct()`).
  ref.listen<AsyncValue<bool>>(deviceOnlineProvider, (prev, next) {
    if (prev?.value == false && next.value == true) kick('online');
  });
});
