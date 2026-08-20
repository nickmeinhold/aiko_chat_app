import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/chat_providers.dart';
import '../domain/channel.dart';
import '../domain/message.dart';

/// Cross-channel grep search over cached message bodies (#8, grep tier). Pure
/// app-side: reads the local drift cache via [messageSearchResultsProvider], no
/// island round-trip. Retracted messages are already absent from the cache and
/// blocked senders are filtered in the provider, so results carry the SAME
/// visibility as the message list.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // Debounce so a fast typist runs one query per pause, not one per keystroke —
    // each keystroke otherwise rebuilds the FutureProvider and re-scans the cache.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      ref.read(messageSearchQueryProvider.notifier).set(value.trim());
    });
  }

  void _openResult(Message m) {
    // Jump to the result's channel, then return to chat. The chat surface watches
    // selectedChannelIdProvider, so it shows the picked channel on the way back.
    ref.read(selectedChannelIdProvider.notifier).select(m.channelId);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(messageSearchQueryProvider);
    final resultsAsync = ref.watch(messageSearchResultsProvider);
    final channelNames = ref
        .watch(channelsProvider)
        .maybeWhen(
          data: (chs) => {for (final Channel c in chs) c.id: c.name},
          orElse: () => const <String, String>{},
        );

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Search messages',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear',
              onPressed: () {
                _controller.clear();
                _onChanged('');
                setState(() {}); // drop the clear button
              },
            ),
        ],
      ),
      body: resultsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            const Center(child: Text("Couldn't search your messages")),
        data: (results) {
          if (query.isEmpty) {
            return const _Hint('Type to search your cached messages.');
          }
          if (results.isEmpty) {
            return _Hint('No messages match "$query".');
          }
          return ListView.separated(
            itemCount: results.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final m = results[i];
              return _SearchResultTile(
                message: m,
                query: query,
                channelName: channelNames[m.channelId] ?? m.channelId,
                onTap: () => _openResult(m),
              );
            },
          );
        },
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).hintColor),
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.message,
    required this.query,
    required this.channelName,
    required this.onTap,
  });

  final Message message;
  final String query;
  final String channelName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sender = message.sender.label ?? 'Unknown';
    return ListTile(
      onTap: onTap,
      title: Row(
        children: [
          Flexible(
            child: Text(
              sender,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '#$channelName',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
      subtitle: _Highlighted(text: message.body, query: query),
      isThreeLine: false,
    );
  }
}

/// Renders [text] with every case-insensitive occurrence of [query] bolded, so
/// the matched span the user searched for is visible in the preview.
class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text, required this.query});
  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    if (query.isEmpty) {
      return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + lowerQuery.length),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
      start = idx + lowerQuery.length;
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
