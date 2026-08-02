import 'dart:typed_data';

import 'package:aiko_chat_app/core/mark/mark_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _key(int fill) => Uint8List.fromList(List.generate(32, (i) => (i * 7 + fill) & 0xFF));

void main() {
  group('blockieGrid', () {
    test('is deterministic — same key paints the same grid', () {
      final a = blockieGrid(_key(3));
      final b = blockieGrid(_key(3));
      expect(a, equals(b));
    });

    test('distinct keys produce distinct grids', () {
      expect(blockieGrid(_key(1)), isNot(equals(blockieGrid(_key(200)))));
    });

    test('is bilaterally symmetric (mirrored halves)', () {
      final g = blockieGrid(_key(42));
      for (var row = 0; row < 8; row++) {
        for (var col = 0; col < 8; col++) {
          expect(g[row][col], g[row][7 - col],
              reason: 'cell ($row,$col) must mirror ($row,${7 - col})');
        }
      }
    });

    test('only emits legal cell states 0/1/2', () {
      final g = blockieGrid(_key(9));
      for (final row in g) {
        for (final c in row) {
          expect(c, anyOf(0, 1, 2));
        }
      }
    });
  });

  group('seedBytes fallback', () {
    test('is deterministic and 32 bytes', () {
      expect(seedBytes('alice'), equals(seedBytes('alice')));
      expect(seedBytes('alice').length, 32);
    });

    test('distinct seeds diverge', () {
      expect(seedBytes('alice'), isNot(equals(seedBytes('bob'))));
    });

    test('does not collapse to a constant lane (empty seed still spreads)', () {
      final b = seedBytes('');
      expect(b.toSet().length, greaterThan(1),
          reason: 'a degenerate hash would fill every lane identically');
    });
  });

  group('MarkAvatar widget', () {
    testWidgets('renders from a full public key', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MarkAvatar(publicKey: _key(5), size: 40)),
      ));
      expect(find.byType(MarkAvatar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders from a seed when no key is present', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: MarkAvatar(seed: 'user-123', size: 40)),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a short/partial key without throwing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkAvatar(publicKey: Uint8List.fromList([1, 2, 3]), size: 40),
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('repaints when the key changes, not when it is identical',
        (tester) async {
      final p1 = MarkPainter(_key(1), Brightness.light);
      final p2 = MarkPainter(_key(1), Brightness.light);
      final p3 = MarkPainter(_key(2), Brightness.light);
      expect(p1.shouldRepaint(p2), isFalse);
      expect(p1.shouldRepaint(p3), isTrue);
    });
  });
}
