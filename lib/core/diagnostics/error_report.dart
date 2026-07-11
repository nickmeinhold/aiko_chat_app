import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../network/network_status.dart';

/// Collects the device/app facts a maintainer needs to reproduce a failure — and
/// nothing else. Deliberately behind an interface so widget tests inject a fake
/// map instead of touching the `device_info_plus`/`package_info_plus` platform
/// channels.
///
/// PII discipline: this returns hardware/OS/app-version facts only. No handle,
/// no tokens, no message content — a problem report is diagnostics, not a data
/// dump.
abstract interface class DiagnosticsSource {
  /// Ordered device + app facts, e.g. `{'App': 'Aiko Chat 0.0.1+6',
  /// 'Device': 'Google Pixel 7', 'OS': 'Android 14 (SDK 34)'}`.
  Future<Map<String, String>> collect();
}

/// The real source: `package_info_plus` for the app version, `device_info_plus`
/// for hardware/OS. Uses [defaultTargetPlatform] (not `dart:io`) so it never
/// pulls `dart:io` into a would-be web build.
class PlatformDiagnosticsSource implements DiagnosticsSource {
  const PlatformDiagnosticsSource();

  @override
  Future<Map<String, String>> collect() async {
    final out = <String, String>{};
    final pkg = await PackageInfo.fromPlatform();
    out['App'] = '${pkg.appName} ${pkg.version}+${pkg.buildNumber}';

    if (kIsWeb) {
      out['Platform'] = 'web';
      return out;
    }
    final info = DeviceInfoPlugin();
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await info.androidInfo;
        out['Device'] = '${a.manufacturer} ${a.model}';
        out['OS'] = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
      case TargetPlatform.iOS:
        final i = await info.iosInfo;
        out['Device'] = i.utsname.machine; // e.g. iPhone15,2
        out['Model'] = i.model;
        out['OS'] = '${i.systemName} ${i.systemVersion}';
      case TargetPlatform.macOS:
        final m = await info.macOsInfo;
        out['Device'] = m.model;
        out['OS'] = 'macOS ${m.osRelease}';
      default:
        out['Platform'] = defaultTargetPlatform.name;
    }
    return out;
  }
}

/// Format a shareable, plain-text problem report from the pieces. Pure and
/// deterministic (time is injected) so it's unit-testable without a clock.
String formatErrorReport({
  required Object? error,
  required NetworkStatus status,
  required String host,
  required Map<String, String> device,
  required DateTime nowUtc,
}) {
  final b = StringBuffer()
    ..writeln('Aiko Chat — problem report')
    ..writeln('Time: ${nowUtc.toIso8601String()}')
    ..writeln('Server: $host')
    ..writeln('Network: ${status.name}');
  for (final e in device.entries) {
    b.writeln('${e.key}: ${e.value}');
  }
  b
    ..writeln('---')
    // The raw exception is for the maintainer, not the user — the friendly
    // message already told the user what to do; this is the technical detail.
    ..writeln('Error: ${error ?? 'unknown'}');
  return b.toString();
}

final diagnosticsSourceProvider = Provider<DiagnosticsSource>(
  (_) => const PlatformDiagnosticsSource(),
);

/// Opens the platform share sheet with [text]. Behind a provider so a widget
/// test captures the shared text instead of invoking the `share_plus` channel.
typedef ShareFn = Future<void> Function(String text);

final shareFnProvider = Provider<ShareFn>(
  (_) => (text) async {
    await SharePlus.instance.share(ShareParams(text: text));
  },
);
