import 'device_platform.dart';

/// Where a push token comes from — the seam between [DeviceRegistrar]'s
/// lifecycle logic and whichever platform SDK actually mints the token.
///
/// The registrar depends on THIS, never on a plugin, for the same reason the
/// chat repository depends on `ChatRestApi` and never on `dio`: the interesting
/// behaviour is all ordering and failure handling, and none of it should need a
/// device, a Firebase project, or an APNs key to test.
///
/// It also keeps the transport decision reversible. Adding a self-hosted
/// Android transport later is a new implementation of this interface plus a new
/// [DevicePlatform] value — no change to the lifecycle that is hard to get right
/// (claude-tasks#3267).
abstract class PushTokenSource {
  /// Ask the OS for permission to show notifications, returning whether it was
  /// granted. Idempotent, and safe to call when already granted.
  ///
  /// A denial is an ordinary answer, not an error: the user has said they do
  /// not want to be woken, and the app must keep working exactly as it does
  /// today. There is no retry and no nag.
  Future<bool> requestPermission();

  /// The current token for this install, or null if permission was refused or
  /// the platform has not issued one yet.
  Future<String?> currentToken();

  /// Tokens issued after the first one.
  ///
  /// PUSH TOKENS ROTATE — on reinstall, on restore-from-backup, and at the
  /// platform's discretion. A registrar that only reads [currentToken] once at
  /// sign-in silently stops being reachable the first time that happens, and
  /// nothing fails: the island holds a token that APNs/FCM will simply refuse
  /// to deliver to. That failure is invisible from the app, which is why the
  /// refresh stream is part of the contract rather than an optimisation.
  Stream<String> tokenRefreshes();

  /// Which service issued these tokens, and therefore which one the island must
  /// talk to. See [DevicePlatform] for why this is not simply the OS.
  DevicePlatform get platform;
}
