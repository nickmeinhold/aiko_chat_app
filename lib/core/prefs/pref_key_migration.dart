/// Reading a preference across the 2026-09-02 island-vocabulary key rename.
///
/// The key IS the storage contract, so both island keys move in two steps: this
/// version reads the new key, falls back to the legacy one, and ADOPTS the value
/// forward under the new name. A later version deletes this file (task #25).
///
/// Adopt-on-read is what makes the migration terminate. The base URL is written
/// only when someone switches island, which most people never do, so a
/// read-without-adopt would leave those installs on the legacy key indefinitely
/// and the fallback could never be removed safely.
///
/// The legacy key is deliberately not deleted — it keeps a downgrade survivable
/// while both versions are in the wild.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// The island base URL, before the vocabulary reached the storage layer.
const kLegacyIslandBaseUrlPrefKey = 'aiko_gateway_base_url';

/// The ever-seen island set, same history.
const kLegacyKnownIslandsPrefKey = 'aiko_known_gateways';

/// Read [key]; failing that, adopt whatever [legacyKey] holds.
///
/// [isUsable] is the CALLER's definition of a real value — presence is not
/// usability (the island config rejects a blank string, the seed store rejects a
/// blob that will not parse), and without it this would keep or adopt a value the
/// caller would reject.
///
/// SAFE ONLY BECAUSE there is no `await` between the read and the write, and this
/// app has one [SharedPreferences] instance created in `main()` with no background
/// isolate. Add an isolate that touches preferences and this becomes a real race
/// in which a chosen island can be overwritten by the legacy value.
///
/// The forward write is fire-and-forget: a failure costs only that the next launch
/// migrates instead, and the value is returned either way.
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
