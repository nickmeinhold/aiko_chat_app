// Gateway picker (#4): the persisted config resolution + the security-critical
// switchIsland contract.
//
// switchIsland is the load-bearing correctness point: JWTs are minted by and
// valid only at the issuing gateway, so re-pointing the app is a SESSION
// boundary. The contract these tests pin (and RED-prove):
//   - a switch to a DIFFERENT gateway tears the session down — tokens cleared,
//     socket disconnected, state logged-out — and flips + persists the config;
//   - re-selecting the CURRENT gateway is a strict no-op — it must NEVER nuke a
//     live session (guarded on the normalized base URL).
// RED-prove: delete `await logout()` → the teardown test goes green-to-red;
// delete the `next == current` guard → the no-op test goes green-to-red.

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/settings/application/island_directory_provider.dart';
import 'package:aiko_chat_app/features/settings/domain/island_entry.dart';
import 'package:aiko_chat_app/features/settings/presentation/island_picker_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

// The key the app WRITES. A pre-vocabulary install's value under
// `aiko_gateway_base_url` is adopted forward on read — see
// `test/core/prefs/pref_key_migration_test.dart`.
const _kKey = 'aiko_island_base_url';

void main() {
  group('IslandConfigController resolution order', () {
    test('with nothing persisted, resolves the prod default', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);

      expect(c.read(configProvider).httpBaseUrl, kDefaultIslandBaseUrl);
    });

    test('a persisted choice WINS over the default', () async {
      SharedPreferences.setMockInitialValues({_kKey: 'http://localhost:8095/'});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);

      // Resolved AND normalized (trailing slash stripped).
      expect(c.read(configProvider).httpBaseUrl, 'http://localhost:8095');
    });
  });

  group('AuthController.switchIsland', () {
    /// A logged-in container: real config + real auth controller, leaf seams
    /// faked. Seeded tokens + FakeRestApi.me() restore the session to logged-in.
    Future<
      ({
        ProviderContainer container,
        InMemoryTokenStore store,
        FakeChatTransport transport,
        SharedPreferences prefs,
      })
    >
    loggedInContainer() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = InMemoryTokenStore(
        const AuthTokens(accessToken: 'a', refreshToken: 'r'),
      );
      final transport = FakeChatTransport();
      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sessionVaultProvider.overrideWithValue(store),
          restApiProvider.overrideWithValue(FakeRestApi()),
          transportProvider.overrideWithValue(transport),
          tokenProviderProvider.overrideWithValue(
            DefaultTokenProvider(
              island: kTestIsland,
              vault: store,
              remoteRefresh: (_) async => RefreshResult('a2'),
            ),
          ),
        ],
      );
      // Drive the cold-start restore to a logged-in session.
      await container.read(authControllerProvider.future);
      expect(
        container.read(authControllerProvider).value,
        isNotNull,
        reason: 'precondition: session restored to logged-in',
      );
      // Initial gateway is the prod default (nothing persisted).
      expect(container.read(configProvider).httpBaseUrl, kDefaultIslandBaseUrl);
      return (
        container: container,
        store: store,
        transport: transport,
        prefs: prefs,
      );
    }

    test(
      'switching to a DIFFERENT island tears down the session AND switches',
      () async {
        final h = await loggedInContainer();
        addTearDown(h.container.dispose);

        await h.container
            .read(authControllerProvider.notifier)
            .switchIsland('http://localhost:8095');

        // Session torn down — the JWT for the old gateway is gone before any call
        // could fire it at the new host.
        expect(h.store.current, isNull, reason: 'tokens cleared on switch');
        expect(
          h.transport.disconnectCalls,
          greaterThanOrEqualTo(1),
          reason: 'old socket disconnected',
        );
        expect(
          h.container.read(authControllerProvider).value,
          isNull,
          reason: 'logged out → router lands on /login for the new gateway',
        );
        // Config flipped + persisted.
        expect(
          h.container.read(configProvider).httpBaseUrl,
          'http://localhost:8095',
        );
        expect(h.prefs.getString(_kKey), 'http://localhost:8095');
      },
    );

    test(
      'the switch shows ONE picture, signed out, with the config already on '
      'the new island: no frame offers /login on the old one',
      () async {
        // A plain logout() would show signed out before the config moved, so
        // the router could land on /login against the OLD island. The switch
        // is one transition: the router sees only its final picture.
        final h = await loggedInContainer();
        addTearDown(h.container.dispose);

        final seen = <(bool, String)>[];
        h.container.listen(
          sessionPictureProvider,
          (_, next) => seen.add((
            next.auth.value != null,
            h.container.read(configProvider).httpBaseUrl,
          )),
          fireImmediately: false,
        );

        await h.container
            .read(authControllerProvider.notifier)
            .switchIsland('http://localhost:8095');

        expect(seen, [(false, 'http://localhost:8095')]);
      },
    );

    test('a teardown failure still flips config to the new gateway (no '
        'old-gateway login window on the error path)', () async {
      // Carnot re-review: if _teardownResources throws (e.g. transport.disconnect
      // after tokens are cleared), the config flip must STILL happen — otherwise
      // the app lands on /login against the OLD cached gateway while the new one
      // is already persisted. RED-prove: move `ref.invalidate` out of the finally
      // (into the try, before teardown can throw) → this fails.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = InMemoryTokenStore(
        const AuthTokens(accessToken: 'a', refreshToken: 'r'),
      );
      final transport = _ThrowingDisconnectTransport();
      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sessionVaultProvider.overrideWithValue(store),
          restApiProvider.overrideWithValue(FakeRestApi()),
          transportProvider.overrideWithValue(transport),
          tokenProviderProvider.overrideWithValue(
            DefaultTokenProvider(
              island: kTestIsland,
              vault: store,
              remoteRefresh: (_) async => RefreshResult('a2'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authControllerProvider.future);

      // Does not throw (teardown error swallowed — the switch still completed).
      await container
          .read(authControllerProvider.notifier)
          .switchIsland('http://localhost:8095');

      expect(
        transport.disconnectCalls,
        greaterThanOrEqualTo(1),
        reason: 'teardown was attempted',
      );
      expect(
        container.read(configProvider).httpBaseUrl,
        'http://localhost:8095',
        reason: 'config flipped to the new gateway despite teardown error',
      );
      expect(container.read(authControllerProvider).value, isNull);
    });

    test(
      'a sign-out that does not reach the disk STOPS the switch: the island '
      'is not saved, the config does not move, and it is surfaced',
      () async {
        // The end must be on disk before the island moves, or the next launch
        // could place the old session on the new island. A failed end is
        // surfaced (picker and /login), and the app is signed out where it was.
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = _ThrowingClearStore(
          const AuthTokens(accessToken: 'a', refreshToken: 'r'),
        );
        late final ProviderContainer container;
        container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            sessionVaultProvider.overrideWithValue(store),
            restApiProvider.overrideWithValue(FakeRestApi()),
            transportProvider.overrideWithValue(FakeChatTransport()),
            tokenProviderProvider.overrideWithValue(
              DefaultTokenProvider(
                island: kTestIsland,
                vault: store,
                remoteRefresh: (_) async => RefreshResult('a2'),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authControllerProvider.future);

        final before = container.read(configProvider).httpBaseUrl;
        await expectLater(
          container
              .read(authControllerProvider.notifier)
              .switchIsland('http://localhost:8095'),
          throwsA(isA<SignOutUnsaved>()),
          reason: 'an unsaved sign-out surfaces instead of being swallowed',
        );
        expect(container.read(configProvider).httpBaseUrl, before);
        expect(prefs.getString(_kKey), isNull, reason: 'the island not saved');
        final auth = container.read(authControllerProvider);
        expect(auth.value, isNull);
        expect(auth.error, isA<SignOutUnsaved>(), reason: 'shown on /login');
        expect(auth.isLoading, isFalse, reason: 'not stuck on /splash');
      },
    );

    test(
      're-selecting the CURRENT gateway is a no-op (keeps the session)',
      () async {
        final h = await loggedInContainer();
        addTearDown(h.container.dispose);

        // Same gateway, with a trailing slash — normalization must treat it as a
        // no-op and NOT log the user out.
        await h.container
            .read(authControllerProvider.notifier)
            .switchIsland('$kDefaultIslandBaseUrl/');

        expect(h.store.current, isNotNull, reason: 'tokens kept — no logout');
        expect(h.transport.disconnectCalls, 0, reason: 'no teardown on no-op');
        expect(
          h.container.read(authControllerProvider).value,
          isNotNull,
          reason: 'still logged in',
        );
        // Persistence untouched (no write on a no-op).
        expect(h.prefs.getString(_kKey), isNull);
      },
    );
  });

  group('IslandPickerScreen', () {
    Future<ProviderContainer> pumpPicker(
      WidgetTester tester, {
      List<IslandEntry> directory = const [],
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = InMemoryTokenStore(
        const AuthTokens(accessToken: 'a', refreshToken: 'r'),
      );
      final transport = FakeChatTransport();
      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sessionVaultProvider.overrideWithValue(store),
          restApiProvider.overrideWithValue(FakeRestApi()),
          transportProvider.overrideWithValue(transport),
          tokenProviderProvider.overrideWithValue(
            DefaultTokenProvider(
              island: kTestIsland,
              vault: store,
              remoteRefresh: (_) async => RefreshResult('a2'),
            ),
          ),
          // No live directory here — these tests exercise the picker/switch flow,
          // not discovery. An empty result makes the screen render the known seed
          // set and fires no real network (which would leak a pending timer).
          islandDirectoryProvider.overrideWith((ref) async => directory),
        ],
      );
      await container.read(authControllerProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: IslandPickerScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets(
      'an island that publishes a description shows it, and keeps the URL',
      (tester) async {
        // ADR-0008 puts `description` in the COSMETIC tier — untrusted
        // self-description, safe to render as-is. The URL stays because it is
        // the island's IDENTITY; demoting the checkable fact to make room for
        // the unverifiable one would be the wrong trade.
        final container = await pumpPicker(
          tester,
          directory: const [
            IslandEntry(
              label: 'Imagineering',
              httpBaseUrl: 'https://chat.imagineering.cc',
              description: "Imagineering's island",
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(find.text("Imagineering's island"), findsOneWidget);
        expect(find.text('https://chat.imagineering.cc'), findsOneWidget);
      },
    );

    testWidgets('ABSENT IS FINE: no description renders exactly the old tile', (
      tester,
    ) async {
      // The common path today — neither live island publishes one — and the
      // one this change must not disturb. A description-shaped hole (an empty
      // line, a stray separator) would be a regression on every tile for a
      // field nobody has filled in yet.
      final container = await pumpPicker(
        tester,
        directory: const [
          IslandEntry(label: 'Enspyr', httpBaseUrl: 'https://chat.enspyr.co'),
        ],
      );
      addTearDown(container.dispose);

      expect(find.text('Enspyr'), findsOneWidget);
      expect(find.text('https://chat.enspyr.co'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Enspyr'), matching: find.byType(ListTile)),
      );
      expect(tile.isThreeLine, isFalse);
      expect(tile.subtitle, isA<Text>());
    });

    testWidgets('renders the presets and marks the active gateway', (
      tester,
    ) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      expect(find.text('Production'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Android emulator'), findsOneWidget);
      // Initial gateway is prod → its tile shows "Connected".
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('confirming a different preset switches the gateway', (
      tester,
    ) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      await tester.tap(find.text('Local'));
      await tester.pumpAndSettle();
      // The confirm dialog warns about sign-out before committing.
      expect(find.text('Switch island?'), findsOneWidget);

      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();

      expect(
        container.read(configProvider).httpBaseUrl,
        'http://localhost:8095',
      );
    });

    // The wide sidebar's island switcher was deleted (its row became the island
    // MARK), and the only assertion that picking your CURRENT island cannot
    // cost you your session lived in its test. The behaviour has to keep a home.
    //
    // It is not the same mechanism, and the difference is the point. The menu
    // let you SELECT the island you were already on and then caught it with a
    // snackbar — a window that has to stay guarded forever. The picker gives the
    // connected tile no `onTap` at all, so the state is never entered. Pinning
    // the guard here would have pinned the weaker of the two.
    testWidgets('the island you are ON is not selectable — the no-op cannot be '
        'entered, rather than being caught after the fact', (tester) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      final before = container.read(configProvider).httpBaseUrl;
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Production'),
          matching: find.byType(ListTile),
        ),
      );
      expect(
        tile.onTap,
        isNull,
        reason:
            'The connected island must not be tappable. A tappable one relies '
            'on a downstream guard to stop a pointless re-login; an untappable '
            'one cannot start it.',
      );
      // NOT `tile.selected` — `_IslandTile` never forwards that flag to the
      // ListTile, it only uses it to pick the icon, the trailing label and
      // whether onTap is null. Assert the marker a person actually sees.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Production'),
            matching: find.byType(ListTile),
          ),
          matching: find.text('Connected'),
        ),
        findsOneWidget,
      );

      // And nothing moved: the assertion above is about the affordance, this
      // one is about the state it protects.
      expect(container.read(configProvider).httpBaseUrl, before);
    });

    testWidgets('an invalid custom URL is rejected (no switch)', (
      tester,
    ) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      await tester.enterText(find.byType(TextField), 'not a url');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      // No confirm dialog, gateway unchanged.
      expect(find.text('Switch island?'), findsNothing);
      expect(container.read(configProvider).httpBaseUrl, kDefaultIslandBaseUrl);
    });
  });
}

/// A transport whose `disconnect` throws AFTER recording the attempt — to drive
/// the teardown-error path of `switchIsland` (Carnot re-review).
class _ThrowingDisconnectTransport extends FakeChatTransport {
  @override
  Future<void> disconnect() async {
    await super.disconnect(); // increments disconnectCalls
    throw Exception('disconnect boom');
  }
}

/// A token store whose Keychain refuses every write and delete, so the vault
/// can neither record a sign-out nor remove the session — to drive the
/// security-critical token-clear failure path of `switchIsland` (Carnot final
/// re-review).
class _ThrowingClearStore extends InMemoryTokenStore {
  _ThrowingClearStore(AuthTokens initial) : super(initial) {
    slots.fault = (op, key) {
      if (op != 'read') throw Exception('keychain $op boom');
    };
  }
}
