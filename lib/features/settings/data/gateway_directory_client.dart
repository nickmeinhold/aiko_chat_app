/// Fetches the live gateway/island directory (#36) — the layer ABOVE per-gateway
/// community discovery: "which independent operators exist to connect to?".
///
/// This is deliberately CROSS-GATEWAY: the directory lives at a well-known origin
/// (Design 05 §10 / handoff #1548 Phase 2), NOT at whichever gateway the app is
/// currently pointed at. So it uses its own bare [Dio] — no auth interceptor, no
/// bearer token — and never rides `restApiProvider` (which is bound to the
/// selected gateway and would re-fetch against the wrong host after a switch).
///
/// The endpoint URL is not published yet (the gateway tab owns standing it up —
/// #1548 cross-tab item 1). Until it is, [kGatewayDirectoryUrl] is empty and
/// [fetch] short-circuits to an empty list with ZERO network — the picker then
/// renders the bundled seed presets, which is the correct launch behavior. The
/// moment the gateway publishes the path, this becomes a one-line default change
/// (or a `--dart-define=GATEWAY_DIRECTORY_URL` override).
library;

import 'package:dio/dio.dart';

import '../domain/server_entry.dart';

/// The well-known directory origin. Empty = "not published yet" → seed-only.
/// Overridable at build time so a dev/staging directory can be pointed at
/// without a code change.
const kGatewayDirectoryUrl = String.fromEnvironment(
  'GATEWAY_DIRECTORY_URL',
  defaultValue: '',
);

class GatewayDirectoryClient {
  final Dio _dio;
  final String _url;

  // Private-named initializing formals: callers pass `dio:` / `url:` (Dart
  // strips the leading underscore for the external parameter name).
  GatewayDirectoryClient(
      {required this._dio, this._url = kGatewayDirectoryUrl});

  /// Fetch + tolerantly parse the directory. Returns the parseable entries
  /// (skipping any malformed one) — or `[]` when the URL is unset (no network).
  ///
  /// Does NOT swallow network/HTTP errors: a real failure throws so the caller's
  /// [FutureProvider] surfaces it as an `AsyncError`, and the picker falls back
  /// to the seed list. (Unset-URL is not a failure — it's "nothing to fetch".)
  Future<List<ServerEntry>> fetch() async {
    if (_url.trim().isEmpty) return const [];
    final res = await _dio.get<dynamic>(_url);
    return _parse(res.data);
  }

  /// Accept either a bare JSON array of entries, or an envelope object holding
  /// the array under a conventional key (`gateways`/`servers`/`entries`/
  /// `directory`). Anything else yields an empty list rather than throwing — a
  /// shape we don't recognise is "no directory", not a crash.
  static List<ServerEntry> _parse(dynamic data) {
    final List<dynamic>? list = switch (data) {
      List<dynamic> l => l,
      Map<String, dynamic> m => _firstList(
          m, const ['gateways', 'servers', 'entries', 'directory']),
      _ => null,
    };
    if (list == null) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ServerEntry.tryFromJson)
        .whereType<ServerEntry>()
        .toList(growable: false);
  }

  static List<dynamic>? _firstList(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final v = m[key];
      if (v is List) return v;
    }
    return null;
  }
}

/// Merge the live [directory] over the bundled [seed], deduped on the normalized
/// base URL (the thing that actually identifies a gateway). Directory entries win
/// and come first (the real federation list); seed entries the directory doesn't
/// mention follow (so dev-only Local/emulator stay reachable). With an empty
/// directory this returns the seed unchanged — the seed-first fallback.
List<ServerEntry> mergeDirectory(
  List<ServerEntry> directory,
  List<ServerEntry> seed, {
  required String Function(String) normalize,
}) {
  final seen = <String>{};
  final merged = <ServerEntry>[];
  for (final entry in [...directory, ...seed]) {
    if (seen.add(normalize(entry.httpBaseUrl))) merged.add(entry);
  }
  return merged;
}
