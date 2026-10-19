import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/call/application/desktop_ring.dart';
import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/call/domain/media_confidentiality.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'call_fixtures.dart';

/// The Mac's ring follows the ring state exactly: it starts once per
/// invitation, carries the disclosure, and stops the moment nothing rings.
/// The native side is a fake that records what it was told, because what
/// matters here is the conversation, not the sound.
void main() {
  CallInvite invite(String id, {String? label = 'Robin'}) => CallInvite(
    call: kTestCall,
    inviteId: id,
    islandMsgId: 'srv-$id',
    channelId: 'dm:aaa:bbb',
    from: MessageSender(
      userId: 'robin-key',
      kind: SenderKind.human,
      label: label,
    ),
    startedAt: DateTime.utc(2026, 10, 19, 8),
  );

  late _Recorder native;
  late ProviderContainer c;
  final me = NotifierProvider<_Me, AppUser?>(_Me.new);

  ProviderContainer build({CallInvite? initial, AppUser? user}) {
    native = _Recorder();
    c = ProviderContainer(
      overrides: [
        desktopRingProvider.overrideWithValue(native),
        currentUserProvider.overrideWith((ref) => ref.watch(me)),
        incomingRingProvider.overrideWith(() => _FakeRing(initial)),
        mediaRoutingProvider.overrideWithValue(
          const MediaRouting(
            confidentiality: MediaConfidentiality.notEndToEndEncrypted,
            islandHost: 'chat.enspyr.co',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(me.notifier).set(user);
    // LISTENED, not read, as RingOverlay watches it in the app: Riverpod 3
    // pauses a provider nothing listens to, and a paused provider's own
    // listeners stop hearing changes.
    c.listen(desktopRingDriverProvider, (_, _) {});
    return c;
  }

  // RING calls only: what the native side was told about calls, without the
  // permission ask a signed-in mount also makes.
  List<String> rings() => native.calls.where((s) => s != 'prepare').toList();

  _FakeRing ring() => c.read(incomingRingProvider.notifier) as _FakeRing;

  test('a ring starts the native ring, naming the caller and disclosing', () {
    build();
    ring().ring(invite('a'));
    expect(native.calls, [
      'start:Robin is calling|This call is not end to end encrypted. '
          'chat.enspyr.co can hear and see it.',
    ]);
  });

  test('the end of a ring stops it', () {
    build();
    ring().ring(invite('a'));
    ring().clear();
    expect(native.calls.last, 'stop');
  });

  // The sender's name resolving to their current handle mid-ring: the same
  // invitation with a different label. There is no guard for this in the
  // driver — CallInvite's equality is its inviteId, so the provider never
  // notifies. This test is the contract that makes the missing guard safe: if
  // that equality ever widens, the sound restarts and this fails.
  test('the same invitation re-published does not restart the sound', () {
    build();
    ring().ring(invite('a', label: 'robin'));
    ring().ring(invite('a', label: 'Robin Langer'));
    expect(native.calls.where((s) => s.startsWith('start')), hasLength(1));
  });

  test('a newer caller replaces the ring without a stop in between', () {
    build();
    ring().ring(invite('a'));
    ring().ring(invite('b', label: 'Sam'));
    expect(native.calls, [
      startsWith('start:Robin is calling'),
      startsWith('start:Sam is calling'),
    ]);
  });

  test('a ring already live when the driver mounts is heard', () {
    build(initial: invite('a'));
    expect(native.calls.single, startsWith('start:Robin is calling'));
  });

  test('a caller with no name rings as a person, never a blank', () {
    build();
    ring().ring(invite('a', label: ''));
    expect(native.calls.single, startsWith('start:Someone is calling'));
  });

  test('nothing ringing at mount sends nothing', () {
    build();
    expect(native.calls, isEmpty);
  });

  test('tearing the app down silences a live ring', () {
    build(initial: invite('a'));
    c.dispose();
    expect(native.calls.last, 'stop');
  });

  test('signed in, the permission is asked once, before anything rings', () {
    build(user: _user('u1'));
    expect(native.calls, ['prepare']);
  });

  test('signed out, nothing is asked', () {
    build();
    expect(native.calls, isEmpty);
  });

  // `currentUserProvider` is DERIVED, so Riverpod recomputes it on the next
  // flush, not synchronously: two changes in one microtask coalesce and the
  // listener never sees the middle one. A real sign-out never lands in the
  // same microtask as the next sign-in, so each step yields first.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a rebuild for the same identity does not ask again', () async {
    build(user: _user('u1'));
    c.read(me.notifier).set(_user('u1', name: 'Renamed'));
    await settle();
    expect(native.calls, ['prepare']);
  });

  test('a different identity signing in asks again', () async {
    build(user: _user('u1'));
    c.read(me.notifier).set(null);
    await settle();
    c.read(me.notifier).set(_user('u2'));
    await settle();
    expect(native.calls, ['prepare', 'prepare']);
  });

  test('a ring while signed in is still just a ring', () {
    build(user: _user('u1'));
    ring().ring(invite('a'));
    expect(rings().single, startsWith('start:Robin is calling'));
  });

  test('a native failure never takes the ring state down with it', () async {
    native = _Recorder(fail: true);
    c = ProviderContainer(
      overrides: [
        desktopRingProvider.overrideWithValue(native),
        currentUserProvider.overrideWithValue(null),
        incomingRingProvider.overrideWith(() => _FakeRing(null)),
        mediaRoutingProvider.overrideWithValue(
          const MediaRouting(
            confidentiality: MediaConfidentiality.notEndToEndEncrypted,
            islandHost: 'chat.enspyr.co',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    // LISTENED, not read, as RingOverlay watches it in the app: Riverpod 3
    // pauses a provider nothing listens to, and a paused provider's own
    // listeners stop hearing changes.
    c.listen(desktopRingDriverProvider, (_, _) {});
    ring().ring(invite('a'));
    await Future<void>.delayed(Duration.zero);
    expect(c.read(incomingRingProvider)?.inviteId, 'a');
  });
}

AppUser _user(String id, {String name = 'Nick'}) => AppUser(
  userId: id,
  username: 'nick',
  displayName: name,
  aikoUsername: 'nick',
);

class _Me extends Notifier<AppUser?> {
  @override
  AppUser? build() => null;
  void set(AppUser? user) => state = user;
}

class _Recorder implements DesktopRing {
  _Recorder({this.fail = false});
  final bool fail;
  final calls = <String>[];

  @override
  Future<void> prepare() async {
    calls.add('prepare');
    if (fail) throw StateError('no channel');
  }

  @override
  Future<void> start({required String title, required String body}) async {
    calls.add('start:$title|$body');
    if (fail) throw StateError('no channel');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (fail) throw StateError('no channel');
  }
}

class _FakeRing extends RingController {
  _FakeRing([this._initial]);
  final CallInvite? _initial;

  @override
  CallInvite? build() => _initial;

  void ring(CallInvite invite) => state = invite;
  void clear() => state = null;
}
