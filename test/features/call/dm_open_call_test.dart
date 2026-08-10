import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/call/presentation/call_screen.dart'
    show resetCallLaunchGuard;
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:aiko_chat_app/features/moderation/presentation/message_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/ui_fakes.dart';

/// The call-only DM path (#2758): long-press another human's message → "Call
/// {name}" opens (find-or-creates) the DM with THAT sender and pushes the call
/// route for the returned channel. These tests pin the two things a regression
/// would silently break: the target threaded to `openDm` is the sender's opaque
/// `userId` (not a label / channel id), and a failed open shows a SnackBar
/// instead of navigating into a dead call.
void main() {
  final robin = Message(
    clientTempId: 'm1',
    id: 'm1',
    channelId: 'general',
    sender: const MessageSender(
        userId: 'robin-key-opaque', kind: SenderKind.human, label: 'Robin'),
    body: 'hey',
    createdAt: DateTime.utc(2026, 8, 10, 13),
    deliveryState: DeliveryState.sent,
  );

  Widget harness(FakeRestApi fake, {Set<String> blocked = const {}}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showMessageActions(context, ref, robin),
                child: const Text('open-actions'),
              ),
            ),
          ),
        ),
        // Stub call route — a marker so the test can assert we navigated here
        // without mounting the real LiveKit CallScreen.
        GoRoute(
          path: '/call/:channelId',
          builder: (context, state) =>
              Scaffold(body: Text('CALL:${state.pathParameters['channelId']}')),
        ),
      ],
    );
    return UncontrolledProviderScope(
      container: ProviderContainer(overrides: [
        restApiProvider.overrideWithValue(fake),
        blockedUserIdsProvider.overrideWithValue(blocked),
      ]),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  tearDown(resetCallLaunchGuard); // the success case navigates and never pops

  testWidgets('Call opens the DM with the sender key and pushes the call route',
      (tester) async {
    final fake = FakeRestApi()
      ..openDmReturns =
          const Channel(id: 'dm:me:robin', name: '', kind: ChannelKind.dm);
    await tester.pumpWidget(harness(fake));

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call Robin'));
    await tester.pumpAndSettle();

    expect(fake.openDmCalls, 1);
    expect(fake.lastOpenDmTarget, 'robin-key-opaque'); // the opaque key, not 'Robin'
    expect(find.text('CALL:dm:me:robin'), findsOneWidget); // room == DM channel id
  });

  testWidgets('a failed open shows a SnackBar and does not navigate',
      (tester) async {
    final fake = FakeRestApi()..openDmThrows = const DmTargetNotFound();
    await tester.pumpWidget(harness(fake));

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call Robin'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't reach Robin"), findsOneWidget);
    expect(find.textContaining('CALL:'), findsNothing); // never entered a call
  });

  testWidgets('Call fails closed on a blocked target — no openDm, no navigation',
      (tester) async {
    final fake = FakeRestApi();
    await tester.pumpWidget(harness(fake, blocked: {'robin-key-opaque'}));

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call Robin'));
    await tester.pumpAndSettle();

    expect(fake.openDmCalls, 0); // never even requested a room (defence-in-depth)
    expect(find.textContaining("You've blocked Robin"), findsOneWidget);
    expect(find.textContaining('CALL:'), findsNothing);
  });
}
