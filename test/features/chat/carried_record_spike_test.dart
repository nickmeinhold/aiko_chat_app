// SPIKE falsifier for "The Carried Record" (docs/RECOMBINATION.md,
// /ascend cold-pole build): proves — or disposes — the claim that a
// subject's locally-cached signed messages can be listed and each signature
// INDEPENDENTLY re-verified from carried bytes alone, with no new schema, no
// new routes, no network.
import 'package:aiko_chat_app/features/chat/domain/carried_record.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

const _me = 'me-user-id';
const _chan = 'chan-1';

Future<Message> _signedMessage(
  SovereignKey key, {
  required String clientTempId,
  required String body,
  String senderUserId = _me,
  String? replyToId,
}) async {
  final payload = SignedPayload(
    rawPublicKey: key.rawPublicKey,
    channelId: _chan,
    clientMsgId: clientTempId,
    signedAtMs: DateTime.now().millisecondsSinceEpoch,
    body: body,
    replyTo: replyToId,
  );
  final signature = await sign(key, payload);
  final origin =
      OriginEnvelope.fromSignature(signature, clientMsgId: clientTempId);
  return Message(
    clientTempId: clientTempId,
    id: clientTempId,
    channelId: _chan,
    sender: MessageSender(userId: senderUserId, kind: SenderKind.human),
    body: body,
    replyToId: replyToId,
    createdAt: DateTime.now().toUtc(),
    deliveryState: DeliveryState.sent,
    origin: origin,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SovereignKey key;

  setUp(() async {
    installSecureStorageMock();
    key = await SovereignKeyStore().loadOrCreate();
  });

  test(
      'renders + independently re-verifies a subject\'s signed local history '
      '(the falsifier)', () async {
    final m1 = await _signedMessage(key, clientTempId: 'a', body: 'hello');
    final m2 = await _signedMessage(key, clientTempId: 'b', body: 'world');
    final m3 = await _signedMessage(key, clientTempId: 'c', body: 'third');

    final record = await carriedRecord(_me, [m1, m2, m3]);

    expect(record.subjectUserId, _me);
    expect(record.entries.length, 3);
    expect(record.verifiedCount, 3);
    expect(record.invalidCount, 0);
    expect(record.unsignedCount, 0);
    expect(
      record.entries.every((e) => e.verdict == CarriedRecordVerdict.verified),
      isTrue,
    );
  });

  test(
      'RED-proof: a message tampered AFTER signing classifies invalid — proves '
      'this is a real re-verify, not a rubber stamp', () async {
    final honest = await _signedMessage(key, clientTempId: 'a', body: 'hello');
    // Tamper with the body post-signing; the carried signature material
    // (origin) is unchanged, so it now authenticates a DIFFERENT body than
    // what's carried — independent verification must catch this.
    final tampered = honest.copyWith(body: 'hello, but attacker edited this');

    final record = await carriedRecord(_me, [tampered]);

    expect(record.entries.single.verdict, CarriedRecordVerdict.invalid);
    expect(record.invalidCount, 1);
    expect(record.verifiedCount, 0);
  });

  test('an unsigned message classifies unsigned and does not crash', () async {
    final unsigned = Message(
      clientTempId: 'u',
      id: 'u',
      channelId: _chan,
      sender: const MessageSender(userId: _me, kind: SenderKind.human),
      body: 'pre-feature history',
      createdAt: DateTime.now().toUtc(),
      deliveryState: DeliveryState.sent,
      // origin: null (default) — legal, pre-feature / never-signed history.
    );

    final record = await carriedRecord(_me, [unsigned]);

    expect(record.entries.single.verdict, CarriedRecordVerdict.unsigned);
    expect(record.unsignedCount, 1);
    expect(record.verifiedCount, 0);
    expect(record.invalidCount, 0);
  });

  test('filters strictly by subjectUserId — another author is excluded',
      () async {
    final mine = await _signedMessage(key, clientTempId: 'mine', body: 'me');
    final theirs = await _signedMessage(
      key,
      clientTempId: 'theirs',
      body: 'not me',
      senderUserId: 'someone-else',
    );

    final record = await carriedRecord(_me, [mine, theirs]);

    expect(record.entries.length, 1);
    expect(record.entries.single.id, 'mine');
  });

  test('a mixed record (verified + invalid + unsigned) tallies correctly',
      () async {
    final good = await _signedMessage(key, clientTempId: 'g', body: 'good');
    final bad =
        (await _signedMessage(key, clientTempId: 'b', body: 'orig'))
            .copyWith(body: 'tampered');
    final none = Message(
      clientTempId: 'n',
      id: 'n',
      channelId: _chan,
      sender: const MessageSender(userId: _me, kind: SenderKind.human),
      body: 'unsigned',
      createdAt: DateTime.now().toUtc(),
      deliveryState: DeliveryState.sent,
    );

    final record = await carriedRecord(_me, [good, bad, none]);

    expect(record.verifiedCount, 1);
    expect(record.invalidCount, 1);
    expect(record.unsignedCount, 1);
    expect(record.entries.length, 3);
  });
}
