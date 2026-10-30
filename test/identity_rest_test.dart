// Wire-contract tests for the RETAINED identity REST seam after social sign-in
// was removed: the gateway response-shape routing through `_resolveOutcome`
// (token → Authenticated vs pending → PendingHandle), the claim-handle conflict
// mapping (409 → HandleTaken), and the add-passkey link-to-existing path.
//
// These exercise the REAL GatewayRestApi against a mocked Dio adapter (the wire
// boundary), NOT a FakeRestApi — so a regression in `_passkeyFinish`,
// `_resolveOutcome`, `claimHandle`, or `addPasskey` fails HERE, at the boundary,
// not just in a fake's canned return. (Previously covered by the deleted
// social_rest_test.dart via the social ingress; the routing is unchanged — it is
// now reached through the passkey finish, which shares the same single door.)

import 'dart:io' show SocketException;

import 'package:aiko_chat_app/features/auth/domain/identity_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  GatewayRestApi apiWith(ResponseBody Function(RequestOptions) handler) {
    final bare = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = FakeHttpAdapter(handler);
    final authed = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = FakeHttpAdapter(handler);
    return GatewayRestApi(bare: bare, authed: authed);
  }

  // The single identity door: passkey register/authenticate finish both funnel
  // through `_resolveOutcome`. These pin that shared parser at the wire, using
  // finishPasskeyRegistration as the entry (register is the first-passkey-
  // creates-account path that can legitimately return either shape).
  group('passkey finish → _resolveOutcome routing', () {
    test('a full token response → Authenticated', () async {
      final api = apiWith(
        (_) => jsonBody(
          200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u1","username":"nick","display_name":"Nick","aiko_username":"nick"}}',
        ),
      );
      final out = await api.finishPasskeyRegistration('st', '{"id":"cred"}');
      expect(out, isA<Authenticated>());
      expect((out as Authenticated).session.user.username, 'nick');
    });

    test(
      'a status:pending response → PendingHandle (new-account claim)',
      () async {
        final api = apiWith(
          (_) => jsonBody(
            200,
            '{"status":"pending","provisioning_token":"ptok","suggested_name":"Robin","email":"r@x.com"}',
          ),
        );
        final out = await api.finishPasskeyRegistration('st', '{"id":"cred"}');
        expect(out, isA<PendingHandle>());
        final p = out as PendingHandle;
        expect(p.provisioningToken, 'ptok');
        expect(p.suggestedName, 'Robin');
        expect(p.email, 'r@x.com');
      },
    );

    test(
      'no access_token (even without a status field) → PendingHandle',
      () async {
        final api = apiWith(
          (_) => jsonBody(200, '{"provisioning_token":"ptok"}'),
        );
        final out = await api.finishPasskeyAuthentication(
          'st',
          '{"id":"cred"}',
        );
        expect(out, isA<PendingHandle>());
      },
    );

    test(
      'a malformed identity response (neither token nor provisioning) fails '
      'LOUDLY, not as a null-cast (cage-match: Maxwell/Kelvin/Carnot)',
      () async {
        final api = apiWith((_) => jsonBody(200, '{"unexpected":"shape"}'));
        expect(
          () => api.finishPasskeyRegistration('st', '{"id":"cred"}'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'a pending response missing its provisioning_token type → FormatException',
      () async {
        final api = apiWith((_) => jsonBody(200, '{"status":"pending"}'));
        expect(
          () => api.finishPasskeyRegistration('st', '{"id":"cred"}'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('posts state + decoded credential to the finish endpoint', () async {
      RequestOptions? captured;
      final api = apiWith((opts) {
        captured = opts;
        return jsonBody(
          200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u","username":"x","display_name":"X","aiko_username":"x"}}',
        );
      });
      await api.finishPasskeyRegistration('st8', '{"id":"cred-1"}');
      expect(captured!.path, '/v1/auth/passkey/register/finish');
      final body = captured!.data as Map;
      expect(body['state'], 'st8');
      expect(body['credential'], {
        'id': 'cred-1',
      }, reason: 'the authenticator JSON is decoded, not double-encoded');
    });

    test(
      'malformed authenticator JSON → FormatException (client plumbing)',
      () async {
        final api = apiWith((_) => jsonBody(200, '{"access_token":"a"}'));
        expect(
          () => api.finishPasskeyRegistration('st', 'not-json'),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  // Retained from social_rest_test.dart: claimHandle serves the first-passkey-
  // creates-account handle claim (the gateway-owned /v1/auth/social/claim path).
  group('claimHandle', () {
    test('200 → AuthSession', () async {
      final api = apiWith(
        (_) => jsonBody(
          200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u2","username":"robin","display_name":"Robin","aiko_username":"robin"}}',
        ),
      );
      final s = await api.claimHandle(
        provisioningToken: 'p',
        handle: 'robin',
        displayName: 'Robin',
      );
      expect(s.user.username, 'robin');
      expect(s.tokens.accessToken, 'a');
    });

    test('409 → HandleTaken', () async {
      final api = apiWith((_) => jsonBody(409, '{"detail":"handle taken"}'));
      expect(
        () => api.claimHandle(
          provisioningToken: 'p',
          handle: 'taken',
          displayName: 'x',
        ),
        throwsA(isA<HandleTaken>()),
      );
    });
  });

  // Retained from social_rest_test.dart: the add-to-existing recovery path is
  // untouched by the social removal.
  group('addPasskey (link to existing account)', () {
    // The load-bearing regression: add/finish returns a BARE user view with NO
    // access_token/provisioning_token. If addPasskey routed through the shared
    // `_resolveOutcome` (like the other finishes), this would throw
    // "neither access_token nor provisioning_token". It must parse an AppUser.
    test(
      'a bare user response (no tokens) → AppUser, not a resolver throw',
      () async {
        final api = apiWith(
          (_) => jsonBody(
            200,
            '{"user_id":"u9","username":"nick","display_name":"Nick","aiko_username":"nick"}',
          ),
        );
        final u = await api.addPasskey('st8', '{"id":"cred"}');
        expect(u.userId, 'u9');
        expect(u.username, 'nick');
      },
    );

    test(
      'posts state + decoded credential to /v1/auth/passkey/add/finish',
      () async {
        RequestOptions? captured;
        final api = apiWith((opts) {
          captured = opts;
          return jsonBody(
            200,
            '{"user_id":"u","username":"x","display_name":"X","aiko_username":"x"}',
          );
        });
        await api.addPasskey('st8', '{"id":"cred-1"}');
        expect(captured!.path, '/v1/auth/passkey/add/finish');
        final body = captured!.data as Map;
        expect(body['state'], 'st8');
        expect(body['credential'], {
          'id': 'cred-1',
        }, reason: 'the authenticator JSON is decoded, not double-encoded');
      },
    );

    test('409 → PasskeyAlreadyRegistered', () async {
      final api = apiWith(
        (_) => jsonBody(409, '{"detail":"passkey already registered"}'),
      );
      expect(
        () => api.addPasskey('st', '{"id":"c"}'),
        throwsA(isA<PasskeyAlreadyRegistered>()),
      );
    });

    test(
      'terminal 401 → Unauthorized (shares the authed-call mapping)',
      () async {
        final api = apiWith((_) => jsonBody(401, '{"detail":"nope"}'));
        expect(
          () => api.addPasskey('st', '{"id":"c"}'),
          throwsA(isA<Unauthorized>()),
        );
      },
    );

    test(
      'malformed authenticator JSON → FormatException (client plumbing)',
      () async {
        final api = apiWith((_) => jsonBody(200, '{"user_id":"u"}'));
        expect(
          () => api.addPasskey('st', 'not-json'),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  // The island's CLOSED-REGISTRATION refusal: `403 {"detail":"registration is
  // closed"}` from `_require_may_provision_account` (island rest/auth.py), the
  // same wording on every account-creating door. #436: it used to surface as a
  // plain Unauthorized, so a would-be new user read "couldn't verify that
  // passkey, create a new one" and looped, leaving a dead passkey per attempt.
  group('registration-closed 403 → RegistrationClosed', () {
    test(
      'register/finish: 403 registration is closed → RegistrationClosed',
      () async {
        final api = apiWith(
          (_) => jsonBody(403, '{"detail":"registration is closed"}'),
        );
        await expectLater(
          api.finishPasskeyRegistration('st', '{"id":"c"}'),
          throwsA(isA<RegistrationClosed>()),
        );
      },
    );

    test(
      'RegistrationClosed IS an Unauthorized (routers on the base type hold)',
      () async {
        final api = apiWith(
          (_) => jsonBody(403, '{"detail":"registration is closed"}'),
        );
        await expectLater(
          api.finishPasskeyRegistration('st', '{"id":"c"}'),
          throwsA(isA<Unauthorized>()),
        );
      },
    );

    test('a body dio leaves as a raw String is read too', () async {
      // text/plain stops dio decoding it, so `data` arrives as a String: the
      // shape `_isSuspended` already tolerates.
      final api = apiWith(
        (_) => ResponseBody.fromString(
          '{"detail":"Registration is closed."}',
          403,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );
      await expectLater(
        api.finishPasskeyRegistration('st', '{"id":"c"}'),
        throwsA(isA<RegistrationClosed>()),
      );
    });

    test('a 403 with another body is NOT RegistrationClosed', () async {
      final api = apiWith((_) => jsonBody(403, '{"detail":"forbidden"}'));
      await expectLater(
        api.finishPasskeyRegistration('st', '{"id":"c"}'),
        throwsA(allOf(isA<Unauthorized>(), isNot(isA<RegistrationClosed>()))),
      );
    });

    test('a 401 is NOT RegistrationClosed, even with the phrase', () async {
      final api = apiWith(
        (_) => jsonBody(401, '{"detail":"registration is closed"}'),
      );
      await expectLater(
        api.finishPasskeyRegistration('st', '{"id":"c"}'),
        throwsA(allOf(isA<Unauthorized>(), isNot(isA<RegistrationClosed>()))),
      );
    });
  });

  // #436 part 2: asking BEFORE the ceremony. `creates_accounts` rides on the
  // passkey entry of `GET /v1/auth/providers` (island PR #433). Only a real
  // boolean is an answer; every "can't tell" is null, which the app reads as
  // "carry on as before", so an island older than the field changes nothing.
  group('passkeyCreatesAccounts ← /v1/auth/providers', () {
    ResponseBody providers(String passkeyExtra) => jsonBody(
      200,
      '{"providers":[{"slug":"passkey","display_name":"Passkey",'
      '"kind":"passkey"$passkeyExtra}]}',
    );

    test('creates_accounts false → false, read from the right path', () async {
      String? path;
      final api = apiWith((o) {
        path = o.path;
        return providers(',"creates_accounts":false');
      });
      expect(await api.passkeyCreatesAccounts(), isFalse);
      expect(path, '/v1/auth/providers');
    });

    test('creates_accounts true → true', () async {
      final api = apiWith((_) => providers(',"creates_accounts":true'));
      expect(await api.passkeyCreatesAccounts(), isTrue);
    });

    test('an island older than the field → null, not false', () async {
      // Byte-for-byte what both live islands (v0.18.0) answered on 2026-10-28.
      final api = apiWith(
        (_) => jsonBody(
          200,
          '{"providers":[{"slug":"passkey","display_name":"Passkey","kind":"passkey"},'
          '{"slug":"apple","display_name":"Apple","kind":"native"}]}',
        ),
      );
      expect(await api.passkeyCreatesAccounts(), isNull);
    });

    test('the flag on ANOTHER provider is not the passkey door', () async {
      final api = apiWith(
        (_) => jsonBody(
          200,
          '{"providers":[{"slug":"apple","creates_accounts":false},'
          '{"slug":"passkey","creates_accounts":true}]}',
        ),
      );
      expect(await api.passkeyCreatesAccounts(), isTrue);
    });

    test('a string "false" is an odd body, not a refusal → null', () async {
      final api = apiWith((_) => providers(',"creates_accounts":"false"'));
      expect(await api.passkeyCreatesAccounts(), isNull);
    });

    test('no passkey entry → null', () async {
      final api = apiWith(
        (_) => jsonBody(200, '{"providers":[{"slug":"apple"}]}'),
      );
      expect(await api.passkeyCreatesAccounts(), isNull);
    });

    test('a 404 → null, never a throw', () async {
      final api = apiWith((_) => jsonBody(404, '{"detail":"Not Found"}'));
      expect(await api.passkeyCreatesAccounts(), isNull);
    });

    test('a non-object body → null, never a throw', () async {
      final api = apiWith((_) => jsonBody(200, '[]'));
      expect(await api.passkeyCreatesAccounts(), isNull);
    });

    test('a network failure → null, never a throw', () async {
      final api = apiWith((_) => throw const SocketException('offline'));
      expect(await api.passkeyCreatesAccounts(), isNull);
    });
  });

  // The island's per-island BAN — `403 {"detail":"account suspended"}` at every
  // ingress (handoff 2026-07-27, island #1914). Must map to the AccountSuspended
  // REFINEMENT of Unauthorized so the UI says "suspended," not "session expired"
  // (which loops: re-auth 403s again). Keyed on the BODY, not the bare 403. An
  // unrelated (non-ban) forbidden is door-dependent (A3): on the authed door it
  // is authZ → `Forbidden`; on the bare login door it stays terminal
  // `Unauthorized`. BOTH REST boundaries are covered by DISTINCT wire paths
  // (cage-match Tesla P1 — an earlier revision tested `_authedCall` twice and
  // left the login door unproven):
  //   - authed routes  → `_authedCall`          (via listBlocks)
  //   - bare login door → `_throwIfAuthTerminal` (via finishPasskeyRegistration,
  //     the passkey-finish path that surfaces a revoked/expired provisioning 403)
  group('account-ban 403 → AccountSuspended', () {
    test(
      'authed route (_authedCall): 403 account suspended → AccountSuspended',
      () async {
        final api = apiWith(
          (_) => jsonBody(403, '{"detail":"account suspended"}'),
        );
        await expectLater(api.listBlocks(), throwsA(isA<AccountSuspended>()));
      },
    );

    test(
      'AccountSuspended IS an Unauthorized (routers on the base type hold)',
      () async {
        final api = apiWith(
          (_) => jsonBody(403, '{"detail":"account suspended"}'),
        );
        await expectLater(api.listBlocks(), throwsA(isA<Unauthorized>()));
      },
    );

    test(
      'login door (_throwIfAuthTerminal): 403 suspended → AccountSuspended',
      () async {
        // finishPasskeyRegistration posts on the token-less _bare client, so its
        // terminal 401/403 maps via _throwIfAuthTerminal — the login/claim door,
        // NOT _authedCall. This is where a banned user's re-auth attempt lands.
        final api = apiWith(
          (_) => jsonBody(403, '{"detail":"account suspended"}'),
        );
        await expectLater(
          api.finishPasskeyRegistration('st', '{"id":"c"}'),
          throwsA(isA<AccountSuspended>()),
        );
      },
    );

    test(
      'login door (_throwIfAuthTerminal): a plain (non-suspended) 403 stays '
      'terminal Unauthorized, NOT Forbidden (A3 door asymmetry is frozen)',
      () async {
        // The A3 unbundle is DOOR-DEPENDENT on purpose: a plain 403 on the AUTHED
        // door is authZ → Forbidden, but on the token-less login/claim door it is a
        // rejected/expired provisioning token = an authN failure → terminal
        // Unauthorized. This test freezes that asymmetry so a future "make it
        // consistent" edit can't collapse provisioning rejection into a
        // non-terminal Forbidden the auth UI wouldn't treat as session death.
        final api = apiWith((_) => jsonBody(403, '{"detail":"forbidden"}'));
        await expectLater(
          api.finishPasskeyRegistration('st', '{"id":"c"}'),
          throwsA(allOf(isA<Unauthorized>(), isNot(isA<Forbidden>()))),
        );
      },
    );

    test('a NON-suspended 403 (authZ denial) → Forbidden, NOT Unauthorized '
        '(A3: authZ ≠ authN, no logout)', () async {
      // e.g. a moderator-only endpoint's forbidden. It must be neither a ban nor
      // a terminal Unauthorized — the session is valid, only THIS action is
      // denied, so the terminal-auth routers must not fire (no logout).
      final api = apiWith((_) => jsonBody(403, '{"detail":"forbidden"}'));
      await expectLater(
        api.listBlocks(),
        throwsA(allOf(isA<Forbidden>(), isNot(isA<Unauthorized>()))),
      );
    });

    test(
      'a 403 that merely mentions "suspend" is NOT a ban (exact-phrase key)',
      () async {
        // Tesla P2: the body key matches the island's phrase, not any "suspend".
        // A near-miss body falls through to the plain-403 → Forbidden branch
        // (A3), never to the ban's AccountSuspended.
        final api = apiWith(
          (_) => jsonBody(403, '{"detail":"cannot suspend operation"}'),
        );
        await expectLater(
          api.listBlocks(),
          throwsA(allOf(isA<Forbidden>(), isNot(isA<AccountSuspended>()))),
        );
      },
    );
  });
}
