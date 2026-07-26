/// The subset of a gateway's advertised `GET /capabilities` document this app
/// acts on (task #1896 — capability-gated sovereign `origin` emit).
///
/// Wire shape (island `/capabilities`, a public/token-less endpoint sibling of
/// `/health`):
///
/// ```json
/// { "carriage": { "origin": true } }
/// ```
///
/// **Fail-closed decode:** any absent, non-bool, or malformed field decodes to
/// `carriesOrigin == false`. A partial or hostile document can therefore only
/// ever *withhold* emit, never *enable* it — the capability must be positively
/// and correctly asserted to turn origin on.
class GatewayCapabilities {
  /// Whether this gateway carries the sovereign `origin` envelope (i.e. it will
  /// persist + re-emit it rather than `bad_origin`-rejecting the whole message).
  final bool carriesOrigin;

  const GatewayCapabilities({required this.carriesOrigin});

  factory GatewayCapabilities.fromJson(Map<String, dynamic> json) {
    final carriage = json['carriage'];
    final origin = carriage is Map ? carriage['origin'] : null;
    // Strict `== true`: a String "true", 1, or null all decode to false.
    return GatewayCapabilities(carriesOrigin: origin == true);
  }
}
