// The centralised friendly-error map (auth_error_text.dart). This is the whole
// contract the login + claim screens share, tested as a pure function so every
// branch is cheap to pin — including the honest offline copy this PR exists for:
// the SAME NetworkUnavailable says a different, true thing depending on whether
// the user was creating an account, signing in, or claiming a handle.
//
// The load-bearing property (inherited from login_error_text_test): an UNMAPPED
// error must surface its RAW text, never a blanket "something went wrong", so a
// new failure mode is never invisible.

import 'package:aiko_chat_app/features/auth/data/auth_exceptions.dart';
import 'package:aiko_chat_app/features/auth/presentation/auth_error_text.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String text(
    Object? e, {
    String host = 'chat.example.com',
    AuthAction action = AuthAction.signIn,
  }) => authErrorText(e, host: host, action: action);

  group('NetworkUnavailable — honest, context-specific offline copy', () {
    test('createAccount → "just this once" + the works-offline promise', () {
      final t = text(
        const NetworkUnavailable(),
        action: AuthAction.createAccount,
      );
      expect(t, contains('just this once'));
      expect(t, contains('works offline'));
    });

    test('signIn → reconnect-to-sign-in (NOT "creating your account")', () {
      final t = text(const NetworkUnavailable(), action: AuthAction.signIn);
      expect(t, contains('Reconnect to sign in'));
      expect(t, isNot(contains('Creating your account')));
    });

    test('claimHandle → finish-setting-up', () {
      final t = text(
        const NetworkUnavailable(),
        action: AuthAction.claimHandle,
      );
      expect(t, contains('finish setting up'));
    });
  });

  group('domain exceptions map by type (transport stays out of the UI)', () {
    test('HandleTaken → "handle is taken"', () {
      expect(text(const HandleTaken()), contains('handle is taken'));
    });

    test('PasskeyAlreadyRegistered → "already registered"', () {
      expect(
        text(const PasskeyAlreadyRegistered()),
        contains('already registered'),
      );
    });

    test('Unauthorized → "couldn\'t verify that passkey"', () {
      expect(text(const Unauthorized(401)), contains("couldn't verify"));
    });
  });

  group('passkey ceremony codes (AuthCeremonyFailed) keep their guidance', () {
    test('no-credentials-available → nudge to Create a passkey', () {
      expect(
        text(const AuthCeremonyFailed('Passkey: no-credentials-available')),
        contains('No passkey found on this device'),
      );
    });

    test('domain-not-associated → names the host', () {
      final t = text(
        const AuthCeremonyFailed('Passkey: domain-not-associated'),
        host: 'my.gateway.dev',
      );
      expect(t, contains('my.gateway.dev'));
    });

    test('deviceNotSupported → plain unsupported message', () {
      expect(
        text(const AuthCeremonyFailed('Passkey: deviceNotSupported')),
        contains("doesn't support passkeys"),
      );
    });

    test('a timeout → try-again', () {
      expect(
        text(const AuthCeremonyFailed('Passkey: timed out')),
        contains('timed out'),
      );
    });
  });

  group('the never-blind-again fallback', () {
    test('an UNMAPPED code surfaces its RAW text, not the generic line', () {
      final t = text(const AuthCeremonyFailed('Passkey: brand-new-code'));
      expect(t, 'Sign-in failed: Passkey: brand-new-code');
      expect(t, isNot(contains('Something went wrong')));
    });

    test('a null/blank error is the ONLY case that gets the generic line', () {
      expect(text(null), 'Something went wrong. Please try again.');
    });
  });
}
