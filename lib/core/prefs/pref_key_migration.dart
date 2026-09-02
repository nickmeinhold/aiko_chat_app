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
/// The forward write is fire-and-forget: persistence here is best-effort, and a
/// failure costs only that the next launch migrates instead. Returns the value
/// either way, so a write failure never changes what this launch sees.
String? readAndAdopt(
  SharedPreferences prefs, {
  required String key,
  required String legacyKey,
}) {
  final current = prefs.getString(key);
  if (current != null) return current;

  final legacy = prefs.getString(legacyKey);
  if (legacy == null) return null;

  unawaited(prefs.setString(key, legacy).catchError((_) => false));
  return legacy;
}
