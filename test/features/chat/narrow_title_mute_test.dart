// Mute on a PHONE.
//
// The long-press menu has existed since #135 — on sidebar rows, which the narrow
// layout does not have. So the capability was wide-only, and the phone got a
// dedicated app-bar button to compensate: a control existing because a gesture
// had nowhere to live.
//
// Now the app bar's conversation title carries the same gesture, and the button
// is gone. The thing worth testing is not that the wrapper is present — it is
// that the gesture SURVIVES THE DROPDOWN. With more than one conversation the
// title IS a DropdownButton, which runs its own gesture recognizers; a
// long-press that lost the arena to it would leave a phone with no way to mute
// at all, and nothing else in the suite would notice.
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

  testWidgets('the mute BUTTON is gone from the narrow app bar', (tester) async {
    narrow(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    expect(find.byKey(const Key('appbar-mute-conversation')), findsNothing,
        reason: 'mute is a long-press now; the strip got its seat back');
  });

  testWidgets('long-pressing the title opens the mute menu — WITH a dropdown, '
      'which is the case that could have lost the gesture arena', (tester) async {
    narrow(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Sanity: this really is the dropdown case, or the test proves nothing.
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.byKey(const Key('mute-gesture-title')), findsOneWidget,
        reason: 'the gesture wrapper is not even in the tree');

    await tester.longPress(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Mute'), findsOneWidget,
        reason: 'the long-press did not reach the mute menu');
  });

  testWidgets('TAPPING the dropdown still opens it — the mute wrapper must not '
      'swallow the gesture that switches conversations', (tester) async {
    narrow(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    // The overlay lists every conversation; 'random' only exists there.
    expect(find.text('random'), findsWidgets,
        reason: 'the dropdown did not open — wrapping the title for long-press '
            'must not cost the tap that switches conversation');
  });

  testWidgets('and with a single conversation, where the title is plain text',
      (tester) async {
    narrow(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: oneChannel), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('general').first);
    await tester.pumpAndSettle();

    expect(find.text('Mute'), findsOneWidget);
  });
}
