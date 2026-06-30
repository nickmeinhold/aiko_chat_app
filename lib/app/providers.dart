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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/auth/token_provider.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/data/broker_auth_client.dart';
import '../features/auth/data/gateway_social_auth_client.dart';
import '../features/auth/data/passkey_auth_client.dart';
import '../features/auth/data/social_auth_client.dart';
import '../features/auth/domain/auth_provider.dart';
import '../features/chat/data/cache/cache_database.dart';
import '../features/chat/data/cache/drift_cache.dart';
import '../features/chat/data/chat_rest_api.dart';
import '../features/chat/data/gateway_rest_api.dart';
import '../features/chat/data/transport/chat_transport.dart';
import '../features/chat/data/transport/gateway_transport.dart';
import '../services/secure_token_store.dart';
import 'config.dart';

// --- config ----------------------------------------------------------------

/// The platform key-value store, loaded once in `main()` (it's async to obtain)
/// and injected here so [GatewayConfigController.build] can read the persisted
/// gateway synchronously. A throwing default means a `main()` that forgot the
/// override fails loudly at first read rather than silently losing persistence.
/// Tests that build [configProvider] override this with an in-memory instance
/// (`SharedPreferences.setMockInitialValues({})`).
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main() with the loaded '
    'SharedPreferences instance (see lib/main.dart).',
  ),
);

/// The persistence key for the user's chosen gateway base URL.
const _kGatewayBaseUrlKey = 'aiko_gateway_base_url';

/// Where the gateway lives — a RUNTIME-mutable, persisted value (the #4 picker).
///
/// `ref.watch(configProvider)` stays synchronous (a [Notifier]'s `build` is
/// sync), so [backendProvider] and [transportProvider] are untouched: changing
/// the gateway flips this state, and the REST backend + WSS transport rebuild
/// automatically against the new host (transport's `onDispose` disconnects the
/// old socket cleanly).
final configProvider =
    NotifierProvider<GatewayConfigController, GatewayConfig>(
  GatewayConfigController.new,
);

/// Owns the gateway selection: resolves the initial value and persists changes.
///
/// Resolution order in [build]: a persisted choice wins; otherwise fall back to
/// [GatewayConfig.fromEnvironment] (`--dart-define` → hardcoded prod). The actual
/// switch is NOT performed here — [AuthController.switchGateway] orchestrates the
/// session teardown (JWTs are gateway-specific) before calling [setGateway], so
/// the security-critical token-clear can't be bypassed by a direct setter call.
class GatewayConfigController extends Notifier<GatewayConfig> {
  @override
  GatewayConfig build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final persisted = prefs.getString(_kGatewayBaseUrlKey);
    if (persisted != null && persisted.trim().isNotEmpty) {
      return GatewayConfig.normalized(persisted);
    }
    return GatewayConfig.fromEnvironment();
  }

  /// Persist and adopt [httpBaseUrl] as the active gateway. Internal to the
  /// switch ceremony — see [AuthController.switchGateway].
  Future<void> setGateway(String httpBaseUrl) async {
    final next = GatewayConfig.normalized(httpBaseUrl);
    await ref
        .read(sharedPreferencesProvider)
        .setString(_kGatewayBaseUrlKey, next.httpBaseUrl);
    state = next;
  }
}

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

/// The social sign-in seam (Apple/Google native SDKs). Tests override this with
/// a fake so the auth controller is exercised without a platform channel.
final socialAuthClientProvider = Provider<SocialAuthClient>(
  (ref) => GatewaySocialAuthClient(),
);

/// The OAuth-broker sign-in seam (GitHub, …). Drives the system web-auth session
/// against the gateway's `/oauth/{slug}/start`. Tests override this with a fake.
final brokerAuthClientProvider = Provider<BrokerAuthClient>(
  (ref) => WebAuthBrokerClient(httpBaseUrl: ref.watch(configProvider).httpBaseUrl),
);

/// The passkey (WebAuthn) sign-in seam — drives the on-device authenticator
/// (iOS AuthenticationServices / Android Credential Manager). Stateless, so a
/// plain singleton; tests override this with a fake.
final passkeyAuthClientProvider = Provider<PasskeyAuthClient>(
  (ref) => PlatformPasskeyAuthClient(),
);

/// The gateway's advertised sign-in providers (native + broker), for the dynamic
/// login UI. A [FutureProvider] so the login screen can render loading/error
/// states; `ref.invalidate` to retry a failed fetch.
final authProvidersProvider = FutureProvider<List<AuthProviderInfo>>(
  (ref) => ref.watch(restApiProvider).listAuthProviders(),
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

/// The local message cache — a **per-user, file-backed** SQLite database, the
/// durable home of message history AND the B4 reconnect watermark
/// (`historyContiguousThrough`). File-backing is what makes the reconnect-resume
/// machinery meaningful: an in-memory cache wiped on every launch has nothing for
/// the forward-fill to resume *from*.
///
/// The file is keyed on the authenticated user id (see [openUserCache]), which
/// preserves the session isolation the old in-memory design got from autoDispose:
/// two users on one device open *different* files, so neither can read the
/// other's history (Carnot C3). A null user id (no session) → ephemeral memory DB.
///
/// `autoDispose` + `.select` on the user id: the provider rebuilds only when the
/// user actually changes (not on transient auth emissions). Logging out unmounts
/// the chat screen → the repo disposes (writes stop) and then this closes the DB;
/// a different user logging in builds a fresh executor over *their* file.
final cacheProvider = Provider.autoDispose<DriftCache>((ref) {
  final userId = ref.watch(
    authControllerProvider.select((s) => s.value?.userId),
  );
  final cache = DriftCache(openUserCache(userId));
  ref.onDispose(cache.close);
  return cache;
});

/// The live connection lifecycle the UI watches for its banner. Distinct
/// states: `connecting`/`connected`/`disconnected` (transient) vs
/// `unauthenticated` (terminal — the auth controller turns it into a logout).
final connectionStateProvider = StreamProvider<ConnectionState>(
  (ref) => ref.watch(transportProvider).connectionState,
);
