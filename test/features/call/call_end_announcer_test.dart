// The SENDING side of the hangup, which nothing tested at all until a
// cage-match said so out loud: "the suite never pulls this rope — wiring and
// live tests inject an already-named end; they do not dispose CallScreen."
//
// Every case here is the same shape: the moment the user hangs up, the world may
// not be ready — the invitation may have no server id yet, and the repository
// the screen was holding may already have been replaced. An announcement that
// only exists during that one instant is an announcement you lose.
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/call/application/call_end_announcer.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

const _channel = 'CH1';

/// The signed-in user, as a knob a test can turn. A plain variable read by the
/// override, invalidated to publish a change — Riverpod 3 has no StateProvider.
AppUser? knobUser = FakeRestApi.defaultUser;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => initializeTestEnvironment());

  late DriftCache cache;
  late FakeChatTransport transport;
  late ChatRepository repo;
  late ProviderContainer container;

  /// UNIQUE per call, because `messages.client_temp_id` is unique and this test
  /// sends TWO messages through one repository (the invitation and its end). A
  /// constant id — the usual fixture shortcut — makes the second insert fail the
  /// constraint, and the announcer's own swallow turns that into "no end sent",
  /// which reads exactly like the bug under test.
  var seq = 0;
  String nextTempId() => 'TMP${seq++}';

  /// Builds a live repo/container pair. [repoOverride] lets a test swap the
  /// repository the announcer will resolve, which is how the mortal-instance
  /// case is reproduced.
  var ackWait = const Duration(seconds: 2);

  ProviderContainer build({ChatRepository? repoOverride}) {
    final c = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith(
          (ref) async => repoOverride ?? repo,
        ),
        // The announcer now snapshots WHO we are — the account AND the island —
        // so its provider graph reaches currentUser and config. Widening that
        // graph is exactly what makes an unoverridden fixture throw here.
        sharedPreferencesProvider.overrideWithValue(testPrefs),
        // Via a knob rather than a fixed value: the identity test has to CHANGE
        // the signed-in user mid-flight. Disposing the container instead would
        // make that test pass for the wrong reason — a disposed ref throws into
        // the announcer's swallow, which looks identical to the guard working.
        currentUserProvider.overrideWith((ref) => knobUser),
        callEndAckWaitProvider.overrideWithValue(ackWait),
      ],
    );
    // PIN IT, exactly as main() does. Providers auto-dispose by default in
    // Riverpod 3, so an unpinned read hands back a Ref whose element is
    // immediately torn down — and every later use of it throws into the
    // announcer's own swallow. A test that skipped this would reproduce the
    // disposal bug rather than the behaviour.
    c.listen(callEndAnnouncerProvider, (_, _) {});
    return c;
  }

  setUp(() {
    knobUser = FakeRestApi.defaultUser;
    ackWait = const Duration(seconds: 2);
    installSecureStorageMock();
    cache = DriftCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: FakeChatRestApi(),
      me: FakeRestApi.defaultUser,
      subscribedChannelIds: const [_channel],
      newTempId: nextTempId,
    );
    repo.start();
    container = build();
  });

  tearDown(() async {
    container.dispose();
    await repo.dispose();
    await transport.dispose();
    await cache.close();
  });

  /// Send an invitation and ACK it, so it has a server ULID like a real one.
  Future<String> sendAndAck({bool ack = true}) async {
    final id = (await repo.sendMessage(_channel, kCallInviteBody))!;
    if (ack) {
      transport.emitAck(id, '01M0GS7FDWBVQ31950B1PTV2DW');
      await pumpEventQueue();
    }
    return id;
  }

  /// Built through the REAL provider, so the announcer holds the same kind of
  /// Ref it holds in production.
  CallEndAnnouncer announcer() => container.read(callEndAnnouncerProvider);

  test('an acked invitation is ended by its SERVER id', () async {
    final inviteId = await sendAndAck();
    final a = announcer();

    a.announce(channelId: _channel, inviteId: inviteId);
    await Future.wait(a.settling);

    final ends = transport.sent.where((m) => m.body == kCallEndBody).toList();
    expect(ends, hasLength(1));
    expect(
      ends.single.replyToId,
      '01M0GS7FDWBVQ31950B1PTV2DW',
      reason:
          'the wire binding is the SERVER id — a client_msg_id gets the whole '
          'frame refused with no_reply_target',
    );
  });

  test('a hangup BEFORE the ack still lands, once the ack arrives', () async {
    // The finding Carnot and Tesla reached independently, and the reason it
    // matters: this is the fastest, most human path — place the call, realise
    // it is a misdial, back straight out. Exactly when you most want the peer's
    // phone to stop. The first version gave up here and printed a line.
    final inviteId = await sendAndAck(ack: false);
    final a = announcer();

    a.announce(channelId: _channel, inviteId: inviteId);
    await pumpEventQueue();
    expect(
      transport.sent.where((m) => m.body == kCallEndBody),
      isEmpty,
      reason: 'precondition: it cannot have sent yet — there is no id to name',
    );

    transport.emitAck(inviteId, '01M0GS7FDWBVQ31950B1PTV2DW');
    await Future.wait(a.settling);

    expect(
      transport.sent.where((m) => m.body == kCallEndBody).single.replyToId,
      '01M0GS7FDWBVQ31950B1PTV2DW',
    );
  });

  test(
    'an invitation never acked announces NOTHING — there is no ring to stop',
    () async {
      final inviteId = await sendAndAck(ack: false);
      ackWait = const Duration(milliseconds: 300);
      container.dispose();
      container = build();
      final a = announcer();

      a.announce(channelId: _channel, inviteId: inviteId);
      await Future.wait(a.settling);

      expect(
        transport.sent.where((m) => m.body == kCallEndBody),
        isEmpty,
        reason:
            'an unacked invitation almost certainly never reached the peer, and a '
            'reply_to the island cannot resolve would sink the whole message',
      );
    },
  );

  test('the invitation is minted on repo A and the hangup still lands after A '
      'is REPLACED', () async {
    // Rewritten after a cage-match said the first version proved nothing: it
    // minted and announced on the SAME fresh repository, so of course the
    // current one flowed. The actual bug is a mortal capture — invitation minted
    // on repo A, lookup and send happening after A has been swapped out — and
    // that frequency was never placed on the coil.
    final inviteId = await sendAndAck(); // ...on repo A (`repo`)

    // A is replaced, as a reconnect / subscription-set change / seedOpenedDm
    // does. Its cache still holds the invitation's ULID, so a correct
    // implementation must read through whatever is CURRENT, not what it held.
    final liveTransport = FakeChatTransport();
    final liveRepo = ChatRepository(
      cache: cache, // the same store A wrote the invitation into
      transport: liveTransport,
      rest: FakeChatRestApi(),
      me: FakeRestApi.defaultUser,
      subscribedChannelIds: const [_channel],
      newTempId: nextTempId,
    );
    liveRepo.start();
    addTearDown(() async {
      await liveRepo.dispose();
      await liveTransport.dispose();
    });

    final c2 = build(repoOverride: liveRepo);
    addTearDown(c2.dispose);
    final a = c2.read(callEndAnnouncerProvider);

    await repo.dispose(); // A is now dead — a captured reference would be inert
    a.announce(channelId: _channel, inviteId: inviteId);
    await Future.wait(a.settling);

    expect(
      liveTransport.sent.where((m) => m.body == kCallEndBody).single.replyToId,
      '01M0GS7FDWBVQ31950B1PTV2DW',
      reason:
          'the hangup went out through the LIVE repository, naming an '
          'invitation minted by one that has since been disposed',
    );
  });

  // NO TEST FOR THE IDENTITY GUARD, deliberately — this is the honest note
  // rather than a green one. The guard is real and kept: an announcement must
  // never be signed on behalf of the next session. But it cannot be SHOWN to
  // fail here, because invalidating the provider whose value it reads disposes
  // the announcer's own Ref first — so the announcement dies with "Cannot use
  // the Ref after it has been disposed" whether the guard exists or not. Same
  // outcome, different mechanism, and a test that cannot tell them apart is
  // decorative. Two earlier attempts at this test passed for exactly that wrong
  // reason before the third one caught itself.
  //
  // The disposal is itself worth a look — holding a Ref across an invalidation
  // is fragile in Riverpod 3 — and is FILED rather than papered over here.

  /// Cleans up the settling list so a pinned, app-lifetime announcer does not
  /// retain every hangup's closure graph forever.
  test('a completed announcement is not retained', () async {
    final inviteId = await sendAndAck();
    final a = announcer();

    a.announce(channelId: _channel, inviteId: inviteId);
    await Future.wait(a.settling);
    await pumpEventQueue();

    expect(a.settling, isEmpty);
  });
}
