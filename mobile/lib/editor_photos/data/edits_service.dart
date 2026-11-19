// Saving edits as Immich versions, switching the shown version and discarding them
// (port of src/edits.js; rendering happens on the device).
//
// Layout in Immich:
// - the original keeps metadata key `editor-photos` = { v: 1, edits: [{ id, createdAt, source, renderedAssetId, recipe }] }
// - each rendered version is a separate JPEG with metadata `editor-photos-render` = { v: 1, originalId, editId }
// - original and rendered versions share one stack; its primary is the version shown
// - "Apply & replace": the history moves to the new asset (with `replacedOriginalId`), the
//   original leaves the stack and goes to Immich's trash
import 'dart:async';

import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/data/sources.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';
import 'package:uuid/uuid.dart';

const editsKey = 'editor-photos';
const renderKey = 'editor-photos-render';

class EditsException implements Exception {
  final String message;

  const EditsException(this.message);

  @override
  String toString() => message;
}

class OriginalInfo {
  final String id;
  final String fileName;
  final String type;
  final double? width;
  final double? height;

  const OriginalInfo({required this.id, required this.fileName, required this.type, this.width, this.height});
}

class EditVersion {
  final String id;
  final String? createdAt;
  final String source;
  final String renderedAssetId;
  final String summary;

  const EditVersion({
    required this.id,
    required this.createdAt,
    required this.source,
    required this.renderedAssetId,
    required this.summary,
  });
}

class EditContext {
  final OriginalInfo original;
  final bool editable;
  final String? stackId;
  final String? shownEditId;
  final Recipe recipe;
  final List<EditVersion> edits;

  const EditContext({
    required this.original,
    required this.editable,
    required this.stackId,
    required this.shownEditId,
    required this.recipe,
    required this.edits,
  });
}

class SaveResult {
  final String editId;
  final String renderedAssetId;
  final int width;
  final int height;
  final String from;
  final bool replaced;

  const SaveResult({
    required this.editId,
    required this.renderedAssetId,
    required this.width,
    required this.height,
    required this.from,
    required this.replaced,
  });
}

String _stripExtension(String? name) {
  final base = (name == null || name.isEmpty ? 'photo' : name).replaceFirst(RegExp(r'\.[^.]+$'), '');
  final safe = base.replaceAll(RegExp(r'[^\w.-]+'), '_');
  final cut = safe.length > 120 ? safe.substring(0, 120) : safe;
  return cut.isEmpty ? 'photo' : cut;
}

/// A string field of a JSON object, or null
String? _field(Object? obj, String key) {
  final value = obj is Map ? obj[key] : null;
  return value is String ? value : null;
}

typedef StepReporter = void Function(String step, [double? progress]);

class EditsService {
  final ImmichApi api;
  final EditorServer? server;
  final Future<GpuRenderer> Function() _renderer;

  EditsService({required this.api, this.server, Future<GpuRenderer> Function()? renderer})
    : _renderer = renderer ?? GpuRenderer.instance;

  Future<List<Json>> editsOf(String originalId) async {
    final meta = await api.metadata(originalId);
    final edits = prop(meta[editsKey], 'edits');
    return edits is List ? [for (final e in edits.whereType<Map>()) e.cast<String, Object?>()] : <Json>[];
  }

  Future<void> _writeEdits(String originalId, List<Json> edits) async {
    if (edits.isNotEmpty) {
      await api.setMetadata(originalId, editsKey, {'v': 1, 'edits': edits});
    } else {
      await api.deleteMetadata(originalId, editsKey);
    }
  }

  /// Any asset of a stack (original or rendered version) leads to the original
  Future<String> resolveOriginal(String assetId) async {
    final meta = await api.metadata(assetId);
    final pointer = meta[renderKey];
    final originalId = _field(pointer, 'originalId');
    if (originalId is String && originalId != assetId) {
      return originalId;
    }
    return assetId;
  }

