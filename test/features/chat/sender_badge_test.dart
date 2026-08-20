import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ui_fakes.dart';

/// The participant badge (#2414): a non-human `sender_kind` must render a
/// visible "who/what" chip so an agent/bot message is distinguishable from a
/// person's — the UX half of "handle non-human sender_kind gracefully". Humans
/// get no badge; any UNKNOWN island sender_kind degrades to `actor` → "Bot"
/// (never silently blends in as human).
Message _msg(MessageSender sender) => Message(
  clientTempId: 't1',
  id: 's1',
  channelId: 'c1',
  sender: sender,
  body: 'hello',
  createdAt: DateTime(2026, 1, 1),
  deliveryState: DeliveryState.sent,
);

Future<void> _pump(WidgetTester tester, MessageSender sender) async {
  await tester.pumpWidget(
    ProviderScope(
      // The tile now watches the channel roster (current-handle resolution); a
      // fake REST api keeps it offline — an empty roster falls back to the label,
      // which is what these badge assertions read.
      overrides: [restApiProvider.overrideWithValue(FakeRestApi())],
      child: MaterialApp(
        home: Scaffold(
          body: MessageTile(
            message: _msg(sender),
            isMine: false,
            channelId: 'c1',
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('human sender shows NO participant badge', (tester) async {
    await _pump(
      tester,
      const MessageSender(userId: 'u2', kind: SenderKind.human, label: 'Alice'),
    );
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy), findsNothing);
  });

  testWidgets('llm sender shows an "AI" badge', (tester) async {
    await _pump(
      tester,
      const MessageSender(kind: SenderKind.llm, label: 'Aiko'),
    );
    expect(find.byIcon(Icons.smart_toy), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('robot sender shows a "Robot" badge', (tester) async {
    await _pump(
      tester,
      const MessageSender(kind: SenderKind.robot, label: 'R2'),
    );
    expect(find.byIcon(Icons.smart_toy), findsOneWidget);
    expect(find.text('Robot'), findsOneWidget);
  });

  testWidgets('unknown island sender_kind (→ actor) still badges as "Bot"', (
    tester,
  ) async {
    // The island may stamp sender_kind='agent'/'bot'/etc from User.kind;
    // fromWire degrades any unknown value to actor. It must STILL render a
    // badge, not blend in as a human message.
    final sender = MessageSender(
      kind: SenderKind.fromWire('agent'),
      label: 'Ag',
    );
    await _pump(tester, sender);
    expect(find.byIcon(Icons.smart_toy), findsOneWidget);
    expect(find.text('Bot'), findsOneWidget);
  });
}
