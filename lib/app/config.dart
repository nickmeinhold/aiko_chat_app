/// App-wide runtime configuration: *where the island lives*.
///
/// Historically this was resolved once from `--dart-define` at build time. As of
/// the in-app island picker (#4) the value is RUNTIME-mutable and persisted (see
/// `IslandConfigController` in `providers.dart`); this class stays a plain,
/// immutable value object. The resolution order for the initial value is:
///
///   persisted choice  →  `--dart-define=ISLAND_BASE_URL`  →  hardcoded prod
///
/// so a shipped binary points at the live island out of the box, a dev build
/// can seed localhost via dart-define, and either can be re-pointed in-app.
///
/// The WSS URL is *derived* from the HTTP base (http→ws, https→wss) so the two
/// can't drift — a single source of truth for "where the island lives".
library;

/// The hardcoded last-resort island: the live production island. Used when
/// nothing is persisted AND no `--dart-define` was supplied (i.e. a bare
/// `flutter run` or a release build that didn't pass `dart_defines/prod.json`).
const kDefaultIslandBaseUrl = 'https://chat.imagineering.cc';

class IslandConfig {
  /// HTTP(S) base for the REST API, e.g. `http://localhost:8095`. No trailing
  /// slash, trimmed — always normalized via [IslandConfig.normalized].
  final String httpBaseUrl;

  const IslandConfig({required this.httpBaseUrl});

  /// Normalize a raw base URL: trim surrounding whitespace and strip a trailing
  /// slash so URL composition (`$base/v1/...`) never doubles. The single place
  /// that owns the canonical form — both the persisted-value path and the
  /// dart-define path funnel through here so a stored `https://x/` and a typed
  /// `https://x` resolve to the same island (and the no-op switch guard holds).
  factory IslandConfig.normalized(String raw) {
    // Strip ALL trailing slashes (not just one) so `https://x//` and `https://x`
    // resolve to the same island — the no-op switch guard compares these, and a
    // single-slash strip would let `https://x//` slip past as a "different"
    // island and needlessly destroy a live session (Carnot).
    final base = raw.trim().replaceAll(RegExp(r'/+$'), '');
    return IslandConfig(httpBaseUrl: base);
  }

  /// Resolve from `--dart-define=ISLAND_BASE_URL=...`, defaulting to the live
  /// production island ([kDefaultIslandBaseUrl]) so a binary with no flag and
  /// no persisted choice still reaches a real island.
  factory IslandConfig.fromEnvironment() {
    // TRIPWIRE for the 2026-09-02 rename of this define, and it exists because I
    // was wrong about needing one. I argued the old name lived only in
    // dart_defines/prod.json, so a rename could not be missed — then found
    // docs/runbooks/phase1-human-e2e.html passing it on a COMMAND LINE. A stale
    // flag does not error: `fromEnvironment` just ignores the unknown name and
    // falls back to kDefaultIslandBaseUrl, so a human e2e run aimed at staging
    // would quietly test PRODUCTION and look like it worked.
    //
    // Silent-wrong-island is exactly the failure a rename should not be able to
    // cause, so the old name is now an error rather than a no-op. Delete this
    // once no runbook, script or shell history could still carry it.
    const stale = String.fromEnvironment('GATEWAY_BASE_URL');
    if (stale.isNotEmpty) {
      throw StateError(
        'GATEWAY_BASE_URL was renamed to ISLAND_BASE_URL on 2026-09-02. It is '
        'still set to "$stale", which this build would otherwise IGNORE while '
        'silently using $kDefaultIslandBaseUrl. Pass --dart-define='
        'ISLAND_BASE_URL=$stale instead.',
      );
    }
    const raw = String.fromEnvironment(
      'ISLAND_BASE_URL',
      defaultValue: kDefaultIslandBaseUrl,
    );
    return IslandConfig.normalized(raw);
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
      other is IslandConfig && other.httpBaseUrl == httpBaseUrl;

  @override
  int get hashCode => httpBaseUrl.hashCode;

  @override
  String toString() => 'IslandConfig($httpBaseUrl)';
}
