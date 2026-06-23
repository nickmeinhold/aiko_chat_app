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
    // Strip a trailing slash so URL composition (`$base/v1/...`) never doubles.
    final base = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    return GatewayConfig(httpBaseUrl: base);
  }

  /// The WSS base, derived from [httpBaseUrl] so it can never disagree about the
  /// host/port: `https://` → `wss://`, `http://` → `ws://`.
  String get wsBaseUrl {
    if (httpBaseUrl.startsWith('https://')) {
      return 'wss://${httpBaseUrl.substring('https://'.length)}';
    }
    if (httpBaseUrl.startsWith('http://')) {
      return 'ws://${httpBaseUrl.substring('http://'.length)}';
    }
    return httpBaseUrl; // already a ws(s) scheme or schemeless — pass through
  }
}
