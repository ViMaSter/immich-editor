// Riverpod state for editor.photos: settings, the server (probed once per session) and
// the suggested edits shown on the timeline.
import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/suggestions_store.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('EditorPhotos');

class EditorPhotosSettingsNotifier extends StateNotifier<EditorPhotosSettings?> {
  EditorPhotosSettingsNotifier() : super(null) {
    unawaited(EditorPhotosSettings.load().then((value) => mounted ? state = value : null));
  }

  Future<void> setSuggestionsEnabled(bool enabled) async {
    final next = EditorPhotosSettings(suggestionsEnabled: enabled);
    state = next;
    await next.save();
    if (!enabled) {
      await SuggestionsStore.save(CachedSuggestions.empty);
    }
  }
}

/// null while loading
final editorPhotosSettingsProvider = StateNotifierProvider<EditorPhotosSettingsNotifier, EditorPhotosSettings?>(
  (ref) => EditorPhotosSettingsNotifier(),
);

/// The editor.photos server next to the current Immich server, if it answers the probe
final editorServerProvider = FutureProvider<EditorServer?>((ref) async {
  ref.watch(authProvider.select((s) => s.isAuthenticated));
  final server = EditorServer.current();
  if (server == null) {
    return null;
  }
  return await server.probe() ? server : null;
});

class SuggestionsNotifier extends StateNotifier<CachedSuggestions> {
  final bool enabled;
  bool _refreshing = false;

  SuggestionsNotifier({required this.enabled}) : super(CachedSuggestions.empty) {
    if (enabled) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    final cached = await SuggestionsStore.load();
    if (mounted) {
      state = cached;
    }
    await refresh();
  }

  /// Fetches the current suggestions (on app open; the background worker does the rest)
  Future<void> refresh() async {
    if (!enabled || _refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final fresh = await SuggestionsStore.refresh();
      if (fresh != null && mounted) {
        state = fresh;
      }
    } catch (error) {
      _log.info('Suggestions are not available: $error');
    } finally {
      _refreshing = false;
    }
  }

  /// Removes a suggestion that was applied or dismissed
  Future<void> remove(String suggestionId) async {
    if (mounted) {
      state = state.without(suggestionId);
    }
    await SuggestionsStore.remove(suggestionId);
  }
}

final editorSuggestionsProvider = StateNotifierProvider<SuggestionsNotifier, CachedSuggestions>((ref) {
  final enabled = ref.watch(editorPhotosSettingsProvider.select((s) => s?.suggestionsEnabled));
  final loggedIn = ref.watch(authProvider.select((s) => s.isAuthenticated));
  return SuggestionsNotifier(enabled: enabled == true && loggedIn);
});
