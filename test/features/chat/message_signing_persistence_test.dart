import 'dart:convert';

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/test_helpers.dart';

const _chan = 'chan';
const _me = AppUser(
    userId: 'me', username: 'me', displayName: 'Me', aikoUsername: 'me');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late DriftCache cache;
  late FakeChatTransport transport;
  late FakeChatRestApi rest;
  late SovereignKey key;
  int seq = 0;

  ChatRepository buildRepo({SovereignKey? signingKey}) {
    final repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: rest,
      me: _me,
      subscribedChannelIds: const [_chan],
      ackTimeout: const Duration(milliseconds: 80),
      signingKey: signingKey,
      newTempId: () => 'tmp${seq++}',
    );
    repo.start();
    return repo;
  }

  // Read the raw drift row (domain Message doesn't expose the signing columns).
  Future<MessageRow> rawRow() =>
      (cache.select(cache.messages)..where((t) => t.channelId.equals(_chan)))
          .getSingle();

  setUp(() async {
    installSecureStorageMock();
    cache = DriftCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    rest = FakeChatRestApi();
    seq = 0;
    key = await SovereignKeyStore().loadOrCreate();
  });

  tearDown(() async {
    await transport.dispose();
    await cache.close();
  });

  Future<void> pump() =>
      Future<void>.delayed(const Duration(milliseconds: 15));

  test('a signed send persists a self-verifying signature on the row', () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'hello world');
    final row = await rawRow();

    expect(row.sig, isNotNull);
    expect(row.senderPubkey, isNotNull);
    expect(row.signedAtMs, isNotNull);
    expect(row.keyVersion, 1);

    // Reconstruct the signed payload from the row + verify — proves the stored
    // bytes are exactly what a future verifier will reconstruct.
    final ok = await verifySignature(
      base64Decode(row.senderPubkey!),
      base64Decode(row.sig!),
      SignedPayload(
        rawPublicKey: base64Decode(row.senderPubkey!),
        channelId: row.channelId,
        clientMsgId: row.clientTempId,
        signedAtMs: row.signedAtMs!,
        body: row.body,
        replyTo: null,
      ),
    );
    expect(ok, isTrue);
    await repo.dispose();
  });

  test('BRIGHT LINE: nothing signing-related leaks onto the wire', () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'hi');
    // OutgoingMessage carries only the four content fields — no sig/pubkey by
    // construction. Assert the wire payload is exactly the pre-signing shape.
    final sent = transport.sent.single;
    expect(sent.clientTempId, isNotNull);
    expect(sent.channelId, _chan);
    expect(sent.body, 'hi');
    expect(sent.replyToId, isNull);
    await repo.dispose();
  });

  test('no signing key → no signature, no crash (graceful optionality)',
      () async {
    final repo = buildRepo(signingKey: null);
    await repo.sendMessage(_chan, 'hi');
    final row = await rawRow();
    expect(row.sig, isNull);
    expect(row.signedAtMs, isNull);
    await repo.dispose();
  });

  test('Temper F2: signedAtMs survives ack overwriting createdAt; sig still '
      'verifies', () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'hi');
    final before = await rawRow();
    final signedAt = before.signedAtMs!;

    // Ack with a DIFFERENT server time — this overwrites createdAt.
    transport.emitAck(before.clientTempId, '01U',
        createdAt: '2030-01-01T00:00:00Z');
    await pump();

    final after = await rawRow();
    final serverMs = DateTime.parse('2030-01-01T00:00:00Z')
        .toUtc()
        .millisecondsSinceEpoch;
    expect(after.createdAt, serverMs, reason: 'ack overwrote createdAt');
    expect(after.signedAtMs, signedAt,
        reason: 'signed time must be immune to ack reconciliation');

    // The signature still verifies against the DURABLE signed time, not createdAt.
    final ok = await verifySignature(
      base64Decode(after.senderPubkey!),
      base64Decode(after.sig!),
      SignedPayload(
        rawPublicKey: base64Decode(after.senderPubkey!),
        channelId: after.channelId,
        clientMsgId: after.clientTempId,
        signedAtMs: after.signedAtMs!,
        body: after.body,
        replyTo: null,
      ),
    );
    expect(ok, isTrue);
    await repo.dispose();
  });

  test('cage-match Carnot: a collapse (server body wins) CLEARS the stale sig',
      () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'my body');
    final before = await rawRow();
    expect(before.sig, isNotNull, reason: 'our optimistic row is signed');

    // A server row with the SAME ULID but a DIFFERENT body arrives first, then
    // our ack collapses our row onto server truth. The stored signature was over
    // "my body" — it must NOT survive beside the server's "server body".
    transport.emitMessage(Message(
      clientTempId: '01U',
      id: '01U',
      channelId: _chan,
      sender: const MessageSender(
          userId: 'me', kind: SenderKind.human, label: 'Me'),
      body: 'server body',
      createdAt: DateTime.parse('2026-01-01T00:00:00Z').toUtc(),
      deliveryState: DeliveryState.sent,
    ));
    await pump();
    transport.emitAck(before.clientTempId, '01U');
    await pump();

    final after = await rawRow();
    expect(after.body, 'server body', reason: 'collapse merged server content');
    expect(after.sig, isNull, reason: 'stale signature cleared on collapse');
    expect(after.senderPubkey, isNull);
    expect(after.signedAtMs, isNull);
    await repo.dispose();
  });

  test('cage-match Tesla R2: a content-identical re-echo PRESERVES the sig',
      () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'same body');
    final sent = transport.sent.single;
    transport.emitAck(sent.clientTempId, '01U'); // happy path keeps the sig
    await pump();
    final acked = await rawRow();
    expect(acked.sig, isNotNull);

    // History re-sync delivers our own message unchanged — must NOT scrape the
    // valid sig off the row (silent history amnesia).
    await cache.upsertInbound(Message(
      clientTempId: '01U',
      id: '01U',
      channelId: _chan,
      sender: const MessageSender(
          userId: 'me', kind: SenderKind.human, label: 'Me'),
      body: 'same body', // identical
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(acked.createdAt, isUtc: true),
      deliveryState: DeliveryState.sent,
    ));
    final after = await rawRow();
    expect(after.sig, isNotNull, reason: 'unchanged content keeps the valid sig');
    expect(after.sig, acked.sig);
  });

  test('cage-match Tesla R2: an inbound update with CHANGED body clears the sig',
      () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'original');
    final sent = transport.sent.single;
    transport.emitAck(sent.clientTempId, '01U');
    await pump();
    expect((await rawRow()).sig, isNotNull);

    await cache.upsertInbound(Message(
      clientTempId: '01U',
      id: '01U',
      channelId: _chan,
      sender: const MessageSender(
          userId: 'me', kind: SenderKind.human, label: 'Me'),
      body: 'server edited', // diverged
      createdAt: DateTime.now().toUtc(),
      deliveryState: DeliveryState.sent,
    ));
    final after = await rawRow();
    expect(after.body, 'server edited');
    expect(after.sig, isNull, reason: 'diverged content drops the stale sig');
  });

  test('cage-match Tesla R3: a content-identical COLLAPSE preserves the seal',
      () async {
    final repo = buildRepo(signingKey: key);
    await repo.sendMessage(_chan, 'echo me');
    final signed = await rawRow();
    expect(signed.sig, isNotNull);

    // Birth-race: our OWN self-echo (identical body) lands as a server row BEFORE
    // the ack, then the ack collapses our signed row onto it. Content is identical
    // to what we signed → the seal must SURVIVE the race-order merge.
    transport.emitMessage(Message(
      clientTempId: '01U',
      id: '01U',
      channelId: _chan,
      sender: const MessageSender(
          userId: 'me', kind: SenderKind.human, label: 'Me'),
      body: 'echo me', // identical to what we signed
      createdAt: DateTime.parse('2026-01-01T00:00:00Z').toUtc(),
      deliveryState: DeliveryState.sent,
    ));
    await pump();
    transport.emitAck(signed.clientTempId, '01U');
    await pump();

    final after = await rawRow();
    expect(after.serverUlid, '01U', reason: 'collapsed onto the server ULID');
    expect(after.sig, signed.sig,
        reason: 'identical-content collapse preserves the valid seal');
    // And it still verifies against the preserved signed_at_ms.
    final ok = await verifySignature(
      base64Decode(after.senderPubkey!),
      base64Decode(after.sig!),
      SignedPayload(
        rawPublicKey: base64Decode(after.senderPubkey!),
        channelId: after.channelId,
        clientMsgId: after.clientTempId,
        signedAtMs: after.signedAtMs!,
        body: after.body,
        replyTo: null,
      ),
    );
    expect(ok, isTrue);
    await repo.dispose();
  });
}
