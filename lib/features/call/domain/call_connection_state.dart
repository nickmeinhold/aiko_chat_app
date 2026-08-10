/// UI-facing lifecycle of an A/V call, parallel to `chat_transport.dart`'s
/// `ConnectionState` for the message wire. The [CallScreen] renders off this.
enum CallConnectionState {
  /// First connect in flight (fetching token + `Room.connect`).
  connecting,

  /// Live in the room.
  connected,

  /// Connection was lost; the bounded-backoff reconnect loop is running.
  reconnecting,

  /// Terminal failure — auth expired, room unreachable, or retries exhausted.
  failed,

  /// The deployment has video disabled (island returned 503). Not an error to
  /// retry — the affordance should be hidden/disabled where this is known.
  videoUnavailable,
}

/// The outcome of a single [LiveKitCallService.connect] attempt. Split so the
/// reconnect loop can distinguish *retry* (network) from *abort* (auth) from
/// *terminal* (video disabled / not a member) — retrying an auth failure as a
/// network blip just burns the backoff schedule.
enum ConnectionResult {
  connected,

  /// A connect was requested while already connecting/connected — a no-op the
  /// caller can treat as success.
  alreadyConnected,

  /// The `Room.connect` itself failed (SFU/TURN unreachable). May be transient
  /// — the reconnect loop keeps trying.
  roomFailed,

  /// The session token was rejected (401/403). Retries won't fix it — abort the
  /// loop and route to re-auth.
  tokenAuthError,

  /// Couldn't reach the island to mint a token (offline). Transient — retry.
  tokenNetworkError,

  /// The island returned 503: video isn't enabled on this deployment. Terminal,
  /// but not a *failure* to apologise for — surface it as "unavailable here."
  videoUnavailable,

  /// The channel doesn't exist for this member (404, existence-hiding). Terminal.
  channelUnavailable,
}
