@Tags(['live'])
library;

// A REAL two-party test against a REAL island.
//
// Everything else in this repo's suite proves the app is self-consistent. This
// proves the two things self-consistency structurally cannot:
//
//   1. that a signature produced by an INDEPENDENT implementation of
//      `signingBytes` verifies here — the app's own round-trip cannot tell a
//      correct codec from a self-consistently wrong one; and
//   2. that a hangup actually stops a ring, end to end, over a live WebSocket,
//      from a second account the app has never seen before.
//
// EXCLUDED from the default run (`--exclude-tags live` in the pre-push gate):
// it needs network, credentials, and a second identity. Run it deliberately:
//
//   RING_HOST=chat.enspyr.co RING_CHANNEL=... RING_B_USER=... RING_B_PASS=... \
//   RING_PROBE=/abs/path/ring_probe.py RING_A_USER=... RING_A_PASS=... \
//   RING_KEY_SEED=... flutter test test/live --run-skipped --tags live
//
// `--run-skipped` is REQUIRED (dart_test.yaml marks this tag skipped). Without
// it the run reports a skip and exits 0 — which looks like verification while
// measuring nothing at all.
import 'dart:convert';
import 'dart:io';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_helpers.dart';

String _env(String k) {
  final v = Platform.environment[k];
  if (v == null || v.isEmpty) {
    throw StateError('$k is required — see this file\'s header');
  }
  return v;
}

/// A [TokenProvider] over one already-minted access token. The live island's
/// password login is not the app's ingress (passkeys are), so this stands in for
/// the ceremony without pretending to be it.
class _StaticTokens implements TokenProvider {
  _StaticTokens(this._token);
  final String _token;

  // The interface is exactly two methods; there is nothing else to stub.
  @override
  Future<String?> currentAccessToken() async => _token;

  /// Returns the SAME token rather than refreshing. This test is minutes long
  /// and the token lives hours — and a stub that silently re-mints would hide a
  /// genuine expiry behind an apparent success.
  @override
  Future<String?> refreshAccessToken() async => _token;
}

Future<Map<String, dynamic>> _login(String host, String u, String p) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('https://$host/v1/auth/login'));
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode({'username': u, 'password': p}));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  client.close();
  if (res.statusCode != 200) {
    throw StateError('login failed ${res.statusCode}: $body');
  }
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Drives the OTHER party — a separate process, a separate implementation of the
/// signing contract, a separate account. That separation is the whole value: a
/// second in-process client would share this one's bugs.
Future<String> _probe(List<String> args) async {
  final r = await Process.run(
    'python3',
    [_env('RING_PROBE'), ...args],
    environment: {
      'AIKO_HOST': _env('RING_HOST'),
      'RING_USER': _env('RING_A_USER'),
      'RING_PASS': _env('RING_A_PASS'),
      'RING_CHANNEL': _env('RING_CHANNEL'),
      'RING_KEY_SEED': _env('RING_KEY_SEED'),
    },
  );
  if (r.exitCode != 0) {
    throw StateError('probe ${args.first} failed:\n${r.stdout}\n${r.stderr}');
  }
  return '${r.stdout}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a real second party rings this client, and their hangup stops it', () async {
    // TestWidgetsFlutterBinding installs an HttpOverrides that answers every
    // request with 400 and never touches the network — correct for a unit suite,
    // fatal for the one test whose entire purpose is a real island. Restoring the
    // real client is the point of this file, not a workaround around a safety.
    HttpOverrides.global = null;
    installSecureStorageMock();
    final host = _env('RING_HOST');
    final channelId = _env('RING_CHANNEL');

    final session = await _login(
      host,
      _env('RING_B_USER'),
      _env('RING_B_PASS'),
    );
    final me = session['user'] as Map<String, dynamic>;
    final meUser = AppUser(
      userId: me['user_id'] as String,
      username: me['username'] as String,
      displayName: (me['display_name'] as String?) ?? '',
      aikoUsername: (me['aiko_username'] as String?) ?? '',
    );

    final cache = DriftCache(NativeDatabase.memory());
    final transport = GatewayTransport(
      wsBaseUrl: 'wss://$host',
      tokens: _StaticTokens(session['access_token'] as String),
      carriesOrigin: () => true,
    );
    final repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: FakeChatRestApi(), // history is irrelevant; the live frames are not
      me: meUser,
      subscribedChannelIds: [channelId],
      newTempId: () =>
          DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase(),
    );
    repo.start();
    await transport.connect();

    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repo),
        currentUserProvider.overrideWithValue(meUser),
        blockedUserIdsProvider.overrideWithValue(const <String>{}),
        mutedChannelIdsProvider.overrideWithValue(const <String>{}),
        mutedUserIdsProvider.overrideWithValue(const <String>{}),
        dmsProvider.overrideWith(
          (ref) async => [
            Channel(id: channelId, name: 'Live', kind: ChannelKind.dm),
          ],
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await repo.dispose();
      await transport.disconnect();
      await cache.close();
    });
    container.listen(dmsProvider, (_, _) {}, fireImmediately: true);
    await container.read(dmsProvider.future);
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await Future<void>.delayed(const Duration(seconds: 3)); // settle the socket

    // --- the other party rings ------------------------------------------------
    final invite = await _probe(['invite']);
    // ignore: avoid_print
    print('probe invite -> $invite');

    final rang = await _await(
      () => container.read(incomingRingProvider) != null,
      const Duration(seconds: 15),
    );
    expect(
      rang,
      isTrue,
      reason:
          'a signed invitation from an INDEPENDENT implementation did not ring. '
          'That is either the byte contract or the verifier — and it is exactly '
          'what a self-roundtrip test cannot tell you',
    );
    final live = container.read(incomingRingProvider)!;
    // ignore: avoid_print
    print('RINGING: invite=${live.inviteId} server=${live.serverMsgId}');

    // --- the other party hangs up ---------------------------------------------
    final stoppedAt = DateTime.now();
    await _probe(['end', live.serverMsgId]);

    final stopped = await _await(
      () => container.read(incomingRingProvider) == null,
      const Duration(seconds: 15),
    );
    final elapsed = DateTime.now().difference(stoppedAt);
    expect(
      stopped,
      isTrue,
      reason: 'the hangup did not stop the ring — the whole point of #3198',
    );
    expect(
      elapsed,
      lessThan(const Duration(seconds: 25)),
      reason:
          'it must stop PROMPTLY, not by out-waiting kCallRingDuration — a ring '
          'that merely expires is the bug, not the fix',
    );
    // ignore: avoid_print
    print('RING STOPPED after ${elapsed.inMilliseconds}ms');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Poll [predicate] until true or [limit] elapses. Real network, real island —
/// there is no scheduler to pump.
Future<bool> _await(bool Function() predicate, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return predicate();
}
