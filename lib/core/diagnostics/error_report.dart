import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/auth/data/auth_exceptions.dart';
import '../../features/chat/data/chat_rest_api.dart';
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

/// A PII-safe, one-line description of an error for a problem report.
///
/// NEVER the raw `toString()` of an arbitrary exception: a [NetworkUnavailable]
/// wraps the original `DioException`, whose string can carry `requestOptions`
/// — and on the claim path that request body holds a `provisioning_token`
/// (a bearer credential), the handle, and the display name (cage-match #74,
/// Carnot + Tesla). So we ALLOWLIST a safe projection per known type, and fall
/// back to the bare class name (which carries no data) for anything else. The
/// invariant is "diagnostics, never a credential" — and it must not depend on a
/// third-party library's `toString()` staying restrained.
String describeError(Object? error) {
  return switch (error) {
    null => 'unknown',
    // Drop the wrapped cause entirely — the type IS the diagnosis, and the
    // cause is the one that carries the request body.
    NetworkUnavailable() => 'NetworkUnavailable',
    Unauthorized(:final statusCode) => 'Unauthorized($statusCode)',
    HandleTaken() => 'HandleTaken',
    PasskeyAlreadyRegistered() => 'PasskeyAlreadyRegistered',
    AuthCeremonyCancelled() => 'AuthCeremonyCancelled',
    // message is 'Passkey: <code>' — an authenticator error code, not user data.
    AuthCeremonyFailed(:final message) => 'AuthCeremonyFailed($message)',
    // Drop the message (it may name channels) — the type is enough to triage.
    SoleAdminDeletionBlocked() => 'SoleAdminDeletionBlocked',
    // Anything else (incl. a raw DioException / FormatException): class name
    // ONLY — never toString(), which could stringify a request body or headers.
    _ => error.runtimeType.toString(),
  };
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
    // "at report time", not at-failure: the tap can be minutes after the error
    // (offline → reconnect → report), so labelling it as current avoids a false
    // "online next to NetworkUnavailable" chord (cage-match #74, Tesla).
    ..writeln('Network (at report time): ${status.name}');
  for (final e in device.entries) {
    b.writeln('${e.key}: ${e.value}');
  }
  b
    ..writeln('---')
    // A SAFE projection of the error for the maintainer — never the raw
    // exception string (see [describeError]).
    ..writeln('Error: ${describeError(error)}');
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
