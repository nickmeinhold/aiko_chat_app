// The SENDING side of the hangup, which nothing tested at all until a
// cage-match said so out loud: "the suite never pulls this rope — wiring and
// live tests inject an already-named end; they do not dispose CallScreen."
//
// Every case here is the same shape: the moment the user hangs up, the world may
// not be ready — the invitation may have no server id yet, and the repository
// the screen was holding may already have been replaced. An announcement that
// only exists during that one instant is an announcement you lose.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  ProviderContainer build({ChatRepository? repoOverride}) {
    final c = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith(
          (ref) async => repoOverride ?? repo,
        ),
      ],
    );
    // PIN IT, exactly as main() does. Providers auto-dispose by default in
    // Riverpod 3, so an unpinned read hands back a Ref whose element is
    // immediately torn down — and every later use of it throws into the
    // announcer's own swallow. A test that skipped this would reproduce the
    // disposal bug rather than the behaviour.
    c.listen(_refProbe, (_, _) {});
    return c;
  }

  setUp(() {
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

  CallEndAnnouncer announcer({Duration? ackWait}) => CallEndAnnouncer(
    container.read(_refProbe),
    ackWait: ackWait ?? const Duration(seconds: 2),
  );

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
      final a = announcer(ackWait: const Duration(milliseconds: 300));

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

  test('it resolves the repository at SEND time, not at hangup time', () async {
    // Tesla's finding. The screen used to capture a repository instance in
    // initState and speak only to it in dispose — but it is autoDispose and
    // rebuilds on reconnect, subscription-set change and seedOpenedDm. A long
    // unanswered ring is exactly when a mobile socket has most likely swapped
    // it, and the hangup then collapsed to a debugPrint.
    final inviteId = await sendAndAck();
    final a = announcer();

    // The repository the screen would have captured is now dead and replaced.
    final freshTransport = FakeChatTransport();
    final freshCache = DriftCache(NativeDatabase.memory());
    final fresh = ChatRepository(
      cache: freshCache,
      transport: freshTransport,
      rest: FakeChatRestApi(),
      me: FakeRestApi.defaultUser,
      subscribedChannelIds: const [_channel],
      newTempId: nextTempId,
    );
    fresh.start();
    addTearDown(() async {
      await fresh.dispose();
      await freshTransport.dispose();
      await freshCache.close();
    });
    final id2 = (await fresh.sendMessage(_channel, kCallInviteBody))!;
    freshTransport.emitAck(id2, '01M0GS7FDWBVQ31950B1PTV2DX');
    await pumpEventQueue();

    final container2 = build(repoOverride: fresh);
    addTearDown(container2.dispose);
    final a2 = CallEndAnnouncer(
      container2.read(_refProbe),
      ackWait: const Duration(seconds: 2),
    );
    a2.announce(channelId: _channel, inviteId: id2);
    await Future.wait(a2.settling);

    expect(
      freshTransport.sent.where((m) => m.body == kCallEndBody),
      hasLength(1),
      reason: 'the announcement went to the LIVE repository, not a dead one',
    );
    expect(a.settling, isEmpty);
    expect(inviteId, isNotEmpty);
  });
}

/// Hands a test the container's own [Ref], which is what the real provider
/// receives. Using the genuine article rather than a hand-made double keeps the
/// announcer's provider reads on the same path they take in production.
final _refProbe = Provider<Ref>((ref) => ref);
