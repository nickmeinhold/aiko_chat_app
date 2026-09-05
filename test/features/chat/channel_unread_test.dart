import 'dart:convert';

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/channel_read_store.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart'
    show UnreadBadge;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

/// Per-channel unread indicators on the channel switcher (app-only feature).
///
/// The repository subscribes to every channel at construction, so each channel's
/// inbound messages are already in the local cache; unread is a pure function of
/// (cached messages, per-channel last-read watermark, my user id) — with the
/// first-sight baseline gated on the channel's history-sync fence.
void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // Isolate watermark persistence across tests — testPrefs is shared for the
  // whole suite (setUpAll), so drop any read-state a prior test wrote.
  setUp(() async {
    for (final k
        in testPrefs
            .getKeys()
            .where((k) => k.startsWith('aiko_channel_lastread_'))
            .toList()) {
      await testPrefs.remove(k);
    }
  });

  // Canonical-length 26-char ULIDs that sort by their trailing chars.
  String ulid(String tail) => '01J${'0' * 21}$tail';

  /// An inbound (server-originated) message for [channelId] from [userId].
  Message inbound(String channelId, String id, String userId, String body) =>
      Message(
        clientTempId: id,
        id: id,
        channelId: channelId,
        sender: MessageSender(
          userId: userId,
          kind: SenderKind.human,
          label: 'User $userId',
        ),
        body: body,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        deliveryState: DeliveryState.sent,
      );

  const twoChannels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
  ];

  /// Let the repo's serialized inbound queue persist + the cache streams emit +
  /// the deferred baseline / store writes flush.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  // These widget tests assert the drawer row badges in the NARROW (phone)
  // layout. The flutter_test default viewport (800x600) is ABOVE the responsive
  // breakpoint (720) and renders the wide sidebar instead, so pin a phone-width
  // viewport.
  Future<void> pumpNarrow(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpApp(tester, container);
  }

  /// Sign in AND drive the `connected` choreography so the repo's history sync
  /// runs and each channel's resume fence settles (`''` for an empty channel).
  /// That fence is what unblocks the first-sight baseline — without it, unread
  /// stays 0 (never floods) exactly as it must while history is still in flight.
  Future<void> signInConnected(
    WidgetTester tester,
    FakeChatTransport transport,
  ) async {
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);
  }

  Finder unreadBadge(String channelId) =>
      find.byKey(Key('sidebar-unread-$channelId'));

  Future<void> expectDrawerUnread(
    WidgetTester tester,
    String channelId,
    Matcher matcher, {
    String? count,
  }) async {
    await openChatDrawer(tester);
    final badge = unreadBadge(channelId);
    expect(badge, matcher);
    if (count != null) {
      expect(
        find.descendant(of: badge, matching: find.text(count)),
        findsOneWidget,
      );
    }
    await closeChatDrawer(tester);
  }

  // ── Store: injective keyspace + durable monotonicity + isolation ────────────

  group('ChannelReadStore', () {
    test(
      'keyspace is injective across ids containing "_" (finding 1)',
      () async {
        final store = ChannelReadStore(testPrefs);
        // Under a flat `<userId>_<channelId>` key these BOTH flatten to
        // `aiko_channel_lastread_a_b_c` and collide; the per-user JSON map keeps
        // them separate.
        await store.setWatermark('a', 'b_c', ulid('0A'));
        await store.setWatermark('a_b', 'c', ulid('0B'));

        expect(store.readAll('a'), {'b_c': ulid('0A')});
        expect(store.readAll('a_b'), {'c': ulid('0B')});
      },
    );

    test(
      'per-user isolation: one user\'s marks are invisible to another',
      () async {
        final store = ChannelReadStore(testPrefs);
        await store.setWatermark('userA', 'c1', ulid('0A'));
        expect(store.readAll('userA'), {'c1': ulid('0A')});
        expect(
          store.readAll('userB'),
          <String, String>{},
        ); // B sees none of A's
      },
    );

    test(
      'durable write is monotonic — an older ulid never rewinds (finding 2)',
      () async {
        final store = ChannelReadStore(testPrefs);
        await store.setWatermark('u', 'c', ulid('0C'));
        await store.setWatermark('u', 'c', ulid('0B')); // out-of-order / older

        expect(
          store.readAll('u')['c'],
          ulid('0C'),
        ); // newest survives, no rewind
      },
    );

    test(
      'two rapid advances persist the newest regardless of order (finding 2)',
      () async {
        final store = ChannelReadStore(testPrefs);
        // Fire both without awaiting between — the serialized chain + CAS must land
        // on the newest, not whichever completes last.
        final a = store.setWatermark('u', 'c', ulid('0B'));
        final b = store.setWatermark('u', 'c', ulid('0C'));
        await Future.wait([a, b]);

        expect(store.readAll('u')['c'], ulid('0C'));
      },
    );

    test(
      'a malformed (non-26-char) id is rejected — no bad monotonic floor',
      () async {
        final store = ChannelReadStore(testPrefs);
        await store.setWatermark('u', 'c', ulid('0A')); // valid
        await store.setWatermark('u', 'c', 'SHORT'); // junk — rejected

        expect(store.readAll('u')['c'], ulid('0A')); // unchanged, uncorrupted
      },
    );

    test(
      'a 26-char but out-of-alphabet id is rejected — length is not enough',
      () async {
        final store = ChannelReadStore(testPrefs);
        await store.setWatermark('u', 'c', ulid('0A')); // valid
        // 26 chars, so a length-only check would accept it, but lowercase glyphs
        // are outside Crockford base32 and sort ABOVE every real (uppercase) ULID —
        // it would freeze compareTo and pin unread at 0 forever (cage-match #109).
        await store.setWatermark('u', 'c', 'zzzzzzzzzzzzzzzzzzzzzzzzzz');
        expect(store.readAll('u')['c'], ulid('0A')); // unchanged, uncorrupted
      },
    );

    test('readAll drops a corrupt 26-char persisted value on load', () async {
      // A corrupt value already on disk (storage corruption / a legacy format)
      // must not enter the marks map, where it would block first-sight baseline
      // (via containsKey) and freeze comparison — it is filtered at load.
      await testPrefs.setString(
        'aiko_channel_lastread_u',
        jsonEncode({'good': ulid('0A'), 'bad': 'zzzzzzzzzzzzzzzzzzzzzzzzzz'}),
      );
      final store = ChannelReadStore(testPrefs);
      expect(store.readAll('u'), {'good': ulid('0A')}); // bad entry dropped
    });

    test('separate channels for one user coexist in the map', () async {
      final store = ChannelReadStore(testPrefs);
      await store.setWatermark('u', 'c1', ulid('0A'));
      await store.setWatermark('u', 'c2', ulid('0B'));
      expect(store.readAll('u'), {'c1': ulid('0A'), 'c2': ulid('0B')});
    });

    test(
      'readAll drops a malformed persisted value (load-time validation)',
      () async {
        // A corrupt/legacy entry must never enter the marks map — it would poison
        // comparison AND block the channel's first-sight baseline via containsKey.
        await testPrefs.setString(
          'aiko_channel_lastread_u',
          jsonEncode({'c1': ulid('0A'), 'bad': 'SHORT'}),
        );
        final store = ChannelReadStore(testPrefs);
        expect(store.readAll('u'), {'c1': ulid('0A')}); // 'bad' dropped
      },
    );
  });

  // ── Widget: switcher badges ────────────────────────────────────────────────

  testWidgets('a message in the non-active channel shows an unread badge', (
    tester,
  ) async {
    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: transport,
    );
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signInConnected(tester, transport); // active channel = c1

    // No unread yet.
    await expectDrawerUnread(tester, 'c2', findsNothing);

    // Another user posts into the NON-active channel c2.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'hey there'));
    await settle(tester);

    // The drawer row now carries the unread badge, count 1.
    await expectDrawerUnread(tester, 'c2', findsOneWidget, count: '1');
  });

  testWidgets(
    'switching to the channel clears its badge (watermark advances)',
    (tester) async {
      final transport = FakeChatTransport();
      final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: transport,
      );
      addTearDown(container.dispose);

      await pumpNarrow(tester, container);
      await signInConnected(tester, transport);

      transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'unread msg'));
      await settle(tester);
      await expectDrawerUnread(tester, 'c2', findsOneWidget, count: '1');

      // Switch to c2 (view it) — viewing marks it read.
      await selectChannelFromDrawer(tester, 'c2');
      await settle(tester);

      // Badge cleared: no aggregate (c1 has none, c2 now read).
      await expectDrawerUnread(tester, 'c2', findsNothing);
      // And the watermark was durably persisted for this user/channel (per-user
      // JSON map under a single key).
      final raw = testPrefs.getString('aiko_channel_lastread_u1');
      expect(raw, isNotNull);
      expect((jsonDecode(raw!) as Map)['c2'], ulid('0A'));
    },
  );

  testWidgets('the active channel never shows a badge', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: transport,
    );
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signInConnected(tester, transport); // active = c1

    // A message arrives in the ACTIVE channel c1 from someone else.
    transport.emitMessage(inbound('c1', ulid('0A'), 'u2', 'in active chan'));
    await settle(tester);

    // The message renders, but the active channel is never badged.
    expect(find.text('in active chan'), findsOneWidget);
    await expectDrawerUnread(tester, 'c1', findsNothing);
  });

  testWidgets('my own messages do not count as unread', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: transport,
    );
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signInConnected(tester, transport); // me = u1

    // An echo of MY OWN message lands in the non-active channel c2.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u1', 'my echo'));
    await settle(tester);

    // No unread — a message from myself is never unread.
    await expectDrawerUnread(tester, 'c2', findsNothing);
  });

  testWidgets('a persisted watermark is honored on load (durability)', (
    tester,
  ) async {
    // Seed a persisted watermark BEFORE the app builds: user u1 has already read
    // c2 through ulid('05') — stored as the per-user JSON map. A non-null mark
    // means no first-sight baseline is needed (so no fence dependency here).
    await testPrefs.setString(
      'aiko_channel_lastread_u1',
      jsonEncode({'c2': ulid('05')}),
    );

    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: transport,
    );
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);
    await settle(tester);

    // A message BELOW the persisted watermark is already-read → no badge.
    transport.emitMessage(inbound('c2', ulid('03'), 'u2', 'old already-read'));
    await settle(tester);
    await expectDrawerUnread(tester, 'c2', findsNothing);

    // A message ABOVE the watermark is genuinely unread → badge appears.
    transport.emitMessage(inbound('c2', ulid('09'), 'u2', 'new unread'));
    await settle(tester);
    await expectDrawerUnread(tester, 'c2', findsOneWidget, count: '1');
  });

  testWidgets(
    'a live message arriving before the fence settles stays unread — baseline '
    'is the FENCE, not newest-cached (finding 3a, live-swallow)',
    (tester) async {
      // Drive the cache directly to control the real ordering. Baseline = fence,
      // NOT newest-cached: a live message that arrived before history settled sits
      // ABOVE the fence, so it must remain unread.
      final cache = DriftCache(NativeDatabase.memory());
      addTearDown(cache.close);

      final transport = FakeChatTransport();
      final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: transport,
        cache: cache,
      );
      addTearDown(container.dispose);

      await pumpNarrow(tester, container);
      await signIn(tester); // NOT connected: fence not settled yet
      await settle(tester);
      await expectDrawerUnread(tester, 'c2', findsNothing); // fence null → 0

      // A LIVE message lands in c2 BEFORE history settles (fence still null).
      await cache.upsertInbound(inbound('c2', ulid('09'), 'u2', 'live-early'));
      await settle(tester);
      await expectDrawerUnread(
        tester,
        'c2',
        findsNothing,
      ); // still 0 — baseline withheld until settle

      // History SETTLES at an OLDER fence (subscribe-time watermark), BELOW the
      // live message: history covered '..05', the live '09' arrived after.
      await cache.advanceHistoryContiguous('c2', ulid('05'));
      await settle(tester);

      // Baseline = fence '05' → the live '09' > '05' is NOT swallowed (count 1).
      // (baseline=newest-cached would baseline to '09' → 0 → RED here.)
      await expectDrawerUnread(tester, 'c2', findsOneWidget, count: '1');
    },
  );

  testWidgets(
    'restart with a settled fence but not-yet-streamed history does not flood '
    '— baseline is the FENCE (finding 3b, fence-first)',
    (tester) async {
      // Durable fence already settled at '05' from a prior session; no marks, and
      // the message stream has not yielded history at first unread build.
      final cache = DriftCache(NativeDatabase.memory());
      addTearDown(cache.close);
      await cache.advanceHistoryContiguous('c2', ulid('05'));

      final transport = FakeChatTransport();
      final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: transport,
        cache: cache,
      );
      addTearDown(container.dispose);

      await pumpNarrow(tester, container);
      await signIn(tester);
      await settle(tester);
      // First sight: fence '05' (durable) but stream empty → baseline = fence '05',
      // NOT '' from the empty stream (which is the round-3 flood).

      // History + a live message now land in the cache.
      await cache.upsertInbound(inbound('c2', ulid('01'), 'u2', 'h1'));
      await cache.upsertInbound(inbound('c2', ulid('03'), 'u2', 'h2'));
      await cache.upsertInbound(inbound('c2', ulid('05'), 'u2', 'h3'));
      await cache.upsertInbound(inbound('c2', ulid('09'), 'u2', 'live'));
      await settle(tester);

      // NO flood: only '09' > baseline '05'. History 01..05 ≤ baseline is read.
      // (baseline=newest-cached-or-'' would baseline '' on the empty first sight →
      // all four count → RED here.)
      await expectDrawerUnread(tester, 'c2', findsOneWidget, count: '1');
    },
  );

  testWidgets('a tail-arrival while scrolled up does NOT mark the channel read '
      '(finding 4)', (tester) async {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford
    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: transport,
    );
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester); // active = c1

    // Fill c1 with enough inbound (from another user) to overflow the viewport,
    // while pinned at the tail → each is marked read as it arrives (this sets a
    // real, non-null watermark on c1, so no fence dependency here).
    for (var i = 0; i < 15; i++) {
      transport.emitMessage(
        inbound('c1', ulid('1${alphabet[i]}'), 'u2', 'm$i'),
      );
      await settle(tester);
    }

    // Scroll UP into history, away from the tail.
    final listFinder = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(listFinder).position;
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);

    // A new message arrives at the tail while the reader is up in history.
    transport.emitMessage(inbound('c1', ulid('1Z'), 'u2', 'unseen-tail'));
    await settle(tester);

    // Switch to c2 → c1 is now non-active. The unseen tail message MUST show as
    // unread: the watermark did not jump past a message the reader never saw.
    await selectChannelFromDrawer(tester, 'c2');
    await settle(tester);

    await expectDrawerUnread(tester, 'c1', findsOneWidget, count: '1');
  });

  testWidgets('unread count reflects multiple messages and the badge caps', (
    tester,
  ) async {
    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: twoChannels),
      transport: transport,
    );
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signInConnected(tester, transport);

    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'one'));
    transport.emitMessage(inbound('c2', ulid('0B'), 'u2', 'two'));
    transport.emitMessage(inbound('c2', ulid('0C'), 'u3', 'three'));
    await settle(tester);

    await openChatDrawer(tester);
    final badge = unreadBadge('c2');
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('3')),
      findsOneWidget,
    );
    // The badge widget is the shared UnreadBadge type.
    expect(find.byType(UnreadBadge), findsWidgets);
    await closeChatDrawer(tester);
  });
}
