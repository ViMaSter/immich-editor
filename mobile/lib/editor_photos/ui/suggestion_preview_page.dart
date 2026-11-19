// Full-screen preview of a suggested edit. Shows the edit — rendered on the device with
// the recipe, using the server's "after" preview until that is ready — and the original
// while the image is pressed. The bottom bar offers Apply, Apply & replace, Edit and
// Dismiss; back returns to the cards without doing anything.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/data/sources.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/providers.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';
import 'package:immich_mobile/editor_photos/ui/editor_actions.dart';
import 'package:immich_mobile/editor_photos/ui/suggestions_row.dart';

class SuggestionPreviewPage extends ConsumerStatefulWidget {
  final Suggestion suggestion;
  final String? beforePath;
  final String? afterPath;

  const SuggestionPreviewPage({super.key, required this.suggestion, this.beforePath, this.afterPath});

  @override
  ConsumerState<SuggestionPreviewPage> createState() => _SuggestionPreviewPageState();
}

class _SuggestionPreviewPageState extends ConsumerState<SuggestionPreviewPage> {
  GpuImageSource? _source;
  ui.Image? _after;
  GpuMasks? _masks;
  bool _busy = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_renderLocally());
  }

  Future<void> _renderLocally() async {
    try {
      final recipe = Recipe.fromJson(widget.suggestion.recipe);
      final api = ImmichApi();
      final renderer = await GpuRenderer.instance();
      final source = await loadPreviewSource(api, widget.suggestion.assetId);
      if (_disposed) {
        source.dispose();
        return;
      }
      _source = source;
      if (recipe.tools.any) {
        final server = await ref.read(editorServerProvider.future);
        if (server != null) {
          final info = await server.maskInfo(widget.suggestion.assetId);
          _masks = await GpuMasks.upload(await server.masks(widget.suggestion.assetId, info));
        }
      }
      if (_disposed) {
        return;
      }
      final image = await renderer.preview(source, recipe, masks: _masks);
      if (_disposed) {
        image.dispose();
        return;
      }
      setState(() => _after = image);
    } catch (_) {
      // The server's preview stays in place
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _after?.dispose();
    _source?.dispose();
    _masks?.dispose();
    super.dispose();
  }

  Widget _file(String? path) => path != null && File(path).existsSync()
      ? Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true)
      : const Center(child: CircularProgressIndicator());

  Future<void> _run(Future<Object?> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    try {
      final result = await action();
      if (result != null && mounted) {
        navigator.pop();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    final source = _source;
    final after = _after != null ? RawImage(image: _after, fit: BoxFit.contain) : _file(widget.afterPath);
    final before = source != null ? RawImage(image: source.image, fit: BoxFit.contain) : _file(widget.beforePath);
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          leading: const BackButton(),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.name),
              if (s.summary.isNotEmpty)
                Text(s.summary, style: const TextStyle(fontSize: 12, color: Colors.white70), maxLines: 1),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: HoldToCompare(
                before: ColoredBox(color: Colors.black, child: before),
                after: ColoredBox(color: Colors.black, child: after),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                s.why.isNotEmpty
                    ? '${s.why} · Hold the photo to see the original'
                    : 'Hold the photo to see the original',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _BarButton(
                      icon: Icons.check,
                      label: 'Apply',
                      onPressed: _busy ? null : () => _run(() => applySuggestion(context, ref, s)),
                    ),
                    _BarButton(
                      icon: Icons.published_with_changes,
                      label: 'Apply & replace',
                      onPressed: _busy ? null : () => _run(() => applySuggestion(context, ref, s, replace: true)),
                    ),
                    _BarButton(
                      icon: Icons.tune,
                      label: 'Edit',
                      onPressed: _busy
                          ? null
                          : () => _run(() => openEditorPhotos(context, ref, s.assetId, suggestion: s)),
                    ),
                    _BarButton(
                      icon: Icons.close,
                      label: 'Dismiss',
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await dismissSuggestion(context, ref, s);
                              return true;
                            }),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _BarButton({required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: onPressed == null ? Colors.white38 : Colors.white),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: onPressed == null ? Colors.white38 : Colors.white)),
          ],
        ),
      ),
    );
  }
}
