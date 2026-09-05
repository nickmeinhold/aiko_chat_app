// The login screen's error banner (login_screen.dart `_authErrorText`).
//
// The bug this pins: a passkey ceremony that failed for a KNOWN reason
// (no credential on device, domain not associated, unsupported device) used to
// collapse into a blanket "Something went wrong. Please try again." — which is
// what left Nick staring at a dead-end on the first live build.
//
// These drive the FULL wire the failure actually travels: the platform
// authenticator throws `AuthCeremonyFailed('Passkey: <code>')` (the exact shape
// PlatformPasskeyAuthClient emits — see passkey_auth_client.dart), the
// controller records it via AsyncValue.guard, and the screen must render
// actionable text. The load-bearing property is the FALLBACK: an UNMAPPED code
// must surface its raw text ("Sign-in failed: …"), never the generic message —
// so a new failure mode is never invisible again.

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/auth_exceptions.dart';
import 'package:aiko_chat_app/features/auth/presentation/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

void main() {
  /// Pump the login screen with a passkey authenticator primed to throw
  /// [authenticateThrows], then drive a passkey sign-in so the controller lands
  /// in an error state and the banner renders. Returns the resolved gateway host
  /// so a test can assert host interpolation without hard-coding the default.
  Future<({ProviderContainer container, String host})> pumpFailedSignIn(
    WidgetTester tester, {
    required Object authenticateThrows,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final rest = FakeRestApi();
    final passkey = FakePasskeyAuthClient(
      authenticateThrows: authenticateThrows,
    );
    final tokenStore = InMemoryTokenStore();
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        restApiProvider.overrideWithValue(rest),
        transportProvider.overrideWithValue(FakeChatTransport()),
        passkeyAuthClientProvider.overrideWithValue(passkey),
        tokenProviderProvider.overrideWithValue(
          DefaultTokenProvider(
            store: tokenStore,
            remoteRefresh: (_) async => 'access2',
            onUnauthenticated: () {},
          ),
        ),
        // Login screen mounts NetworkStatusBanner → fake connectivity/reachability
        // so the test never touches the platform channel or the network.
        connectivityServiceProvider.overrideWithValue(
          FakeConnectivityService(),
        ),
        reachabilityProbeProvider.overrideWithValue(FakeReachabilityProbe()),
        // Stub the 5s-Timer reachability loop so the pumped login screen doesn't
        // leave a pending timer at test teardown.
        islandReachableProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );
    addTearDown(container.dispose);

    // Settle cold-start restore to logged-out so the ingress guard lets the
    // ceremony run (FakeRestApi.me() default is logged-out).
    expect(await container.read(authControllerProvider.future), isNull);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    await container.read(authControllerProvider.notifier).signInWithPasskey();
    await tester.pump();

    final host = Uri.parse(container.read(configProvider).httpBaseUrl).host;
    return (container: container, host: host);
  }

  /// Pump the login screen with NO ceremony driven — just the resting state, with
  /// the passkey hint pre-seeded or not. This is the arm that was missing: every
  /// existing test drove a FAILURE and asserted the banner, so nothing ever looked
  /// at what the screen offers BEFORE you touch it — which is the only thing an App
  /// Store reviewer sees.
  Future<ProviderContainer> pumpFreshLogin(
    WidgetTester tester, {
    required bool passkeySeen,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        restApiProvider.overrideWithValue(FakeRestApi()),
        transportProvider.overrideWithValue(FakeChatTransport()),
        passkeyAuthClientProvider.overrideWithValue(FakePasskeyAuthClient()),
        // Without this the controller reaches for a real token provider and the
        // cold-start restore never settles — the run hangs rather than fails.
        tokenProviderProvider.overrideWithValue(
          DefaultTokenProvider(
            store: InMemoryTokenStore(),
            remoteRefresh: (_) async => 'access2',
            onUnauthenticated: () {},
          ),
        ),
        connectivityServiceProvider.overrideWithValue(FakeConnectivityService()),
        reachabilityProbeProvider.overrideWithValue(FakeReachabilityProbe()),
        islandReachableProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );
    addTearDown(container.dispose);
    if (passkeySeen) {
      await container
          .read(passkeyHintStoreProvider)
          .markSeen(container.read(configProvider).httpBaseUrl);
    }
    expect(await container.read(authControllerProvider.future), isNull);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();
    return container;
  }

  // WHAT A REVIEWER SEES. iOS 0.0.4 was REJECTED on 2026-09-05 — Apple: "We were
  // unable to access the app because an error message prompted after we tried to
  // login" (iPhone 17 Pro Max, iOS 26.6.1, active internet). On a fresh install
  // there is no passkey, so "Already have a passkey? Sign in" CANNOT succeed — and
  // the screen gave it equal standing with the one that works.
  group('LoginScreen ingress emphasis', () {
    testWidgets('FRESH DEVICE: Create is the primary action, and Sign in is still '
        'reachable', (tester) async {
      await pumpFreshLogin(tester, passkeySeen: false);

      expect(
        find.widgetWithText(FilledButton, 'Create a passkey'),
        findsOneWidget,
        reason: 'the ingress that CAN work on a fresh device must be primary',
      );
      // Demoted, NOT removed. A passkey outlives the app: a reinstall or an
      // iCloud-Keychain restore leaves a real credential with no local hint, and
      // hiding sign-in would strand that user. `seen == false` means "no
      // evidence", never "no passkey".
      expect(
        find.widgetWithText(TextButton, 'Already have a passkey? Sign in'),
        findsOneWidget,
        reason: 'sign-in must remain reachable for reinstall / keychain restore',
      );
    });

    testWidgets('RETURNING DEVICE: the emphasis reverses', (tester) async {
      await pumpFreshLogin(tester, passkeySeen: true);

      expect(
        find.widgetWithText(FilledButton, 'Sign in with your passkey'),
        findsOneWidget,
        reason: 'a device that has completed a ceremony should lead with sign-in',
      );
      expect(
        find.widgetWithText(TextButton, 'Create a new passkey'),
        findsOneWidget,
        reason: 'creating another passkey stays available, demoted',
      );
    });

    testWidgets('the hint is keyed PER ISLAND — another island does not inherit it',
        (tester) async {
      final c = await pumpFreshLogin(tester, passkeySeen: true);
      final hint = c.read(passkeyHintStoreProvider);
      expect(hint.seenFor(c.read(configProvider).httpBaseUrl), isTrue);
      expect(
        hint.seenFor('https://chat.enspyr.co'),
        isFalse,
        reason:
            'a passkey is scoped to a relying party; one island must never vouch '
            'for another',
      );
    });
  });

  group('LoginScreen error banner (_authErrorText)', () {
    testWidgets('no-credentials-available → nudge toward Create a passkey', (
      tester,
    ) async {
      await pumpFailedSignIn(
        tester,
        authenticateThrows: const AuthCeremonyFailed(
          'Passkey: no-credentials-available',
        ),
      );

      expect(
        find.textContaining('No passkey found on this device'),
        findsOneWidget,
      );
      expect(find.textContaining('Something went wrong'), findsNothing);
    });

    // REWRITTEN 2026-09-05 after an App Store REJECTION. The old assertion pinned
    // the string "aren't linked to", i.e. it pinned a sentence that blamed the
    // ISLAND for a device-side condition — and an Apple reviewer read that sentence
    // while chat.imagineering.cc was serving a correct AASA, Apple's own CDN was
    // caching it, and the shipped binary carried the right associated-domains
    // entitlement. The test was green the whole time, because it asserted the
    // wording rather than the wording's TRUTH or its usefulness.
    //
    // What is pinned now is the property that actually failed review: the message
    // must name a RECOVERY ACTION and must NOT assert a server fault.
    testWidgets('domain-not-associated → offers a recovery action and does NOT '
        'blame the island', (tester) async {
      final r = await pumpFailedSignIn(
        tester,
        authenticateThrows: const AuthCeremonyFailed(
          'Passkey: domain-not-associated',
        ),
      );

      // Still says WHICH island — that part was right.
      expect(find.textContaining(r.host), findsWidgets);

      // The recovery action is present: the user is pointed at the one control
      // that resolves this, rather than left at a wall.
      expect(find.textContaining('Create a passkey'), findsWidgets);

      // And the island is NOT accused. These are the exact phrasings that were on
      // screen when review rejected us; a regression to any of them is a
      // regression to a false statement about someone else's infrastructure.
      expect(find.textContaining("aren't linked to"), findsNothing);
      expect(find.textContaining('domain association'), findsNothing);
      expect(find.textContaining('still pending'), findsNothing);
    });

    testWidgets('deviceNotSupported → plain unsupported message', (
      tester,
    ) async {
      await pumpFailedSignIn(
        tester,
        authenticateThrows: const AuthCeremonyFailed(
          'Passkey: deviceNotSupported',
        ),
      );

      expect(find.textContaining("doesn't support passkeys"), findsOneWidget);
    });

    testWidgets('an UNMAPPED code surfaces its RAW text, never the generic', (
      tester,
    ) async {
      // The never-blind-again property: a code the mapping doesn't know about
      // must still reach the user verbatim, so a future failure mode is visible.
      await pumpFailedSignIn(
        tester,
        authenticateThrows: const AuthCeremonyFailed(
          'Passkey: some-brand-new-error',
        ),
      );

      expect(
        find.textContaining('Sign-in failed: Passkey: some-brand-new-error'),
        findsOneWidget,
      );
      expect(find.textContaining('Something went wrong'), findsNothing);
    });
  });
}
