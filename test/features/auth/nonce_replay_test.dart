// Replay-defense for the social-sign-in seam (gateway handoff item 3): the app
// must NOT mint its own nonce (a self-generated nonce makes a captured /social
// request replayable). Instead it fetches a server-issued, single-use nonce
// from POST /v1/auth/nonce, threads it through the provider SDK, and submits the
// SAME nonce to /social so the gateway can mark it consumed.
//
// Two seams under test:
//   1. WIRE — GatewayRestApi.fetchNonce hits /v1/auth/nonce on the PRE-AUTH
//      (bare) client and returns the opaque nonce.
//   2. ORCHESTRATION — AuthController.signInWith fetches a nonce, hands THAT
//      nonce to the SDK, and forwards the SAME nonce to /social (single source;
//      the controller never trusts the credential to echo it back).

import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeTestEnvironment();
  });

  group('GatewayRestApi.fetchNonce (wire)', () {
    // Build an api whose BARE and AUTHED clients answer with DIFFERENT handlers,
    // so a test can prove which client a call went out on. fetchNonce is
    // pre-auth → it must use the bare client; if it uses authed, this throws.
    GatewayRestApi apiWithSplit({
      required ResponseBody Function(RequestOptions) bareHandler,
      required ResponseBody Function(RequestOptions) authedHandler,
    }) {
      final bare = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = FakeHttpAdapter(bareHandler);
      final authed = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = FakeHttpAdapter(authedHandler);
      return GatewayRestApi(bare: bare, authed: authed);
    }

    test('POSTs /v1/auth/nonce on the bare (pre-auth) client and returns the nonce',
        () async {
      RequestOptions? captured;
      final api = apiWithSplit(
        bareHandler: (opts) {
          captured = opts;
          return jsonBody(200, '{"nonce":"srv-abc123"}');
        },
        authedHandler: (_) =>
            throw StateError('fetchNonce must not use the authed client'),
      );

      final nonce = await api.fetchNonce();

      expect(nonce, 'srv-abc123');
      expect(captured!.path, '/v1/auth/nonce');
      expect(captured!.method, 'POST');
      // Pre-auth: no bearer token attached.
      expect(captured!.headers['Authorization'], isNull);
    });
  });

  group('AuthController.signInWith (orchestration)', () {
    test(
        'fetches a server nonce and forwards THAT exact nonce to both the SDK and /social',
        () async {
      final rest = FakeRestApi()..nonceToIssue = 'server-nonce-XYZ';
      final social = FakeSocialAuthClient();
      final c = makeContainer(
        rest: rest,
        transport: FakeChatTransport(),
        social: social,
      );
      addTearDown(c.dispose);

      // Cold start: no tokens → logged out.
      expect(await c.read(authControllerProvider.future), isNull);

      await c
          .read(authControllerProvider.notifier)
          .signInWith(SocialProvider.google);

      // The server nonce was fetched exactly once, BEFORE the provider flow.
      expect(rest.fetchNonceCalls, 1,
          reason: 'a fresh server nonce per sign-in — never client-minted');
      // The nonce handed to the SDK is the server one (not a local random).
      expect(social.lastRawNonce, 'server-nonce-XYZ');
      // The nonce submitted to /social is the SAME server one (single source).
      expect(rest.lastSocialNonce, 'server-nonce-XYZ');
    });

    test('a user cancellation fetches no nonce leak past the aborted flow',
        () async {
      // Cancelling mid-flow must still be a clean no-op — the fetched nonce is
      // simply never submitted (the gateway lets an unused nonce expire).
      final rest = FakeRestApi()..nonceToIssue = 'server-nonce-ABC';
      final social = FakeSocialAuthClient(throws: const SocialSignInCancelled());
      final c = makeContainer(
        rest: rest,
        transport: FakeChatTransport(),
        social: social,
      );
      addTearDown(c.dispose);

      expect(await c.read(authControllerProvider.future), isNull);

      await c
          .read(authControllerProvider.notifier)
          .signInWith(SocialProvider.apple);

      // Still logged out (clean restore), and nothing was submitted to /social.
      expect(await c.read(authControllerProvider.future), isNull);
      expect(rest.socialCalls, 0, reason: 'cancelled flow never hits /social');
    });
  });
}
