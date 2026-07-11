/// Provider-wiring integration tests (#33).
///
/// The unit-test pyramid is structurally BLIND to one class of bug: "is this
/// dependency-injected service actually wired to a real impl in the PRODUCTION
/// provider graph?" That blindness is exactly how the #16 `historySyncFault`
/// shipped as a complete no-op — RED-proven, two-agent-approved, and wired to
/// the silent `_NoopTelemetry` because `chatRepositoryProvider` never passed a
/// `telemetry:` arg. Carnot only caught it by reading a file the diff never
/// touched (`chat_providers.dart`). These tests build the real production graph
/// (overriding ONLY leaf I/O — sockets, REST, disk, auth) and assert the
/// constructed objects hold REAL collaborators, not silent noop/stub defaults.
///
/// The scope is cleaved by a structural fact: of `ChatRepository`'s injected
/// collaborators, ONLY `telemetry` has a silent default (`= _NoopTelemetry()`).
/// `cache`/`transport`/`rest`/`me`/`newTempId` are `required` — omitting them is
/// a COMPILE error, never a silent fallback. So the "wire degrades to a no-op"
/// class can only exist on a defaulted param. Telemetry gets a consumption-edge
/// test (the repo holds the provider's exact sink); the required seams just get
/// a "resolves the real impl, not a stub" check.
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/cache/cache_database.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/logging_chat_telemetry.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_chat_transport.dart';
import 'support/fakes.dart';
import 'support/test_helpers.dart' show installSecureStorageMock;

const _me = AppUser(
  userId: 'u1',
  username: 'nick',
  displayName: 'Nick',
  aikoUsername: 'nick',
);

/// Resolves to a fixed user WITHOUT running the real [AuthController.build]
/// (which wires connection-state listeners + an async session restore). Lets the
/// chat graph build offline against a known session.
class _FixedAuthController extends AuthController {
  _FixedAuthController(this._user);
  final AppUser? _user;
  @override
  Future<AppUser?> build() async => _user;
}

/// A container that builds the REAL `chatRepositoryProvider` body, with only the
/// leaf I/O faked: auth (fixed user), channels (empty), transport (no-op
/// connect), REST, and an in-memory cache. Telemetry is left to the real
/// `chatTelemetryProvider` unless [telemetryOverride] is supplied.
ProviderContainer _repoGraphContainer({ChatTelemetry? telemetryOverride}) {
  return ProviderContainer(overrides: [
    authControllerProvider.overrideWith(() => _FixedAuthController(_me)),
    channelsProvider.overrideWith((ref) async => const <Channel>[]),
    // FakeChatTransport.connect() is a no-op, so the production body's
    // `await transport.connect()` never opens a socket.
    transportProvider.overrideWithValue(FakeChatTransport()),
    restApiProvider.overrideWithValue(FakeChatRestApi()),
    cacheProvider.overrideWith((ref) => DriftCache(openUserCache(null))),
    if (telemetryOverride != null)
      chatTelemetryProvider.overrideWithValue(telemetryOverride),
  ]);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // The sovereign key store reads flutter_secure_storage when the real graph
  // builds; mock the channel in-memory (leaf I/O, like the SharedPreferences mock
  // the leaf group uses) so construction stays offline.
  setUpAll(installSecureStorageMock);

  group('chatRepositoryProvider telemetry wiring (#16 regression class)', () {
    test(
        'injects the sink from chatTelemetryProvider — the CONSUMPTION edge, not '
        'just the provider default', () async {
      // A distinct (non-const) sentinel: `same()` against it proves the repo read
      // chatTelemetryProvider AND injected its value. A const LoggingChatTelemetry
      // would be canonicalized — `same()` couldn't distinguish "read the provider"
      // from "hardcoded the same const"; the sentinel removes that ambiguity.
      final sentinel = SpyTelemetry();
      final container = _repoGraphContainer(telemetryOverride: sentinel);
      addTearDown(container.dispose);
      // Keep the autoDispose provider alive across the await.
      container.listen(chatRepositoryProvider, (_, _) {});

      final repo = await container.read(chatRepositoryProvider.future);

      // RED-prove: delete `telemetry: ref.watch(chatTelemetryProvider)` from
      // chat_providers.dart and the repo falls back to the silent _NoopTelemetry
      // default — debugTelemetry is no longer `same(sentinel)` → this fails. That
      // is the exact #16 no-op, caught by an automated test for the first time.
      expect(repo.debugTelemetry, same(sentinel));
    });

    test(
        'resolves a real LoggingChatTelemetry by default, never the silent '
        '_NoopTelemetry', () async {
      final container = _repoGraphContainer();
      addTearDown(container.dispose);
      container.listen(chatRepositoryProvider, (_, _) {});

      final repo = await container.read(chatRepositoryProvider.future);

      // The repo ends up holding the real logging sink the provider produces.
      // (Complements the test above: that one proves "repo uses whatever the
      // provider says"; this proves "the provider says LoggingChatTelemetry".)
      expect(repo.debugTelemetry, isA<LoggingChatTelemetry>());
      expect(repo.debugTelemetry, same(container.read(chatTelemetryProvider)));
    });

    test(
        'wires a REAL sovereign signing key — the same DI-no-op class as '
        'telemetry (sovereign-message-signing)', () async {
      // RED-prove: delete `signingKey: signingKey` from chat_providers.dart and
      // the repo's nullable _signingKey stays null → messages silently never get
      // signed. debugSigningKey being non-null is the automated guard.
      final container = _repoGraphContainer();
      addTearDown(container.dispose);
      container.listen(chatRepositoryProvider, (_, _) {});

      final repo = await container.read(chatRepositoryProvider.future);
      expect(repo.debugSigningKey, isNotNull);
      expect(repo.debugSigningKey!.rawPublicKey.length, 32);
    });
  });

  group('data-layer seams resolve their real impls (not stubs)', () {
    // These collaborators are `required` on ChatRepository, so they cannot
    // silently degrade to a no-op like telemetry could. This guards the adjacent
    // class — a seam quietly rewired to a STUB impl — by pinning each provider to
    // its real production type. Only the deepest leaves (token store, auth) are
    // faked so construction stays offline.
    late SharedPreferences prefs;
    setUpAll(() async {
      // The real transport/rest build configProvider, which reads
      // SharedPreferences; inject an in-memory instance so they resolve offline.
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    ProviderContainer leafContainer() => ProviderContainer(overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          authControllerProvider.overrideWith(() => _FixedAuthController(null)),
          secureTokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        ]);

    test('transportProvider resolves a real GatewayTransport', () {
      final c = leafContainer();
      addTearDown(c.dispose);
      expect(c.read(transportProvider), isA<GatewayTransport>());
    });

    test('restApiProvider resolves a real GatewayRestApi', () {
      final c = leafContainer();
      addTearDown(c.dispose);
      expect(c.read(restApiProvider), isA<GatewayRestApi>());
    });

    test('cacheProvider resolves a real DriftCache', () {
      final c = leafContainer();
      addTearDown(c.dispose);
      expect(c.read(cacheProvider), isA<DriftCache>());
    });
  });
}
