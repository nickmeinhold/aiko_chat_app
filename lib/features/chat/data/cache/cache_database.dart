import 'dart:convert';
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
    final file = File(p.join(dir.path, cacheFileName(userId)));
    return NativeDatabase.createInBackground(file);
  });
}

/// Derives a filesystem-safe, **injective** cache filename from a user id.
///
/// Injectivity IS the isolation guarantee: distinct user ids MUST map to
/// distinct files, or one user could open another's cache (the Carnot C3 leak
/// this whole design prevents). We hex-encode the raw UTF-8 bytes of the id — a
/// 1:1, reversible transform. Critically this is collision-free where the
/// obvious alternatives are not:
///   - strip-the-bad-chars is many-to-one: `a/b` and `ab` both reduce to `ab`,
///     and any two ids that sanitize to empty share one bucket — silently
///     fusing two users' caches;
///   - base64url is injective but case-sensitive, so on a case-insensitive
///     filesystem (macOS/APFS default) two ids can still collide by case-fold.
/// Hex output is always lowercase `[0-9a-f]`: injective, path-safe, never empty
/// for a non-empty id, and stable across case-insensitive filesystems.
String cacheFileName(String userId) {
  final hex = utf8
      .encode(userId)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'cache_$hex.sqlite';
}
