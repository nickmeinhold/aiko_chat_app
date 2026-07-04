/// Fetches the live gateway/island directory (#36) — the layer ABOVE per-gateway
/// community discovery: "which independent operators exist to connect to?".
///
/// Every island serves the FULL known-peer set from `/v1/gateways`, so there is
/// NO privileged "directory host": the app discovers from whichever gateway it is
/// currently pointed at (see [gatewayDirectoryProvider]), and reaching any one
/// island teaches it about all the others. Removing the old single fixed origin
/// is the point — a hardcoded directory URL re-introduced a discovery SPOF even
/// though the gateway side had none. Still deliberately CROSS-GATEWAY-shaped: its
/// own bare [Dio] (no auth interceptor / bearer), never `restApiProvider`.
///
/// [kGatewayDirectoryUrl] remains as an OPTIONAL build-time override (dev/staging
/// can pin a fixed directory); when empty (the shipped default) the provider
/// composes `<current gateway>/v1/gateways`.
library;

import 'package:dio/dio.dart';

import '../domain/server_entry.dart';

/// Optional fixed directory origin (`--dart-define=GATEWAY_DIRECTORY_URL`). Empty
/// = the shipped default: discover from the currently-selected gateway instead of
/// any fixed host. An override is a dev/staging convenience, NOT the production
/// path — pinning it back to one host would re-create the SPOF this removed.
const kGatewayDirectoryUrl = String.fromEnvironment(
  'GATEWAY_DIRECTORY_URL',
  defaultValue: '',
);

class GatewayDirectoryClient {
  final Dio _dio;

  // Private-named initializing formal: callers pass `dio:` (Dart strips the
  // leading underscore for the external parameter name).
  GatewayDirectoryClient({required this._dio});

  /// Fetch + tolerantly parse the directory at [directoryUrl]. Returns the
  /// parseable entries (skipping any malformed one).
  ///
  /// Does NOT swallow network/HTTP errors: a real failure throws so the caller's
  /// [FutureProvider] surfaces it as an `AsyncError`, and the picker falls back
  /// to the seed list.
  Future<List<ServerEntry>> fetchFrom(String directoryUrl) async {
    final res = await _dio.get<dynamic>(directoryUrl);
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
