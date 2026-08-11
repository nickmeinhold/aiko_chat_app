// Widget test for "Your Carried Record" (the AUTHORSHIP-half screen). Drives the
// real carriedRecordProvider → carriedRecord domain path over a fixed, injected
// message set: signed-mine renders ✓, tampered-mine renders invalid, unsigned-mine
// renders —, and a message from ANOTHER author is excluded entirely.
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/features/chat/presentation/carried_record_screen.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

const _me = 'me-user-id';
const _chan = 'chan-1';
const _meUser = AppUser(
  userId: _me,
  username: 'me',
  displayName: 'Me',
  aikoUsername: 'me',
);

/// A fresh, independent Ed25519 key — distinct from the device key. Used to
/// forge a well-formed, VALID signature under a key that is NOT mine.
Future<SovereignKey> _freshKey() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  return SovereignKey(keyPair: kp, rawPublicKey: Uint8List.fromList(pub.bytes));
}

Future<Message> _signedMessage(
  SovereignKey key, {
  required String clientTempId,
  required String body,
  String senderUserId = _me,
}) async {
  final payload = SignedPayload(
    rawPublicKey: key.rawPublicKey,
    channelId: _chan,
    clientMsgId: clientTempId,
    signedAtMs: DateTime.now().millisecondsSinceEpoch,
    body: body,
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
    createdAt: DateTime.now().toUtc(),
    deliveryState: DeliveryState.sent,
    origin: origin,
  );
}

Future<void> _pump(WidgetTester tester, List<Message> messages) async {
  final container = ProviderContainer(overrides: [
    currentUserProvider.overrideWithValue(_meUser),
    myCarriedMessagesProvider.overrideWith((ref) async => messages),
  ]);
  addTearDown(container.dispose);
  // Taller-than-default surface: the screen constrains content to a 560px
  // reading column (ReadingColumn), so entries wrap taller than at full width —
  // a multi-entry record needs the extra height to render every row on screen
  // (the default 800x600 pushes the last row past the ListView cache extent).
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: CarriedRecordScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late SovereignKey key;

  setUp(() async {
    installSecureStorageMock();
    key = await SovereignKeyStore().loadOrCreate();
  });

  testWidgets('lists my signed messages as verified and excludes other authors',
      (tester) async {
    final mine = await _signedMessage(key, clientTempId: 'a', body: 'hello mine');
    final theirs = await _signedMessage(
      key,
      clientTempId: 'b',
      body: 'not mine',
      senderUserId: 'someone-else',
    );

    await _pump(tester, [mine, theirs]);

    // My message is listed and marked verified.
    expect(find.text('hello mine'), findsOneWidget);
    expect(find.text('Verified — provably yours'), findsOneWidget);
    // The other author's message is excluded entirely.
    expect(find.text('not mine'), findsNothing);
  });

  testWidgets(
      'SECURITY: a valid signature under a FOREIGN key (sender.userId == me) '
      'never renders "provably yours"', (tester) async {
    // A forged/cached row claiming to be from me, carrying a well-formed VALID
    // signature — but signed by an attacker's own key. Must NOT read verified.
    final attacker = await _freshKey();
    final forged = await _signedMessage(attacker,
        clientTempId: 'x', body: 'I never wrote this');

    await _pump(tester, [forged]);

    expect(find.text('I never wrote this'), findsOneWidget);
    // Never claimed as mine.
    expect(find.text('Verified — provably yours'), findsNothing);
    // Honestly labelled as a different key.
    expect(find.text('Signed by a different key — not this device'),
        findsOneWidget);
  });

  testWidgets('a tampered message renders as invalid', (tester) async {
    final tampered = (await _signedMessage(key, clientTempId: 'a', body: 'orig'))
        .copyWith(body: 'attacker edited this');

    await _pump(tester, [tampered]);

    expect(find.text('attacker edited this'), findsOneWidget);
    expect(find.text("Invalid — signature doesn't match"), findsOneWidget);
  });

  testWidgets('an unsigned message renders as unsigned (—)', (tester) async {
    final unsigned = Message(
      clientTempId: 'u',
      id: 'u',
      channelId: _chan,
      sender: const MessageSender(userId: _me, kind: SenderKind.human),
      body: 'pre-feature history',
      createdAt: DateTime.now().toUtc(),
      deliveryState: DeliveryState.sent,
      // origin: null → unsigned.
    );

    await _pump(tester, [unsigned]);

    expect(find.text('pre-feature history'), findsOneWidget);
    expect(find.text('Unsigned — no signature carried'), findsOneWidget);
  });

  testWidgets('a mixed record shows all three verdicts together', (tester) async {
    final good = await _signedMessage(key, clientTempId: 'g', body: 'good one');
    final bad = (await _signedMessage(key, clientTempId: 'b', body: 'was good'))
        .copyWith(body: 'tampered one');
    final none = Message(
      clientTempId: 'n',
      id: 'n',
      channelId: _chan,
      sender: const MessageSender(userId: _me, kind: SenderKind.human),
      body: 'unsigned one',
      createdAt: DateTime.now().toUtc(),
      deliveryState: DeliveryState.sent,
    );

    await _pump(tester, [good, bad, none]);

    expect(find.text('Verified — provably yours'), findsOneWidget);
    expect(find.text("Invalid — signature doesn't match"), findsOneWidget);
    expect(find.text('Unsigned — no signature carried'), findsOneWidget);
  });

  testWidgets('empty record shows the honest empty state', (tester) async {
    await _pump(tester, const []);

    expect(
      find.textContaining("haven't authored any messages"),
      findsOneWidget,
    );
  });
}
