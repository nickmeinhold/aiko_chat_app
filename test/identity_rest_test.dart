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
      final api = apiWith((_) => jsonBody(200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u1","username":"nick","display_name":"Nick","aiko_username":"nick"}}'));
      final out = await api.finishPasskeyRegistration('st', '{"id":"cred"}');
      expect(out, isA<Authenticated>());
      expect((out as Authenticated).session.user.username, 'nick');
    });

    test('a status:pending response → PendingHandle (new-account claim)',
        () async {
      final api = apiWith((_) => jsonBody(200,
          '{"status":"pending","provisioning_token":"ptok","suggested_name":"Robin","email":"r@x.com"}'));
      final out = await api.finishPasskeyRegistration('st', '{"id":"cred"}');
      expect(out, isA<PendingHandle>());
      final p = out as PendingHandle;
      expect(p.provisioningToken, 'ptok');
      expect(p.suggestedName, 'Robin');
      expect(p.email, 'r@x.com');
    });

    test('no access_token (even without a status field) → PendingHandle',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"provisioning_token":"ptok"}'));
      final out =
          await api.finishPasskeyAuthentication('st', '{"id":"cred"}');
      expect(out, isA<PendingHandle>());
    });

    test(
        'a malformed identity response (neither token nor provisioning) fails '
        'LOUDLY, not as a null-cast (cage-match: Maxwell/Kelvin/Carnot)',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"unexpected":"shape"}'));
      expect(() => api.finishPasskeyRegistration('st', '{"id":"cred"}'),
          throwsA(isA<FormatException>()));
    });

    test('a pending response missing its provisioning_token type → FormatException',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"status":"pending"}'));
      expect(() => api.finishPasskeyRegistration('st', '{"id":"cred"}'),
          throwsA(isA<FormatException>()));
    });

    test('posts state + decoded credential to the finish endpoint', () async {
      RequestOptions? captured;
      final api = apiWith((opts) {
        captured = opts;
        return jsonBody(200,
            '{"access_token":"a","refresh_token":"r","user":{"user_id":"u","username":"x","display_name":"X","aiko_username":"x"}}');
      });
      await api.finishPasskeyRegistration('st8', '{"id":"cred-1"}');
      expect(captured!.path, '/v1/auth/passkey/register/finish');
      final body = captured!.data as Map;
      expect(body['state'], 'st8');
      expect(body['credential'], {'id': 'cred-1'},
          reason: 'the authenticator JSON is decoded, not double-encoded');
    });

    test('malformed authenticator JSON → FormatException (client plumbing)',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"access_token":"a"}'));
      expect(() => api.finishPasskeyRegistration('st', 'not-json'),
          throwsA(isA<FormatException>()));
    });
  });

  // Retained from social_rest_test.dart: claimHandle serves the first-passkey-
  // creates-account handle claim (the gateway-owned /v1/auth/social/claim path).
  group('claimHandle', () {
    test('200 → AuthSession', () async {
      final api = apiWith((_) => jsonBody(200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u2","username":"robin","display_name":"Robin","aiko_username":"robin"}}'));
      final s = await api.claimHandle(
          provisioningToken: 'p', handle: 'robin', displayName: 'Robin');
      expect(s.user.username, 'robin');
      expect(s.tokens.accessToken, 'a');
    });

    test('409 → HandleTaken', () async {
      final api = apiWith((_) => jsonBody(409, '{"detail":"handle taken"}'));
      expect(
        () => api.claimHandle(
            provisioningToken: 'p', handle: 'taken', displayName: 'x'),
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
    test('a bare user response (no tokens) → AppUser, not a resolver throw',
        () async {
      final api = apiWith((_) => jsonBody(200,
          '{"user_id":"u9","username":"nick","display_name":"Nick","aiko_username":"nick"}'));
      final u = await api.addPasskey('st8', '{"id":"cred"}');
      expect(u.userId, 'u9');
      expect(u.username, 'nick');
    });

    test('posts state + decoded credential to /v1/auth/passkey/add/finish',
        () async {
      RequestOptions? captured;
      final api = apiWith((opts) {
        captured = opts;
        return jsonBody(200,
            '{"user_id":"u","username":"x","display_name":"X","aiko_username":"x"}');
      });
      await api.addPasskey('st8', '{"id":"cred-1"}');
      expect(captured!.path, '/v1/auth/passkey/add/finish');
      final body = captured!.data as Map;
      expect(body['state'], 'st8');
      expect(body['credential'], {'id': 'cred-1'},
          reason: 'the authenticator JSON is decoded, not double-encoded');
    });

    test('409 → PasskeyAlreadyRegistered', () async {
      final api =
          apiWith((_) => jsonBody(409, '{"detail":"passkey already registered"}'));
      expect(
        () => api.addPasskey('st', '{"id":"c"}'),
        throwsA(isA<PasskeyAlreadyRegistered>()),
      );
    });

    test('terminal 401 → Unauthorized (shares the authed-call mapping)',
        () async {
      final api = apiWith((_) => jsonBody(401, '{"detail":"nope"}'));
      expect(() => api.addPasskey('st', '{"id":"c"}'),
          throwsA(isA<Unauthorized>()));
    });

    test('malformed authenticator JSON → FormatException (client plumbing)',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"user_id":"u"}'));
      expect(() => api.addPasskey('st', 'not-json'),
          throwsA(isA<FormatException>()));
    });
  });
}
