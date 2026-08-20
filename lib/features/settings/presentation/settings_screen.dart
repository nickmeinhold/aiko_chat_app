/// Settings — currently the home of account management. Reachable from the chat
/// AppBar. Built as a simple list so later threads (the in-app gateway picker,
/// #4; a blocked-users list, #7) can slot in as new sections without rework.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/theme_presets.dart';
import '../../../core/widgets/reading_column.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_rest_api.dart';
import '../application/theme_mode_controller.dart';
import '../application/theme_preset_controller.dart';
import 'edit_profile_screen.dart';
import 'palette_editor_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _deleting = false;
  bool _addingPasskey = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ReadingColumn(
        child: ListView(
          children: [
            const _SectionHeader('Appearance'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                  ],
                  selected: {ref.watch(themeModeProvider)},
                  onSelectionChanged: (s) =>
                      ref.read(themeModeProvider.notifier).set(s.first),
                ),
              ),
            ),
            const _ThemePresetPicker(),
            const _SectionHeader('Safety'),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Blocked users'),
              subtitle: const Text(
                "People you've blocked won't see your messages.",
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/blocked'),
            ),
            // Operator seat (#33/#35): visible ONLY to a moderator. Presentation
            // gate only — the server ModeratorUser check is the real boundary — so
            // a stale-true flag at worst shows a tile whose actions 403 → Forbidden
            // (handled, not a logout). isModeratorProvider is fail-closed (false
            // when logged out / mid-restore / on an older gateway).
            if (ref.watch(isModeratorProvider))
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Reports'),
                subtitle: const Text(
                  'Review reported messages and act on them.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/moderation/reports'),
              ),
            const _SectionHeader('Identity'),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Edit profile'),
              subtitle: const Text('Change your handle or display name.'),
              trailing: const Icon(Icons.chevron_right),
              // NOTE: raw MaterialPageRoute (not go_router) — deliberate, see
              // claude-tasks follow-up. A go_router migration must first handle the
              // auth-refresh-during-open pop interaction (cage-match #114 finding B).
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EditProfileScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: const Text('Your Carried Record'),
              subtitle: const Text(
                'Messages attributed to you, and which you can cryptographically '
                'prove you signed on this device.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/carried-record'),
            ),
            const _SectionHeader('Sign-in'),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Add a passkey'),
              subtitle: Text(_passkeyBiometricHint()),
              enabled: !_addingPasskey,
              trailing: _addingPasskey
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _addingPasskey ? null : _addPasskey,
            ),
            const _SectionHeader('Account'),
            ListTile(
              leading: Icon(
                Icons.delete_forever,
                color: theme.colorScheme.error,
              ),
              title: Text(
                'Delete account',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Permanently delete your account. This cannot be undone.',
              ),
              enabled: !_deleting,
              trailing: _deleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: _deleting ? null : _confirmAndDelete,
            ),
            const _SectionHeader('Legal'),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Terms of Use & Community Guidelines'),
              subtitle: const Text(
                'The terms you agreed to, including our '
                'zero-tolerance policy.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/eula'),
            ),
          ],
        ),
      ),
    );
  }

  /// Link a new passkey to the signed-in account (#1727). Settings is only
  /// reachable while authenticated, so the controller's live-session precondition
  /// holds. A sheet dismissal returns silently (the controller swallows it); a
  /// real failure surfaces inline via a snackbar without disturbing the session.
  Future<void> _addPasskey() async {
    setState(() => _addingPasskey = true);
    String? message; // null → user cancelled the sheet: no snackbar, no noise
    try {
      final added = await ref
          .read(authControllerProvider.notifier)
          .addPasskeyToCurrentAccount();
      if (added) message = 'Passkey added. You can now sign in with it.';
    } catch (e) {
      message = _addPasskeyError(e);
    }
    if (!mounted) return;
    setState(() => _addingPasskey = false);
    if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  // Neutral 409 copy: the gateway's "already registered" (409) can mean this OR
  // another account, so it must not assert the credential is on *this* one.
  String _addPasskeyError(Object e) => switch (e) {
    PasskeyAlreadyRegistered() =>
      'That passkey is already registered. Try '
          'signing in with it, or use a different passkey.',
    // Before Unauthorized (its supertype): a ban is not "session expired."
    // Short snackbar deliberately says "this island" rather than naming the
    // host (as authErrorText does) — Settings already shows the active server
    // in the Server tile, so the host is on-screen; a terse snackbar reads
    // better here (cage-match Tesla P3, copy-drift is intentional).
    AccountSuspended() => 'This account is suspended on this island.',
    Unauthorized() => 'Your session has expired. Please sign in again.',
    _ => 'Could not add a passkey. Please try again.',
  };

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account and sign-in. Messages you '
          'sent stay in their conversations but are anonymized — no longer '
          'linked to you. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleting = true);
    try {
      // On success the auth guard redirects to /login — no manual nav here.
      await ref.read(authControllerProvider.notifier).deleteAccount();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_deleteError(e))));
    }
  }

  String _deleteError(Object e) {
    if (e is SoleAdminDeletionBlocked) return e.message;
    // A ban (403) can land on delete mid-session too — say so honestly rather
    // than the vague "try again" (cage-match Tesla P3). AccountSuspended is a
    // subtype of Unauthorized, so it must be checked first.
    if (e is AccountSuspended) {
      return 'This account is suspended on this island.';
    }
    return 'Could not delete your account. Please try again.';
  }

  /// Passkey-unlock hint, named for the local platform's authenticators.
  /// Uses [defaultTargetPlatform] (not `dart:io`) to stay web-safe, matching
  /// the diagnostics code — Face ID/Touch ID are Apple-only names and must not
  /// surface on Android.
  static String _passkeyBiometricHint() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return 'Sign in next time with Face ID, Touch ID, or your device '
            'passcode.';
      case TargetPlatform.android:
        return 'Sign in next time with your fingerprint, face unlock, or '
            'device PIN.';
      default:
        return 'Sign in next time with your device biometrics or PIN.';
    }
  }
}

