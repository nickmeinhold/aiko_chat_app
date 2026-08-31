import 'aiko_log.dart';

/// Defence-in-depth redaction — the SECOND layer, and it exists because the
/// first one cannot cover the case that actually bit.
///
/// ## Why a pattern scrubber, when the facades already enforce shape
///
/// The primary discipline is structural: a typed per-subsystem facade has no
/// parameter to pass a secret through (see [AikoLog]). That is the layer to
/// trust, and it is why this one is allowed to be crude.
///
/// It is not sufficient alone. On 2026-08-29 the ISLAND discovered it was
/// writing full APNs device tokens to its container log at INFO — in direct
/// violation of its own written never-log rule, and with no call site at fault:
/// the token arrived inside an httpx request URL, emitted by a DEPENDENCY'S
/// logger. No amount of signature discipline reaches a third party's format
/// string. The island's fix was a formatted-message scrubber; this mirrors it
/// for the same reason, and the two layers are deliberately chosen to FAIL
/// DIFFERENTLY — a redactor that shared the facades' notion of "a field" would
/// be blind to precisely the leak that motivated it.
///
/// ## Over-redaction is accepted; under-redaction is not
///
/// ...but only up to the point where it eats the ids that make a log useful.
/// The thresholds below are set against our OWN identifier shapes, not chosen
/// round numbers:
///
/// | thing | shape | verdict |
/// |---|---|---|
/// | ULID (`messages.id`, `client_msg_id`) | 26 chars, Crockford base32 | **must survive** — it is the correlation key |
/// | APNs device token | 64 hex chars | must be cut |
/// | FCM registration token | ~150+ chars, base64url-ish with `:` and `-` | must be cut |
///
/// So the hex rule fires at >=32 (a ULID is 26, and cannot reach 32), and the
/// general token rule at >=40 (comfortably clear of a ULID, far below an FCM
/// token). A run is trimmed to its first 12 characters rather than blanked:
/// 12 hex is 48 bits — useless for reconstructing a 256-bit token, and
/// empirically enough to correlate a log line against a real row, which is the
/// trade the island measured while debugging #3386.
class RedactingLogSink extends LogSink {
  const RedactingLogSink(this._inner);

  final LogSink _inner;

  /// >=32 hex characters. Anchored on a 12-char prefix that is KEPT.
  static final RegExp _longHex = RegExp(
    r'\b([0-9a-fA-F]{12})[0-9a-fA-F]{20,}\b',
  );

  /// >=40 characters of token-ish alphabet (base64url plus `:`, which FCM uses
  /// as its `<instance>:<token>` separator). Runs AFTER [_longHex] so a hex
  /// token is cut by the tighter rule first.
  static final RegExp _longToken = RegExp(
    r'\b([A-Za-z0-9_\-:]{12})[A-Za-z0-9_\-:]{28,}\b',
  );

  /// Trim any secret-shaped run in [text] to its first 12 characters.
  ///
  /// Exposed for testing so the redactor can be exercised directly against known
  /// token shapes — a scrubber whose only proof is "the sink looked fine" is a
  /// check that cannot go red.
  static String redact(String text) => text
      .replaceAllMapped(_longHex, (m) => '${m[1]}…')
      .replaceAllMapped(_longToken, (m) => '${m[1]}…');

  @override
  void add(LogRecord record) {
    _inner.add(
      LogRecord(
        at: record.at,
        subsystem: record.subsystem,
        level: record.level,
        event: record.event,
        fields: {
          for (final e in record.fields.entries)
            e.key: e.value is String
                ? redact(e.value! as String)
                : e.value,
        },
        // The error is projected to its TYPE NAME, never its string. This is the
        // same invariant `describeError` enforces on the problem-report path,
        // and for the same measured reason: a DioException's toString() can
        // carry the request body, which on the claim path holds a
        // provisioning_token, the handle and the display name (cage-match #74).
        // A redaction regex over that string would be defence in the wrong
        // place — the fix is not to stringify it at all.
        error: record.error == null
            ? null
            : record.error.runtimeType.toString(),
        stackTrace: record.stackTrace,
      ),
    );
  }
}
