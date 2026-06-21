import '../../auth/domain/auth_models.dart';
import '../domain/channel.dart';
import '../domain/message.dart';

/// A page of history: messages plus the cursor to fetch the previous page.
/// [nextBefore] is the gateway's `next_before` (the oldest id in this batch);
/// pass it as the next `before`. Null when there is no older history.
class HistoryPage {
  final String channelId;
  final List<Message> messages;
  final String? nextBefore;
  const HistoryPage(
      {required this.channelId, required this.messages, this.nextBefore});
}

/// The history/auth/media REST seam (plan §B1; media is a later phase). No
/// lifecycle. Riverpod + the repository depend on THIS, never on `dio`.
abstract interface class ChatRestApi {
  Future<AuthSession> login(String username, String password);
  Future<AuthSession> register(
      String username, String displayName, String password);

  /// Exchange a refresh token for a fresh access token (the refresh token is
  /// NOT rotated by the gateway). Returns the new access token.
  Future<String> refresh(String refreshToken);

  Future<AppUser> me();
  Future<List<Channel>> listChannels();
  Future<HistoryPage> getHistory(String channelId,
      {String? before, int limit = 50});
}
