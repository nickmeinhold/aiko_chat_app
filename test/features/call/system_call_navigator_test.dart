// Answering a CallKit ring JOINS THE ROOM (claude-tasks#4420).
//
// Until this existed the handset rang full-screen from a dead process, the user
// swiped, and `CXAnswerCallAction` fulfilled into nothing — a doorbell on an
// empty house. Every test here is a row of that gap closing, and the two that
// matter most are the ones nothing else in the suite can reach:
//
//  * the answer that arrives BEFORE the session does (a VoIP push relaunches a
//    terminated app; the user can swipe while Dart is still restoring), and
//  * the hangup that arrives from the SYSTEM UI, which on a locked handset is
//    the only control the user has.
import 'dart:async';

import 'package:aiko_chat_app/app/feature_flags.dart';
import 'package:aiko_chat_app/app/router.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/application/system_call_providers.dart';
import 'package:aiko_chat_app/features/call/data/system_call_bridge.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/call/domain/system_call_action.dart';
import 'package:aiko_chat_app/features/call/presentation/call_screen.dart'
    show resetCallLaunchGuard;
import 'package:aiko_chat_app/features/call/presentation/system_call_navigator.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUp(resetCallLaunchGuard);

  const channel = 'dm:aaa:bbb';
  const me = AppUser(
    userId: 'me-key',
    username: 'nick',
    displayName: 'Nick',
    aikoUsername: 'nick@island',
  );

  late _FakeBridge bridge;
  late _TestAuth auth;
  late GoRouter router;

  Widget harness({bool signedIn = true, bool callingEnabled = true}) {
    bridge = _FakeBridge();
    auth = _TestAuth(signedIn ? me : null);
    router = GoRouter(
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
        callingEnabledProvider.overrideWithValue(callingEnabled),
        // The bridge is the seam under test; the real one needs CallKit.
        systemCallBridgeProvider.overrideWithValue(
          callingEnabled ? bridge : null,
        ),
        authControllerProvider.overrideWith(() => auth),
        // The navigator lives ABOVE the Router (it wraps `MaterialApp.router`'s
        // child), so it reaches the router through the provider — the same
        // placement constraint that killed the ring banner's primary button
        // until a test pressed it (cage-match #139).
        routerProvider.overrideWithValue(router),
        incomingRingProvider.overrideWith(_FakeRing.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) =>
            SystemCallNavigator(child: child ?? const SizedBox.shrink()),
      ),
    );
  }

  testWidgets('answering joins the room', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    bridge.emit(SystemCallActionKind.answered, channel);
    await tester.pumpAndSettle();

    expect(
      find.text('CALL $channel'),
      findsOneWidget,
      reason:
          'the whole point of #4420: a swipe on the lock screen has to '
          'end up in the room, not in a fulfilled CXAnswerCallAction',
    );
  });

  testWidgets('an answer that arrives BEFORE the session waits for it', (
    tester,
  ) async {
    // The cold-start case, and the normal one rather than the edge: a VoIP push
    // relaunches a terminated app, the user swipes immediately, and the session
    // restore is still a round trip away.
    await tester.pumpWidget(harness(signedIn: false));
    await tester.pumpAndSettle();

    bridge.emit(SystemCallActionKind.answered, channel);
    await tester.pumpAndSettle();
    expect(
      find.text('CALL $channel'),
      findsNothing,
      reason: 'there is no credential yet to mint a room token against',
    );
    expect(
      bridge.ended,
      isEmpty,
      reason: 'and it must not be thrown away either — the user answered',
    );

    auth.signIn(me);
    await tester.pumpAndSettle();
    expect(find.text('CALL $channel'), findsOneWidget);
  });

  testWidgets('hanging up in the SYSTEM UI leaves the room', (tester) async {
    // On a locked handset the system call UI is the only control the user has.
    // Without this the red button stops the CallKit call and the app stays in
    // the room — camera live, nobody looking.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    bridge.emit(SystemCallActionKind.answered, channel);
    await tester.pumpAndSettle();
    expect(find.text('CALL $channel'), findsOneWidget);

    bridge.emit(SystemCallActionKind.ended, channel);
    await tester.pumpAndSettle();
    expect(find.text('CALL $channel'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('an end for a DIFFERENT channel leaves the call alone', (
    tester,
  ) async {
    // The negative control for the test above. A teardown keyed on "a call
    // ended" rather than "THIS call ended" would pass that one and hang up a
    // live conversation here.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    bridge.emit(SystemCallActionKind.answered, channel);
    await tester.pumpAndSettle();

    bridge.emit(SystemCallActionKind.ended, 'dm:ccc:ddd');
    await tester.pumpAndSettle();
    expect(find.text('CALL $channel'), findsOneWidget);
  });

  testWidgets('answered then hung up before the session → never joins', (
    tester,
  ) async {
    // Answer and hangup can both land while Dart is still booting, and they
    // arrive in order because the native side HOLDS them in a list rather than
    // keeping only the newest. Joining here would open a call the user has
    // already left.
    await tester.pumpWidget(harness(signedIn: false));
    await tester.pumpAndSettle();

    bridge.emit(SystemCallActionKind.answered, channel);
    bridge.emit(SystemCallActionKind.ended, channel);
    await tester.pumpAndSettle();

    auth.signIn(me);
    await tester.pumpAndSettle();
    expect(find.text('CALL $channel'), findsNothing);
  });

  testWidgets('answering a second call while one is live ENDS it, silently', (
    tester,
  ) async {
    // `maximumCallsPerCallGroup = 1` and this app models one call. The in-app
    // banner refuses with a snackbar; here the user is on a lock screen with
    // nobody to tell, so the honest render is the system call ending rather
    // than a connected call that goes nowhere.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    bridge.emit(SystemCallActionKind.answered, channel);
    await tester.pumpAndSettle();
    expect(find.text('CALL $channel'), findsOneWidget);

    bridge.emit(SystemCallActionKind.answered, 'dm:ccc:ddd');
    await tester.pumpAndSettle();

    expect(find.text('CALL $channel'), findsOneWidget);
    expect(bridge.ended, ['dm:ccc:ddd']);
  });

  testWidgets('answering silences the in-app ring for the same call', (
    tester,
  ) async {
    // A foregrounded app gets BOTH: the island wakes the handset over APNs and
    // the websocket delivers the invitation. The banner is mounted above the
    // Navigator, so leaving it ringing paints it over the call it just opened.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.text('home')),
    );
    expect(container.read(incomingRingProvider), isNotNull);

    bridge.emit(SystemCallActionKind.answered, channel);
    await tester.pumpAndSettle();
    expect(container.read(incomingRingProvider), isNull);
  });

  testWidgets('calling gated off → no bridge at all', (tester) async {
    // The one-door law. A build that cannot open `/call/:id` must not be
    // answerable INTO it — and with the VoIP token now behind the same gate, it
    // cannot be rung either.
    await tester.pumpWidget(harness(callingEnabled: false));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.text('home')),
    );
    expect(container.read(systemCallBridgeProvider), isNull);
  });
}

