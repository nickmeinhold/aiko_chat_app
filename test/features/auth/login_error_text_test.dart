// The login screen's error banner (login_screen.dart `_authErrorText`).
//
// The bug this pins: a passkey ceremony that failed for a KNOWN reason
// (no credential on device, domain not associated, unsupported device) used to
// collapse into a blanket "Something went wrong. Please try again." — which is
// what left Nick staring at a dead-end on the first live build.
//
// These drive the FULL wire the failure actually travels: the platform
// authenticator throws `SocialSignInFailed('Passkey: <code>')` (the exact shape
// PlatformPasskeyAuthClient emits — see passkey_auth_client.dart:96-98), the
// controller records it via AsyncValue.guard, and the screen must render
// actionable text. The load-bearing property is the FALLBACK: an UNMAPPED code
// must surface its raw text ("Sign-in failed: …"), never the generic message —
// so a new failure mode is never invisible again.

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_provider.dart';
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
    final passkey =
        FakePasskeyAuthClient(authenticateThrows: authenticateThrows);
    final tokenStore = InMemoryTokenStore();
    late final ProviderContainer container;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      passkeyAuthClientProvider.overrideWithValue(passkey),
      tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
        store: tokenStore,
        remoteRefresh: (_) async => 'access2',
        onUnauthenticated: () {},
      )),
      // Keep the button list off the network; the banner is under test, not the
      // buttons, so an empty list (→ native fallback) is enough to render.
      authProvidersProvider.overrideWith((ref) async => const <AuthProviderInfo>[]),
    ]);
    addTearDown(container.dispose);

    // Settle cold-start restore to logged-out so the ingress guard lets the
    // ceremony run (FakeRestApi.me() default is logged-out).
    expect(await container.read(authControllerProvider.future), isNull);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: LoginScreen()),
    ));

    await container.read(authControllerProvider.notifier).signInWithPasskey();
    await tester.pump();

    final host = Uri.parse(container.read(configProvider).httpBaseUrl).host;
    return (container: container, host: host);
  }

  group('LoginScreen error banner (_authErrorText)', () {
    testWidgets('no-credentials-available → nudge toward Create a passkey',
        (tester) async {
      await pumpFailedSignIn(tester,
          authenticateThrows:
              const SocialSignInFailed('Passkey: no-credentials-available'));

      expect(find.textContaining('No passkey found on this device'),
          findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsNothing);
    });

    testWidgets('domain-not-associated → names the gateway host',
        (tester) async {
      final r = await pumpFailedSignIn(tester,
          authenticateThrows:
              const SocialSignInFailed('Passkey: domain-not-associated'));

      expect(find.textContaining("aren't linked to"), findsOneWidget);
      // The host is interpolated so the user knows WHICH server isn't linked.
      expect(find.textContaining(r.host), findsWidgets);
    });

    testWidgets('deviceNotSupported → plain unsupported message',
        (tester) async {
      await pumpFailedSignIn(tester,
          authenticateThrows:
              const SocialSignInFailed('Passkey: deviceNotSupported'));

      expect(find.textContaining("doesn't support passkeys"), findsOneWidget);
    });

    testWidgets('an UNMAPPED code surfaces its RAW text, never the generic',
        (tester) async {
      // The never-blind-again property: a code the mapping doesn't know about
      // must still reach the user verbatim, so a future failure mode is visible.
      await pumpFailedSignIn(tester,
          authenticateThrows:
              const SocialSignInFailed('Passkey: some-brand-new-error'));

      expect(find.textContaining('Sign-in failed: Passkey: some-brand-new-error'),
          findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsNothing);
    });
  });
}
