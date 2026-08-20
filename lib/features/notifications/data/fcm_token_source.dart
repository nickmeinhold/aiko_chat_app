import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../domain/device_platform.dart';
import '../domain/push_token_source.dart';

/// Android's [PushTokenSource] — Firebase Cloud Messaging.
///
/// ANDROID ONLY, AND THE GUARD IS IN THE CONSTRUCTOR RATHER THAN A COMMENT.
/// FlutterFire will happily hand you an APNs-backed token on Apple platforms,
/// which is precisely the outcome the transport split exists to prevent: it
/// would route iOS pushes through Google on the one platform where Apple is
/// already a mandatory intermediary, and it would do so INVISIBLY — the token
/// registers, the island stores it under `platform=fcm`, and everything appears
/// to work. There is no failing test for "we quietly added a second
/// intermediary", so the assertion is the alarm.
///
/// See [DevicePlatform] for the reasoning and claude-tasks#3267 for the island
/// half that consumes these tokens.
class FcmTokenSource implements PushTokenSource {
  FcmTokenSource({TargetPlatform? platformOverride})
      : assert(
          (platformOverride ?? defaultTargetPlatform) == TargetPlatform.android,
          'FcmTokenSource is Android-only. On Apple platforms the APNs device '
          'token is taken natively so that Google is not in the path — see '
          'DevicePlatform. If you are here to "just make it work on iOS", that '
          'is the decision this assertion exists to make you take deliberately.',
        );

  /// Initialise Firebase for this process. Safe to call more than once.
  ///
  /// Deliberately NOT called from `main()` unconditionally: `initializeApp` on
  /// an Apple platform would look for a `GoogleService-Info.plist` that this
  /// project does not ship and must never ship.
  static Future<void> ensureInitialized() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  }

  @override
  DevicePlatform get platform => DevicePlatform.fcm;

  @override
  Future<bool> requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    return switch (settings.authorizationStatus) {
      // PROVISIONAL COUNTS. It means the user has not been asked yet but
      // delivery is allowed quietly — a device that can be reached, which is
      // the only question this method answers. Treating it as a refusal would
      // register nothing and make the quiet-delivery state unreachable.
      AuthorizationStatus.authorized || AuthorizationStatus.provisional => true,
      AuthorizationStatus.denied || AuthorizationStatus.notDetermined => false,
    };
  }

  @override
  Future<String?> currentToken() => FirebaseMessaging.instance.getToken();

  @override
  Stream<String> tokenRefreshes() => FirebaseMessaging.instance.onTokenRefresh;
}
