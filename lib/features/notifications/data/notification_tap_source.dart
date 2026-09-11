import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel ids of TAPPED call notifications (claude-tasks#3588).
///
/// Two platforms, two mechanisms, one stream — and the split is forced, not
/// stylistic. See [ApnsNotificationTapSource] and [FcmNotificationTapSource].
abstract class NotificationTapSource {
  /// Channel ids from notifications the user tapped. Emits at most once per tap,
  /// and MAY emit before the first frame — a cold start caused BY the tap is the
  /// case this whole path exists for.
  Stream<String> get taps;
}

/// **THE PAYLOAD KEY IS `c`, ONE CHARACTER**, on both platforms. The island
/// sends `{"aps": {...}, "c": "<channel_id>"}` and nothing else; the short name
/// is deliberate there (a 4KB APNs ceiling). Reading `channel_id` yields null,
/// routes nowhere, and reports no problem.
const kTapChannelKey = 'c';

/// Apple's tap source: an `EventChannel` fed by the
/// `UNUserNotificationCenterDelegate` in `ios/Runner/AppDelegate.swift`.
///
/// NOT FlutterFire, for the same reason [ApnsTokenSource] is not: our iOS pushes
/// come from the island straight to APNs, so Firebase is not in the path and its
/// `onMessageOpenedApp` never fires for them. Verified rather than assumed —
/// this app ships no `GoogleService-Info.plist` and logs
/// "App Delegate Proxy is disabled" at launch, so FlutterFire could not see an
/// APNs tap here even if we asked it to.
class ApnsNotificationTapSource implements NotificationTapSource {
  ApnsNotificationTapSource({
    TargetPlatform? platformOverride,
    EventChannel? taps,
  }) : assert(
         const {
           TargetPlatform.iOS,
           TargetPlatform.macOS,
         }.contains(platformOverride ?? defaultTargetPlatform),
         'ApnsNotificationTapSource is Apple-only; Android taps arrive through '
         'FcmNotificationTapSource.',
       ),
       _taps = taps ?? const EventChannel(_eventChannelName);

  static const _eventChannelName =
      'cc.imagineering.aikoChatApp/notifications/taps';

  final EventChannel _taps;

  @override
  Stream<String> get taps => _taps
      .receiveBroadcastStream()
      .where((e) => e is String && e.isNotEmpty)
      .cast<String>();
}

/// Android's tap source.
///
/// Two calls, and BOTH are needed for different app states — this is the part
/// that is easy to half-build:
///  * [FirebaseMessaging.instance.getInitialMessage] — the app was TERMINATED
///    and the tap launched it. Returns once, then never again.
///  * [FirebaseMessaging.onMessageOpenedApp] — the app was BACKGROUNDED and the
///    tap resumed it.
/// Implement only the second and a tap from a killed app silently does nothing,
/// which is the exact state a call notification is most likely to arrive in.
class FcmNotificationTapSource implements NotificationTapSource {
  FcmNotificationTapSource({
    TargetPlatform? platformOverride,
    FirebaseMessaging? messaging,
  }) : assert(
         (platformOverride ?? defaultTargetPlatform) == TargetPlatform.android,
         'FcmNotificationTapSource is Android-only; Apple taps arrive through '
         'ApnsNotificationTapSource.',
       ),
       _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  @override
  Stream<String> get taps async* {
    final launched = await _messaging.getInitialMessage();
    final fromLaunch = _channelIdOf(launched?.data);
    if (fromLaunch != null) yield fromLaunch;
    yield* FirebaseMessaging.onMessageOpenedApp
        .map((m) => _channelIdOf(m.data))
        .where((id) => id != null)
        .cast<String>();
  }

  static String? _channelIdOf(Map<String, dynamic>? data) {
    final raw = data?[kTapChannelKey];
    return (raw is String && raw.isNotEmpty) ? raw : null;
  }
}
