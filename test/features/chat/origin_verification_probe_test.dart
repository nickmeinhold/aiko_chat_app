// #1896 verified-sender PROBE. Pins that ChatRepository._persistInbound surfaces
// a carried-but-invalid origin (originCryptoValid == false) via
// ChatTelemetry.originVerificationFailed — and ONLY then — so we can measure the
// base rate of `false` before any user-facing integrity warning ships. Drives the
// REAL repo inbound path (not the persist mirror in origin_inbound_persist_test).
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

const _me = AppUser(
  userId: 'me',
  username: 'me',
  displayName: 'Me',
  aikoUsername: 'me',
);
const _chan = 'chan';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late DriftCache cache;
  late FakeChatTransport transport;
  late FakeChatRestApi rest;
  late ChatRepository repo;
  late SpyTelemetry spy;
  late SovereignKey signer;

  setUp(() async {
    installSecureStorageMock();
    cache = DriftCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    rest = FakeChatRestApi();
    spy = SpyTelemetry();
    signer = await SovereignKeyStore().loadOrCreate();
    repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: rest,
      me: _me,
      subscribedChannelIds: const [_chan],
      telemetry: spy,
      ackTimeout: const Duration(milliseconds: 80),
      newTempId: () => 'tmp',
    );
    repo.start();
  });

  tearDown(() async {
    await repo.dispose();
    await transport.dispose();
    await cache.close();
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 15));
  Future<List<Message>> rows() => cache.watchChannel(_chan).first;

  // A foreign-fanout inbound message (userId != 'me'), signed over [signedBody]
  // but DELIVERED with [viewBody] — differ them to forge a body that the sig
  // can't verify (carried-but-invalid).
  Future<Message> signedInbound({
    required String ulid,
    required String signedBody,
    String? viewBody,
  }) async {
    final sig = await sign(
      signer,
      SignedPayload(
        rawPublicKey: signer.rawPublicKey,
        channelId: _chan,
        clientMsgId: 'sig-$ulid',
        signedAtMs: 1720000000000,
        body: signedBody,
      ),
    );
    return Message.fromView({
      'msg_id': ulid,
      'channel_id': _chan,
      'sender': {'user_id': 'other', 'kind': 'human', 'label': 'Other'},
      'body': viewBody ?? signedBody,
      'created_at': '2026-01-01T00:00:00Z',
      'reply_to': null,
      'origin': OriginEnvelope.fromSignature(
        sig,
        clientMsgId: 'sig-$ulid',
      ).toWire(),
    });
  }

  test('a carried-but-invalid origin fires the probe exactly once + persists '
      'verdict=false', () async {
    transport.emitMessage(
      await signedInbound(
        ulid: '01BAD',
        signedBody: 'real',
        viewBody: 'tampered',
      ),
    );
    await pump();

    expect(spy.originVerificationFailures, hasLength(1));
    final (sender, channel, ulid, msg) = spy.originVerificationFailures.single;
    expect(sender, 'other', reason: 'opaque account id, for base-rate triage');
    expect(channel, _chan);
    expect(ulid, '01BAD', reason: 'stable server id, for dedup/correlation');
    expect(msg, 'sig-01BAD');
    // The probe does not change persistence: the verdict is still stored.
    final m = (await rows()).firstWhere((m) => m.id == '01BAD');
    expect(m.originCryptoValid, isFalse);
  });

  test('a re-delivered carried-but-invalid origin fires the probe ONLY ONCE '
      '(per-message base rate, not per-delivery)', () async {
    // The exact double-count the probe must NOT do: live fanout, then a history
    // re-page / reconnect replay of the SAME server ULID (cage-match Carnot + Tesla).
    final bad = await signedInbound(
      ulid: '01DUP',
      signedBody: 'real',
      viewBody: 'tampered',
    );
    transport.emitMessage(bad);
    await pump();
    transport.emitMessage(bad); // identical re-delivery (history re-sync)
    await pump();

    expect(
      spy.originVerificationFailures,
      hasLength(1),
      reason:
          'the second delivery is a no-op update, not a newly-invalid '
          'transition — the probe counts the message once',
    );
    expect(
      (await rows()).firstWhere((m) => m.id == '01DUP').originCryptoValid,
      isFalse,
    );
  });

  test('a verified message re-signed to INVALID fires the probe on the '
      'transition (not over-suppressed)', () async {
    // First a VALID signed message: verdict true, no probe.
    transport.emitMessage(await signedInbound(ulid: '01T', signedBody: 'v1'));
    await pump();
    expect(spy.originVerificationFailures, isEmpty);
    // Then the SAME ULID re-echoed with a diverged body the origin doesn't sign
    // → verdict flips true→false → a genuinely new invalid observation fires once.
    transport.emitMessage(
      await signedInbound(ulid: '01T', signedBody: 'v1', viewBody: 'v2'),
    );
    await pump();
    expect(
      spy.originVerificationFailures,
      hasLength(1),
      reason: 'true→false is a newly-invalid transition, not a replay',
    );
  });

  test(
    'a VALID carried origin does NOT fire the probe (verdict=true)',
    () async {
      transport.emitMessage(
        await signedInbound(ulid: '01OK', signedBody: 'hello'),
      );
      await pump();

      expect(spy.originVerificationFailures, isEmpty);
      final m = (await rows()).firstWhere((m) => m.id == '01OK');
      expect(m.originCryptoValid, isTrue);
    },
  );

  test(
    'an UNSIGNED inbound message does NOT fire the probe (verdict=null)',
    () async {
      transport.emitMessage(
        Message.fromView({
          'msg_id': '01PLAIN',
          'channel_id': _chan,
          'sender': {'user_id': 'other', 'kind': 'human', 'label': 'Other'},
          'body': 'plain',
          'created_at': '2026-01-01T00:00:00Z',
          'reply_to': null,
        }),
      );
      await pump();

      expect(spy.originVerificationFailures, isEmpty);
      final m = (await rows()).firstWhere((m) => m.id == '01PLAIN');
      expect(m.originCryptoValid, isNull);
    },
  );
}
