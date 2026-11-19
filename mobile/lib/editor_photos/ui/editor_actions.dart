// Entry points shared by the asset viewer, the suggestion cards and the full-screen
// suggestion preview: open the editor, apply (or apply & replace) a suggestion on the
// device, dismiss one.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/edits_service.dart';
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/editor_session.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/providers.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_page.dart';

Future<EditorServer?> _server(WidgetRef ref) async {
  try {
    return await ref.read(editorServerProvider.future).timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  }
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
}

/// Opens the editor for [assetId] (optionally starting from a suggested edit). Returns the
/// saved version, or null when nothing was saved.
Future<SaveResult?> openEditorPhotos(
  BuildContext context,
  WidgetRef ref,
  String assetId, {
  Suggestion? suggestion,
}) async {
  final navigator = Navigator.of(context);
  final cancelled = ValueNotifier(false);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        onPopInvokedWithResult: (didPop, _) => cancelled.value = true,
        child: const AlertDialog(
          content: Row(
            children: [
              SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(width: 20),
              Expanded(child: Text('Opening the editor…')),
            ],
          ),
        ),
      ),
    ),
  );
  EditorSession? session;
  try {
    final server = await _server(ref);
    session = EditorSession(assetId: assetId, api: ImmichApi(), server: server, suggestion: suggestion);
    await session.open();
  } catch (error) {
    session?.dispose();
    session = null;
    if (!cancelled.value) {
      navigator.pop();
    }
    if (context.mounted) {
      _snack(context, "Couldn't open the photo: $error");
    }
    return null;
  }
  if (cancelled.value) {
    session.dispose();
    return null;
  }
  navigator.pop();
  if (!session.context!.editable) {
    session.dispose();
    if (context.mounted) {
      _snack(context, 'Only photos can be edited.');
    }
    return null;
  }
  final opened = session;
  final result = await navigator.push<SaveResult>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => EditorPhotosPage(session: opened)),
  );
  if (result != null && suggestion != null) {
    await ref.read(editorSuggestionsProvider.notifier).remove(suggestion.id);
  }
  if (result != null && context.mounted) {
    _snack(context, result.replaced ? 'Saved; the original is in the trash' : 'Saved as a new version');
  }
  return result;
}

/// Asks before the original is replaced (Apply & replace)
Future<bool> confirmReplace(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Replace the original?'),
      content: const Text(
        "The edited photo takes its place. The original moves to Immich's trash, where it stays for 30 days.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
          child: const Text('Apply & replace'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Renders [suggestion] on the device and saves it exactly like a manual save, then
/// reports `applied`. With [replace] the original is replaced (after confirmation).
Future<SaveResult?> applySuggestion(
  BuildContext context,
  WidgetRef ref,
  Suggestion suggestion, {
  bool replace = false,
}) async {
  if (replace && !await confirmReplace(context)) {
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  final navigator = Navigator.of(context);
  final step = ValueNotifier<(String, double?)>(('Preparing', null));
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<(String, double?)>(
            valueListenable: step,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${value.$1}…'),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: value.$2),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  try {
    final server = await _server(ref);
    final edits = EditsService(api: ImmichApi(), server: server);
    final originalId = await edits.resolveOriginal(suggestion.assetId);
    final result = await edits.save(
      originalId,
      Recipe.fromJson(suggestion.recipe),
      source: 'suggestion',
      replace: replace,
      onStep: (text, [progress]) => step.value = (text, progress),
    );
    navigator.pop();
    unawaited(server?.feedback(suggestion.id, 'applied').catchError((Object _) {}));
    await ref.read(editorSuggestionsProvider.notifier).remove(suggestion.id);
    if (context.mounted) {
      _snack(context, replace ? 'Applied; the original is in the trash' : 'Applied as a new version');
    }
    return result;
  } catch (error) {
    navigator.pop();
    if (context.mounted) {
      _snack(context, "Couldn't apply the edit: $error");
    }
    return null;
  }
}

/// Dismisses a suggestion (reported to the server as `dismissed`)
Future<void> dismissSuggestion(BuildContext context, WidgetRef ref, Suggestion suggestion) async {
  final server = await _server(ref);
  unawaited(server?.feedback(suggestion.id, 'dismissed').catchError((Object _) {}));
  await ref.read(editorSuggestionsProvider.notifier).remove(suggestion.id);
}
