/// Moderation domain types (UGC — Apple 1.2 / Google UGC, #7).
///
/// Hand-written (not Freezed), matching the Phase-1 convention in
/// `chat/domain/message.dart`: the layer is small and the wire mapping is the
/// only invariant that matters.
library;

/// A user the current account has blocked. Mirrors the gateway `GET /v1/blocks`
/// row shape `{user_id, display_name, created_at}`. Carries the display name so
/// the "Blocked users" settings list renders + unblocks without a second lookup.
class BlockedUser {
  final String userId;
  final String displayName;
  final DateTime createdAt;

  const BlockedUser({
    required this.userId,
    required this.displayName,
    required this.createdAt,
  });

  factory BlockedUser.fromJson(Map<String, dynamic> j) => BlockedUser(
    userId: j['user_id'] as String,
    displayName: (j['display_name'] as String?) ?? 'Unknown',
    // Lenient: a bad/missing timestamp falls back to epoch so decoding never
    // throws (same load/write symmetry as Message.fromView).
    createdAt:
        DateTime.tryParse((j['created_at'] as String?) ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// The closed set of report reasons. MUST match the gateway's
/// `moderation_service.REPORT_REASONS` — the gateway 422s an unknown value, so a
/// drift here surfaces as a failed report rather than silent acceptance. The
/// wire value is the enum name; [label] is the human-facing menu text.
enum ReportReason {
  spam('Spam'),
  harassment('Harassment or bullying'),
  hate('Hate speech'),
  violence('Violence or threats'),
  sexual('Sexual or inappropriate content'),
  other('Something else');

  const ReportReason(this.label);

  /// Human-facing label for the report menu.
  final String label;

  /// The wire value sent to the gateway (`{"reason": "<name>"}`).
  String get wire => name;

  /// Resolve a gateway wire value back to a reason, or null if it is not one we
  /// know (forward-compatible: the operator queue renders an unknown reason as
  /// its raw wire string rather than dropping the report).
  static ReportReason? fromWire(String wire) {
    for (final r in values) {
      if (r.name == wire) return r;
    }
    return null;
  }
}

/// One unresolved report in the moderator triage queue. Mirrors the gateway
/// `GET /v1/reports?status=pending` row shape
/// (`moderation_service.list_pending_reports`): the report joined to the
/// reported message (a body preview + channel + sender) and the reporter (a
/// display name, nullable — a report's reporter may be anonymized to null by
/// account deletion). Display-only: the app NEVER ingests [messageBody] into its
/// message cache (it is a privileged preview that bypasses the visibility
/// filter, and may already be soft-deleted — see [messageDeletedAt]).
class PendingReport {
  final String reportId;
  final String messageId;
  final String channelId;

  /// The report reason, as the gateway's wire string. [reasonLabel] maps it to a
  /// human label, falling back to the raw value for an unknown (forward-compat).
  final String reason;
  final String? reporterDisplayName;

  /// The reported message's body — a privileged preview for moderator context
  /// ONLY. Never written to the message cache.
  final String messageBody;
  final String messageSenderUserId;
  final DateTime createdAt;

  /// Non-null iff the reported message is ALREADY soft-deleted (a prior takedown
  /// or a self-delete) — the queue still shows it so a moderator can ban the
  /// sender or dismiss without re-taking-down.
  final DateTime? messageDeletedAt;

  const PendingReport({
    required this.reportId,
    required this.messageId,
    required this.channelId,
    required this.reason,
    required this.reporterDisplayName,
    required this.messageBody,
    required this.messageSenderUserId,
    required this.createdAt,
    required this.messageDeletedAt,
  });

  /// The human-facing reason label, or the raw wire value for an unknown reason.
  String get reasonLabel => ReportReason.fromWire(reason)?.label ?? reason;

  /// True iff the reported message has already been soft-deleted.
  bool get isAlreadyDeleted => messageDeletedAt != null;

  factory PendingReport.fromJson(Map<String, dynamic> j) => PendingReport(
    reportId: j['report_id'] as String,
    messageId: j['message_id'] as String,
    channelId: (j['channel_id'] as String?) ?? '',
    reason: (j['reason'] as String?) ?? 'other',
    reporterDisplayName: j['reporter_display_name'] as String?,
    messageBody: (j['message_body'] as String?) ?? '',
    messageSenderUserId: (j['message_sender_user_id'] as String?) ?? '',
    // Lenient timestamps (same load/write symmetry as BlockedUser): a bad value
    // never throws decoding — createdAt falls back to epoch, deletedAt to null.
    createdAt:
        DateTime.tryParse((j['created_at'] as String?) ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    messageDeletedAt: DateTime.tryParse(
      (j['message_deleted_at'] as String?) ?? '',
    )?.toUtc(),
  );
}
