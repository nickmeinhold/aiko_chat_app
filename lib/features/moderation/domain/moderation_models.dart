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
}
