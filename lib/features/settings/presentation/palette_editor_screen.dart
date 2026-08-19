import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/theme_builder.dart';
import '../../../app/theme/theme_laws.dart';
import '../../../core/widgets/reading_column.dart';
import '../application/theme_preset_controller.dart';

/// Author your own colours, one role at a time.
///
/// THE DESIGN DECISION worth knowing before reading the code: this editor does
/// not let you pick a colour and then tell you it was a bad choice. It only
/// OFFERS colours that keep the design language intact — every candidate swatch
/// is run through [checkPalette] against the palette it would produce, and the
/// ones that would make something unreadable are shown struck through with the
/// reason, not silently hidden.
///
/// Two reasons for reachability-over-validation. It is kinder: nobody enjoys
/// being told their choice was wrong after making it. And it is honest about
/// where the guarantee lives — the builder owns relationships, so the editor's
/// job is to own which colours are REACHABLE. Showing the rejected swatches
/// rather than filtering them out keeps the constraint legible instead of
/// making the palette feel mysteriously sparse.
///
/// Scope: colour only. Nothing here can move, hide or resize a control
/// (claude-tasks#2715).
class PaletteEditorScreen extends ConsumerStatefulWidget {
  const PaletteEditorScreen({super.key});

  @override
  ConsumerState<PaletteEditorScreen> createState() =>
      _PaletteEditorScreenState();
}

class _PaletteEditorScreenState extends ConsumerState<PaletteEditorScreen> {
  Brightness? _editing;
  PaletteRole _role = PaletteRole.signal;

