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

  testWidgets('agent sender shows an "Agent" badge, NOT the unknown "Bot"', (
    tester,
  ) async {
    // ADR-0005: an agent is a first-class Principal that can hold standing of
    // its own. "Bot" is this badge's GENERIC-UNKNOWN label, so rendering an
    // agent as "Bot" states the opposite of the decision — the lesser standing
    // that ADR rejects, arriving through the render.
    await _pump(
      tester,
      MessageSender(kind: SenderKind.fromWire('agent'), label: 'Ag'),
    );
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Bot'), findsNothing);
    expect(find.byIcon(Icons.hub), findsOneWidget);
  });

  testWidgets('an agent still wears a badge — it is not a human', (
    tester,
  ) async {
    // The half of the old decode that was ALREADY RIGHT, pinned so the fix above
    // cannot quietly undo it. This is what island #3096 existed to fix: an agent
    // must never wear a human's unbadged label. Changing WHICH badge it wears
    // must not change WHETHER it wears one.
    expect(SenderKind.agent.isExternalActor, isTrue);
    await _pump(
      tester,
      const MessageSender(kind: SenderKind.agent, label: 'Ag'),
    );
    expect(find.byType(Icon), findsWidgets);
  });

  testWidgets('a genuinely unknown sender_kind still badges as "Bot"', (
    tester,
  ) async {
    // THE CONTRACT THIS TEST ALWAYS MEANT TO PIN, with a witness that actually
    // satisfies it. It used to prove "unknown degrades to a badge" using
    // 'agent' — a value the island had been able to emit since migration
    // 0022_users_kind, and one this repo's own ADR-0005 had decided the meaning
    // of. The contract was right and the example was not, so the test stayed
    // green while the value it named was mishandled, and its green is the reason
    // nobody looked. The tolerance itself is deliberate and stays: the island
    // relies on it to rule out a fail-closed read path.
    await _pump(
      tester,
      MessageSender(kind: SenderKind.fromWire('hologram'), label: 'Ho'),
    );
    expect(find.byIcon(Icons.smart_toy), findsOneWidget);
    expect(find.text('Bot'), findsOneWidget);
  });
}
