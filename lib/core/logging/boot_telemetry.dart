import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'aiko_logger.dart';
import 'boot_clock.dart';
import 'log_providers.dart';

/// The wake, in phases.
///
/// ## Why this exists
///
/// A push-woken ring is refused as STALE when the journey from the caller's
/// signature to our admission exceeds [kCallInviteFreshness]. On 2026-09-20 the
/// same handset, build and island produced both outcomes within seventy
/// minutes — admitted at `ageMs=4913`, refused at `ageMs=12725` — and the
/// island log put the difference almost entirely in one place: 1.4s from push
/// to our first REST call in the good run, 9.6s in the bad one.
///
/// Nothing in the app explained it. The two list fetches are already
/// `Future.wait`-ed, and Firebase init returns immediately on Apple platforms.
/// So the time was going somewhere structurally invisible, and "fix the startup
/// path" had no target: engine boot, plugin registration, a keychain read, a
/// sleeping radio and an OS throttling a background launch are five different
/// causes with five different fixes, and every one of them produced the same
/// single log line.
///
/// Each phase below is logged with a delta in milliseconds, so ONE report
/// decomposes the wake instead of establishing that it was slow.
///
/// ## The deltas are relative to `main()`, not to the push
///
/// The app cannot see the push — PushKit wakes it natively and the payload does
/// not carry the island's send time. So the absolute anchor lives in the island
/// log, and these deltas hang off [appMainEnteredAt]. Pairing the two is
/// deliberate: `push → main()` is the OS's half of the wake and nothing in Dart
/// can shorten it, while everything after `main()` is ours. A fix aimed at the
/// wrong half is the outcome this split exists to prevent.
class BootTelemetry {
  const BootTelemetry(this._log);

  final AikoLogger _log;

  /// The Dart side is alive and the first frame is scheduled.
  ///
  /// `mainAtMs` is absolute (epoch UTC) rather than a delta, because it is the
  /// one value that has to line up against a clock this process cannot read —
  /// the island's `apns sent` line.
  void bootStarted() {
    // ONCE PER PROCESS. Its natural call site is the root widget's `build`,
    // which reruns on every theme, router and locale change — and this buffer
    // is the one the ring's own events have to survive in. A boot event that
    // repeats would evict exactly what it was added to sit beside.
    if (_bootAnnounced) return;
    _bootAnnounced = true;
    _log.info(
      'app.boot.started',
      fields: {'mainAtMs': appMainEnteredAt?.millisecondsSinceEpoch ?? -1},
    );
  }

  /// Process-scoped, like [appMainEnteredAt] and for the same reason: "this
  /// process has announced its boot" is one fact, and the provider holding it
  /// can be rebuilt.
  static bool _bootAnnounced = false;

  /// TEST-ONLY. A process is booted once; a test suite boots many.
  static void resetForTest() {
    _bootAnnounced = false;
    _socketAnnounced = false;
  }

  /// Session restore answered — the gate every network call waits behind.
  ///
  /// [signedIn] is recorded because a restore that resolves EMPTY is a
  /// different event wearing the same duration, and `_tryJoin` ends a held
  /// answer on exactly that value.
  void authResolved({required bool signedIn}) => _log.info(
    'app.boot.auth',
    fields: {'sinceMainMs': _sinceMain(), 'signedIn': signedIn},
  );

  /// The websocket is up. Until this instant no invitation can arrive at all,
  /// so this is the true deadline a ring is racing.
  void socketConnected() {
    // FIRST connect only. Later reconnects are real events but they are not
    // this one — a socket that comes back after an hour asleep would otherwise
    // log a `sinceMainMs` of 3,600,000 under a name that says "boot".
    if (_socketAnnounced) return;
    _socketAnnounced = true;
    _log.info('app.boot.socket', fields: {'sinceMainMs': _sinceMain()});
  }

  static bool _socketAnnounced = false;

  /// Milliseconds since `main()`, or -1 when `main()` never ran (every widget
  /// test). -1 rather than 0: a zero would read as "instant" and quietly
  /// flatter the very measurement this class exists to take.
  int _sinceMain() {
    final started = appMainEnteredAt;
    if (started == null) return -1;
    return DateTime.now().toUtc().difference(started).inMilliseconds;
  }
}

final bootTelemetryProvider = Provider<BootTelemetry>(
  (ref) => BootTelemetry(ref.watch(rootLoggerProvider).child('boot')),
);
