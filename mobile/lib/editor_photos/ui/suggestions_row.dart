// "Based on your uploads in the last …, here are some edits": a row of suggestion cards
// on the timeline. Each card shows the edit (hold to see the original) with Apply,
// Apply & replace, Edit and Dismiss; tapping it opens the full-screen preview.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/suggestions_store.dart';
import 'package:immich_mobile/editor_photos/providers.dart';
import 'package:immich_mobile/editor_photos/ui/editor_actions.dart';
import 'package:immich_mobile/editor_photos/ui/suggestion_preview_page.dart';

/// Height the row takes on the timeline when it has suggestions
const suggestionsRowHeight = 318.0;

/// Whether the timeline should reserve room for the row
final suggestionsRowVisibleProvider = Provider<bool>(
  (ref) => ref.watch(editorSuggestionsProvider.select((s) => s.batch.suggestions.isNotEmpty)),
);

class EditorSuggestionsRow extends ConsumerWidget {
  const EditorSuggestionsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.watch(editorSuggestionsProvider);
    final suggestions = cache.batch.suggestions;
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final text = cache.batch.text ?? 'Here are some edits for your recent uploads';
    return SizedBox(
      height: suggestionsRowHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Icon(Icons.auto_fix_high, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(text, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) => SuggestionCard(suggestion: suggestions[index], cache: cache),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [after], or [before] while pressed (hold to compare)
class HoldToCompare extends StatefulWidget {
  final Widget before;
  final Widget after;
  final VoidCallback? onTap;

  const HoldToCompare({super.key, required this.before, required this.after, this.onTap});

  @override
  State<HoldToCompare> createState() => _HoldToCompareState();
}

class _HoldToCompareState extends State<HoldToCompare> {
  bool _holding = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPressStart: (_) => setState(() => _holding = true),
      onLongPressEnd: (_) => setState(() => _holding = false),
      onLongPressCancel: () => setState(() => _holding = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.after,
          AnimatedOpacity(opacity: _holding ? 1 : 0, duration: const Duration(milliseconds: 90), child: widget.before),
          if (_holding)
            const Positioned(
              left: 8,
              top: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.all(Radius.circular(4))),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('Original', style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Widget _cachedImage(String? path, {BoxFit fit = BoxFit.cover}) {
  if (path == null || !File(path).existsSync()) {
    return const ColoredBox(
      color: Colors.black12,
      child: Center(child: Icon(Icons.image_outlined)),
    );
  }
  return Image.file(File(path), fit: fit, gaplessPlayback: true);
}

class SuggestionCard extends ConsumerWidget {
  final Suggestion suggestion;
  final CachedSuggestions cache;

  const SuggestionCard({super.key, required this.suggestion, required this.cache});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    void openPreview() => unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => SuggestionPreviewPage(
            suggestion: suggestion,
            beforePath: cache.before[suggestion.id],
            afterPath: cache.after[suggestion.id],
          ),
        ),
      ),
    );
    return SizedBox(
      width: 220,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: HoldToCompare(
                onTap: openPreview,
                before: _cachedImage(cache.before[suggestion.id]),
                after: _cachedImage(cache.after[suggestion.id]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Text(
                suggestion.name,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                suggestion.why.isNotEmpty ? suggestion.why : suggestion.summary,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(onPressed: () => applySuggestion(context, ref, suggestion), child: const Text('Apply')),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.tune),
                  onPressed: () => openEditorPhotos(context, ref, suggestion.assetId, suggestion: suggestion),
                ),
                IconButton(
                  tooltip: 'Apply & replace',
                  icon: const Icon(Icons.published_with_changes),
                  onPressed: () => applySuggestion(context, ref, suggestion, replace: true),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close),
                  onPressed: () => dismissSuggestion(context, ref, suggestion),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
