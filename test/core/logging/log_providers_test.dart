import 'package:aiko_chat_app/core/diagnostics/error_report.dart';
import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/log_providers.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/call/application/ring_telemetry.dart';
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rootLoggerProvider wires a REAL sink, never a no-op', () {
    // The exact regression a cage-match caught once already on the chat
    // telemetry seam (PR #45, Carnot): production fell back to the silent
    // default and swallowed every must-be-seen signal. Delete the wiring in
    // log_providers.dart and this goes red.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(logSinkProvider), isNot(isA<NoopLogSink>()));
    expect(c.read(rootLoggerProvider).subsystem, 'aiko');
  });

  test(
    'the production sink REDACTS BEFORE the buffer — a shared report is clean',
    () {
      // This is the security property of the sink ORDER, and it is the one that
      // matters most: the buffer is the sink whose contents a user hands to
      // somebody else. If redaction were applied per-branch instead of wrapping
      // the fan-out, a future third branch could be added without one, and the
      // branch that leaked would be this one.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      const token =
          'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

      c.read(rootLoggerProvider).info('push.registered', fields: {'t': token});

      final buffered = c.read(logBufferProvider).snapshot();
      expect(buffered, hasLength(1));
      expect(
        buffered.single.format(),
        isNot(contains(token)),
        reason: 'an unredacted token reached the exportable buffer',
      );
      expect(buffered.single.format(), contains('a1b2c3d4e5f6…'));
    },
  );

  test('the log buffer survives across screens — it is not autoDispose', () {
    // The buffer's job is to still hold the run-up to a failure at the moment
    // the user decides to report it, which is always after the screen that
    // caused it is gone. An autoDisposed buffer is empty exactly when needed.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(rootLoggerProvider).info('a');
    final sub = c.listen(logBufferProvider, (_, __) {});
    sub.close(); // last listener gone — an autoDispose provider would reset here
    expect(c.read(logBufferProvider).snapshot(), hasLength(1));
  });

  test('pushTelemetryProvider reaches the real buffer, not a no-op', () {
    // Asserted BEHAVIOURALLY rather than by type: `isNot(PushTelemetry.noop)`
    // would pass for a facade wired to a second, differently-broken no-op. The
    // question that matters is "does a push failure reach the thing a user can
    // export", so the test asks exactly that.
    final c = ProviderContainer();
    addTearDown(c.dispose);

    c.read(pushTelemetryProvider).registerFailed('abc123', StateError('x'));

    final lines = [for (final r in c.read(logBufferProvider).snapshot()) r.format()];
    expect(lines, hasLength(1));
    expect(lines.single, contains('aiko.push'));
    expect(lines.single, contains('push.register.failed'));
    // The consequence field is the point of the event: this is the terminal
    // reach failure, and its whole symptom is a call that never rings.
    expect(lines.single, contains('device-will-not-wake'));
  });

  test('ringTelemetryProvider reaches the real buffer, not a no-op', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    c.read(ringTelemetryProvider).ringRefused('dm:a:b', RingRefusal.stale);

    final line = c.read(logBufferProvider).snapshot().single.format();
    expect(line, contains('aiko.call.ring'));
    expect(line, contains('call.ring.refused'));
    // The reason is the payload. A record that said only "refused" would
    // reproduce the exact defect this change removed.
    expect(line, contains('reason=stale'));
  });

  group('formatErrorReport carries the log tail', () {
    String report({List<String> tail = const [], int dropped = 0}) =>
        formatErrorReport(
          error: null,
          status: NetworkStatus.online,
          host: 'https://example.test',
          device: const {'App': 'Aiko Chat 0.0.1+1'},
          nowUtc: DateTime.utc(2026, 8, 31),
          logTail: tail,
          logDropped: dropped,
        );

    test('omits the section entirely when there is nothing to say', () {
      expect(report(), isNot(contains('Recent log')));
    });

    test('includes the lines', () {
      final out = report(tail: ['line-one', 'line-two']);
      expect(out, contains('Recent log (2 lines):'));
      expect(out, contains('line-one'));
      expect(out, contains('line-two'));
    });

    test('NAMES the dropped count — a truncated tail must read as truncated', () {
      // A tail that reads as complete when it is truncated is the same lie the
      // whole logging change exists to remove.
      expect(
        report(tail: ['x'], dropped: 17),
        contains('Recent log (1 lines, 17 older lines dropped):'),
      );
    });

    test('reports truncation even if every line was dropped', () {
      expect(report(dropped: 3), contains('3 older lines dropped'));
    });
  });
}
