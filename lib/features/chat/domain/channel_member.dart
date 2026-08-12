import 'message.dart';

/// One member of a channel, from `GET /v1/channels/{id}/members`.
///
/// [handle] is the member's CURRENT handle (the island resolves it live from the
/// user row — it is `username`, the #2631 rename-able alias), NOT a send-time
/// snapshot. ADR-0004 dropped the central `/v1/mentions` directory in favour of
/// this per-island roster, so this endpoint IS the key→current-handle lookup:
/// it lets a message's sender name render the sender's handle *as it is now*
/// rather than the frozen label stamped onto the message when it was sent.
class ChannelMember {
  final String userId;
  final String role;
  final bool canPost;
  final String handle;
  final String displayName;

  const ChannelMember({
    required this.userId,
    required this.role,
    required this.canPost,
    required this.handle,
    required this.displayName,
  });

  factory ChannelMember.fromJson(Map<String, dynamic> j) => ChannelMember(
        userId: j['user_id'] as String,
        role: (j['role'] as String?) ?? '',
        canPost: (j['can_post'] as bool?) ?? false,
        handle: (j['handle'] as String?) ?? '',
        displayName: (j['display_name'] as String?) ?? '',
      );
}

/// The name to show for a message's sender — the CURRENT handle for the sender's
/// key, not the send-time [MessageSender.label] snapshot. This is the display
/// half of "identity is the key, the handle is a mutable label" (ADR-0005): a
/// rename must retroactively re-title every past message, exactly as the avatar
/// (keyed off `userId`) already does.
///
/// Resolution order:
///  1. **Me** — my own messages render [myHandle] (from `AppUser.username`),
///     always current with zero fetch, so my rename shows instantly.
///  2. **A current channel member** — the [roster]'s live handle for the key.
///  3. **Fallback** — the stored label (a sender who has left the channel, or
///     the roster not yet loaded); never worse than today's behaviour.
String senderDisplayName(
  MessageSender sender, {
  required bool isMine,
  String? myHandle,
  Map<String, String>? roster,
}) {
  if (isMine && myHandle != null && myHandle.isNotEmpty) return myHandle;
  final id = sender.userId;
  if (id != null) {
    final current = roster?[id];
    if (current != null && current.isNotEmpty) return current;
  }
  return sender.displayLabel;
}

/// The display title for a DM conversation — a DM has no server `name`
/// (identity=key, ADR-0004), so its title is the peer's CURRENT handle, resolved
/// from the channel [roster] (`{userId: handle}`) exactly as [senderDisplayName]
/// resolves message authors. Shared by the sidebar DM row and the narrow-layout
/// title so the two never drift.
///
/// * roster absent (loading / fetch failed) → a neutral label, never the raw key.
/// * [myId] null (a brief auth gap) → a neutral label, NEVER a guessed peer: with
///   no "me" to exclude, every member reads as a peer and the row could be titled
///   with the viewer's OWN handle (cage-match Tesla).
/// * only-me in the roster → a self-DM ("Notes to self").
String dmPeerTitle(Map<String, String>? roster, String? myId) {
  if (roster == null || roster.isEmpty || myId == null) return 'Direct message';
  // Three DISTINCT cases (cage-match #132 Carnot — a blank peer handle must NOT
  // read as a self-DM): a roster with no non-me member is a true self-DM; a peer
  // WITH a handle titles the row; a peer with no handle yet is still a peer, so a
  // neutral label, never '' and never 'Notes to self'.
  final peers = roster.entries.where((e) => e.key != myId).toList();
  if (peers.isEmpty) return 'Notes to self';
  final named =
      peers.where((e) => e.value.isNotEmpty).map((e) => e.value).firstOrNull;
  return named ?? 'Direct message';
}
