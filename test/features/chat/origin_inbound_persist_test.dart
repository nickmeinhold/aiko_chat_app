import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

// Steps 2-3 of the wire half: inbound origin validate + persist + verify (into
// the typed columns, no JSON blob) and the collapse/set-on-success law.
const _chan = 'chan';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late DriftCache cache;
  late SovereignKey signer;

  setUp(() async {
    installSecureStorageMock();
    cache = DriftCache(NativeDatabase.memory());
    signer = await SovereignKeyStore().loadOrCreate();
  });
  tearDown(() => cache.close());

  Future<MessageRow> rawRow(String ulid) =>
      (cache.select(cache.messages)..where((t) => t.serverUlid.equals(ulid)))
          .getSingle();

  Future<Message> readDomain(String ulid) async {
    final rows = await cache.watchChannel(_chan).first;
    return rows.firstWhere((m) => m.id == ulid);
  }

  // Build a signed inbound message_view (as the gateway would echo it). The
  // signed `client_msg_id` is deliberately DIFFERENT from the ULID, mirroring a
  // real inbound row whose PK is the server ULID, not the signed id.
  Future<Map<String, dynamic>> signedView({
    required String ulid,
    required String signedCmid,
    required String signedBody,
    String? viewBody, // defaults to signedBody; differ it to forge a bad sig
    String? replyTo,
  }) async {
    final payload = SignedPayload(
      rawPublicKey: signer.rawPublicKey,
      channelId: _chan,
      clientMsgId: signedCmid,
      signedAtMs: 1720000000000,
      body: signedBody,
      replyTo: replyTo,
    );
    final sig = await sign(signer, payload);
    final origin =
        OriginEnvelope.fromSignature(sig, clientMsgId: signedCmid).toWire();
    return {
      'msg_id': ulid,
      'channel_id': _chan,
      'sender': {'user_id': 'other', 'kind': 'human', 'label': 'Other'},
      'body': viewBody ?? signedBody,
      'created_at': '2026-01-01T00:00:00Z',
      'reply_to': replyTo,
      'origin': origin,
    };
  }

  // Mirror ChatRepository._persistInbound (verify once at ingest, then upsert).
  Future<void> persist(Map<String, dynamic> view) async {
    final m = Message.fromView(view);
    final o = m.origin;
    final verified = o == null
        ? m
        : m.copyWith(
            originCryptoValid: await verifyOrigin(o,
                channelId: m.channelId, body: m.body, replyTo: m.replyToId));
    await cache.upsertInbound(verified);
  }

  group('fromView — inbound origin shape gate (T2)', () {
    test('a valid origin is admitted and carried on the Message', () async {
      final m = Message.fromView(await signedView(
          ulid: '01ULID', signedCmid: 'sender-tmp-1', signedBody: 'hi'));
      expect(m.origin, isNotNull);
      expect(m.origin!.clientMsgId, 'sender-tmp-1');
      expect(m.originCryptoValid, isNull, reason: 'verify is async, not in fromView');
    });

    test('a MALFORMED origin is dropped; the message is still delivered', () async {
      final view = await signedView(
          ulid: '01ULID', signedCmid: 'c', signedBody: 'hi');
      (view['origin'] as Map)['extra'] = 'boom'; // breaks the exact-key-set gate
      final m = Message.fromView(view);
      expect(m.origin, isNull, reason: 'bad envelope dropped');
      expect(m.body, 'hi', reason: 'message survives (absent == unverified)');
    });
  });

  group('persist + verify (T5) into typed columns (T3)', () {
    test('a valid inbound origin persists verified=1 into the typed columns',
        () async {
      await persist(await signedView(
          ulid: '01A', signedCmid: 'sender-tmp', signedBody: 'hello'));
      final row = await rawRow('01A');
      expect(row.sig, isNotNull);
      expect(row.senderPubkey, isNotNull);
      expect(row.signedAtMs, 1720000000000);
      expect(row.keyVersion, 1);
      expect(row.originCryptoValid, 1, reason: 'verified at ingest');
      // The signed id is stored because it differs from the ULID PK.
      expect(row.signedClientMsgId, 'sender-tmp');
    });

    test('a well-formed but INVALID signature persists verified=0 (carried-but-'
        'invalid), sig still stored', () async {
      // Sign over "real", but the view body is "tampered" → sig can't verify.
      await persist(await signedView(
          ulid: '01B',
          signedCmid: 'c',
          signedBody: 'real',
          viewBody: 'tampered'));
      final row = await rawRow('01B');
      expect(row.sig, isNotNull, reason: 'carried, so stored');
      expect(row.originCryptoValid, 0, reason: 'body mismatch → unverifiable');
    });

    test('round-trips: _toDomain reconstructs the origin + verdict from columns',
        () async {
      await persist(await signedView(
          ulid: '01C', signedCmid: 'sender-tmp', signedBody: 'rt'));
      final m = await readDomain('01C');
      expect(m.originCryptoValid, isTrue);
      expect(m.origin, isNotNull);
      expect(m.origin!.clientMsgId, 'sender-tmp',
          reason: 'signed id survives the round-trip, not the ULID');
      // The reconstructed origin re-verifies against the message content.
      expect(
          await verifyOrigin(m.origin!,
              channelId: m.channelId, body: m.body, replyTo: m.replyToId),
          isTrue);
    });
  });

  group('collapse / set-on-success law (T4)', () {
    test('SET-on-success: a first fanout INSERT sets the origin columns', () async {
      await persist(await signedView(
          ulid: '01D', signedCmid: 'c', signedBody: 'x'));
      expect((await rawRow('01D')).originCryptoValid, 1);
    });

    test('a content-identical re-echo PRESERVES the verdict + sig', () async {
      final view =
          await signedView(ulid: '01E', signedCmid: 'c', signedBody: 'same');
      await persist(view);
      final first = await rawRow('01E');
      await persist(view); // identical re-echo (history re-sync)
      final second = await rawRow('01E');
      expect(second.sig, first.sig);
      expect(second.originCryptoValid, 1);
    });

    test('cage-match Tesla: a diverged body with a FRESH valid origin REPLACES, '
        'not clears', () async {
      // Server re-echoes the same ULID with a NEW body AND a new envelope signing
      // that new body. The origin follows the incoming body → SET (verified=1),
      // never cleared at the zero-crossing.
      await persist(await signedView(
          ulid: '01H', signedCmid: 'c1', signedBody: 'v1'));
      await persist(await signedView(
          ulid: '01H', signedCmid: 'c2', signedBody: 'v2'));
      final row = await rawRow('01H');
      expect(row.body, 'v2');
      expect(row.sig, isNotNull, reason: 'the fresh origin replaces the old one');
      expect(row.originCryptoValid, 1, reason: 'the new origin signs the new body');
      expect(row.signedClientMsgId, 'c2', reason: 'the new signed id, not c1');
    });

    test('a diverged-body re-echo CLEARS sig + verdict + signed id (coherence)',
        () async {
      await persist(await signedView(
          ulid: '01F', signedCmid: 'c', signedBody: 'orig'));
      expect((await rawRow('01F')).sig, isNotNull);

      // Server re-echoes the SAME ULID with an edited body and no origin.
      await cache.upsertInbound(Message(
        clientTempId: '01F',
        id: '01F',
        channelId: _chan,
        sender: const MessageSender(kind: SenderKind.human),
        body: 'edited',
        createdAt: DateTime.now().toUtc(),
        deliveryState: DeliveryState.sent,
      ));
      final row = await rawRow('01F');
      expect(row.body, 'edited');
      expect(row.sig, isNull, reason: 'stale sig cleared');
      expect(row.originCryptoValid, isNull, reason: 'verdict clears WITH the sig');
      expect(row.signedClientMsgId, isNull, reason: 'signed id clears too');
    });
  });

  test('an unsigned inbound message stores no origin, no verdict', () async {
    await persist({
      'msg_id': '01G',
      'channel_id': _chan,
      'sender': {'user_id': 'o', 'kind': 'human', 'label': 'O'},
      'body': 'plain',
      'created_at': '2026-01-01T00:00:00Z',
      'reply_to': null,
    });
    final row = await rawRow('01G');
    expect(row.sig, isNull);
    expect(row.originCryptoValid, isNull);
  });
}
