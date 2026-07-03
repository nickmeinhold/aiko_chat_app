// Inbound backpressure (#9) — the named tradeoff deferred from #33 (PR#19).
//
// The inbound FIFO (_inboundTail) funnels ack/message/error through one writer
// for ordering, but had NO bound: under a sustained flood the chain of pending
// `.then` units (each capturing its event) grew unbounded. The fix is
// pause-upstream backpressure — at a high-water mark the three inbound
// subscriptions PAUSE; at a low-water mark they resume. Pause, NOT drop, because
// the streams carry messages and a dropped live message is permanent loss (B4
// only re-syncs on reconnect).
//
// These tests pin: (1) a flood engages backpressure exactly at the high-water
// mark and releases at the low-water mark, with NO message loss; (2) sub-
// threshold load never engages the valve.
//
// RED-prove (1): delete `_maybePauseInbound()` from `_enqueueInbound` → the
// engage transition never records → the flood test goes green-to-red. Delete the
// `s.pause()` loop body → events are never held → the "no further processing
// while paused" depth cap breaks.

import 'dart:async';

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';

const _me = AppUser(
    userId: 'me', username: 'me', displayName: 'Me', aikoUsername: 'me');
const _chan = 'chan';

Message _server(String ulid) => Message(
      clientTempId: ulid,
      id: ulid,
      channelId: _chan,
      sender: const MessageSender(
          userId: 'u2', kind: SenderKind.human, label: 'Alice'),
      body: 'body-$ulid',
      createdAt: DateTime.parse('2026-01-01T12:00:01Z').toUtc(),
      deliveryState: DeliveryState.sent,
    );

/// A real in-memory cache whose `upsertInbound` can be GATED on a completer, so a
/// test can wedge inbound handlers mid-write and watch the FIFO depth climb.
class _GatingCache extends DriftCache {
  _GatingCache(super.e);
  Completer<void>? gate;

  @override
  Future<void> upsertInbound(Message serverMsg) async {
    if (gate != null) await gate!.future;
    return super.upsertInbound(serverMsg);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _GatingCache cache;
  late FakeChatTransport transport;
  late FakeChatRestApi rest;
  late ChatRepository repo;
  late SpyTelemetry spy;

  setUp(() {
    cache = _GatingCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    rest = FakeChatRestApi();
    spy = SpyTelemetry();
    repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: rest,
      me: _me,
      subscribedChannelIds: const [_chan],
      telemetry: spy,
      // Small marks so the test floods quickly; hysteresis gap is high>low.
      inboundHighWater: 3,
      inboundLowWater: 1,
      newTempId: () => 'tmp',
    );
    repo.start();
  });

  tearDown(() async {
    // Release any held gate so dispose's drain can complete.
    if (!(cache.gate?.isCompleted ?? true)) cache.gate!.complete();
    await repo.dispose();
    await transport.dispose();
    await cache.close();
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));
  Future<List<Message>> rows() => cache.watchChannel(_chan).first;

  test('a flood ENGAGES backpressure at the high-water mark, then RELEASES at '
      'the low-water mark — with no message loss', () async {
    // Wedge the writer so units enqueue but cannot settle → depth climbs.
    cache.gate = Completer<void>();

    // Emit 4 messages (> high-water 3). Delivery climbs depth to 3, where the
    // valve pauses the subs; the 4th is held (buffered), not dropped.
    for (var i = 0; i < 4; i++) {
      transport.emitMessage(_server('m$i'));
    }
    await pump();

    // Engaged exactly once, at the high-water mark.
    expect(spy.backpressure.where((t) => t.$1).toList(), [(true, 3)],
        reason: 'pause fires once, at depth == high-water');
    expect(spy.backpressure.any((t) => !t.$1), isFalse,
        reason: 'still wedged → not released yet');

    // Emit 3 MORE while paused. They buffer on the paused subs (no delivery, no
    // loss) — depth must NOT climb past the high-water mark.
    for (var i = 4; i < 7; i++) {
      transport.emitMessage(_server('m$i'));
    }
    await pump();
    expect(spy.backpressure.where((t) => t.$1).toList(), [(true, 3)],
        reason: 'paused: no further engage, depth stayed capped at high-water');

    // Release the writer → the queue drains, crosses the low-water mark, resumes.
    cache.gate!.complete();
    await pump();
    await pump();

    expect(spy.backpressure.last.$1, isFalse,
        reason: 'settled released, not stuck engaged');
    expect(spy.backpressure.where((t) => !t.$1).first, (false, 1),
        reason: 'resume fires at depth == low-water');

    // NO LOSS: every one of the 7 messages (incl. the ones emitted while paused)
    // landed in the cache. This is the correctness crux — pause never drops.
    final ids = (await rows()).map((m) => m.id).toSet();
    expect(ids, {'m0', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6'});
  });

  test('sub-threshold load never engages the valve', () async {
    // 2 messages, below the high-water of 3, no gate — handlers complete freely.
    transport.emitMessage(_server('a'));
    transport.emitMessage(_server('b'));
    await pump();

    expect(spy.backpressure, isEmpty,
        reason: 'never crossed high-water → valve silent');
    expect((await rows()).map((m) => m.id).toSet(), {'a', 'b'});
  });
}
