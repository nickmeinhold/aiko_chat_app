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
}
