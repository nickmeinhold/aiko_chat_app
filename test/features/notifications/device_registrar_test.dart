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

import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
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

    test('an OBSERVED over-delete is restored — the straggler signals the live '
        'door, it does not POST from the DELETE path', () async {
      // The straggler, round 4 (Carnot + Tesla, independently). The DELETE is
      // issued for a dead session, the same user signs back in and re-registers
      // the same token, and THEN the DELETE lands — matching (user_id, token)
      // and removing the live row. Ordering cannot fix it: Future.timeout does
      // not cancel the request, and the island offers no fencing token.
      //
      // Round 5 answered this by POSTing from _attemptUnregister itself. That
      // was defect five (below): a write issued from a dead session's path, on
      // a check sampled before its own await. Cast 3 keeps the OUTCOME and
      // changes the ISSUER — the straggler's completion signals the live door,
      // which restates the current pairing at the CURRENT generation.
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

    test('DEFECT FIVE: a restore that lands after the session ended owes a '
        'DELETE — it does not leave a routable row behind', () async {
      // THE ACCEPTANCE TEST FOR THIS WHOLE DESIGN. Round 5's repair checked
      // `_registered != token` BEFORE its await and never again, so a logout
      // inside the restore POST's flight re-created a routable row for a
      // signed-out handset — the exact outcome the feature exists to prevent,
      // produced by the mechanism added to prevent it.
      //
      // RED-PROOF: run this against e5d7c01 and the debt is empty, because the
      // repair had no tail at all.
      await registrar.start();
      final deleteGate = Completer<void>();
      api.unregisterDeviceGate = deleteGate.future;
      await registrar.unpair(credential: 'cred-a');
      await pumpEventQueue();

      await registrar.start(); // same user back; tok-1 is live again
      final restoreGate = Completer<void>();
      api.registerDeviceGate = restoreGate.future;

      deleteGate.complete(); // straggler lands on the live row -> restore fires
      await pumpEventQueue();

      // ...and the session ends while that restore is still on the wire.
      api.unregisterDeviceGate = null;
      await registrar.unpair(credential: 'cred-b');
      await registrar.settled;
      await pumpEventQueue();
      expect(
        pending.read(_island),
        isEmpty,
        reason:
            'precondition: the second unpair paid its own debt, so nothing is '
            'owed at the moment the straggling restore lands',
      );

      restoreGate.complete(); // the restore finally lands, into a dead session
      await pumpEventQueue();

      expect(
        pending.read(_island),
        contains('tok-1'),
        reason:
            'the restore may have created a row for a handset nobody is signed '
            'in to. It must be OWED a delete, not assumed harmless — nothing '
            'else in the system will ever notice it',
      );
    });

    test('a restore reaches the wire even though the token is UNCHANGED — '
        'skip-if-same is an optimisation, not a wall', () async {
      // Carnot and Tesla, round 2, independently. `_register` returned BEFORE
      // the wire when `token == _registered`, which is exactly the steady state
      // a restatement exists to restate. An invariant a restore cannot enter is
      // prose, not a door.
      //
      // RED-PROOF: drop the `force` flag and this reads 2, not 3 — the restore
      // is silently swallowed and the handset stays deaf.
      await registrar.start();
      final gate = Completer<void>();
      api.unregisterDeviceGate = gate.future;
      await registrar.unpair(credential: 'cred-a');
      await pumpEventQueue();
      await registrar.start();

      expect(
        registrar.registeredToken,
        'tok-1',
        reason: 'precondition: same token',
      );

      gate.complete();
      await registrar.settled;
      await pumpEventQueue();

      expect(api.registeredDevices.map((d) => d.token), [
        'tok-1',
        'tok-1',
        'tok-1',
      ]);
    });

    test('no restore fires when the pairing has genuinely ended', () async {
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

  // The far side of every POST. Round 2 of the design temper found the invariant
  // was incomplete in three separate ways, each traced to a defect rather than
  // imagined: it fired only on SUCCESS, it tested only the SESSION and not the
  // TOKEN, and its single remedy (owe a delete) is the WRONG one when a late
  // POST reassigned a live row away from the user who now owns it.
  group('the register invariant — the check on the far side', () {
    test('a register that LANDS and then throws, after the session ended, owes '
        'a debt — "it threw" is not "nothing happened"', () async {
      // The one real insight in round 5's repair branch, nearly thrown out with
      // it. A POST whose response was lost may still have written the row, so an
      // ambiguous failure must fail toward deletion.
      //
      // RED-PROOF: handle only the success path and the debt is empty.
      await registrar.start();
      final gate = Completer<void>();
      api.registerDeviceGate = gate.future;
      api.registerDeviceThrowsAfterLanding = Exception('response lost');

      source.refreshes.add('tok-2'); // a rotation puts a POST on the wire
      await pumpEventQueue();

      await registrar.unpair(credential: 'cred-a'); // session ends mid-POST
      await registrar.settled;
      await pumpEventQueue();

      gate.complete();
      await pumpEventQueue();

      expect(
        pending.read(_island),
        contains('tok-2'),
        reason:
            'the island may hold tok-2 for a session that has ended, and no '
            'later event re-examines a POST that threw',
      );
    });

    test('a register REJECTED before it could write owes nothing — the remedy '
        'follows what the write DID, not merely that it failed', () async {
      // The control for the test above. Without it, "owe a debt on every
      // failure" passes just as well, and a debt for a row that was never
      // created is a DELETE aimed at whatever holds that token next.
      await registrar.start();
      final gate = Completer<void>();
      api.registerDeviceGate = gate.future;
      api.registerDeviceThrows = Unauthorized(401);

      source.refreshes.add('tok-2');
      await pumpEventQueue();
      await registrar.unpair(credential: 'cred-a');
      await registrar.settled;
      await pumpEventQueue();
      gate.complete();
      await pumpEventQueue();

      expect(
        pending.read(_island),
        isNot(contains('tok-2')),
        reason: 'the island rejected this before writing anything',
      );
    });

    test('a register in flight across a ROTATION does not roll the pairing '
        'back — generation alone cannot see this', () async {
      // Tesla, round 2. `_generation` answers session liveness, not token
      // currency: a POST for tok-1 in flight while the platform rotates to
      // tok-2 lands with the generation STILL MATCHING. If the tail accepts it,
      // `_registered` rolls back to the stale token, `unpair` then owes the
      // wrong one, and tok-2's row routes to a handset nobody can clear.
      //
      // RED-PROOF: test the generation only, and registeredToken reads 'tok-1'.
      source.token = 'tok-1';
      final gate = Completer<void>();
      api.registerDeviceGate = gate.future;
      final first = registrar.start(); // tok-1's POST goes on the wire
      await pumpEventQueue();

      api.registerDeviceGate = null;
      source.refreshes.add('tok-2'); // rotation lands FIRST
      await pumpEventQueue();

      gate.complete(); // now tok-1's straggling POST completes
      await first;
      await pumpEventQueue();

      expect(
        registrar.registeredToken,
        'tok-2',
        reason:
            'the newer token is the desired one; a straggler cannot undo it',
      );
      expect(
        pending.read(_island),
        contains('tok-1'),
        reason:
            'tok-1 may have been written and nobody wants it — fail toward '
            'deletion for a row that is merely STALE',
      );
    });

    test('a late POST that REASSIGNS a live row is answered by restating it, '
        'not by owing a delete', () async {
      // The finding that corrected the governing principle (Tesla, round 2).
      // `register_device` upserts on UNIQUE(token) and REASSIGNS user_id, so a
      // POST crossing a logout does not linger — it takes the row BACK from
      // whoever owns it now. A DELETE cannot undo that: `unregister` matches
      // (user_id, token), and the current session's credential no longer
      // matches the row. Only a POST from the CURRENT session reclaims it.
      //
      // The in-flight POST here is a RESTATEMENT, because that is the only way
      // one exists: an ordinary refresh of an unchanged token never reaches the
      // wire, which is the whole reason `force` had to exist.
      //
      // RED-PROOF: send this case to `remember` like any other stale POST and
      // the count does not move — the previous owner keeps the handset.
      await registrar.start();
      final deleteGate = Completer<void>();
      api.unregisterDeviceGate = deleteGate.future;
      await registrar.unpair(credential: 'cred-a');
      await pumpEventQueue();
      await registrar.start();

      // The straggler lands on the live pairing and the live door restates it.
      final restateGate = Completer<void>();
      api.registerDeviceGate = restateGate.future;
      api.unregisterDeviceGate = null;
      deleteGate.complete();
      await registrar.settled;
      await pumpEventQueue();

      // That restatement is still on the wire when the session ends...
      await registrar.unpair(credential: 'cred-b');
      await registrar.settled;
      await pumpEventQueue();

      // ...and the next user signs in and takes tok-1 for themselves.
      api.registerDeviceGate = null;
      await registrar.start();
      expect(registrar.registeredToken, 'tok-1', reason: 'precondition');
      final beforeLanding = api.registeredDevices.length;

      restateGate.complete(); // the straggler lands and reassigns the row away
      await pumpEventQueue();

      expect(
        api.registeredDevices.length,
        beforeLanding + 2,
        reason:
            'TWO, and counting only one is how this test was void: completing '
            'the gate records the straggler MID-FLIGHT REGISTER itself (+1), '
            'which happens whatever the remedy is. The restatement is the '
            'SECOND (+1) — otherwise the previous owner\'s notifications ride '
            'this handset until the next sign-in, and no DELETE this session '
            'can issue will match the row',
      );
      expect(api.registeredDevices.last.token, 'tok-1');
      expect(
        pending.read(_island),
        isNot(contains('tok-1')),
        reason:
            'and it must NOT also be owed a delete — the restatement made this '
            'row ours, so a debt would drain at the next sign-in and remove it',
      );
    });
  });

  // A register is an OBLIGATION from the moment it is on the wire. Both of these
  // were found by the cage-match (Carnot, P1 x2) reading the real checkout, and
  // both are silent in production: the island keeps routing to a handset nobody
  // is signed in to, and nothing anywhere raises.
  group('the register write-ahead obligation', () {
    test('a register that LANDS then throws in a LIVE session is still owed at '
        'the next logout — a lost response never tells us it landed', () async {
      // `_registered` is set on CONFIRMED success only, and `unpair` owes what
      // `_registered` names. So before the write-ahead, a POST that wrote the row
      // and then lost its response left `_registered` null, and the logout that
      // followed recorded NOTHING.
      //
      // RED-PROOF: drop the remember() before the POST and the debt is empty.
      api.registerDeviceThrowsAfterLanding = Exception('response lost');
      await registrar.start();
      expect(
        registrar.registeredToken,
        isNull,
        reason: 'precondition: an ambiguous register is not recorded as landed',
      );

      await registrar.unpair(credential: 'cred-a');
      await pumpEventQueue();

      expect(
        pending.read(_island),
        contains('tok-1'),
        reason:
            'the island may hold tok-1 for a session that has just ended, and '
            'the only thing that could ever have known is gone',
      );
    });

    test('a logout while the FIRST registration is still in flight leaves a '
        'DURABLE debt — not one that depends on the POST coming back', () async {
      // The PR claims the debt is durable before the credential clear. It was
      // not, for a register still on the wire: `unpair` read a null
      // `_registered`, recorded nothing and returned, and only the eventual
      // `_settle` remembered anything. A process kill or app suspension in that
      // interval is exactly the failure the debt record exists to survive.
      //
      // RED-PROOF: drop the remember() before the POST and this reads empty —
      // the debt only appears after the gate is completed.
      final gate = Completer<void>();
      api.registerDeviceGate = gate.future;
      unawaited(registrar.start());
      await pumpEventQueue();
      expect(api.registeredDevices, isEmpty, reason: 'precondition: in flight');

      await registrar.unpair(credential: 'cred-a');

      expect(
        pending.read(_island),
        contains('tok-1'),
        reason:
            'durable NOW, with the POST still on the wire — a kill here must not '
            'lose the only record that this island may hold a row',
      );
      gate.complete();
      await pumpEventQueue();
    });

    test('epoch-only staleness inside ONE session does not restate — only a '
        'session edge can reassign a row', () async {
      // Maxwell's own finding. A reassignment needs a DIFFERENT user's credential
      // to have posted; two registers racing inside one session both belong to
      // the same user, so the newer one already owns the row and restating is a
      // pointless round trip under a log line that is not true.
      //
      // RED-PROOF: widen the branch back to `if (_registered == token)` and the
      // count goes to 3 — a spurious restatement.
      await registrar.start();
      final gate = Completer<void>();
      api.registerDeviceGate = gate.future;
      source.refreshes.add('tok-2'); // an older register goes on the wire
      await pumpEventQueue();

      api.registerDeviceGate = null;
      source.refreshes.add('tok-2'); // superseded by a newer one, same session
      await pumpEventQueue();
      final before = api.registeredDevices.length;

      gate.complete(); // the older one lands, stale by EPOCH but not generation
      await pumpEventQueue();

      expect(
        api.registeredDevices.length,
        before + 1,
        reason:
            'ONE — the straggler\'s own landing, which completing the gate '
            'records whatever the remedy is. A second would be a restatement, '
            'and there is nothing to restate: same session, same user, same '
            'token, so nothing was taken. (Asserting == before instead makes '
            'this test unsatisfiable — the same void-test trap the reassignment '
            'case hit.)',
      );
      expect(
        pending.read(_island),
        isNot(contains('tok-2')),
        reason:
            'and the LIVE token must not be owed a delete — that would aim the '
            'next drain at the pairing we just confirmed',
      );
    });
  });

  group('a restatement must not fight a rotation', () {
    test('a straggling DELETE does NOT restate over a register already in '
        'flight — that would owe a delete for the LIVE platform token', () async {
      // Tesla's resonant collision (cage-match). `_registered` is the last
      // CONFIRMED token, not the desired one, so while a rotation is on the wire
      // it is deliberately stale. Restating it there makes a THIRD writer that
      // fights the second with a NEWER epoch:
      //   sign-in registers tok-1 -> platform rotates to tok-2 (in flight) ->
      //   the dead session's DELETE lands and restates tok-1 at a higher epoch ->
      //   tok-2 settles STALE and is owed a DELETE (the live token!) while the
      //   memo rolls back to tok-1. Silently unreachable, and skip-if-same means
      //   nothing re-registers tok-2 until the next real rotation.
      //
      // RED-PROOF: drop the `_registerEpoch != _settledEpoch` yield in _restate
      // and this goes red on BOTH assertions.
      await registrar.start(); // tok-1 confirmed
      final deleteGate = Completer<void>();
      api.unregisterDeviceGate = deleteGate.future;
      await registrar.unpair(credential: 'cred-a');
      await pumpEventQueue();
      await registrar.start(); // same user back, tok-1 live again

      final rotateGate = Completer<void>();
      api.registerDeviceGate = rotateGate.future;
      source.token = 'tok-2';
      source.refreshes.add('tok-2'); // the rotation goes on the wire
      await pumpEventQueue();

      api.unregisterDeviceGate = null;
      deleteGate.complete(); // the dead session's DELETE lands mid-rotation
      await registrar.settled;
      await pumpEventQueue();

      api.registerDeviceGate = null;
      rotateGate.complete(); // the rotation settles
      await pumpEventQueue();

      expect(
        registrar.registeredToken,
        'tok-2',
        reason:
            'the platform rotated; a restatement of the older token must not '
            'roll the pairing back to a token FCM will not re-emit',
      );
      expect(
        pending.read(_island),
        isNot(contains('tok-2')),
        reason:
            'and the LIVE platform token must never be owed a delete — the next '
            'drain would remove the only row that can wake this handset',
      );
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
