/// A selectable gateway in the picker (#4).
///
/// Deliberately a flat value object (label + base URL) so P2 can swap the source
/// of the list — from these hardcoded presets to the live discovery directory
/// (Design 05 §10) — without touching the picker UI. The directory entry will
/// carry more (latency, member counts, …); the picker only ever needs these two.
library;

class ServerEntry {
  /// Human label shown in the picker, e.g. "Production".
  final String label;

  /// The gateway HTTP base URL, e.g. `https://chat.imagineering.cc`. Normalized
  /// at switch time via `GatewayConfig.normalized`.
  final String httpBaseUrl;

  const ServerEntry({required this.label, required this.httpBaseUrl});
}

/// The built-in presets — the launch source for the picker list. Production is
/// first so the common case (point at the live server) is one tap. Local and the
/// Android-emulator loopback cover dev against a gateway on the host machine.
const kGatewayPresets = <ServerEntry>[
  ServerEntry(label: 'Production', httpBaseUrl: 'https://chat.imagineering.cc'),
  ServerEntry(label: 'Local', httpBaseUrl: 'http://localhost:8095'),
  ServerEntry(
      label: 'Android emulator', httpBaseUrl: 'http://10.0.2.2:8095'),
];
