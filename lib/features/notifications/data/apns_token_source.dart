import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/device_platform.dart';
import '../domain/push_environment.dart';
import '../domain/push_token_source.dart';

/// Apple's [PushTokenSource] — the RAW APNs device token, taken from Apple
/// directly over a platform channel implemented in `ios/Runner/AppDelegate.swift`.
///
/// APPLE ONLY, AND THE GUARD IS IN THE CONSTRUCTOR rather than a comment, exactly
/// as in [FcmTokenSource]. The two are mirror images: each asserts it is not
/// being used on the other's platform, because the failure of getting that wrong
/// is silent in both directions — a token registers, the island stores it under
/// some `platform`, and everything appears to work while pushes go to a service
/// that has never heard of this device.
///
/// Deliberately NOT FlutterFire. Firebase will relay to APNs for you, which
/// would add Google as a SECOND intermediary on the one platform where Apple is
/// already a mandatory one. See [DevicePlatform] for the full argument.
class ApnsTokenSource implements PushTokenSource {
  ApnsTokenSource({
    TargetPlatform? platformOverride,
    MethodChannel? methods,
    EventChannel? refreshes,
  }) : assert(
         const {
           TargetPlatform.iOS,
           TargetPlatform.macOS,
         }.contains(platformOverride ?? defaultTargetPlatform),
         'ApnsTokenSource is Apple-only. There is no APNs on Android — the '
         'token comes from FCM there (see FcmTokenSource and DevicePlatform).',
       ),
       _methods = methods ?? const MethodChannel(_methodChannelName),
       _refreshes = refreshes ?? const EventChannel(_eventChannelName);

  static const _methodChannelName = 'cc.imagineering.aikoChatApp/apns';
  static const _eventChannelName = 'cc.imagineering.aikoChatApp/apns/refreshes';

  final MethodChannel _methods;
  final EventChannel _refreshes;

  @override
  DevicePlatform get platform => DevicePlatform.apns;

  @override
  Future<bool> requestPermission() async {
    // A MissingPluginException here means the native half is not in the build —
    // a `.swift` outside the Runner target, or a platform we do not implement.
    // Answering "not granted" degrades reach and nothing else, which is the
    // contract: declining notifications must never be able to fail a sign-in,
    // and neither must a missing channel.
    try {
      return await _methods.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException catch (e) {
      debugPrint('ApnsTokenSource: permission request failed: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint(
        'ApnsTokenSource: native APNs channel is not in this build: $e',
      );
      return false;
    }
  }

  @override
  Future<String?> currentToken() async {
    try {
      return await _methods.invokeMethod<String>('currentToken');
    } on PlatformException catch (e) {
      debugPrint('ApnsTokenSource: no device token: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint(
        'ApnsTokenSource: native APNs channel is not in this build: $e',
      );
      return null;
    }
  }

  @override
  Future<PushEnvironment?> pushEnvironment() async {
    try {
      return PushEnvironment.fromWire(
        await _methods.invokeMethod<String>('pushEnvironment'),
      );
    } on PlatformException catch (e) {
      debugPrint('ApnsTokenSource: no push environment: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint(
        'ApnsTokenSource: native APNs channel is not in this build: $e',
      );
      return null;
    }
  }

  @override
  Stream<String> tokenRefreshes() => _refreshes
      .receiveBroadcastStream()
      .map((event) => event as String)
      // A rotation stream that ERRORS would take the registrar's subscription
      // down with it, and the registrar would then be deaf to every later
      // rotation for the life of the session — silently, since nothing surfaces
      // a dead stream. Dropping the bad event keeps the subscription alive.
      .handleError(
        (Object e) => debugPrint('ApnsTokenSource: rotation stream error: $e'),
      );
}
