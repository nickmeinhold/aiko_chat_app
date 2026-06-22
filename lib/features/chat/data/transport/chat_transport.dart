import '../../domain/message.dart';

/// Realtime connection lifecycle. `unauthenticated` is terminal until the user
/// re-logs-in (the router watches it → redirect to login); it is distinct from
/// `disconnected` (a transient drop that will be retried).
enum ConnectionState { disconnected, connecting, connected, unauthenticated }

/// Server `ack` decoded — maps our optimistic [clientMsgId] to the server [msgId].
class AckResult {
  final String clientMsgId;
  final String msgId;
  final String? createdAt;
  const AckResult(
      {required this.clientMsgId, required this.msgId, this.createdAt});
}

/// Server `error` decoded. [refClientMsgId] ties it to a failed send when known.
class TransportError {
  final String code;
  final String detail;
  final String? refClientMsgId;
  const TransportError(
      {required this.code, required this.detail, this.refClientMsgId});
}

/// The realtime seam (plan §B1). Riverpod + the repository depend on THIS, never
/// on `web_socket_channel`. The Phase-1 inbound surface is messages/acks/errors;
/// typing/presence/reactions are later phases. All streams are broadcast and
/// **outlive reconnects** (a single `.listen` by the repository survives a
/// dropped socket — review finding 3).
abstract interface class ChatTransport {
  Stream<ConnectionState> get connectionState;
  Stream<Message> get messages;
  Stream<AckResult> get acks;
  Stream<TransportError> get errors;

  /// Open the socket (pulls a token via the TokenProvider). Idempotent if
  /// already connected/connecting.
  Future<void> connect();

  /// Close the socket and stop reconnecting (until [connect] is called again).
  Future<void> disconnect();

  /// (Re)subscribe to channels and await the server's subscription-ack. Returns
  /// the per-channel **fence** map (channelId -> newest persisted ULID at
  /// subscription-effective time; `""` for an empty channel). The reconcile
  /// engine fetches history up to the fence and lets the live stream own
  /// everything beyond it — no gap (design 04 §Gap 2). Additive server-side;
  /// safe to re-send the full set after a reconnect.
  ///
  /// Completes with a [TransportError] if the socket drops before the ack (the
  /// caller retries in a fresh reconnect epoch) or if called while disconnected.
  Future<Map<String, String>> subscribe(List<String> channelIds);

  /// Serialise + send a message frame. ALWAYS returns the clientTempId and
  /// never throws; deliverability is signalled via [connectionState]/[errors]
  /// and owned by the repository's outbox.
  String sendMessage(OutgoingMessage message);
}
