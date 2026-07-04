/// Provider graph for resilient gateway/island discovery (#36).
///
/// Three parts, no single point of failure:
///  1. BOOTSTRAP from multiple bundled seeds ([kGatewayPresets]) — survives any
///     one being down.
///  2. DISCOVER from the CURRENTLY-SELECTED gateway's `/v1/gateways`
///     ([gatewayDirectoryProvider]) — not a fixed origin. Re-fires on a gateway
///     switch (it watches [configProvider]).
///  3. GROW: every successfully-discovered island is unioned into a persisted
///     "ever-seen" set ([knownGatewaysProvider] via [GatewaySeedStore]), so it
///     becomes a future bootstrap contact. Reachable set = presets ∪ ever-seen.
///
/// The picker watches [knownGatewaysProvider] (renders instantly, incl. persisted
/// islands) and overlays [gatewayDirectoryProvider] once the live fetch lands —
/// a slow/absent/failed directory never blocks the screen.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../data/gateway_directory_client.dart';
import '../data/gateway_seed_store.dart';
import '../domain/server_entry.dart';

String _normalizeUrl(String url) => GatewayConfig.normalized(url).httpBaseUrl;

/// The directory client — its own [Dio], unauthenticated (the directory is
/// public). Tests override this with a fake to drive entries/errors without a
/// network. The Dio is disposed with the provider scope.
final gatewayDirectoryClientProvider = Provider<GatewayDirectoryClient>((ref) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));
  ref.onDispose(dio.close);
  return GatewayDirectoryClient(dio: dio);
});

/// The local "islands I've met" store, backed by SharedPreferences.
final gatewaySeedStoreProvider = Provider<GatewaySeedStore>((ref) {
  return GatewaySeedStore(
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
final knownGatewaysProvider =
    NotifierProvider<KnownGatewaysNotifier, List<ServerEntry>>(
        KnownGatewaysNotifier.new);

class KnownGatewaysNotifier extends Notifier<List<ServerEntry>> {
  @override
  List<ServerEntry> build() => _merge(const []);

  /// Union [discovered] into the known set + persist, then publish the merged
  /// list. Idempotent: re-remembering already-known islands is a no-op write of
  /// the same set. Skips the state update when nothing changed so a periodic
  /// re-fetch doesn't churn listeners.
  Future<void> remember(List<ServerEntry> discovered) async {
    final store = ref.read(gatewaySeedStoreProvider);
    final persisted = await store.remember(discovered);
    final next = _merge(persisted);
    if (!_sameUrls(next, state)) state = next;
  }

  /// presets ∪ [persisted], deduped on normalized URL (presets first / win).
  List<ServerEntry> _merge(List<ServerEntry> persisted) {
    final seen = <String>{};
    final merged = <ServerEntry>[];
    for (final entry in [...kGatewayPresets, ...persisted]) {
      if (seen.add(_normalizeUrl(entry.httpBaseUrl))) merged.add(entry);
    }
    return merged;
  }

  static bool _sameUrls(List<ServerEntry> a, List<ServerEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_normalizeUrl(a[i].httpBaseUrl) != _normalizeUrl(b[i].httpBaseUrl)) {
        return false;
      }
    }
    return true;
  }
}

/// The live directory fetched from the CURRENT gateway. `AsyncError` on a
/// network/HTTP failure (picker then shows the known set); the entries on
/// success — which are also unioned into [knownGatewaysProvider] so they persist.
/// Watches [configProvider], so switching gateways re-discovers from the new one.
/// `ref.invalidate` to retry.
final gatewayDirectoryProvider = FutureProvider<List<ServerEntry>>((ref) async {
  final base = _normalizeUrl(ref.watch(configProvider).httpBaseUrl);
  // Optional fixed override (dev/staging); default = discover from the current
  // gateway, so there is no privileged directory host to fail.
  final override = kGatewayDirectoryUrl.trim();
  final url = override.isNotEmpty ? override : '$base/v1/gateways';

  final entries = await ref.watch(gatewayDirectoryClientProvider).fetchFrom(url);

  // Fold the discovery into the persisted set (fire-and-forget: a persistence
  // hiccup must not fail discovery — the live entries still render this session).
  if (entries.isNotEmpty) {
    unawaited(ref.read(knownGatewaysProvider.notifier).remember(entries));
  }
  return entries;
});
