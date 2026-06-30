import 'package:aiko_chat_app/features/chat/data/logging_chat_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Carnot HIGH (PR #45 cage-match): the reconcile telemetry was a silent no-op
  // in the shipped app — chatRepositoryProvider never wired a real sink, so the
  // repo fell back to _NoopTelemetry and every must-be-seen signal (including
  // the #16 historySyncFault) was swallowed. The provider now wires
  // LoggingChatTelemetry; this pins that the production sink is constructible and
  // handles EVERY signal without throwing, so it cannot rot back into uselessness
  // unobserved (a throwing telemetry would itself be a swallowed failure).
  test('LoggingChatTelemetry handles every reconcile signal without throwing',
      () {
    const t = LoggingChatTelemetry();
    expect(() {
      t.orphanAck('c1', '01ABC');
      t.reconnectFailed(StateError('boom'), StackTrace.current);
      t.historyGapBeforeFence('chan', '01ABC', '01DEF');
      t.historyGapBeforeFence('chan', null, '01DEF'); // null cursor path
      t.historySyncFault('chan', '01ABC', '01DEF', 3);
      t.historySyncFault('chan', null, '01DEF', 7); // null cursor + higher streak
      t.inboundWriteFailed(StateError('boom'), StackTrace.current);
    }, returnsNormally);
  });
}
