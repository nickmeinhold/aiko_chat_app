// `reconcileInstallId` — the door that closes the sealed-Keychain gap.
//
// WHY IT EXISTS. The Keychain is sealed until the first unlock after boot, so a
// VoIP wake on a just-booted handset registers with no `install_id`. Nothing
// asks again on its own: `_register` returns at its skip-if-same guard, and a
// foreground tap is a RESUME, not a rebirth — same process, same registrar,
// same `_registered` (cage-match round 2, Tesla). Without this the row stays
// id-less until jetsam.
//
// THE NEGATIVE CASES CARRY THE WEIGHT. A door that restates when it should not
// is a second defect wearing a fix's coat: it would put a third writer on a
// path whose whole design is single-writer, and on a CHANGED id it would
// quietly propagate an anomaly that means two ids exist for one handset.

import 'package:aiko_chat_app/features/notifications/application/device_registrar.dart';
import 'package:aiko_chat_app/features/notifications/data/pending_unregister_store.dart';
import 'package:aiko_chat_app/features/notifications/domain/install_id_source.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/ui_fakes.dart';
import 'install_id_test_support.dart';

/// A source whose answer a test can change between calls — the sealed-then-open
/// Keychain, at the level the registrar sees it.
class _MutableSource implements InstallIdSource {
  _MutableSource(this.value);
  String? value;
  int asks = 0;

  @override
  Future<String?> installId() async {
    asks++;
    await Future<void>.delayed(Duration.zero);
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRestApi api;
  late PendingUnregisterStore pending;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = FakeRestApi();
    pending = PendingUnregisterStore(await SharedPreferences.getInstance());
  });

  DeviceRegistrar build(InstallIdSource ids) => DeviceRegistrar(
    source: FixedTokenSource(kind: TokenKind.alert, token: 'tok-1'),
    api: api,
    pending: pending,
    islandBaseUrl: 'https://island.example',
    installIds: ids,
  );

  test('a sealed-then-open Keychain re-registers with the id', () async {
    final ids = _MutableSource(null);
    final registrar = build(ids);
    await registrar.start();
    expect(api.registeredInstallIds, [null], reason: 'booted locked');

    ids.value = 'ID-1';
    await registrar.reconcileInstallId();
    // Settling is scheduled through `_restate`, which fires unawaited.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.registeredInstallIds, [null, 'ID-1']);
    expect(api.liveRows, {'tok-1'}, reason: 'same row, restated');
  });

  test('no restate when the row already carries the id', () async {
    final ids = _MutableSource('ID-1');
    final registrar = build(ids);
    await registrar.start();
    expect(api.registeredInstallIds, ['ID-1']);

    await registrar.reconcileInstallId();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A pointless POST is not harmless here: it is a third writer on a
    // single-writer path, and it re-opens the in-flight window for nothing.
    expect(api.registeredInstallIds, ['ID-1'], reason: 'nothing to fill');
  });

  test('no restate when the source still has nothing', () async {
    final ids = _MutableSource(null);
    final registrar = build(ids);
    await registrar.start();

    await registrar.reconcileInstallId();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.registeredInstallIds, [null]);
  });

  // A CHANGED id is an anomaly, not an update. An install id is stable for the
  // life of the install, so `A -> B` means two ids exist for one handset —
  // exactly the split this field was built to prevent. Restating would
  // propagate it silently; the door refuses and the telemetry says so.
  test('a CHANGED id is refused, not restated', () async {
    final ids = _MutableSource('ID-1');
    final registrar = build(ids);
    await registrar.start();
    expect(api.registeredInstallIds, ['ID-1']);

    ids.value = 'ID-2';
    await registrar.reconcileInstallId();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      api.registeredInstallIds,
      ['ID-1'],
      reason: 'an anomaly is surfaced, never propagated',
    );
  });

  test('nothing registered yet is left to start()', () async {
    final ids = _MutableSource('ID-1');
    final registrar = build(ids);

    await registrar.reconcileInstallId();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.registeredInstallIds, isEmpty);
    expect(ids.asks, 0, reason: 'returns before it even asks the source');
  });
}
