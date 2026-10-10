/// How long ago this device's native side was woken for a call — the instant
/// an invitation's freshness is judged from when Dart reaches it late
/// (design 23).
///
/// **Three answers, not two** (design 23 v3.1, requirement 1). A nullable
/// duration folded "the oracle has not synced" into "not actionable", and
/// "not actionable" is judged at `now` — the instant that refused every locked
/// answer. So the third answer is a type, and the caller must handle it.
library;

sealed class WakeAge {
  const WakeAge();

  /// Decodes the control channel's reply. Only a well-formed `woke` or
  /// `unknown` is believed; everything else, `null` included (a platform with
  /// no native half, or an older one), is [WakeNotActionable] — today's
  /// behaviour, judged at `now`.
  ///
  /// `unknown` is the ONE answer that defers admission, so only the native side
  /// may give it. Decoding a malformed reply as unknown would turn a broken
  /// bridge into a retry loop on every ring.
  static WakeAge decode(Object? reply) {
    if (reply is! Map) return const WakeNotActionable();
    switch (reply['state']) {
      case 'woke':
        final ms = reply['ms'];
        if (ms is int && ms >= 0) return Woke(Duration(milliseconds: ms));
        return const WakeNotActionable();
      case 'unknown':
        return const WakeUnknown();
      default:
        return const WakeNotActionable();
    }
  }
}

/// The wake for exactly this call arrived [age] ago, and the system still holds
/// the call as ringing or answered. Measured on the native side's monotonic,
/// sleep-inclusive clock, so it is a duration and never a timestamp.
final class Woke extends WakeAge {
  const Woke(this.age);
  final Duration age;

  @override
  bool operator ==(Object other) => other is Woke && other.age == age;

  @override
  int get hashCode => age.hashCode;

  @override
  String toString() => 'Woke($age)';
}

/// This device holds no ringing or answered system call for this call: never
/// woken for it, ended, another call, or rebooted since. Freshness is judged at
/// `now`, as before design 23.
final class WakeNotActionable extends WakeAge {
  const WakeNotActionable();

  @override
  String toString() => 'WakeNotActionable()';
}

/// The native side cannot tell yet: a wake for this call is recorded, but the
/// system's own call state has not confirmed it. Admission waits and asks
/// again; it is never judged at `now`.
final class WakeUnknown extends WakeAge {
  const WakeUnknown();

  @override
  String toString() => 'WakeUnknown()';
}
