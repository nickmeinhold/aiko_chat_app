/// Renaming a SharedPreferences key is a data migration, not a rename.
///
/// The key IS the storage contract: change the constant and every existing
/// install silently loses the value — for `aiko_gateway_base_url` that means
/// being moved back to the compiled-in default island without being told.
///
/// So both island keys move in two steps. This version READS the legacy key when
/// the new one is absent and immediately ADOPTS the value under the new name; a
/// later version deletes [readAndAdopt] and the legacy constants with it.
///
/// ADOPT-ON-READ IS THE PART THAT MAKES IT TERMINATE. Read-legacy/write-new alone
/// never finishes: `aiko_gateway_base_url` is only written when someone actually
/// switches island, which most people never do, so those installs would keep the
/// legacy key indefinitely and the fallback could never be removed safely. It
/// would LOOK complete — every new install clean — while the population that
/// would notice is the one still on the old key. Writing forward the first time
/// the value is read means one launch of any version carrying this file is
/// enough.
///
/// The legacy key is deliberately NOT deleted. It costs a few dozen bytes and it
/// keeps a downgrade survivable while both versions are in the wild.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// The island base URL, before ADR-0001's vocabulary reached the storage layer.
const kLegacyIslandBaseUrlPrefKey = 'aiko_gateway_base_url';

/// The ever-seen island set, same history.
const kLegacyKnownIslandsPrefKey = 'aiko_known_gateways';

/// Read [key]; failing that, adopt whatever [legacyKey] holds.
///
/// PRECONDITION, made explicit because a reviewer was right to ask (Carnot,
/// cage-match PR #173): this is a check-then-act — read the new key, then write
/// it — and it is safe here for two reasons that a future change could remove.
/// First, there is NO `await` between the read and the write, and Dart is
/// single-threaded, so nothing can interleave within an isolate. Second, this
/// app has exactly one `SharedPreferences` instance, created once in `main()`
/// and injected; there are no background isolates and no native writer.
///
/// Add a background isolate that touches preferences — a push handler, say — and
/// the second reason fails, and this becomes a real race in which a person's
/// chosen island can be overwritten by the legacy value. The finding was
/// rejected on today's code, not on the shape of the code.
///
/// The forward write is fire-and-forget: persistence here is best-effort, and a
/// failure costs only that the next launch migrates instead. Returns the value
/// either way, so a write failure never changes what this launch sees.
/// [isUsable] decides what counts as a real value, and it exists because a
/// reviewer pointed out that this helper was answering a WEAKER question than
/// its callers ask (Carnot, cage-match PR #173). Presence is not usability: the
/// island config rejects a blank string, and the seed store rejects a blob that
/// will not parse, so "the new key exists" and "the new value is usable" are two
/// different predicates — and migration policy was being decided with the wrong
/// one. No path in today's code reaches the gap, because the only things ever
/// written to the new key are a legacy value or a real island URL. The gap was
/// in the design regardless, and the fix is to let the caller state the rule
/// rather than to guard the case.
String? readAndAdopt(
  SharedPreferences prefs, {
  required String key,
  required String legacyKey,
  bool Function(String)? isUsable,
}) {
  final usable = isUsable ?? (v) => true;

  final current = prefs.getString(key);
  if (current != null && usable(current)) return current;

  final legacy = prefs.getString(legacyKey);
  if (legacy == null || !usable(legacy)) return current;

  unawaited(prefs.setString(key, legacy).catchError((_) => false));
  return legacy;
}
