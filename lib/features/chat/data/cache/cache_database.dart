import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opens the [QueryExecutor] backing a [DriftCache].
///
/// Persistence is **per-user** by design. The local cache is the durable home
/// of message history AND the B4 reconnect watermark (`historyContiguousThrough`),
/// so it must survive an app restart — but it must NOT leak across users sharing
/// one device. A single shared file would do exactly that: user B logging in
/// would reopen user A's history (the Carnot C3 cross-session leak the in-memory
/// + autoDispose design previously dissolved). Keying the file on the user id
/// keeps both properties: each user's history persists across restarts, and no
/// user can ever read another's cache because they open different files.
///
/// A null [userId] (no authenticated session — e.g. a transient pre-login build)
/// gets an ephemeral in-memory database: nothing to persist, nothing to leak.
QueryExecutor openUserCache(String? userId) {
  if (userId == null) return NativeDatabase.memory();
  return LazyDatabase(() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'aiko_chat_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dir.path, _cacheFileName(userId)));
    return NativeDatabase.createInBackground(file);
  });
}

/// Derives a filesystem-safe cache filename from a user id. Server user ids are
/// ULIDs (Crockford base32 — already path-safe), but we never trust an id that
/// flows into a path: strip anything outside `[0-9A-Za-z_-]` so a malformed id
/// can't escape the cache directory. An id that sanitizes to empty falls back to
/// a constant bucket rather than a path that resolves to the directory itself.
String _cacheFileName(String userId) {
  final safe = userId.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
  return 'cache_${safe.isEmpty ? 'unknown' : safe}.sqlite';
}
