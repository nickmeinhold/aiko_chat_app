import 'dart:async';

import 'package:aiko_chat_app/features/auth/data/broker_auth_client.dart';
import 'package:aiko_chat_app/features/auth/data/passkey_auth_client.dart';
import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
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

  /// Programmable result of `socialSignIn`. Default: a known identity (log
  /// straight in). Set a [PendingHandle] to exercise the claim-handle path.
  SocialOutcome? socialOutcome;

  /// If set, `claimHandle` throws this (e.g. `HandleTaken`).
  Object? claimThrows;

  /// If set, `deleteAccount` throws this (e.g. `SoleAdminDeletionBlocked`).
  Object? deleteThrows;

  int meCalls = 0;
  int socialCalls = 0;
  int claimCalls = 0;
  int deleteCalls = 0;

  AuthSession _session() => AuthSession(
        user: user,
        tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      );

  @override
  Future<String> refresh(String refreshToken) async => 'access2';

  @override
  Future<AppUser> me() async {
    meCalls++;
    if (meThrows != null) throw meThrows!;
    return user;
  }

  @override
  Future<SocialOutcome> socialSignIn({
    required SocialProvider provider,
    required String idToken,
    required String rawNonce,
    String? name,
  }) async {
    socialCalls++;
    return socialOutcome ?? Authenticated(_session());
  }

  /// Programmable provider list for the login screen. Default mirrors the live
  /// gateway: native Apple/Google + the GitHub broker.
  List<AuthProviderInfo> authProviders = const [
    AuthProviderInfo(
        slug: 'apple', displayName: 'Apple', kind: AuthProviderKind.native),
    AuthProviderInfo(
        slug: 'google', displayName: 'Google', kind: AuthProviderKind.native),
    AuthProviderInfo(
        slug: 'github', displayName: 'GitHub', kind: AuthProviderKind.broker),
  ];

  /// Programmable result of `exchangeOAuth`. Default: a known identity (log
  /// straight in). Set a [PendingHandle] to exercise the broker claim path.
  SocialOutcome? brokerOutcome;

  int providersCalls = 0;
  int exchangeCalls = 0;

  @override
  Future<List<AuthProviderInfo>> listAuthProviders() async {
    providersCalls++;
    return authProviders;
  }

  String? lastExchangeVerifier;

  @override
  Future<SocialOutcome> exchangeOAuth(String code, String verifier) async {
    exchangeCalls++;
    lastExchangeVerifier = verifier;
    return brokerOutcome ?? Authenticated(_session());
  }

  /// Programmable passkey outcomes. Default register: a new identity that must
  /// claim a handle (first-passkey-creates-account). Default authenticate: a
  /// known identity (log straight in). Override per-test.
  SocialOutcome? passkeyRegisterOutcome;
  SocialOutcome? passkeyAuthOutcome;

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
  Future<SocialOutcome> finishPasskeyRegistration(
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
  Future<SocialOutcome> finishPasskeyAuthentication(
      String state, String credentialJson) async {
    passkeyAuthFinishCalls++;
    lastPasskeyAuthState = state;
    lastPasskeyAuthCredential = credentialJson;
    return passkeyAuthOutcome ?? Authenticated(_session());
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
  Future<List<Channel>> listChannels() async => channels;

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

/// A [SocialAuthClient] fake — returns a canned credential (or throws, e.g.
/// [SocialSignInCancelled]) without touching a platform channel.
class FakeSocialAuthClient implements SocialAuthClient {
  FakeSocialAuthClient({this.credential, this.throws});

  /// If set, [signIn] throws this instead of returning a credential.
  Object? throws;
  SocialCredential? credential;

  int signInCalls = 0;
  SocialProvider? lastProvider;

  @override
  Future<SocialCredential> signIn(SocialProvider provider) async {
    signInCalls++;
    lastProvider = provider;
    if (throws != null) throw throws!;
    return credential ??
        SocialCredential(
          provider: provider,
          idToken: 'fake-id-token',
          rawNonce: 'fake-nonce',
          name: 'Fake Name',
        );
  }
}

/// A [BrokerAuthClient] fake — returns a canned handoff code (or throws, e.g.
/// [SocialSignInCancelled]) without opening a real web-auth session.
class FakeBrokerAuthClient implements BrokerAuthClient {
  FakeBrokerAuthClient(
      {this.code = 'fake-handoff', this.verifier = 'fake-verifier', this.throws});

  /// If set, [authenticate] throws this instead of returning a handoff.
  Object? throws;
  String code;
  String verifier;

  int authCalls = 0;
  String? lastSlug;

  @override
  Future<BrokerHandoff> authenticate(String slug) async {
    authCalls++;
    lastSlug = slug;
    if (throws != null) throw throws!;
    return (code: code, verifier: verifier);
  }
}

/// A [PasskeyAuthClient] fake — returns canned attestation/assertion JSON (or
/// throws, e.g. [SocialSignInCancelled]) without touching a platform channel.
class FakePasskeyAuthClient implements PasskeyAuthClient {
  FakePasskeyAuthClient({
    this.attestation = 'fake-attestation',
    this.assertion = 'fake-assertion',
    this.registerThrows,
    this.authenticateThrows,
  });

  /// If set, the matching call throws this instead of returning a credential.
  Object? registerThrows;
  Object? authenticateThrows;
  String attestation;
  String assertion;

  int registerCalls = 0;
  int authenticateCalls = 0;
  String? lastRegisterOptions;
  String? lastAuthenticateOptions;

  @override
  Future<String> register(String optionsJson) async {
    registerCalls++;
    lastRegisterOptions = optionsJson;
    if (registerThrows != null) throw registerThrows!;
    return attestation;
  }

  @override
  Future<String> authenticate(String optionsJson) async {
    authenticateCalls++;
    lastAuthenticateOptions = optionsJson;
    if (authenticateThrows != null) throw authenticateThrows!;
    return assertion;
  }
}
