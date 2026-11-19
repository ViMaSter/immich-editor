// Settings and the cache of suggested edits from the editor.photos server.
//
// Everything lives in its own directory under the app's support directory so it stays
// out of the app's database and backups: settings.json, suggestions.json and the
// before/after previews. Suggestions are fetched when the app opens and, through the
// app's background worker, at most once every 24 hours.
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('EditorPhotosSuggestions');

const refreshInterval = Duration(hours: 24);

Future<Directory> editorPhotosDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/editor_photos');
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir;
}

class EditorPhotosSettings {
  final bool suggestionsEnabled;

  const EditorPhotosSettings({this.suggestionsEnabled = true});

  static Future<File> _file() async => File('${(await editorPhotosDir()).path}/settings.json');

  static Future<EditorPhotosSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const EditorPhotosSettings();
      }
      final json = jsonDecode(await file.readAsString());
      return EditorPhotosSettings(suggestionsEnabled: json is Map && json['suggestionsEnabled'] != false);
    } catch (_) {
      return const EditorPhotosSettings();
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.writeAsString(jsonEncode({'suggestionsEnabled': suggestionsEnabled}));
  }
}

/// Cached suggestions with local paths of their previews
class CachedSuggestions {
  final DateTime? fetchedAt;
  final String? server;
  final SuggestionBatch batch;
  final Map<String, String> before;
  final Map<String, String> after;

  const CachedSuggestions({
    this.fetchedAt,
    this.server,
    this.batch = const SuggestionBatch(),
    this.before = const {},
    this.after = const {},
  });

  static const empty = CachedSuggestions();

  bool get isEmpty => batch.suggestions.isEmpty;

  CachedSuggestions without(String suggestionId) => CachedSuggestions(
    fetchedAt: fetchedAt,
    server: server,
    batch: SuggestionBatch(
      window: batch.window,
      text: batch.text,
      suggestions: batch.suggestions.where((s) => s.id != suggestionId).toList(),
    ),
    before: before,
    after: after,
  );

  Map<String, Object?> toJson() => {
    'fetchedAt': fetchedAt?.toIso8601String(),
    'server': server,
    'batch': batch.toJson(),
    'before': before,
    'after': after,
  };

  factory CachedSuggestions.fromJson(Map<String, Object?> json) => CachedSuggestions(
    fetchedAt: json['fetchedAt'] is String ? DateTime.tryParse(json['fetchedAt']! as String) : null,
    server: json['server'] as String?,
    batch: SuggestionBatch.fromJson(((json['batch'] as Map?) ?? const {}).cast<String, Object?>()),
    before: ((json['before'] as Map?) ?? const {}).cast<String, String>(),
    after: ((json['after'] as Map?) ?? const {}).cast<String, String>(),
  );
}

class SuggestionsStore {
  static Future<File> _file() async => File('${(await editorPhotosDir()).path}/suggestions.json');

  static Future<CachedSuggestions> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return CachedSuggestions.empty;
      }
      return CachedSuggestions.fromJson((jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
    } catch (error) {
      _log.warning('Ignoring the suggestions cache: $error');
      return CachedSuggestions.empty;
    }
  }

  static Future<void> save(CachedSuggestions cache) async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(cache.toJson()));
    await tmp.rename(file.path);
  }

  /// Fetches suggestions and their previews. Returns null when the feature is off or the
  /// server is not there (the cache is then left alone).
  static Future<CachedSuggestions?> refresh({EditorServer? server}) async {
    final settings = await EditorPhotosSettings.load();
    if (!settings.suggestionsEnabled) {
      return null;
    }
    final client = server ?? EditorServer.current();
    if (client == null || !await client.probe()) {
      return null;
    }
    final batch = await client.suggestions();
    final dir = Directory('${(await editorPhotosDir()).path}/previews');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final before = <String, String>{};
    final after = <String, String>{};
    for (final s in batch.suggestions) {
      for (final (which, paths) in [('before', before), ('after', after)]) {
        final file = File('${dir.path}/${_safe(s.id)}-$which.jpg');
        if (!file.existsSync()) {
          try {
            final bytes = await client.preview(s.id, which);
            if (bytes == null) {
              continue;
            }
            await file.writeAsBytes(bytes, flush: true);
          } catch (error) {
            _log.warning('Preview $which of ${s.id} failed: $error');
            continue;
          }
        }
        paths[s.id] = file.path;
      }
    }
    // Drop previews of suggestions that are gone
    final keep = {...before.values, ...after.values};
    for (final entity in dir.listSync().whereType<File>()) {
      if (!keep.contains(entity.path)) {
        try {
          entity.deleteSync();
        } catch (_) {
          // best effort
        }
      }
    }
    final cache = CachedSuggestions(
      fetchedAt: DateTime.now(),
      server: client.base.toString(),
      batch: batch,
      before: before,
      after: after,
    );
    await save(cache);
    return cache;
  }

  /// For the background worker: refreshes when the last fetch is older than 24 hours
  static Future<void> refreshIfDue() async {
    try {
      final cache = await load();
      final last = cache.fetchedAt;
      if (last != null && DateTime.now().difference(last) < refreshInterval) {
        return;
      }
      await refresh();
    } catch (error, stack) {
      _log.warning('Background refresh of suggestions failed', error, stack);
    }
  }

  static Future<void> remove(String suggestionId) async {
    final cache = await load();
    await save(cache.without(suggestionId));
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^\w-]+'), '_');
}
