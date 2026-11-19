// Golden comparison of the GPU shader pipeline against the web renderer's output
// (fixtures/pipeline, written by fixtures/generate.mjs with the JavaScript pipeline).
//
// Run with Impeller so render targets keep float precision, like on the phone:
//   flutter test --enable-impeller test/editor_photos/gpu_pipeline_test.dart
// Without Impeller the test renderer (Skia, CPU) only has 8-bit targets; the renderer
// then falls back to offset/scaled 8-bit states and the tolerances are looser.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_pipeline.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';

import 'fixture_utils.dart';

Future<ui.Image> _floatImage(RgbImage img) {
  final rgba = Float32List(img.width * img.height * 4);
  for (var p = 0; p < img.width * img.height; p++) {
    rgba[p * 4] = img.data[p * 3];
    rgba[p * 4 + 1] = img.data[p * 3 + 1];
    rgba[p * 4 + 2] = img.data[p * 3 + 2];
    rgba[p * 4 + 3] = 1;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba.buffer.asUint8List(),
    img.width,
    img.height,
    ui.PixelFormat.rgbaFloat32,
    completer.complete,
    targetFormat: ui.TargetPixelFormat.rgbaFloat32,
  );
  return completer.future;
}

Float32List _rgb(Float32List rgba) {
  final out = Float32List(rgba.length ~/ 4 * 3);
  for (var p = 0; p < rgba.length ~/ 4; p++) {
    out[p * 3] = rgba[p * 4];
    out[p * 3 + 1] = rgba[p * 4 + 1];
    out[p * 3 + 2] = rgba[p * 4 + 2];
  }
  return out;
}

void main() {
  final fixtures = PipelineFixtures.load();

  testWidgets('GPU pipeline matches the web renderer', (tester) async {
    await tester.runAsync(() async {
      final renderer = await GpuRenderer.create(maxTile: 40);
      // ignore: avoid_print
      print('GPU capabilities: ${renderer.caps}');
      final float = renderer.caps.floatTargets;
      final sourceImage = await _floatImage(fixtures.source);
      final rows = <String>[];
      final failures = <String>[];
      var worstMean = 0.0;
      for (final c in fixtures.cases) {
        final recipe = Recipe.fromJson(c.recipe);
        final source = GpuImageSource(
          sourceImage,
          originalWidth: c.sourceWidth ?? fixtures.source.width.toDouble(),
          originalHeight: c.sourceHeight ?? fixtures.source.height.toDouble(),
          owned: false,
        );
        GpuMasks? masks;
        if (c.masks) {
          final m = fixtures.masks;
          masks = await GpuMasks.upload(
            EditorMasks(
              width: m.width,
              height: m.height,
              sky: m.sky,
              subject: m.subject,
              depth: m.depth,
              faces: m.faces,
            ),
            float: renderer.caps.floatTargets,
          );
        }
        final expected = c.expected();
        // Export path: tiles of at most 40 px (so tiling and fields are exercised)
        final (_, w, h) = await renderer.full(source, recipe, masks: masks, maxPixels: c.maxPixels, floatOutput: true);
        expect((w, h), (c.width, c.height), reason: c.name);
        final tiled = diffStats(_rgb(renderer.lastFloatOutput!), expected.data);
        // Preview path (whole image at once) where the case has no separate source size
        String previewText = '-';
        if (c.sourceWidth == null && c.maxPixels == double.infinity) {
          final image = await renderer.preview(source, recipe, masks: masks, floatOutput: true);
          final data = await image.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128);
          image.dispose();
          final preview = diffStats(_rgb(data!.buffer.asFloat32List()), expected.data);
          previewText = '${preview.max.toStringAsFixed(4)} / ${preview.mean.toStringAsFixed(5)}';
          if (preview.mean > worstMean) {
            worstMean = preview.mean;
          }
        }
        masks?.dispose();
        if (tiled.mean > worstMean) {
          worstMean = tiled.mean;
        }
        rows.add(
          '${c.name.padRight(58)} tiled max ${tiled.max.toStringAsFixed(4)} mean ${tiled.mean.toStringAsFixed(5)}'
          '   preview max/mean $previewText',
        );
        if (tiled.mean >= (float ? 0.01 : 0.03)) {
          failures.add('${c.name}: mean ${tiled.mean}');
        }
      }
      sourceImage.dispose();
      // ignore: avoid_print
      print(rows.join('\n'));
      // ignore: avoid_print
      print('worst mean difference: ${worstMean.toStringAsFixed(5)} (0..1 scale)');
      expect(failures, isEmpty);
    });
  });
}
