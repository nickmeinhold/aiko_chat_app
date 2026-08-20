// The push pairing's lifecycle. Every case here is a SILENCE bug if it regresses
// — the island keeps a token the push service refuses to deliver to, and nothing
// raises. There is no observable symptom short of "the call never arrived", so
// the assertions are the only alarm.
//
// The debt half is tested against the REAL PendingUnregisterStore over mock
// SharedPreferences rather than a hand-rolled fake. A fake would be free to be
// more forgiving than the real thing about the two properties that matter here
// — that a write lands before any attempt, and that discharge is a
// compare-and-clear — which is exactly the class of bug this suite exists for.
import 'dart:async';

import 'package:aiko_chat_app/features/notifications/application/device_registrar.dart';
import 'package:aiko_chat_app/features/notifications/data/pending_unregister_store.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_token_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/ui_fakes.dart';

const _island = 'https://island.example';
const _otherIsland = 'https://elsewhere.example';

class _FakeSource implements PushTokenSource {
  bool granted = true;
  String? token = 'tok-1';
  final refreshes = StreamController<String>.broadcast();
  int permissionAsks = 0;

  /// Held open to keep a start() suspended inside the permission prompt, so a
  /// test can unpair while the OS sheet is notionally up.
  Completer<void>? permissionGate;

  @override
  DevicePlatform get platform => DevicePlatform.apns;

  @override
  Future<bool> requestPermission() async {
    permissionAsks++;
    if (permissionGate != null) await permissionGate!.future;
    return granted;
  }

  @override
  Future<String?> currentToken() async => token;

  @override
  Stream<String> tokenRefreshes() => refreshes.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRestApi api;
  late _FakeSource source;
  late PendingUnregisterStore pending;
  late DeviceRegistrar registrar;

