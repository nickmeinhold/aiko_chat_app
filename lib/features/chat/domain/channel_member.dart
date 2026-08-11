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
