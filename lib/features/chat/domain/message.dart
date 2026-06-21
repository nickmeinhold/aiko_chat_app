/// Core chat domain types for Phase 1 (text-only).
///
/// Hand-written (not Freezed) deliberately: the Phase-1 layer is small, and the
/// invariants that matter here — the two-id design, lenient decoding, and
/// load/write symmetry (see docs/design/01-data-layer.md) — are clearer and more
/// directly testable as explicit code than as generated code.
library;

/// Who sent a message. Mirrors the wire `sender.kind`.
///
/// Forward-compat: an unknown wire value decodes to [actor] rather than throwing,
/// so a future gateway kind never crashes an older client (it degrades to the
/// generic external-actor rendering).
enum SenderKind {
  human,
  actor,
  llm,
  robot;

  static SenderKind fromWire(String? raw) {
    switch (raw) {
      case 'human':
        return SenderKind.human;
      case 'llm':
        return SenderKind.llm;
      case 'robot':
        return SenderKind.robot;
      case 'actor':
      default:
        return SenderKind.actor; // unknown / null -> generic external actor
    }
  }

  String get wire => name;

  /// True for non-human participants (LLM, robot, generic actor) — the app
  /// renders these with a participant badge.
  bool get isExternalActor => this != SenderKind.human;
}

/// Message content kind. Phase 1 only ever produces [text]; the rest are
/// reserved so a future media message from the wire doesn't crash this client.
enum MessageKind {
  text,
  image,
  video,
  voice,
  system;

  static MessageKind fromWire(String? raw) {
    switch (raw) {
      case 'image':
        return MessageKind.image;
      case 'video':
        return MessageKind.video;
      case 'voice':
        return MessageKind.voice;
      case 'system':
        return MessageKind.system;
      case 'text':
      default:
        return MessageKind.text;
    }
  }

  String get wire => name;
}

/// Delivery lifecycle of an *outgoing* message. Inbound messages are always
/// [sent] (they exist on the server). `delivered`/`read` are reserved for
/// Phase 4 (read receipts).
enum DeliveryState {
  sending,
  sent,
  delivered,
  read,
  failed;

  String get wire => name;

  static DeliveryState fromWire(String? raw) {
    switch (raw) {
      case 'sending':
        return DeliveryState.sending;
      case 'delivered':
        return DeliveryState.delivered;
      case 'read':
        return DeliveryState.read;
      case 'failed':
        return DeliveryState.failed;
      case 'sent':
      default:
        return DeliveryState.sent;
    }
  }
}

/// The sender of a message. `userId` is null for external actors (LLM/robot/
/// REPL); `label` is **nullable** — the gateway passes `sender_label` straight
/// through and it can be null (review finding #4). UI falls back to the kind.
class MessageSender {
  final String? userId;
  final SenderKind kind;
  final String? label;

  const MessageSender({this.userId, required this.kind, this.label});

  factory MessageSender.fromJson(Map<String, dynamic> j) => MessageSender(
        userId: j['user_id'] as String?,
        kind: SenderKind.fromWire(j['kind'] as String?),
        label: j['label'] as String?,
      );

  Map<String, dynamic> toJson() =>
      {'user_id': userId, 'kind': kind.wire, 'label': label};

  /// Best-effort display name: explicit label, else the kind's name.
  String get displayLabel => (label != null && label!.isNotEmpty) ? label! : kind.name;

  @override
  bool operator ==(Object other) =>
      other is MessageSender &&
      other.userId == userId &&
      other.kind == kind &&
      other.label == label;

  @override
  int get hashCode => Object.hash(userId, kind, label);
}

/// A chat message — the central app type.
///
/// **Two-id design:** [clientTempId] is the durable cache primary key, generated
/// client-side and surviving forever; [id] is the server ULID, which is `null`
/// until the `ack` arrives. Keeping [id] nullable end-to-end (no sentinel) is
/// what gives load/write symmetry: an un-acked row round-trips cache load AND
/// save without throwing.
class Message {
  /// Durable cache PK. For optimistic messages this is a client uuid; for
  /// server-originated messages (history / others' messages) it is the server
  /// [id] (a message never originated by this client is never "optimistic").
  final String clientTempId;

  /// Server ULID. Null until acked. Doubles as the ordering key once present.
  final String? id;

  final String channelId;
  final MessageSender sender;
  final MessageKind kind;
  final String body;
  final String? replyToId;
  final DateTime createdAt;
  final DeliveryState deliveryState;

  const Message({
    required this.clientTempId,
    this.id,
    required this.channelId,
    required this.sender,
    this.kind = MessageKind.text,
    required this.body,
    this.replyToId,
    required this.createdAt,
    required this.deliveryState,
  });

  /// Build from a server `MessageView` (an inbound message frame or a history
  /// row). The server id doubles as the durable cache PK for non-optimistic
  /// rows. `created_at` is required and ISO-8601; a missing/bad value falls back
  /// to epoch so decoding never throws (load/write symmetry).
  factory Message.fromView(Map<String, dynamic> v) {
    final msgId = v['msg_id'] as String;
    return Message(
      clientTempId: msgId,
      id: msgId,
      channelId: v['channel_id'] as String,
      sender: MessageSender.fromJson(
          (v['sender'] as Map?)?.cast<String, dynamic>() ?? const {}),
      kind: MessageKind.fromWire(v['kind'] as String?),
      body: (v['body'] as String?) ?? '',
      replyToId: v['reply_to'] as String?,
      createdAt: _parseTime(v['created_at'] as String?),
      deliveryState: DeliveryState.sent,
    );
  }

  Message copyWith({
    String? id,
    MessageSender? sender,
    String? body,
    DateTime? createdAt,
    DeliveryState? deliveryState,
  }) =>
      Message(
        clientTempId: clientTempId,
        id: id ?? this.id,
        channelId: channelId,
        sender: sender ?? this.sender,
        kind: kind,
        body: body ?? this.body,
        replyToId: replyToId,
        createdAt: createdAt ?? this.createdAt,
        deliveryState: deliveryState ?? this.deliveryState,
      );

  static DateTime _parseTime(String? iso) {
    if (iso == null) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return DateTime.tryParse(iso)?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  @override
  bool operator ==(Object other) =>
      other is Message &&
      other.clientTempId == clientTempId &&
      other.id == id &&
      other.channelId == channelId &&
      other.sender == sender &&
      other.kind == kind &&
      other.body == body &&
      other.replyToId == replyToId &&
      other.createdAt == createdAt &&
      other.deliveryState == deliveryState;

  @override
  int get hashCode => Object.hash(clientTempId, id, channelId, sender, kind,
      body, replyToId, createdAt, deliveryState);
}

/// What the composer hands to the transport/outbox: the durable temp id (which
/// becomes the wire `client_msg_id`) plus the content. No sender field — the
/// server derives identity from the JWT (invariant I5).
class OutgoingMessage {
  final String clientTempId;
  final String channelId;
  final String body;
  final String? replyToId;

  const OutgoingMessage({
    required this.clientTempId,
    required this.channelId,
    required this.body,
    this.replyToId,
  });
}
