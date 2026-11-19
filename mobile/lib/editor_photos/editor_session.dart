// Everything the editor screen needs for one photo: its Immich context and versions, a
// preview-sized source on the GPU, statistics for the automatic suggestions, the masks
// for the tools (from the editor.photos server) and saving.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/edits_service.dart';
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/data/sources.dart';
import 'package:immich_mobile/editor_photos/data/suggestions_store.dart';
import 'package:immich_mobile/editor_photos/model/auto.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';

/// Masks and what the server says about them
class ToolMasks {
  final MaskInfo info;
  final GpuMasks masks;

  const ToolMasks(this.info, this.masks);

  bool get hasSky => info.coverageOf('sky') > 0.03 && masks.hasSky;
  bool get hasColorFocus => (info.coverageOf('subject') > 0.02 && masks.hasSubject) || masks.hasDepth;
  bool get hasPortraitLight => info.faces.isNotEmpty;
  bool get hasBlur => masks.hasDepth;
}

class EditorSession {
  final String assetId;
  final ImmichApi api;

  /// The editor.photos server, only when it answered the probe (else tools are hidden)
  final EditorServer? server;

  /// The suggested edit the current recipe started from (feedback is sent on save)
  Suggestion? suggestion;

  late final EditsService edits = EditsService(api: api, server: server);

  EditContext? context;
  GpuRenderer? renderer;
  GpuImageSource? preview;
  PhotoStats? stats;
  List<Suggestion> assetSuggestions = const [];
  Future<ToolMasks?>? _masks;
  bool _disposed = false;

  EditorSession({required this.assetId, required this.api, this.server, this.suggestion});

  String get originalId => context?.original.id ?? assetId;

  /// Loads the context, the preview source and the renderer
  Future<void> open() async {
    context = await edits.context(assetId);
    final results = await Future.wait<Object>([GpuRenderer.instance(), loadPreviewSource(api, originalId)]);
    renderer = results[0] as GpuRenderer;
    preview = results[1] as GpuImageSource;
    final rgba = await preview!.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba != null) {
      stats = measureRgba8(rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes));
    }
    final cached = await SuggestionsStore.load();
    assetSuggestions = cached.batch.suggestions.where((s) => s.assetId == originalId || s.assetId == assetId).toList();
  }

  /// The recipe to start from: the suggestion's, else the shown (or latest) version's
  Recipe initialRecipe() => suggestion != null ? Recipe.fromJson(suggestion!.recipe) : context!.recipe.copy();

  /// Masks for the tools, loaded on first use (null when the server cannot provide them)
  Future<ToolMasks?> masks() => _masks ??= _loadMasks();

  /// Already-loaded masks (for rendering without waiting)
  ToolMasks? loadedMasks;

  Future<ToolMasks?> _loadMasks() async {
    final s = server;
    if (s == null) {
      return null;
    }
    try {
      final info = await s.maskInfo(originalId);
      final masks = await GpuMasks.upload(await s.masks(originalId, info));
      if (_disposed) {
        masks.dispose();
        return null;
      }
      return loadedMasks = ToolMasks(info, masks);
    } catch (error) {
      _masks = null;
      rethrow;
    }
  }

  /// Preview render of [recipe]; [toneOnly] ignores the geometry (crop tab)
  Future<ui.Image> render(Recipe recipe, {bool toneOnly = false, double maxPixels = double.infinity}) async {
    final masks = recipe.tools.any ? loadedMasks?.masks : null;
    return renderer!.preview(preview!, recipe, masks: masks, toneOnly: toneOnly, maxPixels: maxPixels);
  }

  /// Saves on the device; reports suggestion feedback ('applied' or 'tweaked')
  Future<SaveResult> save(Recipe recipe, {bool replace = false, StepReporter? onStep}) async {
    final s = suggestion;
    final result = await edits.save(
      originalId,
      recipe,
      source: s != null ? 'suggestion' : 'manual',
      replace: replace,
      onStep: onStep,
      masks: recipe.tools.any ? (await masks().catchError((_) => null))?.masks : null,
      proxy: preview,
    );
    if (s != null) {
      final same = Recipe.fromJson(s.recipe).equals(recipe);
      unawaited(
        server
            ?.feedback(s.id, same ? 'applied' : 'tweaked', recipe: same ? null : recipe.toJson())
            .then((_) => SuggestionsStore.remove(s.id))
            .catchError((Object _) {}),
      );
    }
    return result;
  }

  Future<void> discard(String editId) async {
    await edits.discard(originalId, editId);
    context = await edits.context(originalId);
  }

  Future<void> show(String? editId) async {
    await edits.show(originalId, editId);
    context = await edits.context(originalId);
  }

  void dispose() {
    _disposed = true;
    preview?.dispose();
    loadedMasks?.masks.dispose();
  }
}