/// The look picker. Deliberately NOT a list of names: you are choosing an
/// appearance, so each option renders itself — ground, panel, ink, and the three
/// accents in their real roles. Each swatch previews the half of the preset you
/// would actually be looking at right now (the light palette in light, the dark
/// one in dark), so what you tap is what you get rather than a marketing chip.
class _ThemePresetPicker extends ConsumerWidget {
  const _ThemePresetPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(themePresetProvider);
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Theme'),
        ),
        SizedBox(
          height: 116,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            itemCount: kThemePresets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final preset = kThemePresets[i];
              return _PresetSwatch(
                preset: preset,
                brightness: brightness,
                isSelected: preset.id == selected.id,
                onTap: () => ref
                    .read(skinSelectionProvider.notifier)
                    .selectPreset(preset),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            selected.blurb,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Colours & type'),
          subtitle: Text(_lookSummary(ref, selected)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PaletteEditorScreen()),
          ),
        ),
      ],
    );
  }
}

/// One look, drawn in its own colours. The mini-composition mirrors the real
/// surface — a ground, a panel lifted off it by a hairline, two lines of ink,
/// and the accent trio — so the differences you can see here are the
/// differences you will feel in the app.
class _PresetSwatch extends StatelessWidget {
  const _PresetSwatch({
    required this.preset,
    required this.brightness,
    required this.isSelected,
    required this.onTap,
  });

  final ThemePreset preset;
  final Brightness brightness;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = brightness == Brightness.dark ? preset.dark : preset.light;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${preset.label} theme. ${preset.blurb}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 104,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                decoration: BoxDecoration(
                  color: p.ground,
                  borderRadius: BorderRadius.circular(10),
                  // The selection ring is drawn in the CURRENT theme's signal,
                  // not the swatch's own — it belongs to the app chrome doing
                  // the asking, not to the look being offered.
                  border: Border.all(
                    color: isSelected ? scheme.primary : p.hairline,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A panel with two lines of ink on it — a message.
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: p.panel,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: p.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Rule(color: p.ink, width: 46),
                          const SizedBox(height: 3),
                          _Rule(color: p.inkDim, width: 30),
                        ],
                      ),
                    ),
                    const Spacer(),
                    // The accent trio, in role order: signal, beacon, alarm.
                    Row(
                      children: [
                        _Dot(color: p.signal),
                        const SizedBox(width: 5),
                        _Dot(color: p.beacon),
                        const SizedBox(width: 5),
                        _Dot(color: p.alarm),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (isSelected) ...[
                    Icon(Icons.check, size: 14, color: scheme.primary),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      preset.label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isSelected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.color, required this.width});
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 3,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// One line describing the current look, so the tile says what is set rather
/// than merely that a screen exists behind it.
String _lookSummary(WidgetRef ref, ThemePreset preset) {
  final font = ref.watch(appFontProvider);
  final customised = ref.watch(skinSelectionProvider).isCustomised;
  final colours = customised ? '${preset.label}, edited' : preset.label;
  return font.isSystem ? colours : '$colours · ${font.label}';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
