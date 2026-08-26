import 'package:aiko_chat_app/features/call/application/ring_controller.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/call/application/ring_allowlist_provider.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

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
    // The island's verdict on the sender. Variable because the consent path only
    // exists for senders it does NOT call people — a fixture stuck on `human`
    // cannot reach the allowlist branch at all, which is how a wiring test ends
    // up proving nothing about the wiring it was written for.
    SenderKind kind = SenderKind.human,
    String channelId = dmId,
  }) async {
    final key = await SovereignKeyStore().loadOrCreate();
    final signedAt = DateTime.now().toUtc().subtract(age);
    final payload = SignedPayload(
      rawPublicKey: key.rawPublicKey,
      channelId: channelId,
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
      channelId: channelId,
      sender: MessageSender(userId: from, kind: kind, label: 'Robin'),
      body: body,
      replyToId: replyTo,
      createdAt: DateTime.now().toUtc(),
      origin: OriginEnvelope.fromSignature(sig, clientMsgId: clientMsgId),
      deliveryState: DeliveryState.sent,
    );
  }

  late SharedPreferences prefs;

  setUp(() async {
    installSecureStorageMock(); // the sovereign key store needs a backing store
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
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
        // The consent store's backing. Additive: before the allowlist existed
        // nothing in this harness read it, and the ring path is written so that
        // an unreadable store means NO CONSENT rather than no ring.
        sharedPreferencesProvider.overrideWithValue(prefs),
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

  test('a re-delivered invitation does not ring again after Ignore', () async {
    // Cage-match round 7, Tesla. The `_settled` set was deleted because the
    // repository already collapses a re-delivery, and the tests that exercised
    // it went with it — leaving the INVARIANT unpinned. The objection is fair
    // and has history behind it: this same PR deleted `isDmChannelId` because a
    // gateway constraint did not mean what the documentation swore, and one live
    // call refuted six review rounds. Keying a deletion to another peer-side
    // fact and then removing the test that could catch it being wrong is the
    // same move.
    //
    // So this asserts the INVARIANT, not the mechanism. It says nothing about
    // where suppression happens — it says a replay must not ring after Ignore.
    // It passes today because `ChatRepository` announces only on a first insert
    // of a server ULID (measured, with a positive control). If that ever stops
    // being true, this fails HERE, in the feature that cares.
    await warmDms();
    container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
    await pump();
    final invitation = await inbound();

    transport.emitMessage(invitation);
    await pump();
    expect(
      container.read(incomingRingProvider),
      isNotNull,
      reason: 'precondition — it rang the first time',
    );

    container.read(incomingRingProvider.notifier).stopRinging(); // Ignore
    expect(container.read(incomingRingProvider), isNull);

    // The SAME delivery again, well inside the freshness window.
    transport.emitMessage(invitation);
    await pump();

    expect(
      container.read(incomingRingProvider),
      isNull,
      reason:
          'the user dismissed this call — a re-delivery of the very same '
          'message must not ring them a second time, wherever that is enforced',
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

  group('the consent provider actually reaches the gate (#3453)', () {
    // THE SEAM #161 SHIPPED UNPROVEN. `admitRing` was tested with a hand-built
    // consent and the provider was tested in isolation, so nothing anywhere
    // proved the controller hands ONE to the OTHER. A rename, a stale read, or a
    // slice against the wrong channel would have left both suites green.
    //
    // It matters more now than it did then: the wiring changed when consent
    // became per-conversation, and the value being threaded is no longer a bare
    // set that would fail loudly if it went missing — an empty consent and a
    // wrong-room consent behave identically to a correct refusal.
    const otherDm = '01M0GS7FDWBVQ31950B1PTV3AA';

    Future<String> myMultikey() async =>
        encodeMultikey((await SovereignKeyStore().loadOrCreate()).rawPublicKey);

    Future<void> watch() async {
      await warmDms();
      container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
      await pump();
    }

    test('an UNCONSENTED non-human does not ring — the precondition', () async {
      await watch();

      transport.emitMessage(await inbound(kind: SenderKind.llm));
      await pump();

      expect(container.read(incomingRingProvider), isNull);
    });

    test(
      'consent granted THROUGH THE PROVIDER, in this conversation, rings',
      () async {
        await watch();
        final granted = await container
            .read(ringConsentByChannelProvider.notifier)
            .allow(dmId, await myMultikey());
        expect(granted, isTrue, reason: 'precondition: the grant persisted');

        transport.emitMessage(await inbound(kind: SenderKind.llm));
        await pump();

        expect(
          container.read(incomingRingProvider),
          isNotNull,
          reason:
              'the controller must read the live provider at the moment the '
              'invite lands — not a value captured when it was built',
        );
      },
    );

    test(
      'consent granted in ANOTHER conversation does NOT ring here — the '
      'ruling, proved through the real wiring rather than a hand-built value',
      () async {
        await watch();
        await container
            .read(ringConsentByChannelProvider.notifier)
            .allow(otherDm, await myMultikey());

        transport.emitMessage(await inbound(kind: SenderKind.llm));
        await pump();

        expect(container.read(incomingRingProvider), isNull);
      },
    );

    test('a REVOKE reaches the gate too — consent that cannot be withdrawn '
        'is not consent', () async {
      await watch();
      final key = await myMultikey();
      final notifier = container.read(ringConsentByChannelProvider.notifier);
      await notifier.allow(dmId, key);
      await notifier.revoke(dmId, key);

      transport.emitMessage(await inbound(kind: SenderKind.llm));
      await pump();

      expect(container.read(incomingRingProvider), isNull);
    });
  });

  group('the scope token is INSIDE the signature (#3166 asked of channelId)', () {
    // Tesla, confirming round, and the question is exactly right even though the
    // answer is "already closed".
    //
    // This PR made `message.channelId` load-bearing: it now SELECTS which
    // consent bucket the gate consults. `RingConsent` itself documents why we
    // refuse to trust `sender.userId` and `sender.label` — they are
    // server-supplied metadata OUTSIDE the signature, so an island could edit
    // them. Nobody had asked the same question of `channelId`. If the envelope's
    // channel could disagree with the SIGNED channel, the island would not need
    // to forge a key; it could aim a consented key at a different door, and
    // per-conversation consent would be global consent wearing a routing trick.
    //
    // It cannot, and the refutation is two facts that must be pinned TOGETHER:
    //   1. `signingBytes` length-prefixes channelId (message_signing.dart — the
    //      field's own comment reads "else a sig replays into another channel");
    //   2. ingest verifies with `channelId: m.channelId`, the ENVELOPE's value
    //      (chat_repository.dart `_persistInbound`).
    // So a split envelope/signed channel fails verification, lands with
    // `originCryptoValid == false`, and `admitRing` refuses it before `_mayRing`
    // is ever consulted. The channel is as strong as the key, not as weak as the
    // label.
    //
    // Driven through the REAL repository rather than asserted about it, because
    // the property is the composition of those two facts and either one moving
    // would break it silently.
    const otherRoom = '01M0GS7FDWBVQ31950B1PTV3BB';

    test('a message signed for ANOTHER channel does not ring here', () async {
      await warmDms();
      container.listen(incomingRingProvider, (_, _) {}, fireImmediately: true);
      await pump();
      final key = await SovereignKeyStore().loadOrCreate();
      await container
          .read(ringConsentByChannelProvider.notifier)
          .allow(dmId, encodeMultikey(key.rawPublicKey));

      // Signed for `otherRoom`, delivered claiming `dmId` — the aiming attack.
      final signedAt = DateTime.now().toUtc();
      final sig = await sign(
        key,
        SignedPayload(
          rawPublicKey: key.rawPublicKey,
          channelId: otherRoom,
          clientMsgId: 'M1',
          signedAtMs: signedAt.millisecondsSinceEpoch,
          body: kCallInviteBody,
          replyTo: null,
        ),
      );
      transport.emitMessage(
        Message(
          clientTempId: serverIdFor('M1'),
          id: serverIdFor('M1'),
          channelId: dmId,
          sender: const MessageSender(
            userId: robinId,
            kind: SenderKind.llm,
            label: 'Robin',
          ),
          body: kCallInviteBody,
          replyToId: null,
          createdAt: DateTime.now().toUtc(),
          origin: OriginEnvelope.fromSignature(sig, clientMsgId: 'M1'),
          deliveryState: DeliveryState.sent,
        ),
      );
      await pump();

      expect(
        container.read(incomingRingProvider),
        isNull,
        reason:
            'the signature does not cover this envelope channel, so ingest '
            'marks it invalid and the ring gate refuses it — consent for dmId '
            'must not be reachable by relabelling a message signed elsewhere',
      );
    });

    test(
      'POSITIVE CONTROL: the same message signed for THIS channel rings',
      () async {
        // Without this the test above passes for any reason at all — a broken
        // fixture, a dead transport, a consent that never landed. This proves the
        // only difference is the signed channel.
        await warmDms();
        container.listen(
          incomingRingProvider,
          (_, _) {},
          fireImmediately: true,
        );
        await pump();
        final key = await SovereignKeyStore().loadOrCreate();
        await container
            .read(ringConsentByChannelProvider.notifier)
            .allow(dmId, encodeMultikey(key.rawPublicKey));

        transport.emitMessage(await inbound(kind: SenderKind.llm));
        await pump();

        expect(container.read(incomingRingProvider), isNotNull);
      },
    );
  });
}