  Future<EditContext> context(String assetId) async {
    final originalId = await resolveOriginal(assetId);
    final original = await api.asset(originalId);
    final edits = await editsOf(originalId);
    final stackId = _field(original['stack'], 'id');
    Json? stack;
    if (stackId is String) {
      try {
        stack = await api.stack(stackId);
      } catch (_) {
        stack = null;
      }
    }
    final primaryId = (stack?['primaryAssetId'] as String?) ?? originalId;
    final shown = edits.where((e) => e['renderedAssetId'] == primaryId).firstOrNull;
    final exif = (original['exifInfo'] as Map?) ?? const {};
    return EditContext(
      original: OriginalInfo(
        id: original['id']! as String,
        fileName: (original['originalFileName'] as String?) ?? 'photo',
        type: (original['type'] as String?) ?? 'IMAGE',
        width: (original['width'] as num?)?.toDouble() ?? (exif['exifImageWidth'] as num?)?.toDouble(),
        height: (original['height'] as num?)?.toDouble() ?? (exif['exifImageHeight'] as num?)?.toDouble(),
      ),
      editable: original['type'] == 'IMAGE',
      stackId: stack?['id'] as String?,
      shownEditId: shown?['id'] as String?,
      recipe: Recipe.fromJson((shown ?? edits.lastOrNull)?['recipe']),
      edits: [
        for (final e in edits)
          EditVersion(
            id: e['id']! as String,
            createdAt: e['createdAt'] as String?,
            source: (e['source'] as String?) ?? 'manual',
            renderedAssetId: e['renderedAssetId']! as String,
            summary: Recipe.fromJson(e['recipe']).describe(),
          ),
      ],
    );
  }

  /// Masks for the tools, when the recipe uses them and the server can provide them
  Future<GpuMasks?> masksFor(String originalId, Recipe recipe, {bool float = false}) async {
    if (!recipe.tools.any || server == null) {
      return null;
    }
    final info = await server!.maskInfo(originalId);
    return GpuMasks.upload(await server!.masks(originalId, info), float: float);
  }

  /// Renders [recipe] on the device at full resolution and stores it as a new version.
  /// With [replace] the new version takes the original's place.
  Future<SaveResult> save(
    String originalId,
    Recipe rawRecipe, {
    String source = 'manual',
    bool replace = false,
    StepReporter? onStep,
    GpuMasks? masks,
    GpuSource? proxy,
  }) async {
    final report = onStep ?? (_, [_]) {};
    final recipe = rawRecipe.normalized();
    if (recipe.isIdentity) {
      throw const EditsException('Nothing to save: the edit makes no changes');
    }
    report('Loading the original');
    final original = await api.asset(originalId);
    if (original['type'] != 'IMAGE') {
      throw const EditsException('Only photos can be edited');
    }
    final loaded = await loadFullSource(api, originalId);
    GpuMasks? ownMasks;
    try {
      final renderer = await _renderer();
      final toolMasks = masks ?? (ownMasks = await masksFor(originalId, recipe));
      report('Rendering ${loaded.source.width.round()}×${loaded.source.height.round()}');
      final (rgba, width, height) = await renderer.full(
        loaded.source,
        recipe,
        masks: toolMasks,
        proxy: proxy,
        onProgress: (p) => report('Rendering', p),
      );
      report('Encoding');
      final exif = (original['exifInfo'] as Map?)?.cast<String, Object?>() ?? const {};
      final dates = ExifDates.of(original['fileCreatedAt'] as String?, original['localDateTime'] as String?);
      final jpeg = await encodeJpeg(
        rgba,
        width,
        height,
        make: exif['make'] as String?,
        model: exif['model'] as String?,
        dates: dates,
      );

      report('Uploading to Immich');
      final edits = await editsOf(originalId);
      final editId = const Uuid().v4();
      final filename = '${_stripExtension(original['originalFileName'] as String?)}-edit-${edits.length + 1}.jpg';
      final fileCreatedAt = original['fileCreatedAt'] as String? ?? DateTime.now().toUtc().toIso8601String();
      final uploaded = await api.upload(
        bytes: jpeg,
        filename: filename,
        fileCreatedAt: fileCreatedAt,
        fileModifiedAt: (original['fileModifiedAt'] as String?) ?? fileCreatedAt,
        metadata: [
          {
            'key': renderKey,
            'value': {'v': 1, 'originalId': originalId, 'editId': editId},
          },
        ],
      );
      final renderedAssetId = uploaded['id']! as String;
      if (uploaded['status'] == 'duplicate') {
        await api.setMetadata(renderedAssetId, renderKey, {'v': 1, 'originalId': originalId, 'editId': editId});
      }

      // Same place in the timeline, same albums, favourite and shared links as the original
      final update = <String, Object?>{};
      if (dates != null) {
        update['dateTimeOriginal'] = dates.iso;
      }
      final lat = exif['latitude'];
      final lon = exif['longitude'];
      if (lat is num && lon is num && lat.isFinite && lon.isFinite) {
        update['latitude'] = lat;
        update['longitude'] = lon;
      }
      if (update.isNotEmpty) {
        await api.updateAsset(renderedAssetId, update);
      }
      await api.copyAsset({
        'sourceId': originalId,
        'targetId': renderedAssetId,
        'albums': true,
        'sharedLinks': true,
        'favorite': true,
        'sidecar': true,
        'stack': false,
      });

      report('Stacking the new version');
      final fresh = await api.asset(originalId);
      final currentPrimary = _field(fresh['stack'], 'primaryAssetId') ?? originalId;
      await api.createStack([renderedAssetId, currentPrimary]);

      final entry = <String, Object?>{
        'id': editId,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'source': source == 'suggestion' ? 'suggestion' : 'manual',
        'renderedAssetId': renderedAssetId,
        'recipe': recipe.toJson(),
        'from': loaded.from,
      };
      if (replace) {
        report('Replacing the original');
        await api.setMetadata(renderedAssetId, editsKey, {
          'v': 1,
          'edits': [
            ...edits,
            {...entry, 'replacedOriginalId': originalId},
          ],
        });
        await api.setMetadata(renderedAssetId, renderKey, {
          'v': 1,
          'originalId': renderedAssetId,
          'editId': editId,
          'replacedOriginalId': originalId,
        });
        final stacked = await api.asset(renderedAssetId);
        final stackId = _field(stacked['stack'], 'id');
        if (stackId is String) {
          Json? stack;
          try {
            stack = await api.stack(stackId);
          } catch (_) {
            stack = null;
          }
          final members = [
            for (final a in (stack?['assets'] as List?) ?? const [])
              if (a is Map) a['id'] as String,
          ];
          if (members.where((id) => id != originalId).length < 2) {
            await api.deleteStack(stackId);
          } else {
            await api.removeFromStack(stackId, originalId);
          }
        }
        await api.trash([originalId]);
      } else {
        await _writeEdits(originalId, [...edits, entry]);
      }
      return SaveResult(
        editId: editId,
        renderedAssetId: renderedAssetId,
        width: width,
        height: height,
        from: loaded.from,
        replaced: replace,
      );
    } finally {
      ownMasks?.dispose();
      loaded.source.dispose();
    }
  }

