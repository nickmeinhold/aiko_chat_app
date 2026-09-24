/// The wake, decomposed — and the two ways this instrument could lie.
///
/// One handset, one build, one island, seventy minutes apart: a push-woken ring
/// admitted at `ageMs=4913` and another refused at `ageMs=12725`. The island log
/// put the whole difference in the wake (1.4s vs 9.6s from push to our first
/// REST call) and nothing in the app explained it — the list fetches are already
/// `Future.wait`-ed and Firebase init is a no-op on Apple platforms.
///
/// So "fix the startup path" had no target. Engine boot, plugin registration, a
/// keychain read, a sleeping radio and an OS throttling a background launch are
/// five causes with five different fixes, and all five produced one log line.
library;

import 'package:aiko_chat_app/core/logging/boot_clock.dart';
import 'package:aiko_chat_app/core/logging/boot_telemetry.dart';
import 'package:aiko_chat_app/core/logging/log_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(BootTelemetry.resetForTest);
  tearDown(() => appMainEnteredAt = null);

  List<String> linesAfter(void Function(BootTelemetry t) act) {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    act(c.read(bootTelemetryProvider));
    return [for (final r in c.read(logBufferProvider).snapshot()) r.format()];
  }

  test('the boot line carries an ABSOLUTE main() time, not a delta', () {
    // It is the one value that has to be compared against a clock this process
    // cannot read: the island's `apns sent` timestamp. A delta would be
    // unpairable with the only other half of the measurement.
    appMainEnteredAt = DateTime.utc(2026, 9, 20, 3, 34, 41);
    final line = linesAfter((t) => t.bootStarted()).single;
    expect(line, contains('app.boot.started'));
    expect(
      line,
      contains(
        'mainAtMs=${DateTime.utc(2026, 9, 20, 3, 34, 41).millisecondsSinceEpoch}',
      ),
    );
  });

  test('boot is announced ONCE, however many times its widget rebuilds', () {
    // Its call site is the root widget's `build`, which reruns on every theme,
    // router and locale change — into the same 500-record ring the call
    // telemetry has to survive in. A repeating boot line would evict exactly
    // what it was added to sit beside.
    appMainEnteredAt = DateTime.utc(2026, 9, 20);
    final lines = linesAfter((t) {
      t.bootStarted();
      t.bootStarted();
      t.bootStarted();
    });
    expect(lines, hasLength(1));
  });

  test('the socket line is the FIRST connect, not every reconnect', () {
    // A socket returning after an hour asleep would otherwise report a
    // `sinceMainMs` of 3,600,000 under a name that says "boot".
    appMainEnteredAt = DateTime.now().toUtc();
    final lines = linesAfter((t) {
      t.socketConnected();
      t.socketConnected();
    });
    expect(lines, hasLength(1));
    expect(lines.single, contains('app.boot.socket'));
  });

  test(
    'a restore that resolves EMPTY is distinguishable from one that did not',
    () {
      // Same duration, different event — and `_tryJoin` ends a held answer on
      // exactly this value, so a report that could not tell them apart would
      // leave the `signedOut` outcome unexplainable.
      appMainEnteredAt = DateTime.now().toUtc();
      expect(
        linesAfter((t) => t.authResolved(signedIn: false)).single,
        contains('signedIn=false'),
      );
      BootTelemetry.resetForTest();
      expect(
        linesAfter((t) => t.authResolved(signedIn: true)).single,
        contains('signedIn=true'),
      );
    },
  );

  test('with no main() the delta is -1, never 0', () {
    // Every widget test is a process where `main()` never ran. A zero would
    // read as "instant" and flatter the exact measurement this exists to take —
    // the same silent-default failure the ring gate spent this session removing.
    appMainEnteredAt = null;
    expect(
      linesAfter((t) => t.socketConnected()).single,
      contains('sinceMainMs=-1'),
    );
    BootTelemetry.resetForTest();
    expect(linesAfter((t) => t.bootStarted()).single, contains('mainAtMs=-1'));
  });
}
