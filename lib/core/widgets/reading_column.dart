import 'package:flutter/material.dart';

/// Max content width for a reading column. Below this (phones) the child fills;
/// above it (a wide desktop window) the content stays a centered column instead
/// of stretching edge-to-edge (title pinned left, trailing pinned right, dead
/// space between).
const double kReadingColumnWidth = 560;

/// Centres [child] and caps it at [kReadingColumnWidth]. Wrap a Scaffold body
/// (list or detail) that would otherwise stretch full-bleed on desktop; on a
/// phone it's a no-op because the window is narrower than the cap.
class ReadingColumn extends StatelessWidget {
  const ReadingColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kReadingColumnWidth),
        child: child,
      ),
    );
  }
}
