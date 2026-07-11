import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The offline-first channel-list cache (task #19): saveChannels/readChannels
/// round-trip, and the authoritative full-replace semantics (a channel the user
/// can no longer see must vanish from the cache, not linger as a tombstone).
void main() {
  late DriftCache cache;

  setUp(() => cache = DriftCache(NativeDatabase.memory()));
  tearDown(() => cache.close());

  const general =
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard);
  const llm = Channel(
      id: 'c2', name: 'aiko', kind: ChannelKind.llm, aikoChannel: 'bus/aiko');

  test('empty cache reads back as an empty list', () async {
    expect(await cache.readChannels(), isEmpty);
  });

  test('save then read round-trips every field', () async {
    await cache.saveChannels([general, llm]);
    final read = await cache.readChannels();
    expect(read, containsAll([general, llm]));
    expect(read.length, 2);
  });

  test('save is an AUTHORITATIVE full replace (dropped channels vanish)',
      () async {
    await cache.saveChannels([general, llm]);
    await cache.saveChannels([general]); // llm no longer visible server-side
    final read = await cache.readChannels();
    expect(read, [general]);
    expect(read.contains(llm), isFalse,
        reason: 'a gone channel must not linger as a stale local row');
  });
}
