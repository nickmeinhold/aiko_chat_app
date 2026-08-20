// Widget tests for the operator seat (#33/#35): the moderator-gated Settings
// entry and the report queue screen (render + a take-down action removing a tile).

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/moderation/domain/moderation_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

const _modUser = AppUser(
  userId: 'u1',
  username: 'nick',
  displayName: 'Nick',
  aikoUsername: 'nick',
  isModerator: true,
);

PendingReport _report(String id, {String sender = 'bad1'}) => PendingReport(
  reportId: id,
  messageId: 'm-$id',
  channelId: 'c1',
  reason: 'harassment',
  reporterDisplayName: 'Reporter',
  messageBody: 'body of $id',
  messageSenderUserId: sender,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  messageDeletedAt: null,
);

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  testWidgets('a NON-moderator does not see the Reports tile in Settings', (
    tester,
  ) async {
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await _openSettings(tester);

    expect(
      find.text('Blocked users'),
      findsOneWidget,
    ); // sanity: settings loaded
    expect(find.text('Reports'), findsNothing);
  });

  testWidgets('a moderator sees the Reports tile and opens the queue', (
    tester,
  ) async {
    final rest = FakeRestApi(user: _modUser)..pendingReports = [_report('r1')];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await _openSettings(tester);

    expect(find.text('Reports'), findsOneWidget);
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();

    // The queue rendered the pending report's body preview.
    expect(find.text('body of r1'), findsOneWidget);
  });

  testWidgets('taking a message down calls resolve and removes the tile', (
    tester,
  ) async {
    final rest = FakeRestApi(user: _modUser)
      ..pendingReports = [_report('r1'), _report('r2')];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await _openSettings(tester);
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();

    // Open r1's action menu (the first tile's overflow) → Take down → confirm.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take message down'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Take down'));
    await tester.pumpAndSettle();

    expect(rest.resolvedReports, ['r1']);
    expect(find.text('body of r1'), findsNothing); // tile gone
    expect(find.text('body of r2'), findsOneWidget); // sibling remains
  });
}
