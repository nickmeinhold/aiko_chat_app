import 'dart:async';

import 'package:aiko_chat_app/features/auth/data/passkey_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/identity_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/moderation/domain/moderation_models.dart';

/// A full-surface [ChatRestApi] fake for the widget/app-shell tests (the shipped
/// `FakeChatRestApi` only implements the B4 history slice). Each endpoint is
/// programmable; defaults are the happy path.
class FakeRestApi implements ChatRestApi {
  FakeRestApi({
    AppUser? user,
    List<Channel>? channels,
    this.meThrows,
  })  : user = user ?? defaultUser,
        channels = channels ?? const [defaultChannel];

  static const defaultUser = AppUser(
    userId: 'u1',
    username: 'nick',
    displayName: 'Nick',
    aikoUsername: 'nick',
  );
  static const defaultChannel =
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard);

  AppUser user;
  List<Channel> channels;

  /// If set, `me()` (cold-start restore) throws this.
  Object? meThrows;

  /// If set, `listChannels()` throws this (e.g. `NetworkUnavailable` to exercise
  /// the offline channel-cache fallback).
  Object? listChannelsThrows;

  /// When true, [listChannelsThrows] is cleared after the first throw — a
  /// TRANSIENT REST fault (fails once, healed by the time a retry lands).
  bool listChannelsThrowsOnce = false;

  /// If set, invoked INSIDE `me()` before it returns/throws — lets a test
  /// simulate a concurrent event (e.g. a terminal `unauthenticated` clearing
  /// tokens) racing the restore's `me()` call.
  void Function()? onMe;

  /// If set, `claimHandle` throws this (e.g. `HandleTaken`).
  Object? claimThrows;

  /// If set, `deleteAccount` throws this (e.g. `SoleAdminDeletionBlocked`).
  Object? deleteThrows;

  int meCalls = 0;
  int claimCalls = 0;
  int deleteCalls = 0;
  int listChannelsCalls = 0;

  AuthSession _session() => AuthSession(
        user: user,
        tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      );

  @override
  Future<String> refresh(String refreshToken) async => 'access2';

  @override
  Future<AppUser> me() async {
    meCalls++;
    onMe?.call();
    if (meThrows != null) throw meThrows!;
    return user;
  }

  /// Programmable passkey outcomes. Default register: a new identity that must
  /// claim a handle (first-passkey-creates-account). Default authenticate: a
  /// known identity (log straight in). Override per-test.
  IdentityOutcome? passkeyRegisterOutcome;
  IdentityOutcome? passkeyAuthOutcome;

  int passkeyRegisterStartCalls = 0;
  int passkeyRegisterFinishCalls = 0;
  int passkeyAuthStartCalls = 0;
  int passkeyAuthFinishCalls = 0;
  String? lastPasskeyRegisterState;
  String? lastPasskeyRegisterCredential;
  String? lastPasskeyAuthState;
  String? lastPasskeyAuthCredential;

  @override
  Future<PasskeyChallenge> startPasskeyRegistration() async {
    passkeyRegisterStartCalls++;
    return (state: 'reg-state', optionsJson: '{"challenge":"reg-chal"}');
  }

  @override
  Future<IdentityOutcome> finishPasskeyRegistration(
      String state, String credentialJson) async {
    passkeyRegisterFinishCalls++;
    lastPasskeyRegisterState = state;
    lastPasskeyRegisterCredential = credentialJson;
    return passkeyRegisterOutcome ??
        const PendingHandle(
            provisioningToken: 'passkey-prov', suggestedName: null);
  }

  @override
  Future<PasskeyChallenge> startPasskeyAuthentication() async {
    passkeyAuthStartCalls++;
    return (state: 'auth-state', optionsJson: '{"challenge":"auth-chal"}');
  }

  @override
  Future<IdentityOutcome> finishPasskeyAuthentication(
      String state, String credentialJson) async {
    passkeyAuthFinishCalls++;
    lastPasskeyAuthState = state;
    lastPasskeyAuthCredential = credentialJson;
    return passkeyAuthOutcome ?? Authenticated(_session());
  }

  /// If set, `addPasskey` throws this (e.g. `PasskeyAlreadyRegistered`).
  Object? addPasskeyThrows;
  int addPasskeyCalls = 0;
  String? lastAddPasskeyState;
  String? lastAddPasskeyCredential;

  @override
  Future<AppUser> addPasskey(String state, String credentialJson) async {
    addPasskeyCalls++;
    lastAddPasskeyState = state;
    lastAddPasskeyCredential = credentialJson;
    if (addPasskeyThrows != null) throw addPasskeyThrows!;
    return user;
  }

  @override
  Future<AuthSession> claimHandle({
    required String provisioningToken,
    required String handle,
    required String displayName,
  }) async {
    claimCalls++;
    if (claimThrows != null) throw claimThrows!;
    return _session();
  }

  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
    if (deleteThrows != null) throw deleteThrows!;
  }

  @override
  Future<List<Channel>> listChannels() async {
    listChannelsCalls++;
    if (listChannelsThrows != null) {
      final e = listChannelsThrows!;
      if (listChannelsThrowsOnce) listChannelsThrows = null;
      throw e;
    }
    return channels;
  }

  @override
  Future<HistoryPage> getHistory(String channelId,
          {String? before, String? after, int limit = 50}) async =>
      HistoryPage(channelId: channelId, messages: const []);

  // --- moderation (#7) — functional fakes so widget tests can drive block/report.

  /// Programmable: if set, the next block/unblock/report throws this.
  Object? moderationThrows;

  final List<BlockedUser> blocks = [];
  final List<(String messageId, ReportReason reason)> reportCalls = [];

  /// If set, `listBlocks` awaits this before returning — lets a test hold the
  /// initial load in flight to probe the block/build clobber race.
  Completer<void>? listBlocksGate;

  @override
  Future<void> blockUser(String userId) async {
    if (moderationThrows != null) throw moderationThrows!;
    if (blocks.any((b) => b.userId == userId)) return;
    blocks.insert(
        0,
        BlockedUser(
            userId: userId,
            displayName: 'User $userId',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)));
  }

  @override
  Future<void> unblockUser(String userId) async {
    if (moderationThrows != null) throw moderationThrows!;
    blocks.removeWhere((b) => b.userId == userId);
  }

  @override
  Future<List<BlockedUser>> listBlocks() async {
    if (listBlocksGate != null) await listBlocksGate!.future;
    return List.unmodifiable(blocks);
  }

  @override
  Future<void> reportMessage(String messageId, ReportReason reason) async {
    if (moderationThrows != null) throw moderationThrows!;
    reportCalls.add((messageId, reason));
  }
}

