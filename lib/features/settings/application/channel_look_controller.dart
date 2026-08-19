import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/channel_look.dart';
import '../../../app/theme/theme_builder.dart';
import 'theme_preset_controller.dart';

/// Per-channel accents. A DEVICE preference, like the theme mode and preset
/// beside it.
const channelLooksPrefKey = 'aiko_channel_looks';

final channelLooksProvider =
    NotifierProvider<ChannelLookController, ChannelLooks>(
  ChannelLookController.new,
);

class ChannelLookController extends Notifier<ChannelLooks> {
  @override
  ChannelLooks build() => ChannelLooks.decode(
        ref.watch(sharedPreferencesProvider).getString(channelLooksPrefKey),
      );

  /// Tint [channelId], or clear it with a null [hue].
  void setHue(String channelId, Color? hue) {
    state = state.set(channelId, hue);
    ref
        .read(sharedPreferencesProvider)
        .setString(channelLooksPrefKey, state.encode());
  }
}

/// The theme to render a given channel in.
///
/// The composition order IS the cascade: the reader's preset and edits build
/// the palette, the channel is allowed to tint one role of it, and the reader's
/// typeface rides along untouched — a room can suggest a colour, never a face.
/// If the channel's hue would break the reader's palette it is dropped here, so
/// no caller has to think about it.
final channelThemeProvider = Provider.family<ThemeData, ChannelThemeRequest>(
  (ref, request) {
    final preset = ref.watch(themePresetProvider);
    final base =
        request.brightness == Brightness.light ? preset.light : preset.dark;
    return buildTheme(
      ref.watch(channelLooksProvider).applyTo(base, request.channelId),
      font: ref.watch(appFontProvider),
    );
  },
);

/// A channel plus the brightness to render it in. Both are needed: the same
/// hue can be lawful in one brightness and refused in the other, so the theme
/// cannot be resolved from the channel alone.
@immutable
class ChannelThemeRequest {
  const ChannelThemeRequest({required this.channelId, required this.brightness});

  final String? channelId;
  final Brightness brightness;

  @override
  bool operator ==(Object other) =>
      other is ChannelThemeRequest &&
      other.channelId == channelId &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(channelId, brightness);
}
