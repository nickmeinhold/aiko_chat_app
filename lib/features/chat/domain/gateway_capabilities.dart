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
/// **Three states, not two (cage-match Tesla + Carnot).** The gate must
/// distinguish *known-carriage* (`true`), *known-non-carriage* (`false`), and
/// *unknown* (couldn't determine). [parse] returns a concrete value ONLY for an
/// explicit JSON boolean `origin`; an absent, non-bool, or malformed document
/// decodes to **null = unknown**, which the resolver reads as "keep the seed"
/// rather than an authoritative OFF. This is load-bearing: during the island's
/// `/capabilities` rollout a stub 200 (`{}` / `{"carriage":{}}`) must NOT flip
/// an allowlisted, already-carrying host off — that would break the
/// no-regression property the whole feature rests on. A hostile document still
/// cannot *enable* emit: only a strict `== true` turns it on.
class GatewayCapabilities {
  /// Whether this gateway carries the sovereign `origin` envelope (i.e. it will
  /// persist + re-emit it rather than `bad_origin`-rejecting the whole message).
  final bool carriesOrigin;

  const GatewayCapabilities({required this.carriesOrigin});

  /// Parse the `/capabilities` document. Returns:
  ///  - `GatewayCapabilities(carriesOrigin: true/false)` for an explicit JSON
  ///    boolean at `carriage.origin` (the endpoint is authoritative), or
  ///  - `null` ("unknown") when `carriage.origin` is absent or not a bool — a
  ///    partial/stub/hostile 200 is then treated identically to a 404: keep the
  ///    seed. Only an explicit bool ever moves the gate.
  static GatewayCapabilities? parse(Map<String, dynamic> json) {
    final carriage = json['carriage'];
    final origin = carriage is Map ? carriage['origin'] : null;
    if (origin is bool) return GatewayCapabilities(carriesOrigin: origin);
    return null; // absent / malformed / non-bool → unknown, never authoritative
  }
}
