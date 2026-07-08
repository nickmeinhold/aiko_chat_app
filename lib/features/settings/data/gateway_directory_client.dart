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
import 'package:flutter/foundation.dart';

import '../domain/server_entry.dart';

/// The directory-array envelope keys we accept, in PRIORITY order. `islands` is
/// the canonical island-vocabulary key (Design 10) and is tried FIRST; `gateways`
/// is the current wire key, kept for backward-compat; `servers`/`entries`/
/// `directory` are tolerant fallbacks. ORDER IS SEMANTIC — a guard-contract test
/// pins that `islands` wins over `gateways` when both are present, so this is not
/// a set to reorder casually. No island serves `islands` yet, so accepting it is
/// a pure widening today.
const kDirectoryEnvelopeKeysByPriority = <String>[
  'islands',
  'gateways',
  'servers',
  'entries',
  'directory',
];

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

  /// Accept either a bare JSON array of entries, or an envelope object holding the
  /// array under a conventional key (see [kDirectoryEnvelopeKeysByPriority]:
  /// `islands` first, then legacy `gateways`, then tolerant fallbacks). This reads
  /// both a legacy directory and a future island that renames `/v1/gateways`'s
  /// payload during its compat window. Anything else yields an empty list rather
  /// than throwing — a shape we don't recognise is "no directory", not a crash.
  static List<ServerEntry> _parse(dynamic data) => switch (data) {
        List<dynamic> l => _entries(l),
        Map<String, dynamic> m => _firstUsableEnvelope(m),
        _ => const [],
      };

  /// Parse a raw list of directory entries, dropping any malformed one (each is
  /// held to [ServerEntry.tryFromJson]'s http(s)+host bar — the directory is
  /// attacker-influenceable, so a bad entry is skipped, never surfaced).
  static List<ServerEntry> _entries(List<dynamic> raw) => raw
      .whereType<Map<String, dynamic>>()
      .map(ServerEntry.tryFromJson)
      .whereType<ServerEntry>()
      .toList(growable: false);

  /// The parsed entries of the first envelope key (by priority) that yields at
  /// least one USABLE entry.
  ///
  /// Neither an empty list NOR a list whose every entry is malformed shadows a
  /// later populated-and-valid one: during a compat window a peer that serves
  /// `islands: []` (or `islands: [<garbage>]`) beside a populated `gateways: [...]`
  /// must still yield the gateways. Returning the empty/unusable `islands` would
  /// silently blank the directory — a lie strictly worse than picking the legacy
  /// rail — and the whole point of multi-key tolerance is to MAXIMISE directory
  /// availability (same SPOF-avoidance ethos as bundling multiple seeds). If no
  /// present key yields a usable entry, the result is an empty directory — the
  /// correct "recognised but genuinely empty" outcome. Dual-key MISMATCH semantics
  /// (two populated lists that DISAGREE) ultimately belong to the island (#1760);
  /// until then this fail-soft default — unusable never shadows usable, priority
  /// breaks a genuine tie — is the safe pick.
  static List<ServerEntry> _firstUsableEnvelope(Map<String, dynamic> m) {
    List<ServerEntry>? firstUsable;
    final usableKeys = <String>[];
    for (final key in kDirectoryEnvelopeKeysByPriority) {
      final v = m[key];
      if (v is! List) continue;
      final parsed = _entries(v);
      if (parsed.isEmpty) continue;
      usableKeys.add(key);
      firstUsable ??= parsed;
    }
    // Observability breadcrumb (debug only): more than one envelope key yielded
    // usable entries — a peer is double-serving during a compat window. If those
    // lists ever DIVERGE we silently prefer the priority winner; this is the log
    // that saves a future 3am ghost-chase across federated nodes (Tesla).
    if (kDebugMode && usableKeys.length > 1) {
      debugPrint('GatewayDirectoryClient: multiple usable directory envelope keys '
          'present $usableKeys — preferring "${usableKeys.first}" by priority.');
    }
    return firstUsable ?? const [];
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
