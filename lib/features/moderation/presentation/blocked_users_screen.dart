/// The "Blocked users" list (UGC — Apple 1.2 / Google UGC, #7). Reachable from
/// Settings; lets the user review and unblock the people they've blocked. Apple's
/// guideline wants a block mechanism AND a way to manage it — this is the manage
/// half (the block half lives on the message long-press, message_actions.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/moderation_controller.dart';
import '../domain/moderation_models.dart';

class BlockedUsersScreen extends ConsumerWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocksAsync = ref.watch(blockedUsersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked users')),
      body: blocksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load your blocked users.\n$e',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (blocks) {
          if (blocks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "You haven't blocked anyone.\nLong-press a message to block its "
                  'sender.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: blocks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => _BlockedTile(blocks[i]),
          );
        },
      ),
    );
  }
}

class _BlockedTile extends ConsumerStatefulWidget {
  const _BlockedTile(this.user);
  final BlockedUser user;

  @override
  ConsumerState<_BlockedTile> createState() => _BlockedTileState();
}

class _BlockedTileState extends ConsumerState<_BlockedTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_off)),
      title: Text(widget.user.displayName),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(onPressed: _unblock, child: const Text('Unblock')),
    );
  }

  Future<void> _unblock() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(blockedUsersProvider.notifier).unblock(widget.user.userId);
      messenger.showSnackBar(
        SnackBar(content: Text('${widget.user.displayName} unblocked.')),
      );
      // The list rebuilds from the controller's optimistic state removal — this
      // tile is gone, so no setState(_busy=false) needed (and would fire after
      // dispose). Guard anyway for the error path below.
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not unblock. Please try again.')),
      );
    }
  }
}
