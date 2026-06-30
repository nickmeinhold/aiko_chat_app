/// App-wide runtime configuration: *where the gateway lives*.
///
/// Historically this was resolved once from `--dart-define` at build time. As of
/// the in-app gateway picker (#4) the value is RUNTIME-mutable and persisted (see
/// `GatewayConfigController` in `providers.dart`); this class stays a plain,
/// immutable value object. The resolution order for the initial value is:
///
///   persisted choice  →  `--dart-define=GATEWAY_BASE_URL`  →  hardcoded prod
///
/// so a shipped binary points at the live gateway out of the box, a dev build
/// can seed localhost via dart-define, and either can be re-pointed in-app.
///
/// The WSS URL is *derived* from the HTTP base (http→ws, https→wss) so the two
/// can't drift — a single source of truth for "where the gateway lives".
library;

/// The hardcoded last-resort gateway: the live production server. Used when
/// nothing is persisted AND no `--dart-define` was supplied (i.e. a bare
/// `flutter run` or a release build that didn't pass `dart_defines/prod.json`).
const kDefaultGatewayBaseUrl = 'https://chat.imagineering.cc';

class GatewayConfig {
  /// HTTP(S) base for the REST API, e.g. `http://localhost:8095`. No trailing
  /// slash, trimmed — always normalized via [GatewayConfig.normalized].
  final String httpBaseUrl;

  const GatewayConfig({required this.httpBaseUrl});

  /// Normalize a raw base URL: trim surrounding whitespace and strip a trailing
  /// slash so URL composition (`$base/v1/...`) never doubles. The single place
  /// that owns the canonical form — both the persisted-value path and the
  /// dart-define path funnel through here so a stored `https://x/` and a typed
  /// `https://x` resolve to the same gateway (and the no-op switch guard holds).
  factory GatewayConfig.normalized(String raw) {
    // Strip ALL trailing slashes (not just one) so `https://x//` and `https://x`
    // resolve to the same gateway — the no-op switch guard compares these, and a
    // single-slash strip would let `https://x//` slip past as a "different"
    // gateway and needlessly destroy a live session (Carnot).
    final base = raw.trim().replaceAll(RegExp(r'/+$'), '');
    return GatewayConfig(httpBaseUrl: base);
  }

  /// Resolve from `--dart-define=GATEWAY_BASE_URL=...`, defaulting to the live
  /// production gateway ([kDefaultGatewayBaseUrl]) so a binary with no flag and
  /// no persisted choice still reaches a real server.
  factory GatewayConfig.fromEnvironment() {
    const raw = String.fromEnvironment(
      'GATEWAY_BASE_URL',
      defaultValue: kDefaultGatewayBaseUrl,
    );
    return GatewayConfig.normalized(raw);
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

  @override
  bool operator ==(Object other) =>
      other is GatewayConfig && other.httpBaseUrl == httpBaseUrl;

  @override
  int get hashCode => httpBaseUrl.hashCode;

  @override
  String toString() => 'GatewayConfig($httpBaseUrl)';
}
