/// Device-level persistence of "this device has accepted the current Terms".
///
/// Deliberately NOT account-scoped: the acceptance gate runs *before* sign-in
/// (a fresh install must show the Terms to a reviewer who has no account yet),
/// so acceptance is a property of the device, stored in plain
/// [SharedPreferences] — it is not a secret and never leaves the device.
///
/// The key is **versioned** (`_v1`). A material revision of the Terms bumps the
/// suffix, which makes [hasAccepted] return false for everyone until they accept
/// the new text — re-gating without a migration. Tests fake this at the seam
/// (see `FakeEulaStore`), the same way [SecureTokenStore] is faked.
library;

import 'package:shared_preferences/shared_preferences.dart';

class EulaStore {
  static const _key = 'aiko_eula_accepted_v1';

  /// Whether the current Terms have been accepted on this device.
  Future<bool> hasAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// Record acceptance of the current Terms.
  Future<void> setAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}
