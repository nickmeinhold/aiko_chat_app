import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
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

  int loginCalls = 0;
  int meCalls = 0;

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
  Future<List<Channel>> listChannels() async => channels;

  @override
  Future<HistoryPage> getHistory(String channelId,
          {String? before, String? after, int limit = 50}) async =>
      HistoryPage(channelId: channelId, messages: const []);
}
