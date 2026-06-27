import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';

/// A full-surface [ChatRestApi] fake for the widget/app-shell tests (the shipped
/// `FakeChatRestApi` only implements the B4 history slice). Each endpoint is
/// programmable; defaults are the happy path.
class FakeRestApi implements ChatRestApi {
  FakeRestApi({
    AppUser? user,
    List<Channel>? channels,
    this.loginThrows,
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

  /// If set, `login`/`register` throw this (e.g. `Unauthorized(401)`).
  Object? loginThrows;

  /// If set, `me()` (cold-start restore) throws this.
  Object? meThrows;

  /// Programmable result of `socialSignIn`. Default: a known identity (log
  /// straight in). Set a [PendingHandle] to exercise the claim-handle path.
  SocialOutcome? socialOutcome;

  /// If set, `claimHandle` throws this (e.g. `HandleTaken`).
  Object? claimThrows;

  int loginCalls = 0;
  int meCalls = 0;
  int socialCalls = 0;
  int claimCalls = 0;

  AuthSession _session() => AuthSession(
        user: user,
        tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      );

  @override
  Future<AuthSession> login(String username, String password) async {
    loginCalls++;
    if (loginThrows != null) throw loginThrows!;
    return _session();
  }

  @override
  Future<AuthSession> register(String u, String d, String p) async {
    if (loginThrows != null) throw loginThrows!;
    return _session();
  }

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
  Future<List<Channel>> listChannels() async => channels;

  @override
  Future<HistoryPage> getHistory(String channelId,
          {String? before, String? after, int limit = 50}) async =>
      HistoryPage(channelId: channelId, messages: const []);
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
