import 'package:aiko_chat_app/app/feature_flags.dart';
import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/call/presentation/ring_overlay.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/app/router.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:aiko_chat_app/features/moderation/presentation/message_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/test_helpers.dart';

/// Calling is gated OFF for the store build (`app/feature_flags.dart`): it works,
/// but it does not yet disclose that media crosses the island's SFU in the clear,
/// and a ring cannot reach a closed app. This file proves the SHIPPED shape —
/// that every door into calling is actually shut.
///
/// Every case here is paired with its opposite. An assertion that a thing is
/// ABSENT is worth nothing on its own: a typo'd finder, a harness that never
/// rendered, a widget renamed last week all produce `findsNothing` just as
/// convincingly as a working gate. The `enabled` arm is what proves the probe
/// could have seen the thing it reports missing.
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
    inviteId: 'inv-1',
    serverMsgId: 'srv-1',
    channelId: 'dm:me:robin',
    from: const MessageSender(
      userId: 'robin-key',
      kind: SenderKind.human,
      label: 'Robin',
    ),
    startedAt: DateTime.utc(2026, 9, 1, 13),
  );

  group('the shipped default', () {
    test('calling is OFF unless a build explicitly defines ENABLE_CALLING', () {
      // The tripwire for the whole file. Flip this const (or slip
      // ENABLE_CALLING=true into a release dart-define) and calling ships with
      // neither the disclosure nor a ring that reaches a closed app — so the
      // default is asserted directly, not merely relied upon by the cases below.
      expect(kCallingEnabled, isFalse);
    });
  });

  group('the inbound door — the ring banner', () {
    Widget harness({required bool enabled}) => ProviderScope(
      overrides: [
        callingEnabledProvider.overrideWithValue(enabled),
        incomingRingProvider.overrideWith(() => _FakeRing(invite)),
      ],
      child: const MaterialApp(
        home: RingOverlay(child: Scaffold(body: Text('home'))),
      ),
    );

    testWidgets('gated OFF: a live invitation raises no banner', (
      tester,
    ) async {
      await tester.pumpWidget(harness(enabled: false));
      await tester.pumpAndSettle();

      expect(find.text('Incoming call'), findsNothing);
      expect(find.text('Answer'), findsNothing);
      expect(find.text('Robin'), findsNothing);
      // The route underneath is untouched — the gate removes the ring, not the app.
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('gated ON: the same invitation DOES raise the banner', (
      tester,
    ) async {
      // The must-fail arm. Without this, the case above would pass just as
      // happily against an overlay that never rings for anyone.
      await tester.pumpWidget(harness(enabled: true));
      await tester.pumpAndSettle();

      expect(find.text('Incoming call'), findsOneWidget);
      expect(find.text('Answer'), findsOneWidget);
      expect(find.text('Robin'), findsOneWidget);
    });
  });

  group('the outbound door — Call in the long-press sheet', () {
    Widget harness({required bool enabled}) {
      final container = ProviderContainer(
        overrides: [
          callingEnabledProvider.overrideWithValue(enabled),
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

    testWidgets('gated OFF: no Call entry, and the sheet still moderates', (
      tester,
    ) async {
      await tester.pumpWidget(harness(enabled: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-actions'));
      await tester.pumpAndSettle();

      expect(find.text('Call Robin'), findsNothing);
      // The gate must remove ONE entry, not quietly break the sheet — Report and
      // Block are an App Store 1.2 obligation and are not calling's to take with
      // it on the way out.
      expect(find.text('Report message'), findsOneWidget);
      expect(find.text('Block Robin'), findsOneWidget);
    });

    testWidgets('gated ON: the Call entry is there', (tester) async {
      // The must-fail arm: proves `findsNothing` above is the gate talking and
      // not a sheet that never opened or a label that has been renamed.
      await tester.pumpWidget(harness(enabled: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-actions'));
      await tester.pumpAndSettle();

      expect(find.text('Call Robin'), findsOneWidget);
    });
  });

  group('the deep-link door — the /call route', () {
    List<String> pathsWithCallingEnabled(bool enabled) {
      final container = ProviderContainer(
        overrides: [callingEnabledProvider.overrideWithValue(enabled)],
      );
      addTearDown(container.dispose);
      return [
        for (final r in container.read(routerProvider).configuration.routes)
          if (r is GoRoute) r.path,
      ];
    }

    test('gated OFF: /call is not registered at all', () {
      // Not merely unreachable from the UI — UNREGISTERED. A mounted route is a
      // door a crafted `aikochat://call/...` can still open, and it would land
      // on a call screen that has told the user nothing about what it routes
      // their camera through.
      expect(
        pathsWithCallingEnabled(false),
        isNot(contains('/call/:channelId')),
      );
    });

    test('gated ON: /call is registered', () {
      // Must-fail arm: without it, a typo in the path string above would make
      // the gated-OFF assertion pass forever regardless of the gate.
      expect(pathsWithCallingEnabled(true), contains('/call/:channelId'));
    });
  });
}

/// A ring that is already ringing at first build — the state the gate has to
/// suppress. Mirrors the fake in `ring_overlay_test.dart`.
class _FakeRing extends RingController {
  _FakeRing(this._initial);

  final CallInvite? _initial;

  @override
  CallInvite? build() => _initial;

  @override
  void stopRinging() => state = null;
}
