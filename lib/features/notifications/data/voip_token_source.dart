import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../application/push_telemetry.dart';
import '../domain/apns_environment.dart';
import '../domain/device_platform.dart';
import '../domain/push_token_source.dart';
import '../domain/token_kind.dart';

/// The PushKit VoIP token — the one the island rings a locked handset with.
///
/// A SECOND, INDEPENDENT SOURCE alongside [ApnsTokenSource], not a mode of it.
/// PushKit is a separate registry with its own token, its own rotation
/// callbacks and its own permission story, and the two tokens are
/// simultaneously live on one device. Modelling this as a flag on the APNs
/// source would make "which registry issued this string" a thing you infer
/// instead of a thing the type says, and the failure of inferring it wrong is
/// silent: the island stores a token under the wrong `token_kind` and the
/// handset simply never rings.
///
/// **[DevicePlatform.apns], NOT a third platform value.** The island must talk
/// to Apple either way — the split is in what the push DOES on arrival, which is
/// [TokenKind]'s axis. `token_kind` and `platform` are orthogonal and collapsing
/// them produces a value Android could structurally never hold, which is the
/// tell that it is the wrong axis. The island agrees and it is the binding
/// contract: its `TokenKind` is a separate column, not a third `Platform`
/// member.
class VoipTokenSource implements PushTokenSource {
  VoipTokenSource({
    TargetPlatform? platformOverride,
    MethodChannel? methods,
    EventChannel? refreshes,
    MethodChannel? apnsMethods,
    PushTelemetry telemetry = PushTelemetry.noop,
  }) : _telemetry = telemetry,
       assert(
         const {
           TargetPlatform.iOS,
           TargetPlatform.macOS,
         }.contains(platformOverride ?? defaultTargetPlatform),
         'VoipTokenSource is Apple-only. PushKit does not exist on Android — '
         'the equivalent there is a high-priority FCM message plus a '
         'full-screen intent (design 12 Decision 8).',
       ),
       _methods = methods ?? const MethodChannel(_methodChannelName),
       _refreshes = refreshes ?? const EventChannel(_eventChannelName),
       _apnsMethods = apnsMethods ?? const MethodChannel(_apnsChannelName);

  static const _methodChannelName = 'cc.imagineering.aikoChatApp/pushkit';
  static const _eventChannelName =
      'cc.imagineering.aikoChatApp/pushkit/refreshes';

  /// The APNs channel, borrowed for ONE question: which APNs host will accept
  /// this build's tokens.
  ///
  /// That answer is a property of the PROVISIONING PROFILE stapled to the
  /// binary, not of the registry the token came from — both registries mint
  /// tokens for the same environment because there is only one binary. Asking
  /// the existing channel is therefore reading the fact itself; adding a second
  /// `apnsEnvironment` to the PushKit channel would be a second copy of one
  /// value, and two copies of one fact is the drift shape this repo keeps
  /// paying for.
  static const _apnsChannelName = 'cc.imagineering.aikoChatApp/apns';

  final PushTelemetry _telemetry;
  final MethodChannel _methods;
  final EventChannel _refreshes;
  final MethodChannel _apnsMethods;

  @override
  TokenKind get kind => TokenKind.voip;

  @override
  DevicePlatform get platform => DevicePlatform.apns;

  /// **ALWAYS TRUE, AND IT IS NOT A STUB.** A PushKit VoIP token requires no
  /// user permission at all — there is no prompt to show and nothing to decline.
  ///
  /// This is the asymmetry that makes *"reachable for calls, unreachable for
  /// messages"* a normal and permanent state rather than an error: a user who
  /// declines notifications has a VoIP token and will never have an alert token.
  /// Returning false here to mirror [ApnsTokenSource] would make that user
  /// unreachable for calls too, which is precisely backwards — the ring is the
  /// thing they did not decline.
  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<String?> currentToken() async {
    try {
      return await _methods.invokeMethod<String>('currentToken');
    } on PlatformException catch (e) {
      _telemetry.tokenUnavailable('pushkit', e);
      return null;
    } on MissingPluginException catch (e) {
      // The native half is not in this build. Degrades reach and nothing else,
      // exactly as on the alert path: a missing channel must never be able to
      // fail a sign-in.
      _telemetry.nativeChannelMissing('pushkit', e);
      return null;
    }
  }

  @override
  Future<ApnsEnvironment?> apnsEnvironment() async {
    try {
      return ApnsEnvironment.fromApsEnvironment(
        await _apnsMethods.invokeMethod<String>('apnsEnvironment'),
      );
    } on PlatformException catch (e) {
      _telemetry.environmentUnresolved(e);
      return null;
    } on MissingPluginException catch (e) {
      _telemetry.nativeChannelMissing('pushkit', e);
      return null;
    }
  }

  @override
  Stream<String> tokenRefreshes() => _refreshes
      .receiveBroadcastStream()
      .map((event) => event as String)
      // Dropping a bad event rather than letting the stream error, for the
      // reason [ApnsTokenSource] documents: an errored stream takes the
      // registrar's subscription down with it and the registrar is then deaf to
      // every later rotation, silently, for the life of the session.
      .handleError((Object e) => _telemetry.rotationStreamError('pushkit', e));
}