/// A stand-in for CallKit. The real one is an `EventChannel` fed by
/// `SystemCallChannel` in `ios/Runner/AppDelegate.swift`; the names on both
/// sides of that channel are pinned by `system_call_channel_contract_test.dart`,
/// because a fake cannot catch a rename it shares.
class _FakeBridge implements SystemCallBridge {
  final _controller = StreamController<SystemCallAction>.broadcast();
  final List<String> ended = [];

  void emit(SystemCallActionKind kind, String channelId) =>
      _controller.add(SystemCallAction(kind: kind, channelId: channelId));

  @override
  Stream<SystemCallAction> get actions => _controller.stream;

  @override
  Future<void> end(String channelId) async => ended.add(channelId);
}

class _TestAuth extends AuthController {
  _TestAuth(this._user);
  final AppUser? _user;

  @override
  Future<AppUser?> build() async => _user;

  void signIn(AppUser user) => state = AsyncData(user);
}

/// Ringing from the start, so "answering silences it" has something to silence.
class _FakeRing extends RingController {
  @override
  CallInvite? build() => CallInvite(
    inviteId: 'inv-1',
    islandMsgId: 'srv-1',
    channelId: 'dm:aaa:bbb',
    from: MessageSender(
      userId: 'robin-key',
      kind: SenderKind.human,
      label: 'Robin',
    ),
    startedAt: DateTime.utc(2026, 9, 15, 13),
  );

  @override
  void stopRinging() => state = null;
}
