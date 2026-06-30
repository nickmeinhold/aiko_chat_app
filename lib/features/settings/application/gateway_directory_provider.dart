/// Provider graph for the live gateway directory (#36).
///
/// Mirrors `authProvidersProvider` (a [FutureProvider] the UI reads with
/// loading/error/data) — but for a CROSS-GATEWAY resource, so it builds its own
/// bare [Dio] rather than depending on `restApiProvider`. The picker watches
/// [gatewayDirectoryProvider] and falls back to the bundled seed on
/// loading/error/empty, so a slow or absent directory never blocks the screen.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/gateway_directory_client.dart';
import '../domain/server_entry.dart';

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

/// The live directory entries. `[]` when the endpoint is unset (the current
/// launch state — no network fired) or genuinely empty; an `AsyncError` on a
/// network/HTTP failure (the picker then shows the seed presets). `ref.invalidate`
/// to retry.
final gatewayDirectoryProvider = FutureProvider<List<ServerEntry>>(
  (ref) => ref.watch(gatewayDirectoryClientProvider).fetch(),
);
