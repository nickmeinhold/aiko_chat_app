// Persistence + per-user isolation for the file-backed DriftCache (task #40).
//
// openUserCache() itself is thin path_provider glue (it needs Flutter bindings),
// so these tests exercise the PROPERTY that matters directly at the
// DriftCache + File level: a cache over a file survives being closed and
// reopened (messages AND the B4 watermark), and two different files never see
// each other's data (the per-user-keyed isolation that replaces the old
// in-memory + autoDispose C3 guarantee).

import 'dart:io';

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _alice =
    MessageSender(userId: 'u2', kind: SenderKind.human, label: 'Alice');

Message server(String ulid, String channel, String body,
        {MessageSender sender = _alice}) =>
    Message(
      clientTempId: ulid,
      id: ulid,
      channelId: channel,
      sender: sender,
      body: body,
      createdAt: DateTime.utc(2026, 1, 1, 12),
      deliveryState: DeliveryState.sent,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aiko_cache_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File dbFile(String name) => File('${tmp.path}/$name.sqlite');

  test('messages and the B4 watermark survive a close + reopen of the same file',
      () async {
    final file = dbFile('alice');

    // First "launch": write a server message and advance the contiguous-history
    // watermark, then close (drops the in-memory connection, flushes the file).
    final first = DriftCache(NativeDatabase(file));
    await first.upsertInbound(server('01ULID_A', 'general', 'persisted hello'));
    await first.advanceHistoryContiguous('general', '01ULID_A');
    await first.close();

    // Second "launch": a brand-new cache over the SAME file must see both.
    final second = DriftCache(NativeDatabase(file));
    addTearDown(second.close);

    final msgs = await second.watchChannel('general').first;
    expect(msgs.map((m) => m.id), ['01ULID_A'],
        reason: 'message must survive an app restart');
    expect(msgs.single.body, 'persisted hello');

    final fence = await second.historyContiguousThrough('general');
    expect(fence, '01ULID_A',
        reason: 'the reconnect-resume watermark must survive a restart — '
            'otherwise the B4 forward-fill has nothing to resume from');
  });

  test('two per-user files are isolated — no cross-user history leak', () async {
    final aCache = DriftCache(NativeDatabase(dbFile('userA')));
    addTearDown(aCache.close);
    final bCache = DriftCache(NativeDatabase(dbFile('userB')));
    addTearDown(bCache.close);

    await aCache.upsertInbound(server('01ULID_A', 'general', 'A secret'));

    // User B's separate file must not see user A's message (Carnot C3).
    final bMsgs = await bCache.watchChannel('general').first;
    expect(bMsgs, isEmpty,
        reason: 'a different user on the same device must never read another '
            "user's cached history");

    // And A still has its own.
    final aMsgs = await aCache.watchChannel('general').first;
    expect(aMsgs.map((m) => m.id), ['01ULID_A']);
  });
}
