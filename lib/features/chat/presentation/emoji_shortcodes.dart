/// Inline `:shortcode:` emoji autocomplete data + matching logic (#12).
///
/// The composer watches the caret for an unclosed `:token` and offers matching
/// emoji as you type. The matching is kept as PURE top-level functions here (not
/// buried in the widget State) so the fiddly parts — that `:smi` triggers but
/// `http://` and `12:30` do not, and that `startsWith` ranks above `contains` —
/// are unit-testable without a widget harness.
library;

/// Curated shortcode → emoji map. Keys are the GitHub/Slack-style names typed
/// between colons (`:smile:`), lower-case, `[a-z0-9_+-]`. A curated set rather
/// than a full unicode-name dependency: enough to be genuinely useful, small
/// enough to read. Multiple shortcodes may map to the same emoji (aliases).
const Map<String, String> kEmojiShortcodes = {
  // faces — positive
  'grinning': '😀', 'smile': '😄', 'smiley': '😃', 'grin': '😁',
  'laughing': '😆', 'sweat_smile': '😅', 'joy': '😂', 'rofl': '🤣',
  'blush': '😊', 'slightly_smiling_face': '🙂', 'wink': '😉',
  'heart_eyes': '😍', 'smiling_face_with_three_hearts': '🥰',
  'kissing_heart': '😘', 'yum': '😋', 'sunglasses': '😎', 'cool': '😎',
  'star_struck': '🤩', 'partying_face': '🥳', 'hugs': '🤗',
  // faces — thinking / neutral
  'thinking': '🤔', 'raised_eyebrow': '🤨', 'neutral_face': '😐',
  'expressionless': '😑', 'roll_eyes': '🙄', 'unamused': '😒',
  'smirk': '😏', 'zipper_mouth_face': '🤐', 'shushing_face': '🤫',
  'sleeping': '😴', 'sleepy': '😪', 'relieved': '😌',
  // faces — negative
  'confused': '😕', 'worried': '😟', 'frowning': '😦', 'anguished': '😧',
  'cry': '😢', 'sob': '😭', 'weary': '😩', 'tired_face': '😫',
  'triumph': '😤', 'angry': '😠', 'rage': '😡', 'exploding_head': '🤯',
  'flushed': '😳', 'pleading_face': '🥺', 'fearful': '😨', 'cold_sweat': '😰',
  'scream': '😱', 'astonished': '😲', 'dizzy_face': '😵',
  // faces — misc
  'innocent': '😇', 'nerd_face': '🤓', 'money_mouth_face': '🤑',
  'face_with_monocle': '🧐', 'zany_face': '🤪', 'upside_down_face': '🙃',
  'sneezing_face': '🤧', 'mask': '😷', 'nauseated_face': '🤢',
  // hands / gestures
  'thumbsup': '👍', '+1': '👍', 'thumbsdown': '👎', '-1': '👎',
  'ok_hand': '👌', 'pray': '🙏', 'clap': '👏', 'raised_hands': '🙌',
  'muscle': '💪', 'handshake': '🤝', 'wave': '👋', 'point_up': '☝️',
  'point_down': '👇', 'point_left': '👈', 'point_right': '👉',
  'crossed_fingers': '🤞', 'v': '✌️', 'call_me_hand': '🤙',
  'fist': '✊', 'punch': '👊', 'writing_hand': '✍️',
  // hearts / symbols
  'heart': '❤️', 'orange_heart': '🧡', 'yellow_heart': '💛',
  'green_heart': '💚', 'blue_heart': '💙', 'purple_heart': '💜',
  'black_heart': '🖤', 'broken_heart': '💔', 'two_hearts': '💕',
  'sparkling_heart': '💖', 'heartpulse': '💗',
  // celebration / objects
  'fire': '🔥', 'sparkles': '✨', 'tada': '🎉', 'confetti_ball': '🎊',
  'balloon': '🎈', 'gift': '🎁', 'trophy': '🏆', 'medal': '🏅',
  'star': '⭐', 'star2': '🌟', 'boom': '💥', 'zap': '⚡',
  'hundred': '💯', '100': '💯', 'eyes': '👀', 'bulb': '💡',
  'rocket': '🚀', 'anchor': '⚓', 'wave_ocean': '🌊',
  // check / marks
  'white_check_mark': '✅', 'heavy_check_mark': '✔️', 'x': '❌',
  'warning': '⚠️', 'question': '❓', 'exclamation': '❗',
  'no_entry': '⛔', 'recycle': '♻️',
  // people / animals / food (small taste)
  'ghost': '👻', 'robot': '🤖', 'alien': '👽', 'skull': '💀',
  'poop': '💩', 'clown_face': '🤡', 'dog': '🐶', 'cat': '🐱',
  'unicorn': '🦄', 'coffee': '☕', 'beer': '🍺', 'pizza': '🍕',
  'cake': '🎂', 'apple': '🍎',
};

/// The active `:shortcode` token immediately before [caret], or null.
///
/// A token is `:` followed by one-or-more shortcode chars (`[a-z0-9_+-]`), with
/// the caret at its end and no closing colon yet. The `:` must be at the start
/// of the field or preceded by whitespace — so `http://`, `12:30` and a completed
/// `:smile:` do NOT trigger the picker. Matching is case-insensitive downstream,
/// so upper-case in the query is tolerated here.
({int start, String query})? activeShortcodeToken(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final before = text.substring(0, caret);
  final colon = before.lastIndexOf(':');
  if (colon < 0) return null;
  // Preceding char must be the field start or whitespace (not part of a URL/time).
  if (colon > 0 && !RegExp(r'\s').hasMatch(before[colon - 1])) return null;
  final query = before.substring(colon + 1);
  if (query.isEmpty) return null;
  if (!RegExp(r'^[a-zA-Z0-9_+-]+$').hasMatch(query)) return null;
  return (start: colon, query: query);
}

/// Shortcodes matching [query], `startsWith` ranked above `contains`, then
/// alphabetical within each band, capped at [limit]. Returns (shortcode, emoji)
/// entries. An empty query returns nothing (the picker only opens once the user
/// has typed at least one character after the colon).
List<MapEntry<String, String>> filterEmojiShortcodes(
  String query, {
  int limit = 8,
}) {
  final q = query.toLowerCase();
  if (q.isEmpty) return const [];
  final starts = <MapEntry<String, String>>[];
  final contains = <MapEntry<String, String>>[];
  for (final e in kEmojiShortcodes.entries) {
    if (e.key.startsWith(q)) {
      starts.add(e);
    } else if (e.key.contains(q)) {
      contains.add(e);
    }
  }
  int byKey(MapEntry<String, String> a, MapEntry<String, String> b) =>
      a.key.compareTo(b.key);
  starts.sort(byKey);
  contains.sort(byKey);
  return [...starts, ...contains].take(limit).toList();
}
