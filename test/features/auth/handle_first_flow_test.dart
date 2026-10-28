// Handle-first sign-up through the REAL app and router (#436, Nick 2026-10-28).
//
// "A new user is never asked for a handle" was reported on 2026-08-10 and again
// on 2026-10-28. Both times the machinery looked finished: a claim-handle
// screen existed, its route existed, and its tests were green, because the
// test fake answered registration with a PendingHandle the island had stopped
// sending in July (#1728). These tests drive what the island actually answers
// (a live session under an auto-assigned `aiko-…` handle) and assert what a
// person sees: asked first, and never in chat until a handle is chosen.

import 'dart:convert';

import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/handle_input.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show HandleTaken;
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/test_helpers.dart';
import '../../support/ui_fakes.dart';

const _owedKey = 'aiko_owed_handle';
final _screen = find.byKey(const Key('choose-handle-screen'));
final _field = find.byKey(const Key('choose-handle-field'));
final _submit = find.byKey(const Key('choose-handle-submit'));

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // testPrefs is suite-wide: clear the debt and the passkey hint so no test
  // inherits another's sign-up.
  setUp(() async {
    for (final k in testPrefs.getKeys().toList()) {
      if (k == _owedKey || k.startsWith('aiko_passkey_seen_')) {
        await testPrefs.remove(k);
      }
    }
  });

  Future<ProviderContainer> app(
    WidgetTester tester,
    FakeRestApi rest, {
    bool signedIn = false,
  }) async {
    final c = makeContainer(
      rest: rest,
      transport: FakeChatTransport(),
      store: signedIn
          ? InMemoryTokenStore(
              const AuthTokens(accessToken: 'a', refreshToken: 'r'),
            )
          : null,
    );
    addTearDown(c.dispose);
    await pumpApp(tester, c);
    return c;
  }

  testWidgets('"Create a passkey" asks for the handle FIRST, then the new '
      'account lands in chat under it', (tester) async {
    final rest = FakeRestApi(); // the island's real answer: an aiko-… handle
    final c = await app(tester, rest);

    await tester.tap(find.text('Create a passkey'));
    await tester.pumpAndSettle();
    expect(_screen, findsOneWidget);
    expect(
      rest.passkeyRegisterStartCalls,
      0,
      reason: 'no passkey exists before the handle is chosen',
    );

    await tester.enterText(_field, 'nicka');
    await tester.pump();
    expect(
      find.text('Create passkey as @nicka'),
      findsOneWidget,
      reason: 'the button names the handle it commits (30-day cooldown)',
    );
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(rest.lastPasskeyRegisterName, 'nicka');
    expect(c.read(authControllerProvider).value?.username, 'nicka');
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(_screen, findsNothing);
  });

  // The island bounds a handle at 64 CODE POINTS (pydantic). The app used to
  // count UTF-16 units, which refused emoji handles the island accepts.
  test('handle length is counted in code points, as the island counts it', () {
    final forty = '😀' * 40;
    expect(forty.length, 80, reason: 'UTF-16 units: the wrong ruler');
    expect(handleLength(forty), 40);
  });

  testWidgets('an emoji handle the island accepts is not refused by the app', (
    tester,
  ) async {
    final rest = FakeRestApi();
    await app(tester, rest);
    await tester.tap(find.text('Create a passkey'));
    await tester.pumpAndSettle();

    final forty = '😀' * 40; // 40 code points, 80 UTF-16 units
    await tester.enterText(_field, forty);
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(rest.lastPasskeyRegisterName, forty);
  });

  // The first outside user typed the "@" the field already shows: "@armbot"
  // was stored and rendered "@@armbot".
  test('a typed "@" is the prefix, never part of the handle', () {
    expect(normalizeHandle('@armbot'), 'armbot');
    expect(normalizeHandle('@@armbot'), 'armbot');
    expect(normalizeHandle('  @ nick '), 'nick');
    expect(normalizeHandle('ni@ck'), 'ni@ck', reason: 'only a LEADING @');
    expect(normalizeHandle('@'), '', reason: 'nothing left: refused as empty');
  });

  testWidgets('sign-up strips a typed "@" before naming the passkey', (
    tester,
  ) async {
    final rest = FakeRestApi();
    final c = await app(tester, rest);
    await tester.tap(find.text('Create a passkey'));
    await tester.pumpAndSettle();

    await tester.enterText(_field, '@armbot');
    await tester.pump();
    expect(find.text('Create passkey as @armbot'), findsOneWidget);
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(rest.lastPasskeyRegisterName, 'armbot');
    expect(c.read(authControllerProvider).value?.username, 'armbot');
  });

  testWidgets('a handle over 64 code points is refused BEFORE any passkey', (
    tester,
  ) async {
    final rest = FakeRestApi();
    await app(tester, rest);
    await tester.tap(find.text('Create a passkey'));
    await tester.pumpAndSettle();

    await tester.enterText(_field, 'a' * 65);
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.text('A handle is 1 to 64 characters.'), findsOneWidget);
    expect(rest.passkeyRegisterStartCalls, 0, reason: 'no passkey to orphan');
  });

  testWidgets('a handle taken in the meantime keeps the new account on Pick '
      'your handle, never in chat, until another is chosen', (tester) async {
    final rest = FakeRestApi()..updateProfileThrows = const HandleTaken();
    final c = await app(tester, rest);

    await tester.tap(find.text('Create a passkey'));
    await tester.pumpAndSettle();
    await tester.enterText(_field, 'nicka');
    await tester.pump(); // the button enables only once a handle is typed
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(c.read(authControllerProvider).value, isNotNull);
    expect(_screen, findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
    expect(
      find.text('Someone took that handle just now. Pick another.'),
      findsOneWidget,
    );
    expect(find.text('Continue as @nicka'), findsOneWidget, reason: 'kept');

    rest.updateProfileThrows = null;
    await tester.enterText(_field, 'nicka2');
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();
    expect(c.read(authControllerProvider).value?.username, 'nicka2');
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('killed mid-sign-up: the next launch resumes on Pick your '
      'handle, pre-filled', (tester) async {
    await testPrefs.setString(
      _owedKey,
      jsonEncode({
        'handle': 'nicka',
        'display_name': 'Nick',
        'user_id': FakeRestApi.defaultUser.userId,
      }),
    );
    await app(tester, FakeRestApi(), signedIn: true);

    expect(_screen, findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('Continue as @nicka'), findsOneWidget);
  });

  testWidgets('a debt recorded for ANOTHER account does not hold this one', (
    tester,
  ) async {
    await testPrefs.setString(
      _owedKey,
      jsonEncode({
        'handle': 'nicka',
        'display_name': 'Nick',
        'user_id': 'someone-else',
      }),
    );
    await app(tester, FakeRestApi(), signedIn: true);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('an account the island reports as still auto-handled is asked '
      'on launch, and can sign out instead', (tester) async {
    final rest = FakeRestApi(user: FakeRestApi.newAccountUser);
    final c = await app(tester, rest, signedIn: true);

    expect(_screen, findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(c.read(authControllerProvider).value, isNull);
    expect(find.byKey(const Key('login-screen')), findsOneWidget);
  });

  testWidgets('an island that does not report handle_auto gates nobody', (
    tester,
  ) async {
    await app(tester, FakeRestApi(), signedIn: true); // handleAuto: null
    expect(find.byType(ChatScreen), findsOneWidget);
  });
}
