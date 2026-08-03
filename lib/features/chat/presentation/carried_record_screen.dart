/// "Your Carried Record" — the AUTHORSHIP half of The Carried Record
/// (docs/RECOMBINATION.md). Lists the messages the signed-in user authored and
/// INDEPENDENTLY re-verifies each one's carried signature on-device, from the
/// bytes alone — no network, no island, no trust in the cached ingest-time
/// verdict (see [carriedRecord]).
///
/// This is deliberately HALF a ledger. It proves *authorship* — "these are the
/// messages I can cryptographically prove are mine". It says nothing about
/// *judgment* (signed conduct events about you), which is island-gated and out
/// of scope here (#2506). The copy on this screen must never imply a full
/// reputation system.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../application/chat_providers.dart';
import '../domain/carried_record.dart';
import '../domain/message.dart';

/// Every locally-cached message authored by the current user, gathered across
/// all of their channels from the offline cache (no network). Filtering to
/// "mine" is left to [carriedRecord], which is authoritative on the subject
/// filter — this provider just widens the source to every channel the repo
/// knows about.
///
/// Overridable in tests to inject a fixed message set (signed / tampered /
/// unsigned / other-author) without driving the whole repo.
final myCarriedMessagesProvider =
    FutureProvider.autoDispose<List<Message>>((ref) async {
  final me = ref.watch(currentUserProvider);
  if (me == null) return const [];
  final repo = await ref.watch(chatRepositoryProvider.future);
  final channels = await ref.watch(channelsProvider.future);
  final all = <Message>[];
  for (final channel in channels) {
    // The cache stream emits its current snapshot immediately; take that one
    // frame and move on (this is a point-in-time record, not a live feed).
    all.addAll(await repo.watchChannel(channel.id).first);
  }
  return all;
});

/// The current user's carried record: their authored messages, each carried
/// signature re-verified independently and the `verified` verdict BOUND to this
/// device's sovereign public key (so a valid signature under a foreign key is
/// never claimed as yours). Fails closed to an empty record while logged out /
/// before the user id is known.
final carriedRecordProvider =
    FutureProvider.autoDispose<CarriedRecord>((ref) async {
  final me = ref.watch(currentUserProvider);
  if (me == null || me.userId.isEmpty) return CarriedRecord.empty;
  // The subject is ME, and my device holds my sovereign key — bind ownership to
  // it. Loaded here (not in the domain reader) so the reader stays pure/hermetic.
  final myKey = await ref.watch(sovereignKeyStoreProvider).loadOrCreate();
  final messages = await ref.watch(myCarriedMessagesProvider.future);
  return carriedRecord(
    me.userId,
    messages,
    subjectPublicKey: myKey.rawPublicKey,
  );
});

class CarriedRecordScreen extends ConsumerWidget {
  const CarriedRecordScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordAsync = ref.watch(carriedRecordProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your Carried Record')),
      body: recordAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not build your carried record.\n$e',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (record) => _RecordBody(record),
      ),
    );
  }
}

class _RecordBody extends StatelessWidget {
  const _RecordBody(this.record);
  final CarriedRecord record;

  @override
  Widget build(BuildContext context) {
    final entries = record.entries;
    if (entries.isEmpty) {
      return ListView(
        children: const [
          _Header(),
          Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              "You haven't authored any messages on this device yet. Once you "
              'send a signed message, it will appear here.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      // header + one row per entry.
      itemCount: entries.length + 1,
      separatorBuilder: (_, i) =>
          i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) return const _Header();
        return _EntryTile(entries[i - 1]);
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your authored record',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Messages attributed to you in this device’s cache. Only rows '
            'marked Verified are cryptographically bound to this device’s '
            'key — each of those signatures is re-checked here on your device, '
            'from the message itself, with nothing on a server trusted to '
            're-vouch it.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Only messages signed by this device’s key show as verified. '
            'Messages you signed on another device show as signed by a different '
            'key — multi-device support is coming. A dash (—) means no signature '
            'was carried (older or never-signed messages); that is not a sign of '
            'dishonesty. This is only your authorship: it is not a reputation, '
            'and not a record of anything anyone has said about you.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry);
  final CarriedRecordEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label) = switch (entry.verdict) {
      CarriedRecordVerdict.verified => (
          Icons.verified_outlined,
          theme.colorScheme.primary,
          'Verified — provably yours',
        ),
      CarriedRecordVerdict.invalid => (
          Icons.warning_amber_outlined,
          theme.colorScheme.error,
          "Invalid — signature doesn't match",
        ),
      CarriedRecordVerdict.foreignKey => (
          Icons.devices_other_outlined,
          theme.colorScheme.tertiary,
          'Signed by a different key — not this device',
        ),
      CarriedRecordVerdict.unsigned => (
          Icons.remove,
          theme.colorScheme.onSurfaceVariant,
          'Unsigned — no signature carried',
        ),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(entry.body),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          if (entry.signedAtMs != null)
            Text(
              _formatTimestamp(entry.signedAtMs!),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
      isThreeLine: entry.signedAtMs != null,
    );
  }

  static String _formatTimestamp(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