  @override
  Widget build(BuildContext context) {
    // Default to editing the half you are currently looking at.
    final editing = _editing ??= Theme.of(context).brightness;
    final selection = ref.watch(skinSelectionProvider);
    final preset = ref.watch(themePresetProvider);
    final palette = editing == Brightness.light ? preset.light : preset.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your colours'),
        actions: [
          if (selection.isCustomised)
            TextButton(
              onPressed: () =>
                  ref.read(skinSelectionProvider.notifier).resetToPreset(),
              child: const Text('Reset'),
            ),
        ],
      ),
      body: ReadingColumn(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SegmentedButton<Brightness>(
                segments: const [
                  ButtonSegment(
                    value: Brightness.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: Brightness.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {editing},
                onSelectionChanged: (s) =>
                    setState(() => _editing = s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _Preview(palette: palette),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'What to change',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            _RoleStrip(
              palette: palette,
              selected: _role,
              overridden: (editing == Brightness.light
                      ? selection.lightOverrides
                      : selection.darkOverrides)
                  .keys
                  .toSet(),
              onPick: (r) => setState(() => _role = r),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                _role.blurb,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            _SwatchGrid(
              palette: palette,
              role: _role,
              onPick: (c) => ref.read(skinSelectionProvider.notifier).setRole(
                    brightness: editing,
                    role: _role,
                    colour: c,
                  ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// The palette being edited, wearing itself. Rendered through the real
/// [buildTheme], so this is not a mock-up of the result — it IS the result.
class _Preview extends StatelessWidget {
  const _Preview({required this.palette});
  final ThemePalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = buildTheme(palette);
    return Theme(
      data: theme,
      child: Container(
        decoration: BoxDecoration(
          color: palette.ground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.hairline),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('# general', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.panel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('someone else', style: theme.textTheme.bodyMedium),
                  Text('12:04', style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.panelMine,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.hairline),
                ),
                child: Text('and you', style: theme.textTheme.bodyMedium),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Send')),
                const SizedBox(width: 10),
                Text('Failed to send',
                    style: TextStyle(color: palette.alarm, fontSize: 12)),
                const Spacer(),
                Icon(Icons.circle, size: 12, color: palette.beacon),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The eleven roles as a scrollable strip of what they currently are.
class _RoleStrip extends StatelessWidget {
  const _RoleStrip({
    required this.palette,
    required this.selected,
    required this.overridden,
    required this.onPick,
  });

  final ThemePalette palette;
  final PaletteRole selected;
  final Set<PaletteRole> overridden;
  final ValueChanged<PaletteRole> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 78,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: PaletteRole.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final role = PaletteRole.values[i];
          final isSelected = role == selected;
          return Semantics(
            button: true,
            selected: isSelected,
            label: '${role.label}, ${role.blurb}'
                '${overridden.contains(role) ? ', changed' : ''}',
            child: InkWell(
              onTap: () => onPick(role),
              borderRadius: BorderRadius.circular(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 32,
                    decoration: BoxDecoration(
                      color: roleOf(palette, role),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected ? scheme.primary : scheme.outline,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    // A dot marks a role you have changed, so "what did I
                    // actually edit" is answerable at a glance.
                    child: overridden.contains(role)
                        ? Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(Icons.circle,
                                  size: 6, color: scheme.primary),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    role.label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isSelected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Candidate colours for one role — every one of them checked against the
/// design language BEFORE it is offered.
class _SwatchGrid extends StatelessWidget {
  const _SwatchGrid({
    required this.palette,
    required this.role,
    required this.onPick,
  });

  final ThemePalette palette;
  final PaletteRole role;
  final ValueChanged<Color> onPick;

  /// A spread wide enough to be expressive and coarse enough to stay legible:
  /// twelve hues at five lightnesses, plus a neutral column for grounds, inks
  /// and hairlines. Deliberately NOT a freeform picker — every candidate here
  /// gets checked, and an infinite space cannot be.
  static List<Color> _candidates() {
    final out = <Color>[];
    for (final l in [0.12, 0.28, 0.45, 0.68, 0.88]) {
      for (var h = 0; h < 360; h += 30) {
        out.add(HSLColor.fromAHSL(1, h.toDouble(), 0.55, l).toColor());
      }
      out.add(HSLColor.fromAHSL(1, 0, 0, l).toColor()); // neutral
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates();
    final current = roleOf(palette, role);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in candidates)
            _Swatch(
              colour: c,
              isCurrent: c.toARGB32() == current.toARGB32(),
              // The law, consulted per swatch. This is the same function the
              // test suite runs over every shipped palette — not a second
              // implementation that could drift from it.
              //
              // Deliberately NOT filtered to violations naming this role. A
              // relational rule is reported against ONE of the two colours it
              // involves: move the beacon onto the alarm's hue and the engine
              // blames the alarm, which the reader never touched. Filtering by
              // role would then have offered that swatch as legal. A candidate
              // is offerable only if it leaves the palette clean OUTRIGHT —
              // the base palette is always legal, so any violation at all is
              // one this swatch just introduced.
              blockedBy: checkPalette(withRole(palette, role, c))
                  .map((v) => v.message)
                  .firstOrNull,
              onPick: () => onPick(c),
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.colour,
    required this.isCurrent,
    required this.blockedBy,
    required this.onPick,
  });

  final Color colour;
  final bool isCurrent;
  final String? blockedBy;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = blockedBy != null;
    return Tooltip(
      message: blockedBy ?? '',
      triggerMode: blocked ? TooltipTriggerMode.tap : TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        enabled: !blocked,
        label: blocked ? 'Unavailable: $blockedBy' : 'Use this colour',
        child: InkWell(
          onTap: blocked ? null : onPick,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isCurrent ? scheme.primary : scheme.outline,
                width: isCurrent ? 2 : 1,
              ),
            ),
            // A blocked swatch is struck through rather than hidden: the reader
            // can see the constraint exists and why, instead of wondering where
            // the greens went.
            child: blocked
                ? Icon(Icons.close,
                    size: 18, color: scheme.onSurfaceVariant.withValues(alpha: 0.8))
                : isCurrent
                    ? Icon(Icons.check, size: 18, color: scheme.onPrimary)
                    : null,
          ),
        ),
      ),
    );
  }
}
