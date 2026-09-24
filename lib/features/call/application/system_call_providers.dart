import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/feature_flags.dart' show callingEnabledProvider;
import '../data/system_call_bridge.dart';

/// This platform's system-call bridge, or null where there is no platform call
/// UI to bridge to.
///
/// **GATED ON `callingEnabled`, and that gate is the same one door the router
/// and the ring banner stand behind.** A build that cannot open `/call/:id` must
/// not be able to be answered INTO it: the answer would arrive, find no route,
/// and the user would be left holding a connected system call with nothing on
/// the other end — a worse render of "calling is off" than silence.
///
/// `kIsWeb` FIRST, before any platform test — the trap `pushTokenSource`
/// documents: on Flutter web `defaultTargetPlatform` reports the BROWSER'S host
/// OS, so Safari on an iPhone answers `TargetPlatform.iOS` and this would build
/// a CallKit bridge inside a renderer that has never heard of CallKit.
final systemCallBridgeProvider = Provider<SystemCallBridge?>((ref) {
  if (kIsWeb) return null;
  if (!ref.watch(callingEnabledProvider)) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => AppleSystemCallBridge(),
    _ => null,
  };
});
