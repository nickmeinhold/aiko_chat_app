
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notification_tap_source.dart';

/// This platform's tap source, or null where notifications cannot be tapped.
///
/// `kIsWeb` FIRST, before any platform test — the same trap `pushTokenSource`
/// documents: on Flutter web `defaultTargetPlatform` reports the BROWSER'S host
/// OS, so Chrome on an Android handset answers `TargetPlatform.android` and this
/// would construct an FCM source inside a renderer with no FCM behind it.
final notificationTapSourceProvider = Provider<NotificationTapSource?>((ref) {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => FcmNotificationTapSource(),
    TargetPlatform.iOS => ApnsNotificationTapSource(),
    _ => null,
  };
});

/// A tapped call notification's channel id, HELD until something can act on it.
///
/// **Why a buffer rather than navigating from the tap.** The destination is
/// `selectedChannelIdProvider`, which is `autoDispose` ON PURPOSE — it is torn
/// down on logout so a previous user's pick cannot leak into the next session
/// (cage-match #106, Carnot + Tesla). Writing to it from here, app-wide and
/// above the router, would create it with nothing watching, set it, and let it
/// dispose immediately — the pick silently lost. Making this listener *watch* it
/// instead would keep it alive across logout and reintroduce exactly the leak
/// that cage-match closed.
///
/// So the tap waits here, and the chat screen consumes it when it mounts. That
/// also solves the ordering for free: on a cold start caused BY the tap, the tap
/// arrives long before any screen exists, and a buffer is the only thing that can
/// hold it. It is the same shape as the `pending` slot in
/// `NotificationTapChannel` on the Swift side, one layer up.
///
/// KEEP-ALIVE, deliberately: an autoDispose buffer would be collected in the gap
/// between the tap arriving and the first screen mounting, which is the gap it
/// exists to span.
final pendingCallTapProvider = NotifierProvider<PendingCallTap, String?>(
  PendingCallTap.new,
);

class PendingCallTap extends Notifier<String?> {
  @override
  String? build() {
    final source = ref.watch(notificationTapSourceProvider);
    if (source == null) return null;
    final sub = source.taps.listen((channelId) => state = channelId);
    ref.onDispose(sub.cancel);
    return null;
  }

  /// Take the pending tap, clearing it. Returns null when there is none.
  ///
  /// Take-once: a tap is a one-shot navigation intent, and leaving it set would
  /// re-snap the user to that conversation on every subsequent rebuild — a
  /// conversation they may have deliberately navigated away from.
  String? take() {
    final held = state;
    if (held != null) state = null;
    return held;
  }
}
