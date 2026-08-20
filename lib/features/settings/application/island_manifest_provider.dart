import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/widgets/island_mark.dart';

/// The island's own public key, so its mark can be derived from what it IS
/// rather than from the address it currently answers on.
///
/// `GET /v1/island` is the island's SIGNED SELF-MANIFEST — id, display name,
/// base URL, moderation mode, key version, `island_pubkey` and a signature over
/// the lot. Only the pubkey is used here; the rest of the manifest is a
/// federation surface that belongs to whoever builds peering, not to a drawing.
///
/// CACHED IN PREFS, keyed by host, and read synchronously at startup. That is
/// not an optimisation — it is what stops the mark MOVING. A mark derived from
/// the URL and later re-derived from the key is a different mark, so an island
/// settles exactly once, on first contact, and is stable on every launch after.
/// Without the cache it would re-settle on every cold start, which is the one
/// thing an identity mark must never do.
///
/// NOT VERIFIED, and deliberately: the manifest is signed, but this only paints
/// a colour and a coastline. Checking a signature here would imply the mark is a
/// security claim — it is a recognition aid, and treating it as more than that
/// is how a decoration ends up load-bearing. If islands ever need to be
/// cryptographically identified in the UI, that is a different feature with its
/// own trust root, and it should not inherit this one's cache.
const islandPubkeyPrefPrefix = 'aiko_island_pubkey_';

/// The cached pubkey for a host, if we have ever fetched it.
final islandPubkeyProvider = Provider.family<String?, String>((ref, baseUrl) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getString('$islandPubkeyPrefPrefix${islandKey(baseUrl)}');
});

/// Fetch the manifest once and cache the pubkey. Fire-and-forget: a failure
/// leaves the mark on its URL-derived fallback, which is a perfectly good mark —
/// so this never blocks, never retries hard, and never surfaces an error.
final islandManifestFetcherProvider = Provider<void>((ref) {
  final config = ref.watch(configProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  final host = islandKey(config.httpBaseUrl);
  if (prefs.getString('$islandPubkeyPrefPrefix$host') != null) return;
  unawaited(_fetchPubkey(config.httpBaseUrl, host, prefs));
});

Future<void> _fetchPubkey(
  String baseUrl,
  String host,
  SharedPreferences prefs,
) async {
  try {
    final res = await Dio().get<String>(
      '$baseUrl/v1/island',
      options: Options(
        responseType: ResponseType.plain,
        // A drawing must not hold a startup path open. If the island is slow the
        // URL-derived mark is already on screen and good enough.
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    final json = jsonDecode(res.data ?? '');
    if (json is! Map) return;
    final pubkey = json['island_pubkey'];
    // A Multikey is `z…` base58btc. Sanity-bounded rather than parsed: this
    // string is only ever hashed into a hue, so what matters is "plausibly a
    // key", not "a valid Ed25519 point".
    if (pubkey is! String || pubkey.length < 8 || pubkey.length > 128) return;
    await prefs.setString('$islandPubkeyPrefPrefix$host', pubkey);
  } catch (_) {
    // Deliberately swallowed. Offline, an island too old to have /v1/island, a
    // proxy in the way — every one of them means "keep the fallback mark", and
    // none of them means "tell the user something is wrong".
  }
}
