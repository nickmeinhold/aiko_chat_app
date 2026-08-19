/// Blockie mark — a deterministic, key-derived profile avatar (identity cluster
/// v1; style chosen 2026-08-02). A user's Ed25519 public key is painted as an
/// 8×8 mirrored mosaic, so everyone has a unique, unforgeable, upload-free face
/// the moment they exist — no blob storage, no moderation, no privacy
/// declaration. When a message carries no signed key (pre-feature / unsigned
/// sender) a stable [seedBytes] fallback keeps the mark deterministic from the
/// user id, so every sender still renders one.
///
/// The generator mirrors the approved gallery (Ethereum-blockies style): a
/// key-seeded xorshift fills the left half of the grid, mirrored to the right.
/// Determinism is the whole contract — the same key must paint the same mark on
/// every device and for every viewer — so [blockieGrid]/[seedBytes] are pure and
/// unit-pinned, never touching wall-clock, randomness, or platform state.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

const int _grid = 8;

/// Expand an arbitrary seed string into 32 deterministic bytes (FNV-1a spread
/// across 32 lanes). Used only as the *fallback* mark source for a sender with
/// no signed key; it is a visual hash, NOT a security primitive.
Uint8List seedBytes(String seed) {
  final out = Uint8List(32);
  final units = seed.codeUnits;
  for (var i = 0; i < 32; i++) {
    var h = 0x811c9dc5 ^ i; // per-lane offset so lanes don't collapse
    for (final c in units) {
      h = (h ^ c) & 0xFFFFFFFF;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    out[i] = (h ^ (h >> 8)) & 0xFF;
  }
  return out;
}

/// The 8×8 grid of cell states — 0 = background, 1 = colour A, 2 = colour B.
/// The left half is filled from a key-seeded xorshift, then mirrored, so the
/// mark is bilaterally symmetric (the blockie look). Pure + deterministic.
@visibleForTesting
List<List<int>> blockieGrid(Uint8List key) {
  var s = 0x9e3779b9;
  for (final x in key) {
    s = (s ^ (x + 0x6d2b79f5)) & 0xFFFFFFFF;
    final m = (s ^ (s >> 15)) & 0xFFFFFFFF;
    s = (m * (1 | s)) & 0xFFFFFFFF;
  }
  double next() {
    s ^= (s << 13) & 0xFFFFFFFF;
    s ^= s >> 17;
    s ^= (s << 5) & 0xFFFFFFFF;
    s &= 0xFFFFFFFF;
    return s / 4294967296.0;
  }

  final grid = List.generate(_grid, (_) => List<int>.filled(_grid, 0));
  for (var col = 0; col < _grid ~/ 2; col++) {
    for (var row = 0; row < _grid; row++) {
      final v = next();
      final cell = v > 0.62 ? 1 : (v > 0.42 ? 2 : 0);
      grid[row][col] = cell;
      grid[row][_grid - 1 - col] = cell; // mirror
    }
  }
  return grid;
}

class _MarkColors {
  final Color bg, a, b;
  const _MarkColors(this.bg, this.a, this.b);
}

_MarkColors _colorsFor(Uint8List k, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final h1 = (k[3] / 255.0) * 360.0;
  final h2 = (h1 + 40 + (k[7] % 80)) % 360;
  final sat = dark ? 0.55 : 0.60;
  final la = dark ? 0.58 : 0.46;
  final lb = dark ? 0.42 : 0.62;
  final bg = dark ? const Color(0xFF0D2530) : const Color(0xFFDFD6C1);
  return _MarkColors(
    bg,
    HSLColor.fromAHSL(1, h1, sat, la).toColor(),
    HSLColor.fromAHSL(1, h2, sat, lb).toColor(),
  );
}

/// Paints a [blockieGrid] into the given square. Theme-aware via [brightness].
class MarkPainter extends CustomPainter {
  MarkPainter(this.keyBytes, this.brightness);

  final Uint8List keyBytes;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = _colorsFor(keyBytes, brightness);
    final grid = blockieGrid(keyBytes);
    final cell = size.width / _grid;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.bg);
    final pa = Paint()..color = colors.a;
    final pb = Paint()..color = colors.b;
    for (var row = 0; row < _grid; row++) {
      for (var col = 0; col < _grid; col++) {
        final v = grid[row][col];
        if (v == 0) continue;
        // +0.5 overdraw closes hairline seams between cells at fractional dpr.
        final r = Rect.fromLTWH(col * cell, row * cell, cell + 0.5, cell + 0.5);
        canvas.drawRect(r, v == 1 ? pa : pb);
      }
    }
  }

  @override
  bool shouldRepaint(MarkPainter old) =>
      old.brightness != brightness || !_bytesEqual(old.keyBytes, keyBytes);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A rounded square avatar drawn from a public key (preferred) or a stable seed
/// string (fallback). Give it exactly one non-null source; [publicKey] wins.
class MarkAvatar extends StatelessWidget {
  const MarkAvatar({
    super.key,
    this.publicKey,
    this.seed,
    this.size = 32,
    this.radius = 8,
  }) : assert(
         publicKey != null || seed != null,
         'MarkAvatar needs a publicKey or a seed',
       );

  final Uint8List? publicKey;
  final String? seed;
  final double size;
  final double radius;

  Uint8List _resolveBytes() {
    final k = publicKey;
    if (k != null && k.length >= 32) return Uint8List.sublistView(k, 0, 32);
    if (k != null && k.isNotEmpty) {
      final padded = Uint8List(32)..setRange(0, k.length, k);
      return padded;
    }
    return seedBytes(seed ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: MarkPainter(_resolveBytes(), Theme.of(context).brightness),
          isComplex: false,
        ),
      ),
    );
  }
}
