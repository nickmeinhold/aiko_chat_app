import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_rest_api.dart';

/// Edit the mutable identity labels — handle + display name. Identity is the
/// key; these are labels on top of it (handle unique-at-a-time + change
/// cooldown; display name free). Wire: `PATCH /v1/me` (island #2631). Only
/// changed fields are sent, so opening + saving without edits is a no-op.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _handle;
  late final TextEditingController _displayName;
  String? _handleError;
  String? _nameError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authControllerProvider).value;
    _handle = TextEditingController(text: user?.username ?? '');
    _displayName = TextEditingController(text: user?.displayName ?? '');
  }

  @override
  void dispose() {
    _handle.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(authControllerProvider).value;
    if (user == null) return;
    final newHandle = _handle.text.trim();
    final newName = _displayName.text.trim();
    // Client-side symmetry with the island's PatchMeReq validator, which 422s a
    // provided-but-blank handle AND display_name (cage-match #114, Tesla+Wu): guard
    // both here so a cleared field shows an inline "can't be empty" rather than the
    // generic "couldn't update" snackbar a raw 422 would fall through to.
    if (newHandle.isEmpty || newName.isEmpty) {
      setState(() {
        _handleError = newHandle.isEmpty ? 'Handle cannot be empty' : null;
        _nameError = newName.isEmpty ? 'Display name cannot be empty' : null;
      });
      return;
    }
    // Send only what changed — a same-value handle is a server-side no-op, but
    // not sending it keeps the request (and the cooldown) about real intent.
    final handleChanged = newHandle != user.username;
    final nameChanged = newName != user.displayName;
    if (!handleChanged && !nameChanged) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _handleError = null;
      _nameError = null;
    });
    try {
      final updated = await ref.read(restApiProvider).updateProfile(
            handle: handleChanged ? newHandle : null,
            displayName: nameChanged ? newName : null,
          );
      await ref
          .read(authControllerProvider.notifier)
          .applyProfileUpdate(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile updated')));
      Navigator.of(context).pop();
    } on HandleTaken {
      if (mounted) {
        setState(() => _handleError = 'That handle is already taken');
      }
    } on HandleChangeOnCooldown catch (e) {
      if (mounted) {
        setState(() => _handleError = _cooldownMessage(e.retryAfterSeconds));
      }
    } on AccountSuspended {
      // A ban landed mid-edit. Route through the single suspended door
      // (settleBan → _settleSuspension → /suspended) exactly as sign-in/restore
      // do, instead of swallowing it in the generic snackbar below and leaving a
      // banned user "logged in" with no /suspended zone (cage-match #114,
      // Carnot+Tesla+Wu). The router redirect replaces this screen, so no further
      // context use here.
      await ref.read(authControllerProvider.notifier).settleBan();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't update your profile")));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _cooldownMessage(int seconds) {
    final days = (seconds / 86400).ceil();
    if (days >= 1) {
      return 'You can change your handle again in '
          '$days day${days == 1 ? '' : 's'}';
    }
    return 'You changed your handle recently — try again later';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _handle,
            enabled: !_saving,
            decoration: InputDecoration(
              labelText: 'Handle',
              prefixText: '@',
              helperText:
                  'Unique. You can change it again after a cooldown period.',
              errorText: _handleError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _displayName,
            enabled: !_saving,
            decoration: InputDecoration(
              labelText: 'Display name',
              helperText: 'Shown in chat. Change it anytime.',
              errorText: _nameError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
