/// Channel domain type (Phase 1).
///
/// Wire shape from `GET /v1/channels`: `{id, name, kind, aiko_channel}`.
/// Note the wire does NOT carry `is_private` yet (the gateway model has it but
/// doesn't serialize it), so the app can't show a privacy indicator until it does.
library;

enum ChannelKind {
  standard,
  llm,
  robot,
  dm;

  static ChannelKind fromWire(String? raw) {
    switch (raw) {
      case 'llm':
        return ChannelKind.llm;
      case 'robot':
        return ChannelKind.robot;
      case 'dm':
        return ChannelKind.dm;
      case 'standard':
      default:
        return ChannelKind.standard; // unknown / null -> standard
    }
  }

  String get wire => name;
}

class Channel {
  final String id;
  final String name;
  final ChannelKind kind;

  /// The aiko bus channel this maps to (gateway concern; carried for
  /// completeness, UI ignores it in Phase 1).
  final String? aikoChannel;

  const Channel({
    required this.id,
    required this.name,
    required this.kind,
    this.aikoChannel,
  });

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        kind: ChannelKind.fromWire(j['kind'] as String?),
        aikoChannel: j['aiko_channel'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Channel &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.aikoChannel == aikoChannel;

  @override
  int get hashCode => Object.hash(id, name, kind, aikoChannel);
}
