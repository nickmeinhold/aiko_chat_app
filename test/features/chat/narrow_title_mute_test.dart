// Mute on a phone.
//
// The retired app-bar dropdown forced conversation mute behind an unannounced
// title long-press. The title now means "this conversation" and opens the
// details screen, where the same mute state is visible and tap-reachable. The
// drawer owns conversation switching.
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const twoChannels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
  ];
  const oneChannel = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
  ];

  void narrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openDetails(WidgetTester tester) async {
    await tester.tap(find.text('general').first);
    await tester.pumpAndSettle();
  }

  testWidgets('the mute button is gone from the narrow app bar', (
    tester,
  ) async {
    narrow(tester);
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    expect(
      find.byKey(const Key('appbar-mute-conversation')),
      findsNothing,
      reason: 'mute is in conversation details now; the strip got its seat back',
    );
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('tapping the title opens conversation details', (tester) async {
    narrow(tester);
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await openDetails(tester);

    expect(find.text('Mute this conversation'), findsOneWidget);
    expect(find.text('Channel'), findsOneWidget);
  });

  testWidgets('details mute toggles the active conversation', (tester) async {
    narrow(tester);
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    expect(container.read(mutedChannelIdsProvider), isEmpty);

    await openDetails(tester);
    await tester.tap(find.text('Mute this conversation'));
    await tester.pumpAndSettle();

    expect(container.read(mutedChannelIdsProvider), contains('c1'));

    await tester.tap(find.text('Mute this conversation'));
    await tester.pumpAndSettle();

    expect(container.read(mutedChannelIdsProvider), isEmpty);
  });

  // The state, not just the control. Mute moved one tap away into the details,
  // so the app bar is the only place a phone reader can LEARN a conversation is
  // silenced without going looking. Both arms are here on purpose: an indicator
  // that is always drawn would pass a present-when-muted check and say nothing.
  testWidgets('the title announces mute, and only when muted', (tester) async {
    narrow(tester);
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    final glyph = find.descendant(
      of: find.byType(AppBar),
      matching: find.byIcon(Icons.notifications_off),
    );
    expect(glyph, findsNothing, reason: 'an unmuted conversation says nothing');

    await openDetails(tester);
    await tester.tap(find.text('Mute this conversation'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      glyph,
      findsOneWidget,
      reason:
          'a silenced conversation that looks exactly like a quiet one is the '
          'confusion the sidebar mute glyph exists to prevent — and narrow has '
          'no sidebar',
    );
  });

  testWidgets('the drawer still switches conversations', (tester) async {
    narrow(tester);
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await selectChannelFromDrawer(tester, 'c2');

    expect(container.read(selectedChannelIdProvider), 'c2');
    expect(find.widgetWithText(AppBar, 'random'), findsOneWidget);
  });

  testWidgets('details opens with a single plain-title conversation', (
    tester,
  ) async {
    narrow(tester);
    final container = makeContainer(
      rest: FakeRestApi(channels: oneChannel),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButton<String>), findsNothing);

    await openDetails(tester);

    expect(find.text('Mute this conversation'), findsOneWidget);
  });
}
