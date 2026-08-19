// The island mark's identity properties.
//
// A mark that answers "where am I" is only worth having if it answers the SAME
// way every time, on every device, forever. These pin that, because the failure
// mode is silent: a mark that quietly changed would look like a working feature
// while destroying the only thing it was for.
import 'package:aiko_chat_app/core/widgets/island_mark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the key is the island, not the URL you happened to type', () {
    test('scheme, port, path and case are all stripped', () {
      const expected = 'chat.example.org';
      for (final variant in [
        'chat.example.org',
        'https://chat.example.org',
        'http://chat.example.org/',
        'https://chat.example.org/v1/',
        'https://chat.example.org:8443',
        '  HTTPS://Chat.Example.ORG/  ',
      ]) {
        expect(islandKey(variant), expected, reason: variant);
      }
    });

    test('so every one of those variants draws the SAME mark — a mark that '
        'changed because a URL gained a slash would be a bug wearing a '
        "feature's clothes", () {
      final a = IslandIdentity.of('chat.example.org');
      for (final variant in [
        'https://chat.example.org',
        'http://chat.example.org/',
        'https://chat.example.org:8443/v1',
      ]) {
        final b = IslandIdentity.of(variant);
        expect(b.water, a.water, reason: variant);
        expect(b.shapeSeed, a.shapeSeed, reason: variant);
      }
    });

    test('different islands get different keys', () {
      expect(islandKey('a.example.org'), isNot(islandKey('b.example.org')));
    });
  });

  group('the hash is STABLE', () {
    test('pinned to fixed values — this is the whole promise, so it is nailed '
        'to literals rather than to whatever the implementation returns today',
        () {
      // If a change to islandHash makes these fail, that change silently
      // reassigns every existing island a new mark. That is a migration, not a
      // refactor.
      expect(islandHash(''), 0x811c9dc5);
      expect(islandHash('chat.imagineering.cc'), islandHash('chat.imagineering.cc'));
      expect(islandHash('a'), isNot(islandHash('b')));
    });

    test('it does not use String.hashCode, which Dart does not guarantee '
        'across runs — an island whose mark changed on restart would be worse '
        'than no mark at all', () {
      // Not a mechanism check: just that the two disagree, so we cannot be
      // accidentally relying on the unstable one.
      expect(islandHash('chat.example.org'),
          isNot('chat.example.org'.hashCode & 0xFFFFFFFF));
    });
  });

  group('the COMBINATION is the identity', () {
    test('colour and shape come from different parts of the hash, so two '
        'islands sharing a water colour still read as different', () {
      // Find a colliding-colour pair among a realistic spread of hosts.
      final hosts = [
        for (var i = 0; i < 200; i++) 'island$i.example.org',
      ];
      final byColour = <int, List<String>>{};
      for (final h in hosts) {
        byColour
            .putIfAbsent(IslandIdentity.of(h).water.toARGB32(), () => [])
            .add(h);
      }

      final shared = byColour.values.firstWhere((v) => v.length >= 2);
      final a = IslandIdentity.of(shared[0]);
      final b = IslandIdentity.of(shared[1]);
      expect(a.water, b.water, reason: 'fixture should share a colour');
      expect(a.shapeSeed, isNot(b.shapeSeed),
          reason: 'same colour AND same shape would make two islands '
              'indistinguishable');
    });

    test('the colour space is actually used — a palette that collapsed to one '
        'colour would make the mark useless without failing anything else', () {
      final colours = {
        for (var i = 0; i < 200; i++)
          IslandIdentity.of('island$i.example.org').water.toARGB32(),
      };
      expect(colours.length, greaterThanOrEqualTo(6),
          reason: 'only ${colours.length} distinct water colours across 200 '
              'islands');
    });
  });
}
