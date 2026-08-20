// The push pairing's lifecycle. Every case here is a SILENCE bug if it regresses
// — the island keeps a token the push service refuses to deliver to, and nothing
// raises. There is no observable symptom short of "the call never arrived", so
// the assertions are the only alarm.
import 'dart:async';

import 'package:aiko_chat_app/features/notifications/application/device_registrar.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_token_source.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ui_fakes.dart';

class _FakeSource implements PushTokenSource {
  bool granted = true;
  String? token = 'tok-1';
  final refreshes = StreamController<String>.broadcast();
  int permissionAsks = 0;

  @override
  DevicePlatform get platform => DevicePlatform.apns;

  @override
  Future<bool> requestPermission() async {
    permissionAsks++;
    return granted;
  }

  @override
  Future<String?> currentToken() async => token;

  @override
  Stream<String> tokenRefreshes() => refreshes.stream;
}

void main() {
  late FakeRestApi api;
  late _FakeSource source;
  late DeviceRegistrar registrar;

  setUp(() {
    api = FakeRestApi();
    source = _FakeSource();
    registrar = DeviceRegistrar(source: source, api: api);
  });

  tearDown(() => source.refreshes.close());

  test('sign-in registers the current token with its own transport', () async {
    await registrar.start();

    expect(api.registeredDevices, [
      (platform: DevicePlatform.apns, token: 'tok-1'),
    ]);
  });

  test('a refused permission registers NOTHING — a denial is an answer, not a '
      'failure to route around', () async {
    source.granted = false;

    await registrar.start();

    expect(api.registeredDevices, isEmpty);
  });

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

  test('sign-out unregisters the token the island ACTUALLY holds, not the one '
      'it was first given', () async {
    await registrar.start();
    source.refreshes.add('tok-2');
    await pumpEventQueue();

    await registrar.stop();

    // The bug this pins: unregistering 'tok-1' would leave 'tok-2' — the live
    // one — routing this account's pushes to a handset that has signed out.
    expect(api.unregisteredDevices, ['tok-2']);
  });

  test('a registration failure does not throw — it degrades reach, and sign-in '
      'must not fail because a push service was down', () async {
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

  test('after sign-out, a late rotation does NOT re-register — the stream is '
      'cancelled, not merely ignored', () async {
    await registrar.start();
    await registrar.stop();

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

  test('stop without start is a no-op, not a spurious unregister', () async {
    await registrar.stop();

    expect(api.unregisteredDevices, isEmpty);
  });
}
