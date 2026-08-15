import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

/// The ring WIRING (#2808) — the seam the pure `admitRing` tests cannot reach:
/// does an invitation actually travel transport → repository → cross-channel
/// announcement → ring state?
///
/// This is the "code-correct is not works" half. `call_invite_test.dart` proves
/// the decision; this proves the plumbing that carries a message to it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  /// A REAL Ed25519-signed inbound message.
  ///
  /// The repository re-verifies every inbound origin at ingest and overwrites
  /// `originCryptoValid` with its own verdict — so a hand-stubbed signature is
  /// correctly rejected and this fixture MUST sign for real. That makes these
  /// wiring tests a genuine end-to-end crypto path: sign → transport → verify →
  /// persist → announce → admit → ring.
  Future<Message> inbound({
    String from = robinId,
    String body = kCallInviteBody,
    Duration age = const Duration(seconds: 1),
  }) async {
    final key = await SovereignKeyStore().loadOrCreate();
    final signedAt = DateTime.now().toUtc().subtract(age);
    final payload = SignedPayload(
      rawPublicKey: key.rawPublicKey,
      channelId: dmId,
      clientMsgId: 'M1',
      signedAtMs: signedAt.millisecondsSinceEpoch,
      body: body,
      replyTo: null,
    );
    final sig = await sign(key, payload);
    return Message(
      clientTempId: 'M1',
      id: 'M1',
      channelId: dmId,
      sender:
          MessageSender(userId: from, kind: SenderKind.human, label: 'Robin'),
      body: body,
      createdAt: DateTime.now().toUtc(),
      origin: OriginEnvelope.fromSignature(sig, clientMsgId: 'M1'),
      deliveryState: DeliveryState.sent,
    );
  }

  setUp(() {
    installSecureStorageMock(); // the sovereign key store needs a backing store
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

    transport.emitMessage(await inbound());
    await pump();

    final ring = container.read(incomingRingProvider);
    expect(ring, isNotNull, reason: 'the invite should have rung');
    expect(ring!.channelId, dmId);
    expect(ring.from.userId, robinId);
  });

  test('an ordinary message does not ring', () async {
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(await inbound(body: 'hey are you up'));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('my own invite echoing back does not ring me', () async {
    // The caller's own send returns down this same inbound path.
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(await inbound(from: meId));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('a stale invite (history replay) does not ring', () async {
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(
        await inbound(age: kCallInviteFreshness + const Duration(seconds: 5)));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('a replay AFTER Ignore does not ring again', () async {
    // At-least-once delivery: the same signed invitation arrives twice (live +
    // history, reconnect drain). Suppressing only against "currently ringing"
    // was not enough — `stopRinging()` clears that, so a replay landing seconds
    // after Ignore rang all over again (cage-match #139 R2, Carnot).
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    final msg = await inbound();

    transport.emitMessage(msg);
    await pump();
    expect(container.read(incomingRingProvider), isNotNull);

    container.read(incomingRingProvider.notifier).stopRinging();
    expect(container.read(incomingRingProvider), isNull);

    // The SAME invitation, redelivered well inside its freshness window.
    transport.emitMessage(msg);
    await pump();
    expect(container.read(incomingRingProvider), isNull,
        reason: 'a settled invitation must never ring twice');
  });

  test('a RETRACTED invite is never announced, so it never rings', () async {
    // `upsertInbound` suppresses a retracted message via Door A and writes no
    // row, but returns `false` meaning "not newly invalid" — indistinguishable
    // from a successful write. Announcing anyway rang for a taken-down invite no
    // reader could find; a history page carrying an invite AND its retraction
    // produces exactly this, since the pager applies retractions first
    // (cage-match #139 R3, Carnot).
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    final msg = await inbound();

    // Retraction FIRST — presence-independent dead id, the ordering the pager
    // actually produces.
    transport.emitRetraction(dmId, 'RETR1', msg.id!);
    await pump();

    transport.emitMessage(msg);
    await pump();

    expect(container.read(incomingRingProvider), isNull,
        reason: 'a retracted invitation must never ring');
  });

  test('stopRinging clears it', () async {
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(await inbound());
    await pump();
    expect(container.read(incomingRingProvider), isNotNull);

    container.read(incomingRingProvider.notifier).stopRinging();
    expect(container.read(incomingRingProvider), isNull);
  });
}
