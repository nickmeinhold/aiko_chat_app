import 'dart:async';

import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/moderation/domain/moderation_models.dart';

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

  /// How many times the repository routed to [disconnect] (the auth-terminal
  /// path: a reconnect that hit [Unauthorized] disconnects → unauthenticated).
  int disconnectCalls = 0;

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
  Future<void> disconnect() async {
    disconnectCalls++;
    emitConn(ConnectionState.disconnected);
  }

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

  /// Emit an error from a RAW wire `code`, running it through the production
  /// [TransportErrorCode.fromWire] mapping (exactly as `gateway_transport` does)
  /// so tests exercise the real raw→enum classification — including the
  /// unknown-code path — rather than hand-supplying the parsed enum.
  void emitErrorCode(String code,
          {String detail = '', String? refClientMsgId}) =>
      _errors.add(TransportError(
        code: code,
        parsedCode: TransportErrorCode.fromWire(code),
        detail: detail,
        refClientMsgId: refClientMsgId,
      ));
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

  /// If set, getHistory throws this on EVERY call (terminal/transient paths).
  Object? throwOnGetHistory;

  /// getHistory throws for these specific `after` cursors (simulate a mid-sync
  /// failure on one page). Keyed by the resolved cursor (`null` → '').
  final Set<String> throwOnAfter = {};

  /// If set, getHistory awaits this gate before returning — lets a test hold a
  /// page in flight to probe re-entrancy / TOCTOU.
  Completer<void>? getHistoryGate;

  @override
  Future<HistoryPage> getHistory(String channelId,
      {String? before, String? after, int limit = 50}) async {
    getHistoryCalls.add(after);
    if (getHistoryGate != null) await getHistoryGate!.future;
    if (throwOnGetHistory != null) throw throwOnGetHistory!;
    if (throwOnAfter.contains(after ?? '')) {
      throw StateError('staged failure on after=${after ?? ''}');
    }
    return pagesByAfter[after ?? ''] ??
        HistoryPage(channelId: channelId, messages: const []);
  }

  @override
  Future<String> refresh(String refreshToken) => throw UnimplementedError();
  @override
  Future<AppUser> me() => throw UnimplementedError();
  @override
  Future<void> deleteAccount() => throw UnimplementedError();
  @override
  Future<List<Channel>> listChannels() => throw UnimplementedError();
  @override
  Future<void> blockUser(String userId) => throw UnimplementedError();
  @override
  Future<void> unblockUser(String userId) => throw UnimplementedError();
  @override
  Future<List<BlockedUser>> listBlocks() => throw UnimplementedError();
  @override
  Future<void> reportMessage(String messageId, ReportReason reason) =>
      throw UnimplementedError();
  @override
  Future<List<AuthProviderInfo>> listAuthProviders() =>
      throw UnimplementedError();
  @override
  Future<SocialOutcome> exchangeOAuth(String code) => throw UnimplementedError();
  @override
  Future<SocialOutcome> socialSignIn({
    required SocialProvider provider,
    required String idToken,
    required String rawNonce,
    String? name,
  }) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> claimHandle({
    required String provisioningToken,
    required String handle,
    required String displayName,
  }) =>
      throw UnimplementedError();
}

/// Records the observability calls B4 makes, so tests can assert that the
/// "must be seen, never swallowed" cases (orphan ack, reconnect failure, history
/// gap) actually fired.
class SpyTelemetry extends ChatTelemetry {
  final List<(String, String)> orphans = [];
  final List<Object> reconnectErrors = [];
  final List<(String, String?, String)> historyGaps = [];
  final List<Object> inboundWriteErrors = [];

  @override
  void orphanAck(String clientMsgId, String serverUlid) =>
      orphans.add((clientMsgId, serverUlid));
  @override
  void reconnectFailed(Object error, StackTrace stack) =>
      reconnectErrors.add(error);
  @override
  void historyGapBeforeFence(String channelId, String? cursor, String fence) =>
      historyGaps.add((channelId, cursor, fence));
  @override
  void inboundWriteFailed(Object error, StackTrace stack) =>
      inboundWriteErrors.add(error);
}
