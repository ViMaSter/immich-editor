import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/editor_photos/providers.dart';

/// Settings → Editor: turn the editor.photos suggestions off, see whether the server is there
class EditorPhotosSettingsPage extends ConsumerWidget {
  const EditorPhotosSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(editorPhotosSettingsProvider);
    final server = ref.watch(editorServerProvider);
    final cache = ref.watch(editorSuggestionsProvider);
    final enabled = settings?.suggestionsEnabled ?? true;
    final status = server.when(
      data: (s) =>
          s == null ? 'No editor.photos server found next to your Immich server' : 'Connected to ${s.base.host}',
      loading: () => 'Looking for the editor.photos server…',
      error: (error, _) => 'editor.photos is not reachable',
    );
    final fetched = cache.fetchedAt;
    return Scaffold(
      appBar: AppBar(title: const Text('Editor')),
      body: ListView(
        children: [
          SwitchListTile(
            value: enabled,
            onChanged: settings == null
                ? null
                : (value) => unawaited(ref.read(editorPhotosSettingsProvider.notifier).setSuggestionsEnabled(value)),
            title: const Text('Suggested edits'),
            subtitle: const Text(
              'Show edits that editor.photos suggests for your recent uploads. Fetched when the app opens and once a day in the background.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('editor.photos server'),
            subtitle: Text(status),
            trailing: IconButton(
              tooltip: 'Check again',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(editorServerProvider),
            ),
          ),
          if (enabled)
            ListTile(
              leading: const Icon(Icons.auto_fix_high),
              title: const Text('Refresh suggestions'),
              subtitle: Text(
                fetched == null
                    ? 'Not fetched yet'
                    : '${cache.batch.suggestions.length} suggestions, fetched ${_ago(fetched)}',
              ),
              onTap: () => unawaited(ref.read(editorSuggestionsProvider.notifier).refresh()),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Editing works without the server. Sky, Color focus, Portrait light and Blur need it for their masks.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) {
      return 'just now';
    }
    if (d.inHours < 1) {
      return '${d.inMinutes} min ago';
    }
    if (d.inDays < 1) {
      return '${d.inHours} h ago';
    }
    return '${d.inDays} d ago';
  }
}
