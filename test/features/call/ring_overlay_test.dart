import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/call/domain/media_confidentiality.dart';
import 'package:aiko_chat_app/features/call/presentation/call_screen.dart'
    show resetCallLaunchGuard;
import 'package:aiko_chat_app/features/call/presentation/ring_overlay.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aiko_chat_app/app/feature_flags.dart';
import 'package:aiko_chat_app/app/router.dart';
import 'package:go_router/go_router.dart';

/// The ring OVERLAY (#2808) — mounted in `MaterialApp.router`'s `builder`, which
/// is a genuinely load-bearing placement choice: the banner must sit ABOVE the
/// Navigator (so a call reaches any route) while still being INSIDE go_router's
/// scope (so `context.push` resolves). Those two pull in opposite directions and
/// nothing else in the suite exercises it.
void main() {
  setUp(resetCallLaunchGuard);

  final invite = CallInvite(
    inviteId: 'inv-1',
    islandMsgId: 'srv-1',
    channelId: 'dm:aaa:bbb',
    from: const MessageSender(
      userId: 'robin-key',
      kind: SenderKind.human,
      label: 'Robin',
    ),
    startedAt: DateTime.utc(2026, 8, 15, 13),
  );

  Widget harness({CallInvite? initial}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/call/:channelId',
          builder: (_, s) =>
              Scaffold(body: Text('CALL ${s.pathParameters['channelId']}')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        // Calling ships gated OFF (`app/feature_flags.dart`); this file is about
        // the overlay's PLACEMENT, so it opts the capability on. The gated-off
        // shape is proven in `call_gating_test.dart`.
        callingEnabledProvider.overrideWithValue(true),
        incomingRingProvider.overrideWith(() => _FakeRing(initial)),
        // The overlay reaches the router through the PROVIDER (it lives above
        // the Router, outside InheritedGoRouter — cage-match #139), so the test
        // must hand it the same router the harness mounts. Overriding this is
        // what makes the test exercise the real lookup path rather than a
        // parallel one.
        routerProvider.overrideWithValue(router),
        // The banner now carries the media disclosure, which would otherwise
        // reach for the real island config. Pinned here so this file keeps
        // testing PLACEMENT; the disclosure's own behaviour, including the
        // branch that does not ship, lives in media_confidentiality_test.dart.
        mediaRoutingProvider.overrideWithValue(
          const MediaRouting(
            confidentiality: MediaConfidentiality.notEndToEndEncrypted,
            islandHost: 'chat.imagineering.cc',
          ),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) =>
            RingOverlay(child: child ?? const SizedBox.shrink()),
      ),
    );
  }

  testWidgets('nothing ringing → no banner, no layout cost', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.text('Answer'), findsNothing);
    expect(find.text('Ignore'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  // Decision 9d bites hardest right here: this is the last moment the callee
  // can act on it. An indicator that only appeared inside the call would land
  // after they had already answered.
  testWidgets('the ring discloses that media is not encrypted, before Answer', (
    tester,
  ) async {
    await tester.pumpWidget(harness(initial: invite));
    await tester.pumpAndSettle();
    expect(find.text('Not encrypted'), findsOneWidget);
    expect(find.text('Answer'), findsOneWidget);

    // PRESENT is not VISIBLE. This repo has a scar exactly here: the composer's
    // lit rule laid out 431px wide and ZERO px tall and had never once been
    // seen, in either theme, since it shipped — while every test that mentioned
    // it passed. A disclosure nobody can see is the same failure with worse
    // consequences, so the geometry is asserted rather than assumed.
    final rect = tester.getRect(find.text('Not encrypted'));
    expect(rect.width, greaterThan(40));
    expect(rect.height, greaterThan(10));
    // On screen, in the banner, at the moment of the decision. Deliberately NOT
    // asserting it sits above the Answer button: it lives in the caller's
    // column, which grows downward, while Answer is vertically centred in the
    // row — so the chip's top is BELOW the button's bottom by a few pixels and
    // the render is perfectly legible anyway. "Before Answer" is reading order,
    // not a y-coordinate, and encoding it as one was a false precision that
    // failed on correct code.
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThan(tester.view.physicalSize.height));
  });

  testWidgets('a ring shows the caller, Answer and Ignore over the route', (
    tester,
  ) async {
    await tester.pumpWidget(harness(initial: invite));
    await tester.pumpAndSettle();
    expect(find.text('Robin'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(find.text('Answer'), findsOneWidget);
    // "Ignore", never "Decline" — the caller is not told, so the honest word
    // does the work instead of a disclaimer.
    expect(find.text('Ignore'), findsOneWidget);
    expect(find.text('Decline'), findsNothing);
    // Still layered OVER the route, not replacing it.
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('Answer navigates to the call route for the invited channel', (
    tester,
  ) async {
    // THE test this file exists for. The overlay lives in MaterialApp.router's
    // `builder`; if that placement sits outside go_router's InheritedGoRouter
    // scope, `context.push` throws the moment anyone taps Answer — and no other
    // test in the suite would catch it.
    await tester.pumpWidget(harness(initial: invite));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Answer'));
    await tester.pumpAndSettle();

    expect(find.text('CALL dm:aaa:bbb'), findsOneWidget);
  });

  testWidgets('Ignore clears the banner and does NOT navigate', (tester) async {
    await tester.pumpWidget(harness(initial: invite));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ignore'));
    await tester.pumpAndSettle();

    expect(find.text('Answer'), findsNothing);
    expect(find.textContaining('CALL'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets(
    'an unnamed caller still renders as a person, never a blank row',
    (tester) async {
      final anon = CallInvite(
        inviteId: 'inv-2',
        islandMsgId: 'srv-2',
        channelId: 'dm:aaa:bbb',
        from: const MessageSender(userId: 'k', kind: SenderKind.human),
        startedAt: DateTime.utc(2026, 8, 15, 13),
      );
      await tester.pumpWidget(harness(initial: anon));
      await tester.pumpAndSettle();
      expect(find.text('Someone'), findsOneWidget);
    },
  );
}

class _FakeRing extends RingController {
  _FakeRing([this._initial]);
  final CallInvite? _initial;

  @override
  CallInvite? build() => _initial;

  @override
  void stopRinging() => state = null;
}
