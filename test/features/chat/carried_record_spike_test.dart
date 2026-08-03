// Domain falsifier for "The Carried Record" authorship reader
// (docs/RECOMBINATION.md): a subject's locally-cached signed messages are
// listed and each signature INDEPENDENTLY re-verified from carried bytes alone
// — AND the `verified` verdict is bound to the subject's own public key, so a
// valid signature under a foreign key is never claimed as theirs.
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/domain/carried_record.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

const _me = 'me-user-id';
const _chan = 'chan-1';

/// Mint a FRESH, independent Ed25519 key — distinct from the device key. Used to
/// forge a well-formed, VALID signature under a key that is NOT the subject's.
Future<SovereignKey> _freshKey() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  return SovereignKey(
    keyPair: kp,
    rawPublicKey: Uint8List.fromList(pub.bytes),
  );
}

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

Message _unsignedMessage(String id, String body) => Message(
      clientTempId: id,
      id: id,
      channelId: _chan,
      sender: const MessageSender(userId: _me, kind: SenderKind.human),
      body: body,
      createdAt: DateTime.now().toUtc(),
      deliveryState: DeliveryState.sent,
      // origin: null (default) — legal, pre-feature / never-signed history.
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SovereignKey key; // the subject's (device) key

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

    final record = await carriedRecord(_me, [m1, m2, m3],
        subjectPublicKey: key.rawPublicKey);

    expect(record.subjectUserId, _me);
    expect(record.entries.length, 3);
    expect(record.verifiedCount, 3);
    expect(record.invalidCount, 0);
    expect(record.foreignKeyCount, 0);
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

    final record = await carriedRecord(_me, [tampered],
        subjectPublicKey: key.rawPublicKey);

    expect(record.entries.single.verdict, CarriedRecordVerdict.invalid);
    expect(record.invalidCount, 1);
    expect(record.verifiedCount, 0);
  });

  test(
      'RED-proof (the security guarantee): a VALID signature under a FOREIGN '
      'key with sender.userId == me is NEVER verified/"provably yours"',
      () async {
    // The attack: a cached/forged row that CLAIMS to be from me (sender.userId
    // == _me) carrying a well-formed, cryptographically VALID signature — but
    // signed by an attacker's own key, not mine. Selecting "mine" by the
    // non-crypto sender field and trusting any valid sig would render this
    // "Verified — provably yours". Binding `verified` to my key must reject it.
    final attacker = await _freshKey();
    expect(attacker.rawPublicKey, isNot(key.rawPublicKey));

    final forged = await _signedMessage(attacker,
        clientTempId: 'x', body: 'I never wrote this');

    final record = await carriedRecord(_me, [forged],
        subjectPublicKey: key.rawPublicKey);

    // NOT verified — the core guarantee.
    expect(record.verifiedCount, 0);
    expect(record.entries.single.verdict, isNot(CarriedRecordVerdict.verified));
    // Classified as a foreign key: provably signed by *someone*, but not me.
    expect(record.entries.single.verdict, CarriedRecordVerdict.foreignKey);
    expect(record.foreignKeyCount, 1);
  });

  test('an unsigned message classifies unsigned and does not crash', () async {
    final record = await carriedRecord(
        _me, [_unsignedMessage('u', 'pre-feature history')],
        subjectPublicKey: key.rawPublicKey);

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

    final record = await carriedRecord(_me, [mine, theirs],
        subjectPublicKey: key.rawPublicKey);

    expect(record.entries.length, 1);
    expect(record.entries.single.id, 'mine');
  });

  test('a mixed record (verified + invalid + unsigned) tallies correctly',
      () async {
    final good = await _signedMessage(key, clientTempId: 'g', body: 'good');
    final bad = (await _signedMessage(key, clientTempId: 'b', body: 'orig'))
        .copyWith(body: 'tampered');
    final none = _unsignedMessage('n', 'unsigned');

    final record = await carriedRecord(_me, [good, bad, none],
        subjectPublicKey: key.rawPublicKey);

    expect(record.verifiedCount, 1);
    expect(record.invalidCount, 1);
    expect(record.unsignedCount, 1);
    expect(record.entries.length, 3);
  });

  test('fails closed on an empty subject id or empty subject key', () async {
    final m = await _signedMessage(key, clientTempId: 'a', body: 'hello');

    final noSubject =
        await carriedRecord('', [m], subjectPublicKey: key.rawPublicKey);
    expect(noSubject.entries, isEmpty);

    final noKey = await carriedRecord(_me, [m], subjectPublicKey: Uint8List(0));
    expect(noKey.entries, isEmpty);
  });
}
