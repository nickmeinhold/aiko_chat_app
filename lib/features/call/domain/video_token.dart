/// The join credentials for an A/V call, returned by the island's
/// `POST /v1/channels/{channel_id}/video-token` endpoint (handoff #2726).
///
/// The [room] is the channel id itself — a call happens *inside* an existing
/// channel. Participant identity is **server-derived** and baked into [token];
/// the client neither sets nor can influence it (ADR-0005 `speaks-as` resolved
/// server-side, where it cannot be forged). We only ever `Room.connect(url,
/// token)`.
class VideoToken {
  const VideoToken({
    required this.token,
    required this.url,
    required this.room,
  });

  /// The LiveKit JWT — short TTL, checked only at connect (the session outlives
  /// it), so a reconnect must fetch a *fresh* token.
  final String token;

  /// The SFU websocket URL (e.g. `wss://livekit.imagineering.cc`). Comes from
  /// the response, never hardcoded — the deployment owns its transport.
  final String url;

  /// The LiveKit room == the channel id.
  final String room;

  factory VideoToken.fromJson(Map<String, dynamic> json) => VideoToken(
        token: json['token'] as String,
        url: json['url'] as String,
        room: json['room'] as String,
      );
}