  /// Trashes one version ([editId]) or all of them ('all'), keeping the stack consistent
  Future<int> discard(String originalId, String editId) async {
    final edits = await editsOf(originalId);
    final targets = editId == 'all' ? edits.reversed.toList() : edits.where((e) => e['id'] == editId).toList();
    if (targets.isEmpty) {
      throw const EditsException('No such edit');
    }
    var remaining = edits;
    for (final edit in targets) {
      final rendered = edit['renderedAssetId']! as String;
      remaining = remaining.where((e) => e['id'] != edit['id']).toList();
      final original = await api.asset(originalId);
      final stackId = _field(original['stack'], 'id');
      if (stackId is String) {
        Json? stack;
        try {
          stack = await api.stack(stackId);
        } catch (_) {
          stack = null;
        }
        final members = [
          for (final a in (stack?['assets'] as List?) ?? const [])
            if (a is Map) a['id'] as String,
        ];
        if (stack != null && members.contains(rendered)) {
          final others = members.where((id) => id != rendered).toList();
          if (others.length <= 1) {
            await api.deleteStack(stackId);
          } else if (stack['primaryAssetId'] == rendered) {
            // Trashing the primary would hide the whole stack: hand over first
            final fallback =
                remaining.reversed
                    .map((e) => e['renderedAssetId'] as String?)
                    .where((id) => id != null && others.contains(id))
                    .firstOrNull ??
                originalId;
            await api.setStackPrimary(stackId, fallback);
            await api.removeFromStack(stackId, rendered);
          } else {
            await api.removeFromStack(stackId, rendered);
          }
        }
      }
      await api.trash([rendered]);
      await _writeEdits(originalId, remaining);
    }
    return remaining.length;
  }

  /// Shows a version ([editId]) or the original (null) as the stack's primary
  Future<void> show(String originalId, String? editId) async {
    final edits = await editsOf(originalId);
    final target = editId == null
        ? originalId
        : edits.where((e) => e['id'] == editId).firstOrNull?['renderedAssetId'] as String?;
    if (target == null) {
      throw const EditsException('No such edit');
    }
    final original = await api.asset(originalId);
    final stackId = _field(original['stack'], 'id');
    if (stackId is! String) {
      throw const EditsException('This photo has no versions');
    }
    await api.setStackPrimary(stackId, target);
  }
}
