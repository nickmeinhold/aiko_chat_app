/// Provider graph for resilient island discovery (#36).
///
/// Three parts, no single point of failure:
///  1. BOOTSTRAP from multiple bundled seeds ([kIslandPresets]) — survives any
///     one being down.
///  2. DISCOVER from the CURRENTLY-SELECTED island's `/v1/islands`
///     ([islandDirectoryProvider]) — not a fixed origin. Re-fires on an island
///     switch (it watches [configProvider]).
///  3. GROW: every successfully-discovered island is unioned into a persisted
///     "ever-seen" set ([knownIslandsProvider] via [IslandSeedStore]), so it
///     becomes a future bootstrap contact. Reachable set = presets ∪ ever-seen.
///
/// The picker watches [knownIslandsProvider] (renders instantly, incl. persisted
/// islands) and overlays [islandDirectoryProvider] once the live fetch lands —
/// a slow/absent/failed directory never blocks the screen.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../data/island_directory_client.dart';
import '../data/island_seed_store.dart';
import '../domain/island_entry.dart';

String _normalizeUrl(String url) => IslandConfig.normalized(url).httpBaseUrl;

/// The directory client — its own [Dio], unauthenticated (the directory is
/// public). Tests override this with a fake to drive entries/errors without a
/// network. The Dio is disposed with the provider scope.
final islandDirectoryClientProvider = Provider<IslandDirectoryClient>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );
  ref.onDispose(dio.close);
  return IslandDirectoryClient(dio: dio);
});

/// The local "islands I've met" store, backed by SharedPreferences.
final islandSeedStoreProvider = Provider<IslandSeedStore>((ref) {
  return IslandSeedStore(
    prefs: ref.watch(sharedPreferencesProvider),
    normalize: _normalizeUrl,
  );
});

/// The known islands to seed the picker: bundled presets UNION the persisted
/// ever-seen set, deduped on the normalized base URL (presets win, so a bundled
/// island keeps its friendly label over a persisted copy). This is the
/// instantly-available floor the picker renders before (and instead of, on
/// failure) the live directory. [remember] folds a fresh discovery in and
/// persists it, growing the set for next launch.
final knownIslandsProvider =
    NotifierProvider<KnownIslandsNotifier, List<IslandEntry>>(
      KnownIslandsNotifier.new,
    );

class KnownIslandsNotifier extends Notifier<List<IslandEntry>> {
  @override
  List<IslandEntry> build() =>
      // Load the persisted ever-seen set on FIRST build — not just after a
      // discovery this session. This is the whole point of persistence: if the
      // current bootstrap island is DOWN (the SPOF case this feature exists to
      // solve), discovery throws and remember() never fires, so a previously-seen
      // island must still seed the picker from disk to be reachable at all.
      _merge(ref.watch(islandSeedStoreProvider).load());

  /// Union [discovered] into the known set + persist, then publish the merged
  /// list. Idempotent: re-remembering already-known islands is a no-op write of
  /// the same set. Skips the state update when nothing changed so a periodic
  /// re-fetch doesn't churn listeners.
  Future<void> remember(List<IslandEntry> discovered) async {
    final store = ref.read(islandSeedStoreProvider);
    final persisted = await store.remember(discovered);
    final next = _merge(persisted);
    if (!_sameUrls(next, state)) state = next;
  }

  /// presets ∪ [persisted], deduped on normalized URL (presets first / win).
  List<IslandEntry> _merge(List<IslandEntry> persisted) {
    final seen = <String>{};
    final merged = <IslandEntry>[];
    for (final entry in [...kIslandPresets, ...persisted]) {
      if (seen.add(_normalizeUrl(entry.httpBaseUrl))) merged.add(entry);
    }
    return merged;
  }

  static bool _sameUrls(List<IslandEntry> a, List<IslandEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_normalizeUrl(a[i].httpBaseUrl) != _normalizeUrl(b[i].httpBaseUrl)) {
        return false;
      }
    }
    return true;
  }
}

/// The live directory fetched from the CURRENT island. `AsyncError` on a
/// network/HTTP failure (picker then shows the known set); the entries on
/// success — which are also unioned into [knownIslandsProvider] so they persist.
/// Watches [configProvider], so switching islands re-discovers from the new one.
/// `ref.invalidate` to retry.
final islandDirectoryProvider = FutureProvider<List<IslandEntry>>((ref) async {
  final base = _normalizeUrl(ref.watch(configProvider).httpBaseUrl);
  // Optional fixed override (dev/staging); default = discover from the current
  // island, so there is no privileged directory host to fail.
  final override = kIslandDirectoryUrl.trim();
  final url = override.isNotEmpty ? override : '$base/v1/islands';

  final entries = await ref.watch(islandDirectoryClientProvider).fetchFrom(url);

  // Fold the discovery into the persisted set (fire-and-forget: a persistence
  // hiccup must not fail discovery — the live entries still render this session).
  if (entries.isNotEmpty) {
    unawaited(ref.read(knownIslandsProvider.notifier).remember(entries));
  }
  return entries;
});
