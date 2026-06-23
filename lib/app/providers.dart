/// The Phase-1 provider graph — the dependency-injection spine that wires the
/// (already-complete) data layer into the Riverpod world the UI consumes.
///
/// Layering (top depends on bottom; no cycles):
///   config → tokenStore → backend → {restApi, tokenProvider}
///   backend.tokenProvider → transport → connectionState
///   {restApi, tokenProvider, connectionState, authEvents} → authController
///   authController(user) + restApi → channels → chatRepository → messages
///
/// Hand-written providers (no codegen) to match the data layer's deliberate
/// no-Freezed/no-build_runner convention (design 01).
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/token_provider.dart';
import '../features/chat/data/cache/drift_cache.dart';
import '../features/chat/data/chat_rest_api.dart';
import '../features/chat/data/gateway_rest_api.dart';
import '../features/chat/data/transport/chat_transport.dart';
import '../features/chat/data/transport/gateway_transport.dart';
import '../services/secure_token_store.dart';
import 'config.dart';

// --- config ----------------------------------------------------------------

/// Where the gateway lives (from `--dart-define`). Overridable in tests/dev.
final configProvider = Provider<GatewayConfig>(
  (ref) => GatewayConfig.fromEnvironment(),
);

// --- credentials -----------------------------------------------------------

/// The encrypted JWT store. Tests override this with an `InMemoryTokenStore`.
final secureTokenStoreProvider = Provider<SecureTokenStore>(
  (ref) => SecureTokenStore(),
);

/// A broadcast sink for "the session is now *terminally* unauthenticated"
/// (a REST refresh-token rejection, fired by [DefaultTokenProvider]'s
/// `onUnauthenticated`). The auth controller listens to its stream. This
/// decouples the infra-layer backend builder from the app-layer auth
/// controller — the backend pushes an event, it never imports the controller,
/// so there is no provider/import cycle. Distinct from the transport's
/// `ConnectionState.unauthenticated` (the WSS-initiated twin of the same
/// signal); the controller reconciles BOTH into one logout.
final authEventsProvider = Provider<StreamController<void>>((ref) {
  final controller = StreamController<void>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

/// The gateway backend: a token-less client (login/refresh), a single-flight
/// token provider, and an interceptor-wrapped authed client — wired cycle-free
/// by [buildGatewayBackend]. The token provider is shared with the transport so
/// REST and WSS draw from ONE source of tokens.
final backendProvider = Provider<({ChatRestApi api, DefaultTokenProvider tokens})>(
  (ref) {
    final config = ref.watch(configProvider);
    final store = ref.watch(secureTokenStoreProvider);
    final events = ref.watch(authEventsProvider);
    return buildGatewayBackend(
      baseUrl: config.httpBaseUrl,
      store: store,
      // Lazy: only fires at runtime on a definitive RT rejection, long after
      // the auth controller exists — pushing onto the event sink (no cycle).
      onUnauthenticated: () => events.add(null),
    );
  },
);

/// The REST seam the UI + repository depend on (never `dio`).
final restApiProvider = Provider<ChatRestApi>(
  (ref) => ref.watch(backendProvider).api,
);

/// The shared single-flight token provider (used by REST interceptor + WSS).
final tokenProviderProvider = Provider<DefaultTokenProvider>(
  (ref) => ref.watch(backendProvider).tokens,
);

// --- realtime + cache ------------------------------------------------------

/// The realtime transport — a SESSION SINGLETON whose streams outlive every
/// reconnect (invariant B-live). Disposed with the provider scope.
final transportProvider = Provider<ChatTransport>((ref) {
  final config = ref.watch(configProvider);
  final tokens = ref.watch(tokenProviderProvider);
  final transport = GatewayTransport(
    wsBaseUrl: config.wsBaseUrl,
    tokens: tokens,
  );
  ref.onDispose(transport.disconnect);
  return transport;
});

/// The local message cache. Phase 1 is `NativeDatabase.memory()` — history is
/// lost on restart and the reconnect-resume watermark is moot until a
/// file-backed cache lands (task #40, a named B-UI fast-follow tradeoff).
///
/// `autoDispose`: the cache is SESSION-scoped (only the autoDispose chat layer
/// watches it). Logging out unmounts the chat screen → the repo disposes (writes
/// stop) and then this closes — so a different user logging in gets a fresh,
/// empty DB. Session isolation by lifecycle, not by manual clear (Carnot C3).
final cacheProvider = Provider.autoDispose<DriftCache>((ref) {
  final cache = DriftCache(NativeDatabase.memory());
  ref.onDispose(cache.close);
  return cache;
});

/// The live connection lifecycle the UI watches for its banner. Distinct
/// states: `connecting`/`connected`/`disconnected` (transient) vs
/// `unauthenticated` (terminal — the auth controller turns it into a logout).
final connectionStateProvider = StreamProvider<ConnectionState>(
  (ref) => ref.watch(transportProvider).connectionState,
);
