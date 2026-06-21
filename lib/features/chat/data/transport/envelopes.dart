/// WSS wire envelopes — the client side of the gateway's frozen `/v1` frame
/// contract (plan §A1). ALL wire knowledge lives here so a contract change
/// touches one file.
///
/// Phase 1 frames (verified against aiko_chat_gateway/realtime/envelopes.py):
///   client -> server: subscribe {channel_ids}, send {client_msg_id, channel_id, body, reply_to?}
///   server -> client: ack {client_msg_id, msg_id, created_at}, message {msg}, error {code, detail, ref_client_msg_id?}
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// Server -> client (inbound). Sealed: exhaustive switch at the call site.
// ---------------------------------------------------------------------------

sealed class ServerFrame {
  const ServerFrame();

  /// Parse a raw inbound text frame. NEVER throws: a malformed or
  /// unrecognised frame becomes [UnknownFrame] (logged + dropped by the
  /// transport) so an additive/garbled server frame can't kill the socket.
  static ServerFrame parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return UnknownFrame(raw, reason: 'not JSON');
    }
    if (decoded is! Map) {
      return UnknownFrame(raw, reason: 'not an object');
    }
    final j = decoded.cast<String, dynamic>();
    switch (j['type']) {
      case 'ack':
        final cmid = j['client_msg_id'];
        final mid = j['msg_id'];
        if (cmid is! String || mid is! String) {
          return UnknownFrame(raw, reason: 'ack missing ids');
        }
        return AckFrame(
          clientMsgId: cmid,
          msgId: mid,
          createdAt: j['created_at'] as String?,
        );
      case 'message':
        final msg = j['msg'];
        if (msg is! Map) {
          return UnknownFrame(raw, reason: 'message missing msg');
        }
        return MessageFrame(msg.cast<String, dynamic>());
      case 'error':
        return ErrorFrame(
          code: (j['code'] as String?) ?? 'unknown',
          detail: (j['detail'] as String?) ?? '',
          refClientMsgId: j['ref_client_msg_id'] as String?,
        );
      default:
        return UnknownFrame(raw, reason: 'unknown type ${j['type']}');
    }
  }
}

/// Server confirmed our send: maps our [clientMsgId] to the server [msgId].
/// This is what reconciles an optimistic row (sets its id + state=sent).
class AckFrame extends ServerFrame {
  final String clientMsgId;
  final String msgId;
  final String? createdAt;
  const AckFrame(
      {required this.clientMsgId, required this.msgId, this.createdAt});
}

/// A message to render. [msg] is a raw MessageView map (decode via
/// `Message.fromView`). Carries NO client_msg_id — the sender's own echo is
/// deduped by server id against the ack-reconciled row (ack precedes echo;
/// see docs/design/01-data-layer.md E2).
class MessageFrame extends ServerFrame {
  final Map<String, dynamic> msg;
  const MessageFrame(this.msg);

  String? get msgId => msg['msg_id'] as String?;
}

/// Server rejected/failed a frame. [refClientMsgId] ties it back to the
/// offending `send` when known (null for malformed subscribe/non-dict frames).
class ErrorFrame extends ServerFrame {
  final String code;
  final String detail;
  final String? refClientMsgId;
  const ErrorFrame(
      {required this.code, required this.detail, this.refClientMsgId});
}

/// A frame we couldn't classify. Held (not thrown) so the transport can log it
/// and continue; future server frame types land here on an old client.
class UnknownFrame extends ServerFrame {
  final String raw;
  final String reason;
  const UnknownFrame(this.raw, {required this.reason});
}

// ---------------------------------------------------------------------------
// Client -> server (outbound).
// ---------------------------------------------------------------------------

/// Subscribe to channels (membership-at-delivery enforced server-side, I2).
class SubscribeFrame {
  final List<String> channelIds;
  const SubscribeFrame(this.channelIds);

  Map<String, dynamic> toJson() =>
      {'type': 'subscribe', 'channel_ids': channelIds};

  String encode() => jsonEncode(toJson());
}

/// Send a text message. `client_msg_id` is the durable temp id (the reconcile
/// join key). NO sender field by construction (server derives it — I5).
class SendFrame {
  final String clientMsgId;
  final String channelId;
  final String body;
  final String? replyTo;
  const SendFrame({
    required this.clientMsgId,
    required this.channelId,
    required this.body,
    this.replyTo,
  });

  Map<String, dynamic> toJson() => {
        'type': 'send',
        'client_msg_id': clientMsgId,
        'channel_id': channelId,
        'body': body,
        if (replyTo != null) 'reply_to': replyTo,
      };

  String encode() => jsonEncode(toJson());
}
