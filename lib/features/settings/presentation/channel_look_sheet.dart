import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/channel_look.dart';
import '../../../app/theme/theme_builder.dart';
import '../application/channel_look_controller.dart';
import '../application/theme_preset_controller.dart';

/// Give this room a colour.
///
/// The channel tier of the cascade, as a control: one accent, offered from the
/// same lawful-only swatch logic the palette editor uses. A hue that would not
/// survive on the reader's current palette is not offered, so the setting can
/// never store something it would silently refuse to honour.
///
/// Deliberately a small sheet rather than a screen. A channel tint is a passing
/// preference — "make the noisy one red" — not a design session.
Future<void> showChannelLookSheet(
  BuildContext context, {
  required String channelId,
  required String channelLabel,
}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ChannelLookSheet(
        channelId: channelId,
        channelLabel: channelLabel,
      ),
    );

class _ChannelLookSheet extends ConsumerWidget {
  const _ChannelLookSheet({
    required this.channelId,
    required this.channelLabel,
  });

  final String channelId;
  final String channelLabel;

  /// Twelve hues at two lightnesses — enough to tell rooms apart at a glance,
  /// far short of a colour picker. The point is identification, not authorship.
  static List<Color> _candidates() => [
        for (final l in [0.32, 0.55])
          for (var h = 0; h < 360; h += 30)
            HSLColor.fromAHSL(1, h.toDouble(), 0.6, l).toColor(),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = Theme.of(context).brightness;
    final preset = ref.watch(themePresetProvider);
    final base = brightness == Brightness.light ? preset.light : preset.dark;
    final current = ref.watch(channelLooksProvider).hueFor(channelId);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Colour for $channelLabel',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Tints this conversation only. Your own theme is unchanged, and a '
              'colour that would make anything hard to read is not offered.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                // "No colour" first — clearing is the commonest thing anyone
                // wants from this sheet after a week of enthusiasm.
                _Hue(
                  colour: null,
                  isCurrent: current == null,
                  onPick: () => ref
                      .read(channelLooksProvider.notifier)
                      .setHue(channelId, null),
                ),
                for (final c in _candidates())
                  if (ChannelLooks.isLawful(base, c))
                    _Hue(
                      colour: c,
                      isCurrent: current?.toARGB32() == c.toARGB32(),
                      onPick: () => ref
                          .read(channelLooksProvider.notifier)
                          .setHue(channelId, c),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Hue extends StatelessWidget {
  const _Hue({
    required this.colour,
    required this.isCurrent,
    required this.onPick,
  });

  final Color? colour;
  final bool isCurrent;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: isCurrent,
      label: colour == null ? 'No colour' : 'Use this colour',
      child: InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colour ?? scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isCurrent ? scheme.primary : scheme.outline,
              width: isCurrent ? 2 : 1,
            ),
          ),
          child: colour == null
              ? Icon(Icons.format_color_reset_outlined,
                  size: 18, color: scheme.onSurfaceVariant)
              : isCurrent
                  ? const Icon(Icons.check, size: 18, color: Colors.white)
                  : null,
        ),
      ),
    );
  }
}

/// Entry point for the sheet, for an app bar or a context menu.
class ChannelLookAction extends ConsumerWidget {
  const ChannelLookAction({
    super.key,
    required this.channelId,
    required this.channelLabel,
  });

  final String channelId;
  final String channelLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tinted = ref.watch(channelLooksProvider).hueFor(channelId) != null;
    return IconButton(
      tooltip: 'Colour for this conversation',
      icon: Icon(tinted ? Icons.palette : Icons.palette_outlined),
      onPressed: () => showChannelLookSheet(
        context,
        channelId: channelId,
        channelLabel: channelLabel,
      ),
    );
  }
}

/// A palette tinted for a channel — exposed so a preview or a test can compose
/// the same way the app does without duplicating the rule.
ThemePalette paletteForChannel(
  ThemePalette base,
  ChannelLooks looks,
  String? channelId,
) =>
    looks.applyTo(base, channelId);
