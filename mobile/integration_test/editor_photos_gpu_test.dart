// On-device check of the editor.photos GPU pipeline (Impeller on Vulkan/GLES): renders
// recipes with the shaders and compares them with the Dart CPU port, which matches the
// web renderer bit for bit (test/editor_photos/cpu_pipeline_test.dart).
//   flutter test integration_test/editor_photos_gpu_test.dart -d <device>
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_pipeline.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';
import 'package:integration_test/integration_test.dart';

const _w = 96;
const _h = 64;

Uint8List _sourceRgba() {
  final out = Uint8List(_w * _h * 4);
  var seed = 7;
  int rnd() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      final o = (y * _w + x) * 4;
      final noise = rnd() % 21 - 10;
      final sky = y < _h / 3;
      out[o] = ((sky ? 90 : 160) + x + noise).clamp(0, 255);
      out[o + 1] = ((sky ? 140 : 120) + y + noise).clamp(0, 255);
      out[o + 2] = ((sky ? 230 : 80) - x ~/ 2 + noise).clamp(0, 255);
      out[o + 3] = 255;
    }
  }
  return out;
}

EditorMasks _masks() {
  const mw = 48;
  const mh = 32;
  final sky = Float32List(mw * mh);
  final subject = Float32List(mw * mh);
  final depth = Float32List(mw * mh);
  for (var y = 0; y < mh; y++) {
    for (var x = 0; x < mw; x++) {
      final p = y * mw + x;
      sky[p] = (((mh / 3 - y) / 4).clamp(0.0, 1.0) * 255).round() / 255;
      final d = math.sqrt(math.pow((x - mw / 2) / 10, 2) + math.pow((y - mh * 0.6) / 8, 2));
      subject[p] = ((1.2 - d).clamp(0.0, 1.0) * 255).round() / 255;
      depth[p] = ((y / mh) * 255).round() / 255;
    }
  }
  return EditorMasks(
    width: mw,
    height: mh,
    sky: sky,
    subject: subject,
    depth: depth,
    faces: const [FaceBox(x: 0.42, y: 0.5, w: 0.15, h: 0.22)],
  );
}

final _recipes = <String, Map<String, Object?>>{
  'identity': {},
  'tone': {
    'adjust': {'brightness': 0.4, 'contrast': 0.5, 'whitePoint': 0.3, 'blackPoint': -0.2},
  },
  'local tone': {
    'adjust': {'shadows': 0.7, 'highlights': -0.6, 'hdr': 0.5},
  },
  'pop and colour': {
    'adjust': {
      'pop': 0.6,
      'saturation': 0.5,
      'warmth': 0.4,
      'tint': -0.3,
      'skinTone': 0.4,
      'blueTone': 0.5,
      'vignette': 0.6,
    },
  },
  'filter neon': {
    'filter': {'id': 'neon', 'strength': 0.8},
  },
  'geometry': {
    'geometry': {
      'rotate90': 1,
      'angle': 7.5,
      'crop': {'cx': 0.5, 'cy': 0.5, 'w': 0.7, 'h': 0.7},
    },
    'adjust': {'contrast': 0.2},
  },
  'advanced': {
    'advanced': {
      'exposure': 0.6,
      'clarity': 0.5,
      'dehaze': 0.4,
      'levels': {'inBlack': 0.05, 'gamma': 1.3},
      'curves': {
        'rgb': [
          [0.25, 0.2],
          [0.75, 0.85],
        ],
        'b': [
          [0.5, 0.45],
        ],
      },
      'hsl': {
        'blue': {'h': 0.3, 's': 0.4, 'l': -0.2},
      },
      'grading': {
        'shadows': {'hue': 220, 'sat': 0.5},
        'highlights': {'hue': 40, 'sat': 0.4},
      },
      'sharpen': {'amount': 0.6, 'radius': 1.5},
      'noise': 0.5,
      'grain': 0.6,
      'vignette': {'amount': -0.5, 'roundness': 0.4},
    },
  },
  'tools': {
    'tools': {
      'sky': {'palette': 'ember', 'strength': 0.8},
      'colorFocus': {'strength': 0.5},
      'portraitLight': {'x': 0.2, 'y': 0.3, 'strength': 0.9},
      'blur': {
        'strength': 0.7,
        'focus': {'x': 0.5, 'y': 0.7},
      },
    },
  },
};

Float32List _rgb(Float32List rgba) {
  final out = Float32List(rgba.length ~/ 4 * 3);
  for (var p = 0; p < rgba.length ~/ 4; p++) {
    out[p * 3] = rgba[p * 4];
    out[p * 3 + 1] = rgba[p * 4 + 1];
    out[p * 3 + 2] = rgba[p * 4 + 2];
  }
  return out;
}

(double, double) _diff(Float32List a, Float32List b) {
  var max = 0.0;
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    max = math.max(max, d);
    sum += d;
  }
  return (max, sum / a.length);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GPU pipeline on the device matches the CPU port', (tester) async {
    final rgba = _sourceRgba();
    final cpuSource = fromRgba8(rgba, _w, _h);
    final cpuMasks = _masks();
    final results = await tester.runAsync(() async {
      final renderer = await GpuRenderer.create(maxTile: 48);
      final lines = <String>['GPU capabilities: ${renderer.caps}'];
      final image = await imageFromRgba(rgba, _w, _h);
      final source = GpuImageSource(image, owned: false);
      final masks = await GpuMasks.upload(cpuMasks, float: renderer.caps.floatTargets);
      var worst = 0.0;
      for (final entry in _recipes.entries) {
        final recipe = Recipe.fromJson(entry.value);
        final useMasks = recipe.tools.any;
        final expected = renderCpu(cpuSource, recipe, masks: useMasks ? cpuMasks : null);
        final preview = await renderer.preview(source, recipe, masks: useMasks ? masks : null, floatOutput: true);
        final data = await preview.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128);
        preview.dispose();
        final (pMax, pMean) = _diff(_rgb(data!.buffer.asFloat32List()), expected.data);
        await renderer.full(source, recipe, masks: useMasks ? masks : null, floatOutput: true);
        final (tMax, tMean) = _diff(_rgb(renderer.lastFloatOutput!), expected.data);
        worst = math.max(worst, math.max(pMean, tMean));
        lines.add(
          '${entry.key.padRight(16)} preview max ${pMax.toStringAsFixed(4)} mean ${pMean.toStringAsFixed(5)}'
          ' | tiled max ${tMax.toStringAsFixed(4)} mean ${tMean.toStringAsFixed(5)}',
        );
      }
      masks.dispose();
      image.dispose();
      lines.add('worst mean ${worst.toStringAsFixed(5)}');
      return (lines, worst);
    });
    // ignore: avoid_print
    print(results!.$1.join('\n'));
    expect(results.$2, lessThan(0.01));
  });
}
