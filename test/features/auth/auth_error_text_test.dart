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

    test('Unauthorized on signIn → "couldn\'t verify that passkey"', () {
      expect(text(const Unauthorized(401)), contains("couldn't verify"));
    });

    test('Unauthorized on claimHandle → expired-setup, NOT passkey-verify', () {
      final t = text(const Unauthorized(401), action: AuthAction.claimHandle);
      expect(t, contains('setup session expired'));
      expect(t, isNot(contains('passkey')));
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

  group('the never-blind-again fallback names the RIGHT ritual', () {
    test(
      'signIn: an UNMAPPED code surfaces its RAW text as "Sign-in failed"',
      () {
        final t = text(const AuthCeremonyFailed('Passkey: brand-new-code'));
        expect(t, 'Sign-in failed: Passkey: brand-new-code');
        expect(t, isNot(contains('Something went wrong')));
      },
    );

    test('claimHandle: an UNMAPPED failure must NOT say "Sign-in failed"', () {
      // The bug the matrix invited (cage-match #74): a claim-screen fallback
      // that lies about which ritual failed.
      final t = text(
        const AuthCeremonyFailed('Passkey: brand-new-code'),
        action: AuthAction.claimHandle,
      );
      expect(t, "Couldn't finish setup: Passkey: brand-new-code");
      expect(t, isNot(contains('Sign-in failed')));
    });

    test('createAccount: an UNMAPPED failure names account creation', () {
      final t = text(
        const AuthCeremonyFailed('Passkey: brand-new-code'),
        action: AuthAction.createAccount,
      );
      expect(t, "Couldn't create your account: Passkey: brand-new-code");
      expect(t, isNot(contains('Sign-in failed')));
    });

    test('an unmapped NON-ceremony error shows its TYPE, never its toString', () {
      // On-screen PII guard (cage-match #74 R2): a raw DioException reaching the
      // banner must not stringify its request body (provisioning_token/handle).
      final t = text(_LeakyError(), action: AuthAction.claimHandle);
      expect(t, "Couldn't finish setup: _LeakyError");
      expect(t, isNot(contains('SECRET')));
      expect(t, isNot(contains('provisioning_token')));
    });

    test('a null/blank error is the ONLY case that gets the generic line', () {
      expect(text(null), 'Something went wrong. Please try again.');
    });
  });
}

/// An error whose toString() leaks a credential-shaped request body — stands in
/// for a raw DioException reaching the banner.
class _LeakyError {
  @override
  String toString() =>
      'DioException: POST /claim {provisioning_token: SECRET, handle: bob}';
}
