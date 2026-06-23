/// App-wide runtime configuration, resolved from `--dart-define` at build time.
///
/// The gateway base URL is injected so the same binary can target localhost in
/// dev and `chat.imagineering.cc` in prod without a code change:
///
/// ```
/// flutter run --dart-define=GATEWAY_BASE_URL=https://chat.imagineering.cc
/// ```
///
/// The WSS URL is *derived* from the HTTP base (http→ws, https→wss) so the two
/// can't drift — a single source of truth for "where the gateway lives".
library;

class GatewayConfig {
  /// HTTP(S) base for the REST API, e.g. `http://localhost:8095`. No trailing slash.
  final String httpBaseUrl;

  const GatewayConfig({required this.httpBaseUrl});

  /// Resolve from `--dart-define=GATEWAY_BASE_URL=...`, defaulting to the local
  /// gateway so a bare `flutter run` works against a dev server.
  factory GatewayConfig.fromEnvironment() {
    const raw = String.fromEnvironment(
      'GATEWAY_BASE_URL',
      defaultValue: 'http://localhost:8095',
    );
    var base = raw.trim();
    // Strip a trailing slash so URL composition (`$base/v1/...`) never doubles.
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return GatewayConfig(httpBaseUrl: base);
  }

  /// The WSS base, derived from [httpBaseUrl] so it can never disagree about the
  /// host/port: `https`→`wss`, `http`→`ws`. Parsed via [Uri] rather than string
  /// surgery so a normalised/uppercase scheme or stray structure is handled
  /// correctly (Kelvin K1).
  String get wsBaseUrl {
    final uri = Uri.parse(httpBaseUrl);
    final scheme = switch (uri.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      final other => other, // already ws/wss (or unknown) — leave as-is
    };
    return uri.replace(scheme: scheme).toString();
  }
}
