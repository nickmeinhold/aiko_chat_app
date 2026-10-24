/// The Mac's ring: the sound, the notification and the Dock bounce that a
/// phone's operating system supplies on its own.
///
/// On iOS and Android the SYSTEM rings — CallKit, the native ring screen — and
/// [RingOverlay] is a picture drawn on top of a ring that is already sounding.
/// The overlay itself never made a sound, and on a phone it never needed to. A
/// Mac has no CallKit and no push (island#389), so there the overlay IS the
/// whole ring: a silent panel inside a window that may be behind another one.
/// Measured 2026-10-10 and 2026-10-19: the Mac "didn't ring" because it rang in
/// silence, out of sight. This is what makes it audible and findable.
///
/// Driven from the same ring state as the overlay, so the two can never
/// disagree about whether something is ringing.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_providers.dart';
import '../domain/call_invite.dart';
import '../domain/media_confidentiality.dart';
import 'ring_controller.dart';

/// The native half. Start while already ringing replaces the notification (a
/// newer caller) and keeps the sound going.
abstract interface class DesktopRing {
  /// Ask for notification permission if it has never been asked. Called at
  /// sign-in, when nothing is ringing: asked on the first RING instead, the
  /// prompt competed with the call for the same moment, and a hurried
  /// dismissal is a permanent "no" (measured 2026-10-19). Placing a call is no
  /// better — it already raises the camera and microphone prompts.
  Future<void> prepare();
  Future<void> start({required String title, required String body});
  Future<void> stop();
}

/// `aiko/desktop_ring`, implemented in `macos/Runner/MainFlutterWindow.swift`.
class NativeDesktopRing implements DesktopRing {
  const NativeDesktopRing();
  static const _channel = MethodChannel('aiko/desktop_ring');

  @override
  Future<void> prepare() => _channel.invokeMethod<void>('prepare');

  @override
  Future<void> start({required String title, required String body}) =>
      _channel.invokeMethod<void>('start', {'title': title, 'body': body});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');
}

/// This platform's desktop ring, or null where the system rings instead.
/// `kIsWeb` first, for the reason [systemCallBridgeProvider] documents.
final desktopRingProvider = Provider<DesktopRing?>((ref) {
  if (kIsWeb) return null;
  return defaultTargetPlatform == TargetPlatform.macOS
      ? const NativeDesktopRing()
      : null;
});

/// Watch this once, from somewhere always mounted, and the desktop ring
/// follows the ring state for the life of the app.
final desktopRingDriverProvider = Provider<void>((ref) {
  final ring = ref.watch(desktopRingProvider);
  if (ring == null) return;
  // Only a native failure lands here (a missing channel in a test host, a
  // dead engine on shutdown). The overlay is still drawn, so a ring that
  // cannot SOUND must not take the ring down with it.
  void send(Future<void> Function() call) =>
      unawaited(call().catchError((Object _) {}));

  // Once per signed-in identity: `select` calls this only when the user id
  // CHANGES, so a rebuild of the same user never asks twice. The native side
  // then asks macOS only if it never has.
  ref.listen(currentUserProvider.select((u) => u?.userId), (_, next) {
    if (next != null) send(ring.prepare);
  }, fireImmediately: true);

  ref.listen<CallInvite?>(incomingRingProvider, (prev, next) {
    if (next == null) {
      if (prev != null) send(ring.stop);
      return;
    }
    // No same-invitation guard: CallInvite's equality IS inviteId, so a
    // re-publish of the ringing invitation never reaches this listener. A
    // guard here would defend a state nothing can produce; the test "the same
    // invitation re-published does not restart the sound" pins the contract,
    // and fails first if that equality ever changes.
    //
    // The overlay's own naming rule: a missing or empty label is a person.
    final label = next.from.label;
    final caller = (label == null || label.isEmpty) ? 'Someone' : label;
    // The disclosure travels with the ring here too: a notification the user
    // answers from must say what the banner says, or it is the one surface
    // that rings without telling them (Decision 9d).
    final body = ref.read(mediaRoutingProvider).sentence;
    send(() => ring.start(title: '$caller is calling', body: body));
  }, fireImmediately: true);
  ref.onDispose(() => send(ring.stop));
});
