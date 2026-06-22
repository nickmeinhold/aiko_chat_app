import 'dart:async';

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';

/// A [ChatTransport] faked at the INTERFACE level (the shipped fakes are at the
/// `WebSocketChannel` level — too low for B4, design 04 test plan). Tests drive
/// the inbound streams via `emitAck/emitMessage/emitError/emitConn` and inspect
/// the recorded `sent` log + `subscribeCalls`.
class FakeChatTransport implements ChatTransport {
  final _messages = StreamController<Message>.broadcast();
  final _acks = StreamController<AckResult>.broadcast();
  final _errors = StreamController<TransportError>.broadcast();
  final _conn = StreamController<ConnectionState>.broadcast();

  /// Every `sendMessage` the repository dispatched, in order (drain + W1 sends).
  final List<OutgoingMessage> sent = [];

  /// Every `subscribe(channelIds)` call, in order.
  final List<List<String>> subscribeCalls = [];

  /// Fence map `subscribe` resolves with, per channel. A channel absent here
  /// resolves to `""` (empty fence = page from the start).
  Map<String, String> fences = {};

  /// If set, `subscribe` awaits this gate before returning — lets a test wedge
  /// the choreography mid-subscribe to probe ordering/abort.
  Completer<void>? subscribeGate;

  /// Fired synchronously inside `sendMessage`, before it returns — lets a test
  /// observe cache state at the exact moment of dispatch (W1 commit-before-send).
  void Function(OutgoingMessage)? onSend;

  bool disposed = false;

  @override
  Stream<ConnectionState> get connectionState => _conn.stream;
  @override
  Stream<Message> get messages => _messages.stream;
  @override
  Stream<AckResult> get acks => _acks.stream;
  @override
  Stream<TransportError> get errors => _errors.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async => emitConn(ConnectionState.disconnected);

  @override
  Future<Map<String, String>> subscribe(List<String> channelIds) async {
    subscribeCalls.add(List.of(channelIds));
    if (subscribeGate != null) await subscribeGate!.future;
    return {for (final c in channelIds) c: fences[c] ?? ''};
  }

  @override
  String sendMessage(OutgoingMessage message) {
    sent.add(message);
    onSend?.call(message);
    return message.clientTempId;
  }

  // --- test drivers ----------------------------------------------------------
  void emitAck(String clientMsgId, String msgId, {String? createdAt}) => _acks
      .add(AckResult(clientMsgId: clientMsgId, msgId: msgId, createdAt: createdAt));
  void emitMessage(Message m) => _messages.add(m);
  void emitError(TransportError e) => _errors.add(e);
  void emitConn(ConnectionState s) => _conn.add(s);

  Future<void> dispose() async {
    disposed = true;
    await _messages.close();
    await _acks.close();
    await _errors.close();
    await _conn.close();
  }
}

/// A [ChatRestApi] faked for B4: `getHistory` returns pre-staged pages keyed by
/// the `after` cursor (null = the from-start page), and records every call.
/// Only the history surface B4 touches is implemented; the rest throw.
class FakeChatRestApi implements ChatRestApi {
  /// Pages to return keyed by the `after` cursor passed in (`null` → the key '').
  /// Each call pops the page for that cursor; an unmapped cursor yields an empty
  /// page (server has nothing more).
  final Map<String, HistoryPage> pagesByAfter = {};

  /// Every getHistory call's `after` cursor, in order.
  final List<String?> getHistoryCalls = [];

  /// If set, getHistory throws this (test terminal/transient error paths).
  Object? throwOnGetHistory;

  @override
  Future<HistoryPage> getHistory(String channelId,
      {String? before, String? after, int limit = 50}) async {
    getHistoryCalls.add(after);
    if (throwOnGetHistory != null) throw throwOnGetHistory!;
    return pagesByAfter[after ?? ''] ??
        HistoryPage(channelId: channelId, messages: const []);
  }

  @override
  Future<AuthSession> login(String username, String password) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> register(String u, String d, String p) =>
      throw UnimplementedError();
  @override
  Future<String> refresh(String refreshToken) => throw UnimplementedError();
  @override
  Future<AppUser> me() => throw UnimplementedError();
  @override
  Future<List<Channel>> listChannels() => throw UnimplementedError();
}
