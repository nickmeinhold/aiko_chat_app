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

    test('a DENIAL does not permanently deafen the registrar — a later session '
        'edge asks again', () async {
      // Cage-match round 3, Carnot. A denial left the refresh subscription in
      // place, so start()'s idempotency guard made every later call a no-op —
      // and push permission changes OUT OF BAND, in system settings. A user who
      // declined and then enabled notifications was unreachable forever, with
      // nothing reporting a problem.
      source.granted = false;
      await registrar.start();
      expect(api.registeredDevices, isEmpty, reason: 'precondition');

      source.granted = true;
      await registrar.start();

      expect(source.permissionAsks, 2, reason: 'the next edge asks again');
      expect(api.registeredDevices.map((d) => d.token), ['tok-1']);
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
    test('unpair returns as soon as the DEBT is durable — it never waits for '
        'the network', () async {
      await registrar.start();
      final gate = Completer<void>();
      api.unregisterDeviceGate = gate.future;

      await registrar.unpair(credential: 'cred-a');

      // It has RETURNED while the DELETE is still in flight, which is the whole
      // point: the caller clears credentials on the next line. What it DID wait
      // for is the debt write — a local write, microseconds — because a debt
      // that only becomes durable in a later microtask is lost to a process kill
      // at exactly the moment it is needed.
      expect(api.unregisteredDevices, isEmpty);
      expect(pending.read(_island), [
        'tok-1',
      ], reason: 'and the debt is durable');

      gate.complete();
      await registrar.settled;
      expect(api.unregisteredDevices, ['tok-1']);
    });

    test('the credential is carried BY VALUE, not looked up — the whole reason '
        'the DELETE survives a cleared token store', () async {
      await registrar.start();

      await registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(api.unregisterCredentials, ['cred-a']);
    });

    test('sign-out unregisters the token the island ACTUALLY holds, not the '
        'one it was first given', () async {
      await registrar.start();
      source.refreshes.add('tok-2');
      await pumpEventQueue();

      await registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      // The bug this pins: unregistering 'tok-1' would leave 'tok-2' — the live
      // one — routing this account's pushes to a handset that has signed out.
      expect(api.unregisteredDevices, ['tok-2']);
    });

    test('the debt is written BEFORE the attempt, so an offline sign-out still '
        'owes it', () async {
      await registrar.start();
      api.unregisterDeviceThrows = Exception('offline');

      await registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(
        pending.read(_island),
        ['tok-1'],
        reason:
            'recording the debt only on failure would lose it in the two cases '
            'it exists for: an offline sign-out and a process killed in flight',
      );
    });

    test('a successful attempt discharges the debt immediately', () async {
      await registrar.start();

      await registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(pending.read(_island), isEmpty);
    });

    test(
      'no credential (already-dead session) still records the debt',
      () async {
        await registrar.start();

        await registrar.unpair();
        await registrar.settled;

        expect(api.unregisteredDevices, isEmpty);
        expect(pending.read(_island), ['tok-1']);
      },
    );

    test('unpair does not RETURN until the debt is durable', () async {
      // Cage-match round 4, Carnot. An earlier version returned synchronously and
      // wrote the debt in a later microtask — so a process kill or app suspension
      // between logout and that write lost the only retry record while the
      // credential was already gone. "Durability that exists only after a future
      // runs is not durability at teardown time."
      await registrar.start();

      final unpairing = registrar.unpair(credential: 'cred-a');
      expect(
        pending.read(_island),
        isEmpty,
        reason: 'precondition: the write really is in flight, not instant',
      );

      await unpairing;

      expect(pending.read(_island), ['tok-1']);
    });

    test('unpair without start is a no-op, not a spurious debt', () async {
      await registrar.unpair(credential: 'cred-a');
      await registrar.settled;

      expect(api.unregisteredDevices, isEmpty);
      expect(pending.read(_island), isEmpty);
    });

    test('after sign-out, a late rotation does NOT re-register — the stream is '
        'cancelled, not merely ignored', () async {
      await registrar.start();
      await registrar.unpair(credential: 'cred-a');
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

      await registrar.unpair(credential: 'cred-a');
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

      await registrar.unpair(credential: 'cred-a');
      gate.complete();
      await starting;
      await pumpEventQueue();

      expect(
        api.unregisteredDevices,
        isEmpty,
        reason: 'no inline DELETE — it could match the next session\'s row',
      );
      expect(pending.read(_island), ['tok-1']);
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
      expect(pending.read(_island), isEmpty);
    });

    test('a failed drain KEEPS the debt — an unreachable island is one we '
        'still owe', () async {
      await pending.remember(_island, 'tok-owed');
      api.unregisterDeviceThrows = Exception('offline');

      await registrar.drainPending();

      expect(pending.read(_island), ['tok-owed']);
    });

    test('a late unregister that lands on the LIVE pairing is REPAIRED', () async {
      // The straggler, round 4 (Carnot + Tesla, independently). The DELETE is
      // issued for a dead session, the same user signs back in and re-registers
      // the same token, and THEN the DELETE lands — matching (user_id, token)
      // and removing the live row. Ordering cannot fix it: Future.timeout does
      // not cancel the request, and the island offers no fencing token. So the
      // repair IS the contract — notice afterwards and put the row back.
      await registrar.start();
      final gate = Completer<void>();
      api.unregisterDeviceGate = gate.future;

      await registrar.unpair(credential: 'cred-a'); // DELETE now in flight
      await pumpEventQueue();

      await registrar.start(); // the same user returns, re-registers tok-1
      expect(registrar.registeredToken, 'tok-1', reason: 'precondition');
      expect(
        api.registeredDevices,
        hasLength(2),
        reason: 'and it is not held hostage by the in-flight straggler',
      );

      gate.complete(); // the straggling DELETE finally lands on the LIVE row
      await registrar.settled;
      await pumpEventQueue();

      expect(
        api.registeredDevices,
        hasLength(3),
        reason:
            'the pairing must be restored — otherwise the handset is silently '
            'unreachable, and a same-token refresh is a no-op so nothing ever '
            'notices',
      );
      expect(api.registeredDevices.last.token, 'tok-1');
    });

    test('no repair fires when the pairing has genuinely ended', () async {
      await registrar.start();
      final gate = Completer<void>();
      api.unregisterDeviceGate = gate.future;

      await registrar.unpair(credential: 'cred-a');
      await pumpEventQueue();
      gate.complete();
      await registrar.settled;

      expect(
        api.registeredDevices,
        hasLength(1),
        reason: 'nothing holds this token now, so there is nothing to restore',
      );
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
      expect(pending.read(_otherIsland), ['tok-elsewhere']);
    });

    test('registering a token discharges an older debt for it, so the next '
        'drain cannot delete the live row', () async {
      await pending.remember(_island, 'tok-1');

      await registrar.start();

      expect(registrar.registeredToken, 'tok-1');
      expect(pending.read(_island), isEmpty);
    });
  });

  group('the debt record itself', () {
    test('a SECOND debt for the same island does not evict the first — the '
        'single-slot memo bug', () async {
      // Cage-match round 3, Carnot. The store used to keep one token per island,
      // justified by "the device token is stable per install" — a premise the
      // file next door disproves, because start() explicitly handles ROTATION.
      // Sign out offline owing tok-1, rotate, sign out offline again, and the
      // overwrite meant tok-1's row on the island could never be drained by this
      // client. A ledger that silently drops entries is not a ledger.
      await pending.remember(_island, 'tok-1');
      await pending.remember(_island, 'tok-2');

      expect(pending.read(_island), ['tok-1', 'tok-2']);
    });

    test('the drain pays off EVERY owed token, not just the newest', () async {
      await pending.remember(_island, 'tok-1');
      await pending.remember(_island, 'tok-2');

      await registrar.drainPending();

      expect(api.unregisteredDevices, ['tok-1', 'tok-2']);
      expect(pending.read(_island), isEmpty);
    });

    test('one failed debt does not abandon the others', () async {
      await pending.remember(_island, 'tok-1');
      await pending.remember(_island, 'tok-2');
      var calls = 0;
      api.onUnregister = (_) {
        if (++calls == 1) throw Exception('transient');
      };

      await registrar.drainPending();

      expect(pending.read(_island), [
        'tok-1',
      ], reason: 'the failed one stays owed; the other is paid and cleared');
    });

    test('concurrent mutations do not lose an update — the ledger serializes '
        'its read-modify-write', () async {
      // Each mutation is read-map → mutate → write-map, so two overlapping ones
      // interleave and silently drop an entry. Fired together, not awaited in
      // turn, which is how a settling unpair and a discharging register meet.
      await Future.wait([
        pending.remember(_island, 'tok-a'),
        pending.remember(_island, 'tok-b'),
        pending.remember(_island, 'tok-c'),
      ]);

      expect(pending.read(_island).toList()..sort(), [
        'tok-a',
        'tok-b',
        'tok-c',
      ]);
    });

    test(
      'discharge removes only the named token — a NEWER debt is left alone',
      () async {
        await pending.remember(_island, 'tok-old');
        await pending.remember(_island, 'tok-new');

        // A drain of the old token completing late must not discharge the new one.
        await pending.forget(_island, 'tok-old');

        expect(pending.read(_island), ['tok-new']);
      },
    );

    test('debts for different islands coexist', () async {
      await pending.remember(_island, 'tok-a');
      await pending.remember(_otherIsland, 'tok-b');

      expect(pending.read(_island), ['tok-a']);
      expect(pending.read(_otherIsland), ['tok-b']);
    });

    test('a corrupt record reads as nothing owed rather than throwing — an '
        'unpayable debt must never brick a sign-in', () async {
      SharedPreferences.setMockInitialValues({
        'aiko_pending_device_unregisters': 'not json',
      });
      final store = PendingUnregisterStore(
        await SharedPreferences.getInstance(),
      );

      expect(store.read(_island), isEmpty);
    });

    test('the debt survives a new store instance — the point of it being '
        'durable rather than in-memory', () async {
      await pending.remember(_island, 'tok-1');

      final reopened = PendingUnregisterStore(
        await SharedPreferences.getInstance(),
      );

      expect(reopened.read(_island), ['tok-1']);
    });
  });
}
