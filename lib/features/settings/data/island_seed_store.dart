/// The "islands I've met" seed store (#36) — the DHT-style growing half of
/// resilient discovery.
///
/// Discovery bootstraps from the bundled [kIslandPresets], but every island the
/// app successfully learns about (from any island's `/v1/islands`) is UNIONED
/// into a locally-persisted set. On the next cold start that set seeds the picker
/// alongside the presets — so an island seen once becomes a future bootstrap
/// contact, and the reachable set is `presets ∪ ever-seen`, not a single
/// hardcoded origin. There is no privileged "directory host" to be a SPOF.
///
/// SECURITY: a persisted base URL is attacker-influenceable — it originated in a
/// directory response, and a picker tile bypasses the custom-URL validation on
/// its way to `switchIsland`. So [load] re-hydrates every stored entry through
/// [IslandEntry.tryFromJson], the SAME validating parser a freshly-fetched entry
/// clears (absolute http(s) + host). A tampered prefs blob (a `file://`, a
/// missing host, garbage) is dropped on read, never surfaced as a tappable tile.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/prefs/pref_key_migration.dart';

import '../domain/island_entry.dart';

/// SharedPreferences key holding the JSON array of ever-seen islands. Distinct
/// from `islandBaseUrlPrefKey` (the single SELECTED island).
const kKnownIslandsPrefKey = 'aiko_known_islands';

/// Whether [raw] is a JSON array — the shape [IslandSeedStore.load] can use.
/// Passed to `readAndAdopt` so an unusable new value cannot hide a usable legacy
/// one; the decode is cheap and happens once per load.
bool _decodesToList(String raw) {
  if (raw.trim().isEmpty) return false;
  try {
    return jsonDecode(raw) is List;
  } on FormatException {
    return false;
  }
}

class IslandSeedStore {
  // Private-named initializing formals: callers pass `prefs:` / `normalize:`.
  IslandSeedStore({required this._prefs, required this._normalize});

  final SharedPreferences _prefs;
  final String Function(String) _normalize;

  /// The ever-seen islands, re-validated. Returns `[]` on a missing, malformed,
  /// or fully-invalid blob — persistence is best-effort chrome, never a crash
  /// surface. Each surviving entry has cleared [IslandEntry.tryFromJson].
  List<IslandEntry> load() {
    // Legacy-aware read: adopts a pre-vocabulary install's set forward under the
    // new key the first time it is loaded.
    final raw = readAndAdopt(
      _prefs,
      key: kKnownIslandsPrefKey,
      legacyKey: kLegacyKnownIslandsPrefKey,
      // A blob that will not decode into a list is not a remembered set, so it
      // must not shadow a legacy one that would.
      isUsable: _decodesToList,
    );
    if (raw == null || raw.trim().isEmpty) return const [];
    late final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(IslandEntry.tryFromJson) // re-validate: the security invariant
        .whereType<IslandEntry>()
        .toList(growable: false);
  }

  /// Union [discovered] into the persisted set (dedup on the normalized base URL,
  /// the thing that identifies an island) and save. Returns the full merged set
  /// so a caller can update in-memory state without a re-read. Existing entries
  /// win on a collision — a re-advertised island keeps its first-seen label
  /// rather than churning. Invalid discovered entries can't enter (they never
  /// parsed into a [IslandEntry]); the round-trip through JSON on save + [load]
  /// keeps stored and in-memory shapes identical.
  Future<List<IslandEntry>> remember(Iterable<IslandEntry> discovered) async {
    final seen = <String>{};
    final merged = <IslandEntry>[];
    // load() first so already-known islands keep priority over a fresh re-fetch.
    for (final entry in [...load(), ...discovered]) {
      if (seen.add(_normalize(entry.httpBaseUrl))) merged.add(entry);
    }
    // Persistence is best-effort chrome: a write failure costs only cross-launch
    // memory of an island (self-healing — it's re-discovered next session), so it
    // must NOT propagate (this runs as a fire-and-forget after discovery; an
    // unhandled rejection there would be a crash surface). The in-memory merged
    // set is still returned so THIS session grows regardless.
    try {
      await _prefs.setString(
        kKnownIslandsPrefKey,
        jsonEncode(merged.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // swallow: see above — best-effort, self-healing.
    }
    return merged;
  }
}
