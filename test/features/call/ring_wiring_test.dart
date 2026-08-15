import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';

/// The ring WIRING (#2808) — the seam the pure `admitRing` tests cannot reach:
/// does an invitation actually travel transport → repository → cross-channel
/// announcement → ring state?
///
/// This is the "code-correct is not works" half. `call_invite_test.dart` proves
/// the decision; this proves the plumbing that carries a message to it.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const meId = 'me-key';
  const robinId = 'robin-key';
  const dmId = 'dm:aaa:bbb';
  const me = AppUser(
    userId: meId,
    username: 'nick',
    displayName: 'Nick',
    aikoUsername: 'nick',
  );

  late DriftCache cache;
  late FakeChatTransport transport;
  late ChatRepository repo;
  late ProviderContainer container;

  Message inbound({
    String from = robinId,
    String body = kCallInviteBody,
    Duration age = const Duration(seconds: 1),
  }) =>
      Message(
        clientTempId: 'M1',
        id: 'M1',
        channelId: dmId,
        sender: MessageSender(
            userId: from, kind: SenderKind.human, label: 'Robin'),
        body: body,
        createdAt: DateTime.now().toUtc().subtract(age),
        deliveryState: DeliveryState.sent,
      );

  setUp(() {
    cache = DriftCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: FakeChatRestApi(),
      me: me,
      subscribedChannelIds: const [dmId],
      newTempId: () => 'tmp',
    );
    repo.start();
    container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWith((ref) async => repo),
      currentUserProvider.overrideWithValue(me),
      blockedUserIdsProvider.overrideWithValue(const <String>{}),
      mutedChannelIdsProvider.overrideWithValue(const <String>{}),
      mutedUserIdsProvider.overrideWithValue(const <String>{}),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await repo.dispose();
    await transport.dispose();
    await cache.close();
  });

  /// Let the transport listener, the repo's inbound FIFO, the drift write and
  /// the announcement all drain.
  Future<void> pump() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('a fresh invite from a peer rings this device', () async {
    // Subscribe so the controller builds and wires its listener BEFORE the
    // message arrives — a ring that only works if someone was already watching
    // is not a ring.
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(inbound());
    await pump();

    final ring = container.read(incomingRingProvider);
    expect(ring, isNotNull, reason: 'the invite should have rung');
    expect(ring!.channelId, dmId);
    expect(ring.from.userId, robinId);
  });

  test('an ordinary message does not ring', () async {
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(inbound(body: 'hey are you up'));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('my own invite echoing back does not ring me', () async {
    // The caller's own send returns down this same inbound path.
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(inbound(from: meId));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('a stale invite (history replay) does not ring', () async {
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(
        inbound(age: kCallInviteFreshness + const Duration(seconds: 5)));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('stopRinging clears it', () async {
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(inbound());
    await pump();
    expect(container.read(incomingRingProvider), isNotNull);

    container.read(incomingRingProvider.notifier).stopRinging();
    expect(container.read(incomingRingProvider), isNull);
  });
}
