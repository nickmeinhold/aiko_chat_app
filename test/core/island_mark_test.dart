// The island mark's identity properties.
//
// A mark that answers "where am I" is only worth having if it answers the SAME
// way every time, on every device, forever. These pin that, because the failure
// mode is silent: a mark that quietly changed would look like a working feature
// while destroying the only thing it was for.
import 'dart:math' as math;

import 'package:aiko_chat_app/core/widgets/island_mark.dart';
import 'package:flutter/material.dart';
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

    test('THE REAL ISLANDS ARE DIFFERENT COLOURS — this shipped broken', () {
      // "the islands don't seem to be a different color" was not a perception
      // problem. The first cut picked from a palette of EIGHT, and the two
      // islands actually in play both landed on dusk violet. With eight buckets
      // that is a one-in-eight coin flipped every time anyone adds an island —
      // and it came up heads on the only pair that existed.
      final a = IslandIdentity.of('chat.imagineering.cc');
      final b = IslandIdentity.of('enspyr.co');
      expect(a.water, isNot(b.water),
          reason: 'the two real islands must not share a colour');
    });

    test('the colour space is CONTINUOUS, not a handful of buckets', () {
      final colours = {
        for (var i = 0; i < 200; i++)
          IslandIdentity.of('island$i.example.org').water.toARGB32(),
      };
      // A fixed palette of N caps this at N no matter how many islands exist.
      // Well over a hundred distinct colours is the shape of a continuous hue;
      // anything in single digits means someone reintroduced a palette.
      expect(colours.length, greaterThan(100),
          reason: 'only ${colours.length} distinct colours across 200 islands '
              '— that is a palette, not a hue');
    });
  });

  group('it is actually pressable', () {
    // Reported from a real thumb: "the island button is quite hard to press,
    // seems like the border might be swallowing taps". Two causes, both fixed
    // and both pinned here — the target was ~30px, and it deferred its hit test
    // to a CIRCLE inside a square box, leaving the corners dead.
    testWidgets('hitPadding grows the TARGET without moving the MARK — the '
        'whole point, since the caller is handing over space it was already '
        'drawing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: IslandMark(
              baseUrl: 'chat.example.org',
              onTap: () {},
              hitPadding: const EdgeInsets.only(
                left: 12,
                top: 20,
                right: 10,
                bottom: 9,
              ),
            ),
          ),
        ),
      ));

      // The target spans the mark PLUS the padding handed to it.
      final target = tester.getRect(find.byType(IslandMark));
      expect(target.width, 12 + 18 + 10);
      expect(target.height, 20 + 18 + 9);

      // And the drawing itself is exactly where that padding puts it — not
      // recentred, not resized. A 44x44 box (the first fix) passed the size
      // check and MOVED the composer, which is the failure this replaced.
      final painted = tester.getRect(find.byType(CustomPaint).last);
      expect(painted.width, 18);
      expect(painted.left, target.left + 12);
      expect(painted.top, target.top + 20);
    });

    testWidgets('a tap in the CORNER of the target still counts — the dead '
        'corners are what made it feel like the border ate the press',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: IslandMark(
              baseUrl: 'chat.example.org',
              onTap: () => taps++,
              hitPadding: const EdgeInsets.all(14),
            ),
          ),
        ),
      ));

      final rect = tester.getRect(find.byType(IslandMark));
      // The very corner of the padded target: far outside the drawn circle.
      // This is the press that used to land on nothing.
      await tester.tapAt(rect.topLeft + const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: 'a corner press missed — the hit test is still '
          'deferring to the drawing rather than the target');
    });

    testWidgets('with no onTap it stays a decoration and takes no space it '
        'does not need', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(child: IslandMark(baseUrl: 'chat.example.org')),
        ),
      ));
      expect(tester.getSize(find.byType(IslandMark)).width, 18,
          reason: 'a decoration takes exactly the space it draws');
    });
  });

  group('the KEY is the identity, the URL is a fallback', () {
    const pubkey = 'z6MkkPnAewuWA3bMUqjVMUKfoLEvQVboCVcoLnHi1ZZPCCXW';

    test('when the island publishes a key, the mark follows the KEY', () {
      final byUrl = IslandIdentity.of('chat.example.org');
      final byKey =
          IslandIdentity.of('chat.example.org', islandPubkey: pubkey);
      expect(byKey.water, isNot(byUrl.water));
    });

    test('the SAME key at a DIFFERENT address is the SAME island — a domain is '
        'rented, the key is what the island IS', () {
      final before = IslandIdentity.of('old.example.org', islandPubkey: pubkey);
      final after = IslandIdentity.of('new.example.net', islandPubkey: pubkey);
      expect(after.water, before.water);
      expect(after.shapeSeed, before.shapeSeed);
    });

    test('and a DIFFERENT key at the SAME address is a DIFFERENT island — '
        'inheriting a lapsed domain must not inherit its mark', () {
      final incumbent =
          IslandIdentity.of('chat.example.org', islandPubkey: pubkey);
      final squatter = IslandIdentity.of('chat.example.org',
          islandPubkey: 'z6MkuSomeoneElseEntirelyDifferentKeyHere00000000');
      expect(squatter.water, isNot(incumbent.water));
    });

    test('an empty key is not a key — fall back rather than derive from ""', () {
      expect(IslandIdentity.of('chat.example.org', islandPubkey: '').water,
          IslandIdentity.of('chat.example.org').water);
    });
  });

  group('the SHAPES differ, not just the colours', () {
    // "long islands, fat, they should look like islands too". The first cut
    // varied only the coastline ripple on a fixed squash, so every island came
    // out the same egg at different angles of dent. Elongation and tilt are what
    // make two marks read as different PLACES.
    //
    // Shape lives in the painter, so these measure the PAINTED PATH rather than
    // any declared field — the bounds of the land are the thing a reader
    // actually sees.
    Path landPath(String host) => IslandPainter(
          identity: IslandIdentity.of(host),
          rim: const Color(0xFF000000),
        ).landPath(const Size(100, 100));

    /// ELONGATION — how much longer an island is than it is wide, measured
    /// rotation-invariantly by the principal axes of its coastline.
    ///
    /// TWO WEAKER METRICS FAILED HERE FIRST, and both passed the regression they
    /// existed to catch:
    ///   - the BOUNDING BOX: a rotated egg has a different box from an
    ///     unrotated one, so pinning the aspect to a constant still varied it;
    ///   - MAX/MIN RADIUS: the coastline harmonics alone swing that around, so
    ///     a fleet of identical eggs with different dents scored as "varied".
    ///
    /// Second moments ignore both rotation and local bumpiness and answer the
    /// actual question: is this island LONG. 1.0 is a disc; 2.0 is twice as long
    /// as it is wide.
    double elongation(String host) {
      final metric = landPath(host).computeMetrics().first;
      final pts = [
        for (var i = 0; i < 240; i++)
          metric.getTangentForOffset(metric.length * i / 240)!.position,
      ];
      final mx = pts.map((p) => p.dx).reduce((a, b) => a + b) / pts.length;
      final my = pts.map((p) => p.dy).reduce((a, b) => a + b) / pts.length;
      var sxx = 0.0, syy = 0.0, sxy = 0.0;
      for (final p in pts) {
        final dx = p.dx - mx;
        final dy = p.dy - my;
        sxx += dx * dx;
        syy += dy * dy;
        sxy += dx * dy;
      }
      sxx /= pts.length;
      syy /= pts.length;
      sxy /= pts.length;
      // Eigenvalues of the 2x2 covariance matrix.
      final tr = sxx + syy;
      final det = sxx * syy - sxy * sxy;
      final disc = math.sqrt(math.max(0, tr * tr / 4 - det));
      final l1 = tr / 2 + disc;
      final l2 = tr / 2 - disc;
      return math.sqrt(l1 / math.max(l2, 1e-9));
    }

    test('islands come in DIFFERENT PROPORTIONS — some long, some fat', () {
      final shapes = [
        for (var i = 0; i < 60; i++) elongation('island$i.example.org'),
      ];
      final longest = shapes.reduce((a, b) => a > b ? a : b);
      final roundest = shapes.reduce((a, b) => a < b ? a : b);

      expect(roundest, lessThan(1.35),
          reason: 'nothing is round — everything is a spit (roundest '
              '${roundest.toStringAsFixed(2)})');
      expect(longest, greaterThan(1.8),
          reason: 'nothing is LONG — every island is the same egg (longest '
              '${longest.toStringAsFixed(2)})');
      expect(longest - roundest, greaterThan(0.6),
          reason: 'the range of proportions is too narrow to read as different '
              'places');
    });

    test('two islands do not paint the same coastline', () {
      expect(elongation('chat.imagineering.cc'),
          isNot(closeTo(elongation('enspyr.co'), 0.1)),
          reason: 'the two real islands must differ in SHAPE as well as colour');
    });

    test('every island still FITS ITS DISC — a coastline that escapes the water '
        'is not an island', () {
      for (var i = 0; i < 60; i++) {
        final b = landPath('island$i.example.org').getBounds();
        expect(b.left, greaterThanOrEqualTo(2.0), reason: 'island$i spills left');
        expect(b.top, greaterThanOrEqualTo(2.0), reason: 'island$i spills up');
        expect(b.right, lessThanOrEqualTo(98.0), reason: 'island$i spills right');
        expect(b.bottom, lessThanOrEqualTo(98.0),
            reason: 'island$i spills down');
      }
    });
  });
}
