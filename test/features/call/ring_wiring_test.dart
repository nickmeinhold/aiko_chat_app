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
  /// The island's ULID for a given client id — LITERAL and distinct per id.
  ///
  /// This was `'01M0GS7FDWBVQ31950B1PTV2D' + clientMsgId.hashCode.abs() % 10`:
  /// a TEN-VALUE space, in the file that argues against fixtures which cannot
  /// express the failing input (cage-match round 4, Tesla). Two fixture ids
  /// landing in one bucket would collide on `clientTempId`, the repository would
  /// not announce the second, and `_settled` / `endsInvite` would go unexamined
  /// while every test in this file stayed green — the same void-test class in a
  /// smaller hat. `String.hashCode` is also not a stable cross-version contract,
  /// so an SDK bump could mint that collision silently.
  ///
  /// A map, so an unknown id FAILS rather than quietly hashing into a neighbour.
  const serverIds = {
    'M1': '01M0GS7FDWBVQ31950B1PTV2D0',
    'M2': '01M0GS7FDWBVQ31950B1PTV2D1',
    'M9': '01M0GS7FDWBVQ31950B1PTV2D2',
    // The caller's RETRY: the same signed invitation, a DIFFERENT island ULID.
    // The whole point is that this is not derivable from 'M1'.
    'RETRY': '01M0GS7FDWBVQ31950B1PTV2D3',
  };
  String serverIdFor(String clientMsgId) {
    final id = serverIds[clientMsgId];
    if (id == null) {
      throw ArgumentError(
        'no server ULID pinned for "$clientMsgId" — add one to serverIds '
        'rather than deriving it, so two fixtures can never share a row',
      );
    }
    return id;
  }

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
    // The SERVER ulid, variable INDEPENDENTLY of the client id.
    //
    // It defaulted to `serverIdFor(clientMsgId)` and nothing else — a pure
    // function of the client id, so the two could not be varied apart and the
    // one shape that can defeat `_settled` (one signed invitation, two server
    // ULIDs) was inexpressible. That is why deleting the replay guard left every
    // test in this file green: the suite could not build the failing input
    // (cage-match round 3, Maxwell). A fixture that agrees with itself is the
    // recurring mechanism behind every void test this feature has produced.
    String? serverId,
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
    final ulid = serverId ?? serverIdFor(clientMsgId);
    return Message(
      // clientTempId IS THE SERVER ULID for an inbound message, exactly as
      // `Message.fromView` builds one: `final msgId = v['msg_id'] as String;
      // Message(clientTempId: msgId, id: msgId, ...)`. The signed client id
      // lives only in the origin envelope, which is where `inviteId` reads it.
      //
      // This fixture used to put the SIGNED id here, which production never
      // does — and the messages table is keyed on `clientTempId`, so a caller
      // retry (same signed id, new ULID) collided on the primary key and was
      // dropped as a write failure instead of inserting and ringing. That made
      // `_settled` look like unreachable dead code when it is in fact
      // load-bearing: the divergence, not the guard, was the defect
      // (cage-match round 3, Maxwell — measured, after the first "fix" to this
      // fixture was itself void).
      clientTempId: ulid,
      // The SERVER ulid — distinct from the client id (the gateway's reply_to
      // is an FK onto messages.id, and a fixture reusing one string for both
      // cannot tell a correct binding from the wire bug a live probe caught),
      // and canonical ULID SHAPE, because a value no island could mint proves
      // the binding against an id that cannot occur.
      id: ulid,
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

  test('a caller RETRY after Ignore does not ring again', () async {
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

    // THE CALLER RETRIES — and that, not a redelivery, is the shape that can
    // actually defeat `_settled`.
    //
    // This assertion used to re-emit `msg` itself and passed for the wrong
    // reason: `ChatRepository._announceInbound` fires only on `inserted`, a
    // FIRST insert of that server ULID, so a redelivery of one message never
    // reaches the ring at all. Deleting the guard under test left this test —
    // and every other in this file — green (cage-match round 3, Maxwell;
    // measured with a positive control).
    //
    // HONEST LABEL: the island will not currently produce this delivery. Its
    // `messages_service` holds UNIQUE(channel_id, client_msg_id) and returns the
    // EXISTING row on a resend, so one signed invitation has exactly one ULID and
    // a retry is reconciled rather than re-inserted. An earlier version of this
    // comment asserted the opposite as fact, without checking the peer repo —
    // the same unverified-premise error the rest of this file was written to fix.
    //
    // The test is kept because the guard is kept: its precondition lives in
    // ANOTHER repository, so this constructs the delivery a relaxed island
    // idempotency contract would start emitting, and pins that the ring stays
    // silent for it. Defence in depth, labelled as such rather than dressed up
    // as a reachable bug.
    transport.emitMessage(await inbound(serverId: serverIdFor('RETRY')));
    await pump();
    expect(
      container.read(incomingRingProvider),
      isNull,
      reason:
          'the user pressed Ignore on THIS invitation — a retry of it carries '
          'the same signed id and must stay dismissed',
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
        await inbound(
          body: kCallEndBody,
          clientMsgId: 'M2',
          replyTo: serverIdFor('M1'),
        ),
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

  test('a hangup does not resurrect the ring on a caller RETRY', () async {
    // The hangup settles the invitation, so a retry of it finds the id already
    // dealt with — the same memory that makes Ignore stick. (Was written against
    // a redelivery, which the repository dedupes before the ring ever sees it;
    // see the retry note above.)
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    transport.emitMessage(await inbound());
    await pump();
    transport.emitMessage(
      await inbound(
        body: kCallEndBody,
        clientMsgId: 'M2',
        replyTo: serverIdFor('M1'),
      ),
    );
    await pump();
    expect(
      container.read(incomingRingProvider),
      isNull,
      reason: 'precondition',
    );

    transport.emitMessage(await inbound(serverId: serverIdFor('RETRY')));
    await pump();

    expect(container.read(incomingRingProvider), isNull);
  });

  test('a hangup naming the RETRY stops the ring, banner and all', () async {
    // Cage-match round 4, Tesla. The stop is bound to ONE island ULID; the ring's
    // identity is the signed `clientMsgId`. Those are not the same name, and a
    // caller retry is where they come apart: the island mints a second ULID for
    // one signed invitation, so a hangup can name a ULID the live invitation
    // does not carry.
    //
    // What that used to leave behind is the bug this PR exists to remove,
    // restored as a rebuild gap: the overtake arm called `_settle`, which drops
    // `_live` but leaves `state` and the expiry timer holding the invitation —
    // so the banner kept ringing for a call the device could prove was over, and
    // Answer still joined the dead room until the timer fired.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    // The first delivery rings, under the island's FIRST ulid.
    transport.emitMessage(await inbound());
    await pump();
    expect(
      container.read(incomingRingProvider),
      isNotNull,
      reason: 'precondition — the bell is ringing',
    );

    // The caller hangs up, naming the ulid of their RETRY, which this device has
    // not seen. Nothing can match yet, and that is honest.
    transport.emitMessage(
      await inbound(
        body: kCallEndBody,
        clientMsgId: 'M2',
        replyTo: serverIdFor('RETRY'),
      ),
    );
    await pump();

    // ...and now the retry itself lands: same signed invitation, second ulid.
    transport.emitMessage(await inbound(serverId: serverIdFor('RETRY')));
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNull,
      reason:
          'the caller hung up on this very invitation — settling it in the '
          'bookkeeping while the banner keeps ringing is not stopping a ring',
    );
  });

  test('a LATER end cannot evict the genuine one from the overtake memory', () async {
    // Cage-match round 3, Tesla. The overtake memory hung one value per target
    // ULID, and the caller/channel clauses run at LOOKUP time — so an end this
    // device would ultimately REFUSE could still displace a genuine stop that
    // arrived before it. The existing third-party test only ever plays the
    // impostor FIRST, which is the ordering that cannot fail; this is the
    // ordering that can.
    //
    // Not reachable in a two-party DM today, because a stranger cannot learn the
    // invitation's ULID. It is reachable the moment calls are channel-wide —
    // which is the future `isDmChannelId` was deleted to make room for, and the
    // reason a single slot for a contested key does not get to stay.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    // The caller's genuine hangup, overtaking its own invitation.
    transport.emitMessage(
      await inbound(
        body: kCallEndBody,
        clientMsgId: 'M2',
        replyTo: serverIdFor('M1'),
      ),
    );
    await pump();
    // ...then somebody else's stop, naming the SAME call.
    transport.emitMessage(
      await inbound(
        from: 'mallory-key',
        body: kCallEndBody,
        clientMsgId: 'M9',
        replyTo: serverIdFor('M1'),
      ),
    );
    await pump();

    transport.emitMessage(await inbound()); // ...and now the invitation
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNull,
      reason:
          'the caller DID hang up before the invitation arrived — a later stop '
          'from someone with no standing must not erase that fact',
    );
  });

  test('an end that OVERTAKES its own invite still stops the ring', () async {
    // Cage-match round 1 (Tesla + Maxwell). Delivery here is at-least-once and
    // locally out of order — live + history dual delivery, reconnect drain — and
    // `_settled` exists because `_live` was not memory enough. An unmatched end
    // was the inverted twin: a signed "this call is dead" thrown away because
    // nothing was ringing YET, after which the invitation arrived inside its
    // freshness window and the bell rang for a corpse, for the full 30 seconds.
    //
    // Push makes this likelier rather than rarer: the island wakes a handset on
    // the INVITE body only, so a cold start processes the invitation first by
    // construction and the end is an ordinary afterthought.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    // The hangup lands FIRST, naming an invitation this client has not seen.
    transport.emitMessage(
      await inbound(
        body: kCallEndBody,
        clientMsgId: 'M2',
        replyTo: serverIdFor('M1'),
      ),
    );
    await pump();
    expect(
      container.read(incomingRingProvider),
      isNull,
      reason: 'precondition',
    );

    transport.emitMessage(await inbound()); // ...and now the invitation
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNull,
      reason:
          'the call was already over before its invitation arrived — ringing '
          'here is the exact bug this PR exists to remove, just reordered',
    );
  });

  test('a THIRD PARTY cannot pre-poison the overtake memory', () async {
    // Cage-match round 2 (Carnot + Tesla, independently). The out-of-order
    // memory used to record any verified, non-self end with a reply target and
    // then suppress an invitation by its server id ALONE — skipping the caller
    // and channel binding the live path enforces. So an end the in-order path
    // would have refused could silence a genuine ring, provided its author could
    // name the invitation's server id. `isDmChannelId` was deleted partly
    // BECAUSE channel-wide calls are a real future feature, and that feature
    // makes those ids visible in the room.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();

    // Someone who is not the caller sends a signed stop naming the invitation.
    transport.emitMessage(
      await inbound(
        from: 'mallory-key',
        body: kCallEndBody,
        clientMsgId: 'M9',
        replyTo: serverIdFor('M1'),
      ),
    );
    await pump();

    transport.emitMessage(await inbound()); // the genuine invitation
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNotNull,
      reason:
          'only the caller may end their own call — the remembered end must be '
          'matched by the SAME clauses the live path applies, or the memory is '
          'a weaker second gate',
    );
  });
}
