/// Fetches the live island directory (#36) — the layer ABOVE per-island community
/// discovery: "which independent operators exist to connect to?".
///
/// Every island serves the FULL known-peer set from `/v1/islands`, so there is NO
/// privileged "directory host": the app discovers from whichever island it is
/// currently on, and composes `<current island>/v1/islands`.

library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../domain/island_entry.dart';

/// The directory-array envelope keys we accept, in PRIORITY order: `islands`
/// first, then `entries`/`directory` as tolerant fallbacks for a
/// differently-SHAPED directory. Order is semantic and a guard-contract test pins
/// it, so this is not a set to reorder casually.
///
/// Dropping a key means an island serving only that key parses to an EMPTY
/// directory rather than an error — silent degradation to the seed list. That is
/// acceptable only while we operate every island.
const kDirectoryEnvelopeKeysByPriority = <String>[
  'islands',
  'entries',
  'directory',
];

/// Optional fixed directory origin (`--dart-define=ISLAND_DIRECTORY_URL`). Empty
/// = the shipped default: discover from the currently-selected island instead of
/// any fixed host. An override is a dev/staging convenience, NOT the production
/// path — pinning it back to one host would re-create the SPOF this removed.
const kIslandDirectoryUrl = String.fromEnvironment(
  'ISLAND_DIRECTORY_URL',
  defaultValue: '',
);

class IslandDirectoryClient {
  final Dio _dio;

  // Private-named initializing formal: callers pass `dio:` (Dart strips the
  // leading underscore for the external parameter name).
  IslandDirectoryClient({required this._dio});

  /// Fetch + tolerantly parse the directory at [directoryUrl]. Returns the
  /// parseable entries (skipping any malformed one).
  ///
  /// Does NOT swallow network/HTTP errors: a real failure throws so the caller's
  /// [FutureProvider] surfaces it as an `AsyncError`, and the picker falls back
  /// to the seed list.
  Future<List<IslandEntry>> fetchFrom(String directoryUrl) async {
    final res = await _dio.get<dynamic>(directoryUrl);
    return _parse(res.data);
  }

  /// Accept either a bare JSON array of entries, or an envelope object holding
  /// the array under one of [kDirectoryEnvelopeKeysByPriority]. An unrecognised
  /// shape yields an empty list rather than throwing — "no directory", not a
  /// crash.
  static List<IslandEntry> _parse(dynamic data) => switch (data) {
    List<dynamic> l => _entries(l),
    Map<String, dynamic> m => _firstUsableEnvelope(m),
    _ => const [],
  };

  /// Parse a raw list of directory entries, dropping any malformed one (each is
  /// held to [IslandEntry.tryFromJson]'s http(s)+host bar — the directory is
  /// attacker-influenceable, so a bad entry is skipped, never surfaced).
  static List<IslandEntry> _entries(List<dynamic> raw) => raw
      .whereType<Map<String, dynamic>>()
      .map(IslandEntry.tryFromJson)
      .whereType<IslandEntry>()
      .toList(growable: false);

  /// The parsed entries of the first envelope key (by priority) that yields at
  /// least one USABLE entry.
  ///
  /// Neither an empty list NOR a list whose every entry is malformed shadows a
  /// later populated-and-valid one: during a compat window a peer that serves
  /// `islands: []` (or `islands: [<garbage>]`) beside a populated `islands: [...]`
  /// must still yield the islands. Returning the empty/unusable `islands` would
  /// silently blank the directory — a lie strictly worse than picking the legacy
  /// rail — and the whole point of multi-key tolerance is to MAXIMISE directory
  /// availability (same SPOF-avoidance ethos as bundling multiple seeds). If no
  /// present key yields a usable entry, the result is an empty directory — the
  /// correct "recognised but genuinely empty" outcome. Dual-key MISMATCH semantics
  /// (two populated lists that DISAGREE) ultimately belong to the island (#1760);
  /// until then this fail-soft default — unusable never shadows usable, priority
  /// breaks a genuine tie — is the safe pick.
  static List<IslandEntry> _firstUsableEnvelope(Map<String, dynamic> m) {
    List<IslandEntry>? firstUsable;
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
      debugPrint(
        'IslandDirectoryClient: multiple usable directory envelope keys '
        'present $usableKeys — preferring "${usableKeys.first}" by priority.',
      );
    }
    return firstUsable ?? const [];
  }
}

/// Merge the live [directory] over the bundled [seed], deduped on the normalized
/// base URL (the thing that actually identifies an island). Directory entries win
/// and come first (the real federation list); seed entries the directory doesn't
/// mention follow (so dev-only Local/emulator stay reachable). With an empty
/// directory this returns the seed unchanged — the seed-first fallback.
List<IslandEntry> mergeDirectory(
  List<IslandEntry> directory,
  List<IslandEntry> seed, {
  required String Function(String) normalize,
}) {
  final seen = <String>{};
  final merged = <IslandEntry>[];
  for (final entry in [...directory, ...seed]) {
    if (seen.add(normalize(entry.httpBaseUrl))) merged.add(entry);
  }
  return merged;
}
