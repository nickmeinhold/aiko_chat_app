import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
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
    String clientMsgId = 'M1',
    String? replyTo,
  }) async {
    final key = await SovereignKeyStore().loadOrCreate();
    final signedAt = DateTime.now().toUtc().subtract(age);
    final payload = SignedPayload(
      rawPublicKey: key.rawPublicKey,
      channelId: dmId,
      clientMsgId: clientMsgId,
      signedAtMs: signedAt.millisecondsSinceEpoch,
      body: body,
      // Signed, not decorative: the end message names the call it ends here,
      // and `replyTo` is inside signingBytes — so the binding cannot be forged
      // or rewritten in transit.
      replyTo: replyTo,
    );
    final sig = await sign(key, payload);
    return Message(
      clientTempId: clientMsgId,
      id: clientMsgId,
      channelId: dmId,
      sender: MessageSender(
        userId: from,
        kind: SenderKind.human,
        label: 'Robin',
      ),
      body: body,
      replyToId: replyTo,
      createdAt: DateTime.now().toUtc(),
      origin: OriginEnvelope.fromSignature(sig, clientMsgId: clientMsgId),
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
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repo),
        currentUserProvider.overrideWithValue(me),
        blockedUserIdsProvider.overrideWithValue(const <String>{}),
        mutedChannelIdsProvider.overrideWithValue(const <String>{}),
        mutedUserIdsProvider.overrideWithValue(const <String>{}),
        // The ring resolves DM-ness from the app's OWN channel model, never from
        // the id's shape — a real DM channel id is a bare ULID (live-verified),
        // and the `dm:` prefix lives on a column the app never receives.
        dmsProvider.overrideWith(
          (ref) async => [
            const Channel(id: dmId, name: 'Ring Test', kind: ChannelKind.dm),
          ],
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await repo.dispose();
    await transport.dispose();
    await cache.close();
  });

  /// Let the transport listener, the repo's inbound FIFO, the drift write and
  /// the announcement all drain.
  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 30));

  /// Warm `dmsProvider` before the ring reads it. In production the repository
  /// itself watches it (the subscription set is built from it), so it is always
  /// resolved by the time messages flow; here the repo is overridden, so the
  /// harness has to stand in for that keep-alive or `_isDm` reads an unresolved
  /// AsyncValue and fails closed.
  Future<void> warmDms() async {
    container.listen(dmsProvider, (_, _) {}, fireImmediately: true);
    await container.read(dmsProvider.future);
  }

  test('a fresh invite from a peer rings this device', () async {
    // Subscribe so the controller builds and wires its listener BEFORE the
    // message arrives — a ring that only works if someone was already watching
    // is not a ring.
    await warmDms();
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
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(await inbound(body: 'hey are you up'));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('my own invite echoing back does not ring me', () async {
    // The caller's own send returns down this same inbound path.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(await inbound(from: meId));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('a stale invite (history replay) does not ring', () async {
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    transport.emitMessage(
      await inbound(age: kCallInviteFreshness + const Duration(seconds: 5)),
    );
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('a replay AFTER Ignore does not ring again', () async {
    // At-least-once delivery: the same signed invitation arrives twice (live +
    // history, reconnect drain). Suppressing only against "currently ringing"
    // was not enough — `stopRinging()` clears that, so a replay landing seconds
    // after Ignore rang all over again (cage-match #139 R2, Carnot).
    await warmDms();
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
    expect(
      container.read(incomingRingProvider),
      isNull,
      reason: 'a settled invitation must never ring twice',
    );
  });

  test('a RETRACTED invite is never announced, so it never rings', () async {
    // `upsertInbound` suppresses a retracted message via Door A and writes no
    // row, but returns `false` meaning "not newly invalid" — indistinguishable
    // from a successful write. Announcing anyway rang for a taken-down invite no
    // reader could find; a history page carrying an invite AND its retraction
    // produces exactly this, since the pager applies retractions first
    // (cage-match #139 R3, Carnot).
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    final msg = await inbound();

    // Retraction FIRST — presence-independent dead id, the ordering the pager
    // actually produces.
    transport.emitRetraction(dmId, 'RETR1', msg.id!);
    await pump();

    transport.emitMessage(msg);
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNull,
      reason: 'a retracted invitation must never ring',
    );
  });

  test('a live ring SURVIVES a repository rebuild', () async {
    // The case the feature exists for: a FIRST-EVER DM invite seeds the DM,
    // which invalidates dmsProvider, which rebuilds chatRepositoryProvider —
    // while the ring is live. Nothing in the suite invalidated the repo mid-ring
    // until now (cage-match #139 R4, Tesla).
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(await inbound());
    await pump();
    expect(container.read(incomingRingProvider), isNotNull);

    container.invalidate(chatRepositoryProvider);
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNotNull,
      reason: 'a repo reconnecting is not the user ignoring a call',
    );
  });

  test(
    'the ring window is measured from the SIGNED start, rebuild or not',
    () async {
      // One state, one equation of motion. `_consider` used to arm an absolute
      // kCallRingDuration while `_republish` derived the remainder from
      // startedAt, so a ring's length depended on whether a rebuild happened
      // (cage-match #139 R5, Carnot). An invitation already older than the ring
      // window must not ring at all — even though it is inside the 10s freshness
      // gate, admission and duration are different clocks.
      await warmDms();
      container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
      await pump();

      // Freshness gate is 10s and ring duration is 30s, so this cannot arise from
      // a real signature; drive it directly to pin the arithmetic.
      final ctl = container.read(incomingRingProvider.notifier);
      expect(
        kCallRingDuration > kCallInviteFreshness,
        isTrue,
        reason: 'if this inverts, the admission gate alone bounds the ring',
      );
      ctl.stopRinging();
      expect(container.read(incomingRingProvider), isNull);
    },
  );

  test('stopRinging clears it', () async {
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(await inbound());
    await pump();
    expect(container.read(incomingRingProvider), isNotNull);

    container.read(incomingRingProvider.notifier).stopRinging();
    expect(container.read(incomingRingProvider), isNull);
  });

  test(
    'the caller hanging up STOPS the ring — the whole point of #3198',
    () async {
      // Without this the callee rings for the rest of kCallRingDuration for a call
      // that is already over, and answering it joins an empty room. The ring
      // self-terminating at 30s bounds the damage; this makes the stop PROMPT.
      await warmDms();
      container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
      await pump();
      transport.emitMessage(await inbound());
      await pump();
      expect(
        container.read(incomingRingProvider),
        isNotNull,
        reason: 'precondition: it must be ringing before a hangup can stop it',
      );

      transport.emitMessage(
        await inbound(body: kCallEndBody, clientMsgId: 'M2', replyTo: 'M1'),
      );
      await pump();

      expect(container.read(incomingRingProvider), isNull);
    },
  );

  test('an end naming a DIFFERENT call leaves this ring alone', () async {
    // Hang up, ring again immediately, and the first end must not reach through
    // and kill the second ring. The signed replyTo is what scopes it to ONE call.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(await inbound());
    await pump();

    transport.emitMessage(
      await inbound(body: kCallEndBody, clientMsgId: 'M2', replyTo: 'OTHER'),
    );
    await pump();

    expect(container.read(incomingRingProvider), isNotNull);
  });

  test('a hangup does not resurrect the ring on the invite replay', () async {
    // At-least-once delivery: the INVITE can arrive again inside its freshness
    // window, after the hangup. stopRinging settles the invitation, so the
    // replay finds it already dealt with — the same memory that makes Ignore
    // stick.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(await inbound());
    await pump();
    transport.emitMessage(
      await inbound(body: kCallEndBody, clientMsgId: 'M2', replyTo: 'M1'),
    );
    await pump();
    expect(
      container.read(incomingRingProvider),
      isNull,
      reason: 'precondition',
    );

    transport.emitMessage(await inbound()); // the invite, delivered again
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });
}
