import 'package:aiko_chat_app/core/diagnostics/error_report.dart';
import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/log_providers.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/call/application/ring_telemetry.dart';
import 'package:aiko_chat_app/features/call/domain/answer_outcome.dart';
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

    final lines = [
      for (final r in c.read(logBufferProvider).snapshot()) r.format(),
    ];
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

  group('the answer path says which branch it took (2026-09-20)', () {
    // A killed handset woke on a VoIP push, rang, verified the signature and
    // ADMITTED the invitation in 4.9s — then ended its own system call 1.4s
    // later and joined nothing, while the caller sat in an empty room. The
    // app's entire record of that was ONE line, `call.ring.started`: every door
    // past the admission gate wrote nothing, so a perfect ring and a ring that
    // died produced byte-identical evidence.
    //
    // These assertions pin the FIELD NAMES, not just that something was
    // logged — the next handset report is read through them, and a renamed
    // field makes a bundle unreadable exactly when it matters.

    String lineFor(void Function(RingTelemetry t) act) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      act(c.read(ringTelemetryProvider));
      return c.read(logBufferProvider).snapshot().single.format();
    }

    test('a held answer that never gets an admitted invitation names it', () {
      final line = lineFor(
        (t) => t.answerResolved('dm:a:b', AnswerOutcome.neverAdmitted),
      );
      expect(line, contains('call.answer.resolved'));
      expect(line, contains('outcome=neverAdmitted'));
    });

    test('an answer that JOINED is recorded too — the positive control', () {
      // Without it, silence after `held` means both "the call connected" and
      // "the logger never ran", which is the defect this whole group exists to
      // remove rather than relocate.
      final line = lineFor(
        (t) => t.answerResolved('dm:a:b', AnswerOutcome.joined),
      );
      expect(line, contains('outcome=joined'));
    });

    test(
      'the caller hanging up is nameable — the silence that cost the most',
      () {
        final line = lineFor(
          (t) => t.ringStopped('dm:a:b', RingStopCause.callerHungUp),
        );
        expect(line, contains('call.ring.stopped'));
        expect(line, contains('cause=callerHungUp'));
      },
    );

    test(
      'a stop with nothing live omits the channel rather than inventing one',
      () {
        final line = lineFor(
          (t) => t.ringStopped(null, RingStopCause.windowElapsed),
        );
        expect(line, contains('cause=windowElapsed'));
        expect(line, isNot(contains('channel=')));
      },
    );

    test('the call screen opening and closing are BOTH recorded', () {
      // The discriminator the island log could not provide: a missing room
      // token proves the join did not finish, never whether the screen was
      // reached at all.
      expect(
        lineFor((t) => t.callScreenOpened('dm:a:b')),
        contains('call.screen.opened'),
      );
      expect(
        lineFor((t) => t.callScreenDisposed('dm:a:b')),
        contains('call.screen.disposed'),
      );
    });

    test('EVERY native call action is recorded, answered or not', () {
      // The `ended` arm of `_onAction` records itself only when it ends an
      // answer we were holding — so a call the system killed before anyone
      // answered passed through in total silence, which is every failing run
      // on 2026-09-20. The unconditional line is what makes "who ended it"
      // answerable from a report instead of from a root-only device log.
      expect(
        lineFor((t) => t.systemCallAction('dm:a:b', 'ended')),
        allOf(contains('call.system.action'), contains('kind=ended')),
      );
      expect(
        lineFor((t) => t.systemCallAction('dm:a:b', 'answered')),
        contains('kind=answered'),
      );
    });

    test('`ended` carries WHICH native event ended it', () {
      // A `CXEndCallAction` (somebody ended the call) and `providerDidReset`
      // (the system tore our provider down and every call with it) mean
      // opposite things and were the same byte on this channel. On 2026-09-20 a
      // handset rang, was never answered, and lost its call 2.1s later — and no
      // report could say which of the two had happened.
      expect(
        lineFor(
          (t) => t.systemCallAction('dm:a:b', 'ended', origin: 'providerReset'),
        ),
        allOf(contains('kind=ended'), contains('origin=providerReset')),
      );
      expect(
        lineFor(
          (t) => t.systemCallAction('dm:a:b', 'ended', origin: 'endAction'),
        ),
        contains('origin=endAction'),
      );
    });

    test('an origin-less action omits the field rather than saying null', () {
      // Every build before today produces exactly this, and `origin=null`
      // would invite a reader to think the native side had answered the
      // question and said "neither".
      expect(
        lineFor((t) => t.systemCallAction('dm:a:b', 'ended')),
        isNot(contains('origin')),
      );
    });

    test('every AnswerOutcome renders a distinct, non-empty name', () {
      // Driven, not rostered: a value added later with no case here still gets
      // asserted, and a duplicate name (two branches that read identically in a
      // report) fails.
      final names = {for (final o in AnswerOutcome.values) o.name};
      expect(names, hasLength(AnswerOutcome.values.length));
      for (final o in AnswerOutcome.values) {
        expect(
          lineFor((t) => t.answerResolved('dm:a:b', o)),
          contains('outcome=${o.name}'),
        );
      }
    });
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

    test(
      'NAMES the dropped count — a truncated tail must read as truncated',
      () {
        // A tail that reads as complete when it is truncated is the same lie the
        // whole logging change exists to remove.
        expect(
          report(tail: ['x'], dropped: 17),
          contains('Recent log (1 lines, 17 older lines dropped):'),
        );
      },
    );

    test('reports truncation even if every line was dropped', () {
      expect(report(dropped: 3), contains('3 older lines dropped'));
    });
  });
}
