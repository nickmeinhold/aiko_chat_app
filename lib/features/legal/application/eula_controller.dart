/// EULA acceptance state — an [AsyncNotifier] over the [EulaStore], mirroring
/// the auth controller's async-restore-in-`build` shape so the router's redirect
/// can treat "acceptance still loading" exactly like "session still restoring"
/// (park on the splash, don't flash the gate).
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/eula_store.dart';

/// The persistence seam. Tests override this with a `FakeEulaStore`.
final eulaStoreProvider = Provider<EulaStore>((ref) => EulaStore());

/// The Terms text, loaded from the bundled asset. A provider so tests inject a
/// ready string (no real-async asset read racing `pumpAndSettle`); production
/// reads `assets/legal/eula.md`.
final eulaTextProvider = FutureProvider<String>(
  (ref) => rootBundle.loadString('assets/legal/eula.md'),
);

/// `false` until the current Terms are accepted on this device; flips to `true`
/// the moment [EulaAcceptanceController.accept] persists. The router watches
/// this and gates every route behind acceptance.
final eulaAcceptanceProvider =
    AsyncNotifierProvider<EulaAcceptanceController, bool>(
  EulaAcceptanceController.new,
);

class EulaAcceptanceController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref.read(eulaStoreProvider).hasAccepted();

  /// Record acceptance and publish it. The router's `refreshListenable` picks
  /// up the state change and redirects past the gate — no manual navigation.
  Future<void> accept() async {
    await ref.read(eulaStoreProvider).setAccepted();
    state = const AsyncData(true);
  }
}