/// A [PasskeyAuthClient] fake — returns canned attestation/assertion JSON (or
/// throws, e.g. [AuthCeremonyCancelled]) without touching a platform channel.
class FakePasskeyAuthClient implements PasskeyAuthClient {
  FakePasskeyAuthClient({
    this.attestation = 'fake-attestation',
    this.assertion = 'fake-assertion',
    this.registerThrows,
    this.authenticateThrows,
    this.gate,
  });

  /// If set, the matching call throws this instead of returning a credential.
  Object? registerThrows;
  Object? authenticateThrows;
  String attestation;
  String assertion;

  /// If set, [register]/[authenticate] park on this completer before resolving —
  /// lets a test hold a ceremony in-flight (the platform sheet "open") to probe
  /// the controller's single-flight guard against a concurrent second ingress.
  Completer<void>? gate;

  int registerCalls = 0;
  int authenticateCalls = 0;
  String? lastRegisterOptions;
  String? lastAuthenticateOptions;

  @override
  Future<String> register(String optionsJson) async {
    registerCalls++;
    lastRegisterOptions = optionsJson;
    if (gate != null) await gate!.future;
    if (registerThrows != null) throw registerThrows!;
    return attestation;
  }

  @override
  Future<String> authenticate(String optionsJson) async {
    authenticateCalls++;
    lastAuthenticateOptions = optionsJson;
    if (gate != null) await gate!.future;
    if (authenticateThrows != null) throw authenticateThrows!;
    return assertion;
  }
}
