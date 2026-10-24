import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/answer_outcome.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/call/presentation/ring_overlay.dart';
import 'package:aiko_chat_app/app/router.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/moderation/presentation/message_actions.dart';
import 'package:aiko_chat_app/features/call/presentation/call_screen.dart'
    show callRouteRedirect;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/test_helpers.dart';
import 'call_fixtures.dart';

/// Every door into calling is OPEN, and each one is proven reachable here.
///
/// This was `call_gating_test`: while calling shipped behind a build flag, each
/// door had a gated-OFF case paired with a gated-ON one. The flag was deleted in
/// 0.0.6 once both things it held for were built (the media disclosure, and a
/// ring that reaches a closed app). What survives is the half that still says
/// something: the banner rings, the sheet offers Call WITH its disclosure, and
/// `/call` is registered but joins nothing without a call of ours.
void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const me = AppUser(
    userId: 'u1',
    username: 'nick',
    displayName: 'Nick',
    aikoUsername: 'nick',
  );

  const generalChannel = Channel(
    id: 'general',
    name: 'general',
    kind: ChannelKind.standard,
  );

  final message = Message(
    clientTempId: 'm1',
    id: 'm1',
    channelId: 'general',
    sender: const MessageSender(
      userId: 'robin-key',
      kind: SenderKind.human,
      label: 'Robin',
    ),
    body: 'hey',
    createdAt: DateTime.utc(2026, 9, 1, 12),
    deliveryState: DeliveryState.sent,
  );

  final invite = CallInvite(
    call: kTestCall,
    inviteId: 'inv-1',
    islandMsgId: 'srv-1',
    channelId: 'dm:me:robin',
    from: const MessageSender(
      userId: 'robin-key',
      kind: SenderKind.human,
      label: 'Robin',
    ),
    startedAt: DateTime.utc(2026, 9, 1, 13),
  );

  group('the inbound door — the ring banner', () {
    Widget harness() => ProviderScope(
      overrides: [incomingRingProvider.overrideWith(() => _FakeRing(invite))],
      child: const MaterialApp(
        home: RingOverlay(child: Scaffold(body: Text('home'))),
      ),
    );

    testWidgets('a live invitation raises the banner', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.text('Incoming call'), findsOneWidget);
      expect(find.text('Answer'), findsOneWidget);
      expect(find.text('Robin'), findsOneWidget);
    });
  });

  group('the outbound door — Call in the long-press sheet', () {
    Widget harness() {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(me),
          channelsProvider.overrideWith((ref) async => const [generalChannel]),
          dmsProvider.overrideWith((ref) async => const <Channel>[]),
        ],
      );
      addTearDown(container.dispose);
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, _) => Scaffold(
                  body: Consumer(
                    builder: (context, ref, _) => TextButton(
                      onPressed: () =>
                          showMessageActions(context, ref, message),
                      child: const Text('open-actions'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // THE CALLER'S PRE-CONNECT DISCLOSURE (Decision 9d; Carnot, cage-match
    // round 2). The in-call chip is painted on the call screen's first frame,
    // which for the CALLER is concurrent with connect rather than before it —
    // `CallScreen.initState` fires `unawaited(connect())` and returns before
    // anything paints. The callee has the ring banner; the caller has this.
    //
    // So this is the assertion that the caller is warned while they can still
    // not-call. It goes red if the subtitle is ever dropped for tidiness.
    testWidgets('the Call entry discloses before the caller can tap it', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-actions'));
      await tester.pumpAndSettle();

      expect(find.text('Call Robin'), findsOneWidget);
      expect(
        find.textContaining('not end to end encrypted'),
        findsOneWidget,
        reason:
            'the caller reaches the call screen with connect already in flight, '
            'so THIS is their only surface that precedes it',
      );
    });

    testWidgets('Call sits alongside Report and Block', (tester) async {
      // Report and Block are an App Store 1.2 obligation: adding Call must not
      // crowd them out of the sheet.
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-actions'));
      await tester.pumpAndSettle();

      expect(find.text('Call Robin'), findsOneWidget);
      expect(find.text('Report message'), findsOneWidget);
      expect(find.text('Block Robin'), findsOneWidget);
    });
  });

  group('the deep-link door — the /call route', () {
    List<String> routePaths() {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return [
        for (final r in container.read(routerProvider).configuration.routes)
          if (r is GoRoute) r.path,
      ];
    }

    test(
      'a /call with no call of ours is redirected home — it joins nothing',
      () {
        // Design 22 v2.5: a joined room is a call, and a call has a CallRef. A
        // bare or crafted deep link names none, so it never reaches CallScreen:
        // no room is joined that no event could address (Tesla, design 22
        // temper round 1).
        expect(callRouteRedirect(null), '/');
        expect(callRouteRedirect('junk'), '/');
        expect(callRouteRedirect((call: kTestCall, outgoing: false)), isNull);
      },
    );

    test('/call is registered', () {
      expect(routePaths(), contains('/call/:channelId'));
    });
  });
}

/// A ring that is already ringing at first build. Mirrors the fake in `ring_overlay_test.dart`.
class _FakeRing extends RingController {
  _FakeRing(this._initial);

  final CallInvite? _initial;

  @override
  CallInvite? build() => _initial;

  @override
  void stopRinging(RingStopCause cause) => state = null;
}
