import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/skin_share.dart';
import '../../../app/theme/theme_builder.dart';
import '../application/theme_preset_controller.dart';

/// Send your look to someone, and take theirs.
///
/// The importing half is the interesting one, and its rule is: NOTHING IS
/// APPLIED WITHOUT BEING SEEN. A skin arrives as a code from outside, so the
/// reader gets a rendered preview and an explicit Apply — never a paste that
/// silently becomes their app. Refusals name their reason, and a skin that had
/// to be adjusted to stay readable says so rather than pretending it arrived
/// intact.
class SkinShareSection extends ConsumerWidget {
  const SkinShareSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Share', style: Theme.of(context).textTheme.labelMedium),
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('Share this look'),
          subtitle: const Text('Colours and typeface. Not your channels.'),
          onTap: () async {
            final code = encodeSkin(ref.read(skinSelectionProvider));
            await SharePlus.instance.share(ShareParams(text: code));
          },
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text("Use someone's look"),
          subtitle: const Text('Paste a skin code to preview it.'),
          onTap: () => _showImportSheet(context, ref),
        ),
      ],
    );
  }
}

Future<void> _showImportSheet(BuildContext context, WidgetRef ref) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ImportSheet(),
    );

class _ImportSheet extends ConsumerStatefulWidget {
  const _ImportSheet();

  @override
  ConsumerState<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<_ImportSheet> {
  final _controller = TextEditingController();
  SkinImport? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _read(String raw) => setState(() => _result = decodeSkin(raw));

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Use someone's look",
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: 'aiko-skin:v1:…',
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  _controller.text = data?.text ?? '';
                  _read(_controller.text);
                },
              ),
            ),
            maxLines: 2,
            // Cheap defence at the door: the decoder caps length anyway, but
            // there is no reason to let a megabyte into a text field first.
            maxLength: kMaxSkinCodeLength,
            onChanged: _read,
          ),
          if (result != null && !result.ok)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                result.error!.message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (result != null && result.ok) ...[
            const SizedBox(height: 8),
            _Preview(palette: result.selection!.resolve().light),
            const SizedBox(height: 6),
            _Preview(palette: result.selection!.resolve().dark),
            if (result.wasAdjusted)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${result.adjustedRoles} '
                  '${result.adjustedRoles == 1 ? "colour was" : "colours were"} '
                  'changed to keep everything readable, so this is not exactly '
                  'what was sent.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  ref
                      .read(skinSelectionProvider.notifier)
                      .applyImported(result.selection!);
                  Navigator.of(context).pop();
                },
                child: const Text('Use this look'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The incoming palette, rendered through the real builder — a preview that is
/// a mock-up would defeat the purpose of previewing.
class _Preview extends StatelessWidget {
  const _Preview({required this.palette});
  final ThemePalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = buildTheme(palette);
    return Container(
      decoration: BoxDecoration(
        color: palette.ground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.hairline),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Expanded(child: Text('a message', style: theme.textTheme.bodyMedium)),
          Container(width: 12, height: 12, color: palette.signal),
          const SizedBox(width: 6),
          Container(width: 12, height: 12, color: palette.beacon),
          const SizedBox(width: 6),
          Container(width: 12, height: 12, color: palette.alarm),
        ],
      ),
    );
  }
}
