import 'package:aiko_chat_app/features/chat/presentation/emoji_shortcodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('activeShortcodeToken', () {
    test('detects a token at the caret after whitespace', () {
      const text = 'hello :smi';
      final tok = activeShortcodeToken(text, text.length);
      expect(tok, isNotNull);
      expect(tok!.start, 6);
      expect(tok.query, 'smi');
    });

    test('detects a token at the very start of the field', () {
      const text = ':fire';
      final tok = activeShortcodeToken(text, text.length);
      expect(tok!.start, 0);
      expect(tok.query, 'fire');
    });

    test(
      'does NOT trigger inside a URL (colon not preceded by whitespace)',
      () {
        const text = 'see http://x';
        expect(activeShortcodeToken(text, text.length), isNull);
      },
    );

    test('does NOT trigger inside a time like 12:30', () {
      const text = 'at 12:30';
      expect(activeShortcodeToken(text, text.length), isNull);
    });

    test('does NOT trigger mid-word (a:smi)', () {
      const text = 'a:smi';
      expect(activeShortcodeToken(text, text.length), isNull);
    });

    test('does NOT trigger on a completed :shortcode:', () {
      const text = ':smile: ';
      // caret right after the closing colon
      expect(activeShortcodeToken(text, 7), isNull);
    });

    test('empty query (bare colon) does not trigger', () {
      const text = 'hi :';
      expect(activeShortcodeToken(text, text.length), isNull);
    });

    test('respects the caret position, not just end of text', () {
      const text = ':smi later';
      // caret just after ':smi'
      final tok = activeShortcodeToken(text, 4);
      expect(tok!.query, 'smi');
    });

    test('an invalid (-1) caret yields null', () {
      expect(activeShortcodeToken('anything', -1), isNull);
    });
  });

  group('filterEmojiShortcodes', () {
    test('ranks startsWith above contains, alphabetical within', () {
      final r = filterEmojiShortcodes('smi');
      expect(r, isNotEmpty);
      // every result contains the query
      expect(r.every((e) => e.key.contains('smi')), isTrue);
      // the startsWith matches come first and are alphabetised
      final starts = r.where((e) => e.key.startsWith('smi')).toList();
      expect(starts.first.key, 'smile');
      // 'smile' (startsWith) outranks 'sweat_smile' (contains only)
      final smileIdx = r.indexWhere((e) => e.key == 'smile');
      final sweatIdx = r.indexWhere((e) => e.key == 'sweat_smile');
      if (sweatIdx != -1) expect(smileIdx, lessThan(sweatIdx));
    });

    test('is case-insensitive', () {
      expect(
        filterEmojiShortcodes('SMI').map((e) => e.key),
        filterEmojiShortcodes('smi').map((e) => e.key),
      );
    });

    test('resolves an exact common shortcode to its emoji', () {
      final fire = filterEmojiShortcodes(
        'fire',
      ).firstWhere((e) => e.key == 'fire');
      expect(fire.value, '🔥');
    });

    test('handles + in a shortcode (:+1:)', () {
      final r = filterEmojiShortcodes('+1');
      expect(r.first.value, '👍');
    });

    test('empty query returns nothing', () {
      expect(filterEmojiShortcodes(''), isEmpty);
    });

    test('no match returns nothing', () {
      expect(filterEmojiShortcodes('zzzznotathing'), isEmpty);
    });

    test('respects the limit', () {
      expect(filterEmojiShortcodes('a', limit: 3).length, lessThanOrEqualTo(3));
    });
  });
}
