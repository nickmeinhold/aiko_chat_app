// THE AFFIRMING INSTRUMENT for the carriage emit gate (claude-tasks#4759).
//
// Every existing test of this gate checks a PART: `getCapabilities` parsing, the
// allowlist seed, and the strip path with the gate OPEN. None asserts the thing
// the gate exists to do — that a CLOSED gate withholds a VALID envelope from the
// wire. A healthy live island cannot test this: it confirms health and says
// nothing about withholding.
//
// It matters because the live data disagrees with the code. Between 2026-08-10
// and 2026-09-16 the allowlist alone decided carriage, `chat.enspyr.co` was not
// on it, and `/capabilities` 404'd — yet app-originated messages to enspyr
// carried origin envelopes. Either the gate does not withhold, or the binary
// that sent them predates the gate. This test separates those.

import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  final seed = AuthTokens(accessToken: 'a0', refreshToken: 'r0');
  DefaultTokenProvider tokens() => DefaultTokenProvider(
    store: InMemoryTokenStore(seed),
    remoteRefresh: (rt) async => 'access1',
  );

  OriginEnvelope validEnvelope(String id) => OriginEnvelope(
    keyVersion: 1,
    rawPublicKey: Uint8List(32), // a well-formed Ed25519 key length
    clientMsgId: id,
    signedAtMs: 1,
    sig: Uint8List(64),
  );

  test('a CLOSED gate withholds a VALID envelope from the wire', () async {
    late FakeWebSocketChannel fake;
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: tokens(),
      channelFactory: (uri) => fake = FakeWebSocketChannel(),
      carriesOrigin: () => false, // the pre-2026-09-16 enspyr state
    );
    await t.connect();
    final id = t.sendMessage(
      OutgoingMessage(
        clientTempId: 'tmp1',
        channelId: 'c1',
        body: 'hello',
        origin: validEnvelope('tmp1'),
      ),
    );
    expect(id, 'tmp1');
    final sent = fake.sent.firstWhere((f) => f.contains('"type":"send"'));
    expect(
      sent.contains('"origin"'),
      isFalse,
      reason: 'the gate is closed — the envelope must NOT reach the wire',
    );
  });

  // The positive control. Without it, a test asserting absence passes just as
  // well when the envelope could never have been built in the first place.
  test('an OPEN gate does put the same envelope on the wire', () async {
    late FakeWebSocketChannel fake;
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: tokens(),
      channelFactory: (uri) => fake = FakeWebSocketChannel(),
      carriesOrigin: () => true,
    );
    await t.connect();
    t.sendMessage(
      OutgoingMessage(
        clientTempId: 'tmp2',
        channelId: 'c1',
        body: 'hello',
        origin: validEnvelope('tmp2'),
      ),
    );
    final sent = fake.sent.firstWhere((f) => f.contains('"type":"send"'));
    expect(
      sent.contains('"origin"'),
      isTrue,
      reason: 'positive control — this envelope IS emittable when the gate opens',
    );
  });
}
