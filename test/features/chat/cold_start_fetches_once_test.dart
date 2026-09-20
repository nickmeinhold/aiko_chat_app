/// One cold start, one fetch of each list — and why a duplicate was fatal.
///
/// [deviceOnlineProvider] is a `StreamProvider` fed by an async `isOnline()`, so
/// every launch emits `AsyncLoading` then `AsyncData(true)`. A bare
/// `ref.watch` of it treats that as a change, so `channelsProvider` and
/// `dmsProvider` each fetched twice on every cold start — the second time to
/// learn the network was still as online as it had been.
///
/// On a fast link that is invisible. On a VoIP wake from Bangkok it is not: the
/// app has ~5-6 seconds of background life to get a websocket up, because that
/// is how the call invitation arrives, and the duplicate round also REBUILDS
/// `chatRepositoryProvider` — which is the thing the socket waits on. Measured
/// 2026-09-20: socket at 6.0s, call already dead.
library;

import 'dart:async';

import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _LateConnectivity implements ConnectivityService {
  /// Resolves on a later microtask, like the real one: the whole defect lives
  /// in the gap between the provider being read and this answering.
  @override
  Future<bool> isOnline() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return true;
  }

  final _changes = StreamController<bool>.broadcast();
  @override
  Stream<bool> get onlineChanges => _changes.stream;

  void goOffline() => _changes.add(false);
  void goOnline() => _changes.add(true);
  Future<void> close() => _changes.close();
}

void main() {
  late _LateConnectivity connectivity;
  late ProviderContainer container;
  var builds = 0;

  setUp(() {
    builds = 0;
    connectivity = _LateConnectivity();
    container = ProviderContainer(
      overrides: [connectivityServiceProvider.overrideWithValue(connectivity)],
    );
  });

  tearDown(() {
    container.dispose();
    connectivity.close();
  });

  test('loading → online is NOT a change, so nothing refetches', () async {
    final probe = FutureProvider.autoDispose<int>((ref) async {
      ref.watch(onlineRecoveriesForTest);
      return ++builds;
    });
    container.listen(probe, (_, _) {}, fireImmediately: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      builds,
      1,
      reason: 'the network never changed; only our knowledge of it did',
    );
  });

  test(
    'the BARE watch is what double-fetches — the must-fail control',
    () async {
      // Without this arm the test above could pass for the wrong reason (a
      // container that never delivers the second emission at all), and the fix
      // would be unfalsifiable.
      var bareBuilds = 0;
      final probe = FutureProvider.autoDispose<int>((ref) async {
        ref.watch(deviceOnlineProvider);
        return ++bareBuilds;
      });
      container.listen(probe, (_, _) {}, fireImmediately: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        bareBuilds,
        2,
        reason: 'AsyncLoading → AsyncData(true) rebuilds; this is the defect',
      );
    },
  );

  test(
    'a REAL recovery edge still refetches — the semantics are preserved',
    () async {
      // The reason both call sites watch connectivity at all: an offline launch
      // serves the cache, and without a refetch on the way back the user is
      // stranded there with no socket.
      final probe = FutureProvider.autoDispose<int>((ref) async {
        ref.watch(deviceOnlineProvider.select((a) => a.value ?? true));
        return ++builds;
      });
      container.listen(probe, (_, _) {}, fireImmediately: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(builds, 1);

      connectivity.goOffline();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(builds, 2, reason: 'online → offline is a real transition');

      connectivity.goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(builds, 3, reason: 'the recovery edge must still refetch');
    },
  );
}
