/// A takedown *retraction* — the app-side consumer of the island's forward-ULID
/// takedown-propagation event (`/crucible` 2026-07-28; island PR #104,
/// `ef2dd00`). When a moderator takes a message down, the island emits a NEW
/// event with its OWN higher ULID ([id]) that references the taken-down message
/// ([targetMsgId]). It rides the SAME forward paths a message does — WS fanout
/// while live, `get_history` catch-up while offline — so a client that already
/// synced the message past its watermark still learns it is gone, through the one
/// history cursor (no separate deletions feed, no second cursor).
///
/// The wire word is **retraction**, NOT "tombstone": the island reserves
/// "tombstone" for the account-deletion *husk*, which REMAINS visible; a
/// retraction REMOVES.
///
/// Invariant by construction: [id] > [targetMsgId] (the retraction rides the
/// forward cursor), so on a forward walk a retraction is always observed AFTER
/// its target. Suppression is nonetheless **presence-independent** — the dead id
/// is recorded whether or not the target was ever synced (a takedown of an
/// already-husked message emits a retraction too), so ordering never matters.
class Retraction {
  /// The channel the taken-down message lived in.
  final String channelId;

  /// The retraction event's OWN ULID — the higher, forward-cursor id. This is the
  /// value the history pager advances its cursor to when a retraction is the last
  /// item on a page (island `next_after = rows[-1].id`, merged across types).
  final String id;

  /// The ULID of the message being taken down — the id suppressed in the cache.
  final String targetMsgId;

  const Retraction({
    required this.channelId,
    required this.id,
    required this.targetMsgId,
  });

  @override
  bool operator ==(Object other) =>
      other is Retraction &&
      other.channelId == channelId &&
      other.id == id &&
      other.targetMsgId == targetMsgId;

  @override
  int get hashCode => Object.hash(channelId, id, targetMsgId);

  @override
  String toString() =>
      'Retraction(channelId: $channelId, id: $id, targetMsgId: $targetMsgId)';
}