  DeviceRegistrar build({String island = _island}) => DeviceRegistrar(
    source: source,
    api: api,
    pending: pending,
    islandBaseUrl: island,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = FakeRestApi();
    source = _FakeSource();
    pending = PendingUnregisterStore(await SharedPreferences.getInstance());
    registrar = build();
  });

  tearDown(() => source.refreshes.close());

  group('registering', () {
    test(
      'sign-in registers the current token with its own transport',
      () async {
        await registrar.start();

        expect(api.registeredDevices, [
          (platform: DevicePlatform.apns, token: 'tok-1'),
        ]);
      },
    );

    test(
      'a refused permission registers NOTHING — a denial is an answer, not a '
      'failure to route around',
      () async {
        source.granted = false;

        await registrar.start();

        expect(api.registeredDevices, isEmpty);
      },
    );

    test(
      'a rotated token is registered — the case that fails silently',
      () async {
        await registrar.start();

        source.refreshes.add('tok-2');
        await pumpEventQueue();

        expect(api.registeredDevices.map((d) => d.token), ['tok-1', 'tok-2']);
      },
    );

    test(
      'an unchanged token is not re-registered on every refresh event',
      () async {
        await registrar.start();

        source.refreshes.add('tok-1');
        await pumpEventQueue();

        expect(api.registeredDevices, hasLength(1));
      },
    );

    test('a registration failure does not throw — it degrades reach, and '
        'sign-in must not fail because a push service was down', () async {
      api.registerDeviceThrows = Exception('APNs unreachable');

      await expectLater(registrar.start(), completes);
      expect(
        registrar.registeredToken,
        isNull,
        reason:
            'a failed register must not be recorded as landed, or the next '
            'sign-in will skip it and the device stays unreachable forever',
      );
    });

    test('start is idempotent — a second call does not double-subscribe or '
        're-ask for permission', () async {
      await registrar.start();
      await registrar.start();

      expect(source.permissionAsks, 1);

      source.refreshes.add('tok-2');
      await pumpEventQueue();
      // Two subscriptions would register the rotation twice.
      expect(
        api.registeredDevices.where((d) => d.token == 'tok-2'),
        hasLength(1),
      );
    });
  });

  group('unpairing is a debt, not a round trip', () {
    test('unpair returns before ANY network work — this is what lets the '
        'credential clear run on the very next line', () async {
      await registrar.start();

      registrar.unpair(credential: 'cred-a');

      // Synchronously after the call returns, nothing has been sent. If unpair
      // ever became something a caller had to await, the window that three
      // rounds of guards failed to close would be back.
      expect(api.unregisteredDevices, isEmpty);

      await registrar.settled;
      expect(api.unregisteredDevices, ['tok-1']);
    });

    test('the credential is carried BY VALUE, not looked up — the whole reason '
        'the DELETE survives a cleared token store', () async {
      await registrar.start();

      registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(api.unregisterCredentials, ['cred-a']);
    });

    test('sign-out unregisters the token the island ACTUALLY holds, not the '
        'one it was first given', () async {
      await registrar.start();
      source.refreshes.add('tok-2');
      await pumpEventQueue();

      registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      // The bug this pins: unregistering 'tok-1' would leave 'tok-2' — the live
      // one — routing this account's pushes to a handset that has signed out.
      expect(api.unregisteredDevices, ['tok-2']);
    });

    test('the debt is written BEFORE the attempt, so an offline sign-out still '
        'owes it', () async {
      await registrar.start();
      api.unregisterDeviceThrows = Exception('offline');

      registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(
        pending.read(_island),
        'tok-1',
        reason:
            'recording the debt only on failure would lose it in the two cases '
            'it exists for: an offline sign-out and a process killed in flight',
      );
    });

    test('a successful attempt discharges the debt immediately', () async {
      await registrar.start();

      registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(pending.read(_island), isNull);
    });

    test(
      'no credential (already-dead session) still records the debt',
      () async {
        await registrar.start();

        registrar.unpair();
        await registrar.settled;

        expect(api.unregisteredDevices, isEmpty);
        expect(pending.read(_island), 'tok-1');
      },
    );

    test('unpair without start is a no-op, not a spurious debt', () async {
      registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(api.unregisteredDevices, isEmpty);
      expect(pending.read(_island), isNull);
    });

    test('after sign-out, a late rotation does NOT re-register — the stream is '
        'cancelled, not merely ignored', () async {
      await registrar.start();
      registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      source.refreshes.add('tok-late');
      await pumpEventQueue();

      expect(
        api.registeredDevices.map((d) => d.token),
        isNot(contains('tok-late')),
        reason:
            'a signed-out app that re-registers on rotation resurrects push '
            'routing for an account nobody is signed in to',
      );
    });

    test('an unpair DURING the permission prompt is seen by the registration '
        'that follows it', () async {
      // The round-2 bug, RED-proven: the generation used to be sampled AFTER
      // this await, so an unpair while the OS sheet was up was invisible and the
      // previous account's token went to the island under a dead session.
      source.permissionGate = Completer<void>();
      final starting = registrar.start();

      registrar.unpair(credential: 'cred-a');
      source.permissionGate!.complete();
      await starting;
      await registrar.settled;

      expect(api.registeredDevices, isEmpty);
    });

    test('a registration that LANDS after sign-out owes a debt instead of '
        'deleting inline', () async {
      // The other round-2 bug. An inline undo unregisters by token, and the
      // token is stable per install — so by the time it completed it could be
      // matching a row the NEXT session had registered, deleting a live pairing
      // to tidy up a dead one. As a debt it is safe by ordering instead.
      final gate = Completer<void>();
      api.registerDeviceGate = gate.future;
      final starting = registrar.start();
      await pumpEventQueue();

      registrar.unpair(credential: 'cred-a');
      gate.complete();
      await starting;
      await pumpEventQueue();

      expect(
        api.unregisteredDevices,
        isEmpty,
        reason: 'no inline DELETE — it could match the next session\'s row',
      );
      expect(pending.read(_island), 'tok-1');
    });
  });

  group('draining the debt', () {
    test('drain pays the island back and clears the record', () async {
      await pending.remember(_island, 'tok-owed');

      await registrar.drainPending();

      expect(api.unregisteredDevices, ['tok-owed']);
      expect(
        api.unregisterCredentials,
        [null],
        reason:
            'the drain runs inside a live session, so the interceptor resolves '
            'the credential — carrying one by value would be the teardown path',
      );
      expect(pending.read(_island), isNull);
    });

    test('a failed drain KEEPS the debt — an unreachable island is one we '
        'still owe', () async {
      await pending.remember(_island, 'tok-owed');
      api.unregisterDeviceThrows = Exception('offline');

      await registrar.drainPending();

      expect(pending.read(_island), 'tok-owed');
    });

    test('a re-register waits for the previous unpair to SETTLE — the one way '
        'the two halves could still cross', () async {
      // Found by checking the fixes against each other rather than against the
      // defect each repairs. Sign out (the DELETE goes out slowly), sign back in
      // as the same user: the drain and the re-register both complete, and then
      // the straggling DELETE lands on the row we just created. Silent
      // unreachability — the exact class this change exists to remove.
      await registrar.start();
      final gate = Completer<void>();
      api.unregisterDeviceGate = gate.future;

      registrar.unpair(credential: 'cred-a'); // DELETE now hanging
      await pumpEventQueue();

      final restarting = registrar.start(); // the same user signs back in
      await pumpEventQueue();

      expect(
        api.registeredDevices,
        hasLength(1),
        reason:
            'the re-register must NOT have happened yet — it is ordered after '
            'the outstanding unpair, so the straggler cannot overtake it',
      );

      gate.complete();
      await restarting;
      await pumpEventQueue();

      expect(api.registeredDevices, hasLength(2));
      expect(
        api.unregisteredDevices,
        ['tok-1'],
        reason: 'and the DELETE landed BEFORE that second register, not after',
      );
      expect(registrar.registeredToken, 'tok-1');
    });

    test('drain with nothing owed sends nothing', () async {
      await registrar.drainPending();

      expect(api.unregisteredDevices, isEmpty);
    });

    test('a debt owed to ANOTHER island is not paid here — after a gateway '
        'switch the DELETE would be addressed to the wrong island', () async {
      await pending.remember(_otherIsland, 'tok-elsewhere');

      await registrar.drainPending();

      expect(api.unregisteredDevices, isEmpty);
      expect(pending.read(_otherIsland), 'tok-elsewhere');
    });

    test('registering a token discharges an older debt for it, so the next '
        'drain cannot delete the live row', () async {
      await pending.remember(_island, 'tok-1');

      await registrar.start();

      expect(registrar.registeredToken, 'tok-1');
      expect(pending.read(_island), isNull);
    });
  });

  group('the debt record itself', () {
    test(
      'discharge is a compare-and-clear — a NEWER debt is left alone',
      () async {
        await pending.remember(_island, 'tok-old');
        await pending.remember(_island, 'tok-new');

        // A drain of the old token completing late must not discharge the new one.
        await pending.forget(_island, 'tok-old');

        expect(pending.read(_island), 'tok-new');
      },
    );

    test('debts for different islands coexist', () async {
      await pending.remember(_island, 'tok-a');
      await pending.remember(_otherIsland, 'tok-b');

      expect(pending.read(_island), 'tok-a');
      expect(pending.read(_otherIsland), 'tok-b');
    });

    test('a corrupt record reads as nothing owed rather than throwing — an '
        'unpayable debt must never brick a sign-in', () async {
      SharedPreferences.setMockInitialValues({
        'aiko_pending_device_unregisters': 'not json',
      });
      final store = PendingUnregisterStore(
        await SharedPreferences.getInstance(),
      );

      expect(store.read(_island), isNull);
    });

    test('the debt survives a new store instance — the point of it being '
        'durable rather than in-memory', () async {
      await pending.remember(_island, 'tok-1');

      final reopened = PendingUnregisterStore(
        await SharedPreferences.getInstance(),
      );

      expect(reopened.read(_island), 'tok-1');
    });
  });
}
