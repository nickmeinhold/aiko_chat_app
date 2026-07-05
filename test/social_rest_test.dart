// Wire-contract tests for the social-sign-in REST seam (#5): the gateway
// response-shape routing (token → Authenticated vs pending → PendingHandle) and
// the claim-handle conflict mapping (409 → HandleTaken). Mirrors the
// `GatewayRestApi parsing` group in transport_seam_test.dart.

import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
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

  group('socialSignIn response routing', () {
    test('a full token response → Authenticated', () async {
      final api = apiWith((_) => jsonBody(200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u1","username":"nick","display_name":"Nick","aiko_username":"nick"}}'));
      final out = await api.socialSignIn(
          provider: SocialProvider.google, idToken: 't', rawNonce: 'n');
      expect(out, isA<Authenticated>());
      expect((out as Authenticated).session.user.username, 'nick');
    });

    test('a status:pending response → PendingHandle', () async {
      final api = apiWith((_) => jsonBody(200,
          '{"status":"pending","provisioning_token":"ptok","suggested_name":"Robin","email":"r@x.com"}'));
      final out = await api.socialSignIn(
          provider: SocialProvider.apple, idToken: 't', rawNonce: 'n');
      expect(out, isA<PendingHandle>());
      final p = out as PendingHandle;
      expect(p.provisioningToken, 'ptok');
      expect(p.suggestedName, 'Robin');
      expect(p.email, 'r@x.com');
    });

    test('no access_token (even without a status field) → PendingHandle',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"provisioning_token":"ptok"}'));
      final out = await api.socialSignIn(
          provider: SocialProvider.google, idToken: 't', rawNonce: 'n');
      expect(out, isA<PendingHandle>());
    });

    test('forwards provider name + nonce + optional name in the body',
        () async {
      RequestOptions? captured;
      final api = apiWith((opts) {
        captured = opts;
        return jsonBody(200,
            '{"access_token":"a","refresh_token":"r","user":{"user_id":"u","username":"x","display_name":"X","aiko_username":"x"}}');
      });
      await api.socialSignIn(
          provider: SocialProvider.apple,
          idToken: 'tok',
          rawNonce: 'nonce123',
          name: 'Robin Langer');
      final body = captured!.data as Map;
      expect(body['provider'], 'apple');
      expect(body['id_token'], 'tok');
      expect(body['nonce'], 'nonce123');
      expect(body['name'], 'Robin Langer');
    });
  });

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
