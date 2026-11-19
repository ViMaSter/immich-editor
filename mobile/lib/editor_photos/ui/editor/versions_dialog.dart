// The Versions dialog: the original and every saved edit, with Show this / Discard
// (renderVersions / versionAction in editor.js).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/editor_session.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

/// Shows the dialog; resolves once it is closed (the session's context may have changed)
Future<void> showVersionsDialog(BuildContext context, EditorSession session, {ThemeData? theme}) => showDialog<void>(
  context: context,
  builder: (_) {
    final dialog = VersionsDialog(session: session);
    return theme == null ? dialog : Theme(data: theme, child: dialog);
  },
);

class VersionsDialog extends StatefulWidget {
  const VersionsDialog({super.key, required this.session});

  final EditorSession session;

  @override
  State<VersionsDialog> createState() => _VersionsDialogState();
}

class _VersionRow {
  final String? id;
  final String label;
  final String assetId;
  final String summary;
  final String? source;

  const _VersionRow(this.id, this.label, this.assetId, this.summary, [this.source]);
}

class _VersionsDialogState extends State<VersionsDialog> {
  final Map<String, Future<Uint8List>> _thumbnails = {};
  bool _busy = false;
  String? _error;

  Future<Uint8List> _thumbnail(String assetId) =>
      _thumbnails[assetId] ??= widget.session.api.thumbnail(assetId, 'thumbnail');

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) {
        return;
      }
      if (widget.session.context?.edits.isEmpty ?? true) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _busy = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.session.context!;
    final rows = [
      _VersionRow(null, 'Original', ctx.original.id, 'As taken'),
      for (var i = 0; i < ctx.edits.length; i++)
        _VersionRow(
          ctx.edits[i].id,
          'Edit ${i + 1}',
          ctx.edits[i].renderedAssetId,
          ctx.edits[i].summary,
          ctx.edits[i].source,
        ),
    ];
    final error = _error;
    return AlertDialog(
      title: const Text('Versions'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(error, style: const TextStyle(color: EditorColors.danger, fontSize: 13)),
              ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _row(rows[i], ctx.shownEditId),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: EditorColors.danger),
          onPressed: _busy ? null : () => unawaited(_act(() => widget.session.discard('all'))),
          child: const Text('Discard all edits'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }

  Widget _row(_VersionRow row, String? shownEditId) {
    final shown = row.id == shownEditId;
    final id = row.id;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: EditorColors.panel2,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        border: Border.all(color: shown ? EditorColors.accent : Colors.transparent, width: 2),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: SizedBox(
              width: 64,
              height: 64,
              child: FutureBuilder<Uint8List>(
                future: _thumbnail(row.assetId),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return const ColoredBox(color: EditorColors.panel);
                  }
                  return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${row.label}${shown ? ' · shown' : ''}${row.source == 'suggestion' ? ' · suggestion' : ''}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: EditorColors.text),
                ),
                const SizedBox(height: 2),
                Text(
                  row.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: EditorColors.muted),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!shown)
                TextButton(
                  onPressed: _busy ? null : () => unawaited(_act(() => widget.session.show(id))),
                  child: const Text('Show this'),
                ),
              if (id != null)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: EditorColors.danger),
                  onPressed: _busy ? null : () => unawaited(_act(() => widget.session.discard(id))),
                  child: const Text('Discard'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
