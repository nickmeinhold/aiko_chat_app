import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:aiko_chat_app/app/providers.dart' show transportProvider;
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/chat/application/transport_wake.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_chat_transport.dart';

class _Connectivity implements ConnectivityService {
  _Connectivity(this.initial);
  final bool initial;
  final changes = StreamController<bool>.broadcast();
  @override
  Future<bool> isOnline() async => initial;
  @override
  Stream<bool> get onlineChanges => changes.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (ProviderContainer, FakeChatTransport, _Connectivity) mount({
    bool online = true,
  }) {
    final transport = FakeChatTransport();
    final conn = _Connectivity(online);
    final c = ProviderContainer(
      overrides: [
        transportProvider.overrideWithValue(transport),
        connectivityServiceProvider.overrideWithValue(conn),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(conn.changes.close);
    // LISTEN, not read: Riverpod 3 pauses a provider nothing listens to, and a
    // paused provider's own ref.listen goes deaf. main.dart watches it.
    c.listen(transportWakeProvider, (_, _) {});
    return (c, transport, conn);
  }

  test(
    'coming back ONLINE kicks; the seed and staying online do not',
    () async {
      final (_, transport, conn) = mount(online: false);
      await pumpEventQueue();
      expect(
        transport.reconnectReasons,
        isEmpty,
        reason: 'the seed is not an edge',
      );

      conn.changes.add(true);
      await pumpEventQueue();
      conn.changes.add(true); // a wifi↔cellular swap that stays online
      await pumpEventQueue();

      expect(transport.reconnectReasons, ['online']);
    },
  );

  test('going offline does not kick', () async {
    final (_, transport, conn) = mount();
    await pumpEventQueue();
    conn.changes.add(false);
    await pumpEventQueue();
    expect(transport.reconnectReasons, isEmpty);
  });

  test('the app RESUMING kicks — unlocking after an Answer is a resume', () {
    final (_, transport, _) = mount();
    final binding = TestWidgetsFlutterBinding.instance;
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(s);
    }
    expect(transport.reconnectReasons, ['resume']);
  });
}
