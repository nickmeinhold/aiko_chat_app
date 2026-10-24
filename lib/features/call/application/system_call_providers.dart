import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/system_call_bridge.dart';

/// This platform's system-call bridge, or null where there is no platform call
/// UI to bridge to.
///
/// `kIsWeb` FIRST, before any platform test — the trap `pushTokenSource`
/// documents: on Flutter web `defaultTargetPlatform` reports the BROWSER'S host
/// OS, so Safari on an iPhone answers `TargetPlatform.iOS` and this would build
/// a CallKit bridge inside a renderer that has never heard of CallKit.
final systemCallBridgeProvider = Provider<SystemCallBridge?>((ref) {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => NativeSystemCallBridge(),
    _ => null,
  };
});
