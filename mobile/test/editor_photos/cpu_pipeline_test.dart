import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_pipeline.dart';
import 'package:immich_mobile/editor_photos/render/js_math.dart';

import 'fixture_utils.dart';

// The port keeps the JavaScript's double arithmetic and Float32 stores in the same order,
// so it reproduces render() almost bit for bit. Only Math.exp/sin/cos can differ from V8
// by one double ulp, which very rarely flips a Float32 rounding (≈ 6e-8). A few of those
// can be amplified by later steps (division by the dehaze transmission, the contrast
// S-curve), hence a margin well below one 8-bit step (1/255 ≈ 3.9e-3).
const _maxTolerance = 1e-5;
const _meanTolerance = 1e-7;

/// Port of `chart()` in edit-core.test.js: grey ramp on top, coloured patches below
RgbImage chart([int width = 64, int height = 48]) {
  final img = RgbImage(width, height);
  const patches = [
    [0.8, 0.55, 0.45],
    [0.25, 0.45, 0.8],
    [0.3, 0.6, 0.3],
    [0.9, 0.85, 0.2],
  ];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final j = (y * width + x) * 3;
      if (y < height / 2) {
        final v = x / (width - 1);
        img.data[j] = v;
        img.data[j + 1] = v;
        img.data[j + 2] = v;
      } else {
        final p = patches[((x / width) * patches.length).floor()];
        img.data.setAll(j, p);
      }
    }
  }
  return img;
}

double _mean(Iterable<double> values) => values.fold(0.0, (a, b) => a + b) / values.length;

double meanLuma(RgbImage img) => _mean(luminance(img));

double saturationOf(RgbImage img) {
  var s = 0.0;
  final d = img.data;
  for (var j = 0; j < d.length; j += 3) {
    s += math.max(d[j], math.max(d[j + 1], d[j + 2])) - math.min(d[j], math.min(d[j + 1], d[j + 2]));
  }
  return s / (d.length / 3);
}

RgbImage tone(RgbImage img, Map<String, Object?> values) =>
    applyToneCpu(img.clone(), Recipe.fromJson({'adjust': values}));

RgbImage render(RgbImage img, Map<String, Object?> recipe) => renderCpu(img, Recipe.fromJson(recipe));

bool hasNaN(RgbImage img) => img.data.any((v) => v.isNaN);

void main() {
  group('matches the JavaScript render()', () {
    final fixtures = PipelineFixtures.load();
    for (final c in fixtures.cases) {
      test(c.name, () {
        final out = renderCpu(
          fixtures.source,
          Recipe.fromJson(c.recipe),
          maxPixels: c.maxPixels,
          sourceWidth: c.sourceWidth,
          sourceHeight: c.sourceHeight,
          masks: c.masks ? fixtures.masks : null,
        );
        final expected = c.expected();
        expect((out.width, out.height), (expected.width, expected.height));
        final stats = diffStats(out.data, expected.data);
        // ignore: avoid_print
        print(
          '${c.name.padRight(48)} ${out.width}×${out.height}  max ${stats.max.toStringAsExponential(2)}  '
          'mean ${stats.mean.toStringAsExponential(2)}  differing ${stats.differing}/${out.data.length}',
        );
        expect(stats.max, lessThan(_maxTolerance), reason: 'max abs difference');
        expect(stats.mean, lessThan(_meanTolerance), reason: 'mean abs difference');
      });
    }

    test('face boxes move into the output geometry like transformMasks', () {
      for (final c in fixtures.cases.where((c) => c.masks)) {
        final recipe = Recipe.fromJson(c.recipe);
        final moved = transformMasks(
          fixtures.masks,
          recipe.geometry,
          c.sourceWidth ?? fixtures.source.width.toDouble(),
          c.sourceHeight ?? fixtures.source.height.toDouble(),
          c.width,
          c.height,
        )!;
        expect(moved.faces.length, c.faces!.length, reason: c.name);
        for (var i = 0; i < moved.faces.length; i++) {
          final got = moved.faces[i];
          final want = c.faces![i];
          for (final (a, b) in [(got.x, want.x), (got.y, want.y), (got.w, want.w), (got.h, want.h)]) {
            expect(a, closeTo(b, 1e-12), reason: '${c.name} face $i');
          }
          expect(got.score, want.score);
        }
        expect(moved.sky!.length, c.width * c.height);
      }
    });

    test('toRgba8 and toRgb8 dither and round like the JavaScript', () {
      final withBytes = fixtures.cases.where((c) => c.rgba8 != null).toList();
      expect(withBytes, isNotEmpty);
      for (final c in withBytes) {
        final img = c.expected();
        expect(toRgba8(img), readFixtureBytes('pipeline/${c.rgba8}'), reason: c.name);
        expect(toRgb8(img), readFixtureBytes('pipeline/${c.rgb8}'), reason: c.name);
      }
    });
  });

  group('JavaScript number semantics', () {
    test('Uint8ClampedArray rounding', () {
      expect(<double>[0.5, 1.5, 2.5, 2.5000001, -1, 254.5, 255.5, 300, double.nan].map(uint8Clamp), [
        0,
        2,
        2,
        3,
        0,
        254,
        255,
        255,
        0,
      ]);
    });

    test('Math.imul and Math.hypot', () {
      expect(imul(0x7fffffff, 2), -2);
      expect(imul(-5, 1274126177), (-5 * 1274126177).toSigned(32));
      expect(jsHypot(3, 4), 5);
      expect(jsHypot(0, 0), 0);
      expect(jsHypot(double.nan, double.infinity), double.infinity);
    });

    test('previews and saves round to the same 8-bit values', () {
      final rgba = Uint8List.fromList([for (var i = 0; i < 16 * 4; i++) i % 4 == 3 ? 255 : (i * 37) % 256]);
      final img = fromRgba8(rgba, 4, 4);
      expect(img.data[0], 0);
      expect(img.data[1], closeTo(37 / 255, 1e-7));
      // toRGB8 (server saves) rounds: 8-bit values survive a round trip
      final rgb = toRgb8(img);
      for (var p = 0; p < 16; p++) {
        expect(rgb.sublist(p * 3, p * 3 + 3), rgba.sublist(p * 4, p * 4 + 3));
      }
      // toRGBA8 (previews) gives exactly the same pixels
      expect(toRgba8(img), rgba);
      // and so does a value off the 8-bit grid, through the dither
      final grey = RgbImage(4, 4)..data.fillRange(0, 48, 0.3);
      final saved = toRgb8(grey);
      final shown = toRgba8(grey);
      for (var p = 0; p < 16; p++) {
        expect(shown.sublist(p * 4, p * 4 + 3), saved.sublist(p * 3, p * 3 + 3));
      }
    });
  });

  // Ports of the pipeline tests in edit-core.test.js
  group('behaviour', () {
    test('the empty recipe leaves pixels unchanged', () {
      final img = chart();
      final out = renderCpu(img, Recipe.defaults());
      expect(out.width, img.width);
      expect(out.height, img.height);
      expect(diffStats(out.data, img.data).max, lessThan(1e-5));
    });

    test('sliders move the image in the expected direction', () {
      final img = chart();
      final base = meanLuma(img);
      expect(meanLuma(tone(img, {'brightness': 0.6})), greaterThan(base + 0.03));
      expect(meanLuma(tone(img, {'brightness': -0.6})), lessThan(base - 0.03));
      expect(meanLuma(tone(img, {'shadows': 0.8})), greaterThan(base));
      expect(meanLuma(tone(img, {'whitePoint': 0.8})), greaterThan(base));
      expect(meanLuma(tone(img, {'blackPoint': 0.8})), lessThan(base));
      expect(saturationOf(tone(img, {'saturation': 0.7})), greaterThan(saturationOf(img)));
      expect(saturationOf(tone(img, {'saturation': -1})), lessThan(0.01), reason: 'saturation -1 is greyscale');
      final warm = tone(img, {'warmth': 1});
      const j = (40 * 64 + 2) * 3; // a patch pixel
      expect(warm.data[j], greaterThan(img.data[j]), reason: 'warmth shifts red up');
      expect(warm.data[j + 2], lessThan(img.data[j + 2]), reason: 'and blue down');
      final vignetted = tone(img, {'vignette': 1});
      const centre = (24 * 64 + 32) * 3;
      expect(vignetted.data[0], lessThan(img.data[0] + 1e-6));
      expect((vignetted.data[centre] - img.data[centre]).abs(), lessThan(0.02));
    });

    test('contrast spreads the grey ramp without clipping it', () {
      final img = chart();
      final out = tone(img, {'contrast': 1});
      expect(out.data[(5 * 64 + 10) * 3], lessThan(img.data[(5 * 64 + 10) * 3]));
      expect(out.data[(5 * 64 + 54) * 3], greaterThan(img.data[(5 * 64 + 54) * 3]));
      expect(out.data[(5 * 64 + 63) * 3], lessThanOrEqualTo(1));
      expect(out.data[(5 * 64) * 3], greaterThanOrEqualTo(0));
    });

    test('straightening a tilted line makes it level', () {
      // A dark line rising 4° to the right; rotating by -4° must flatten it
      const w = 200;
      const h = 120;
      final img = RgbImage(w, h);
      img.data.fillRange(0, img.data.length, 1);
      final tan = math.tan((4 * math.pi) / 180);
      for (var x = 0; x < w; x++) {
        final y = (h / 2 - (x - w / 2) * tan).round();
        for (var t = -1; t <= 1; t++) {
          img.data.fillRange(((y + t) * w + x) * 3, ((y + t) * w + x) * 3 + 3, 0);
        }
      }
      final out = render(img, {
        'geometry': {'angle': 4},
      });
      int rowOfLine(int x) {
        var best = 0;
        var bestV = 2.0;
        for (var y = 0; y < out.height; y++) {
          final v = out.data[(y * out.width + x) * 3];
          if (v < bestV) {
            bestV = v;
            best = y;
          }
        }
        return best;
      }

      expect((rowOfLine(10) - rowOfLine(out.width - 10)).abs(), lessThanOrEqualTo(1));
    });

    test('no slider combination produces invalid pixels', () {
      final img = chart();
      img.data.fillRange(0, 3, 0);
      img.data.fillRange(3, 6, 1);
      const values = {
        'hdr': 1.0,
        'brightness': 1.0,
        'contrast': 1.0,
        'whitePoint': 1.0,
        'highlights': -1.0,
        'shadows': 1.0,
        'blackPoint': 1.0,
        'saturation': 1.0,
        'warmth': 1.0,
        'tint': -1.0,
        'skinTone': 1.0,
        'blueTone': 1.0,
        'pop': 1.0,
        'vignette': 1.0,
      };
      final keys = values.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        for (var j = i; j < keys.length; j++) {
          for (final sign in const [1, -1]) {
            final adjust = {keys[i]: values[keys[i]]! * sign, keys[j]: values[keys[j]]!};
            expect(hasNaN(tone(img, adjust)), isFalse, reason: '$adjust');
          }
        }
      }
    });

    test('advanced adjustments: identity, exposure, curves, HSL and grading', () {
      final img = chart();
      final same = render(img, {'advanced': Advanced.defaults().toJson()});
      expect(diffStats(same.data, img.data).max, lessThan(1e-5), reason: 'defaults change nothing');
      final lut = curveLut([
        [0.25, 0.15],
        [0.75, 0.85],
      ]);
      expect(lut[256], lessThan(0.2));
      expect(lut[768], greaterThan(0.8));
      expect(lut[0], 0);
      expect(lut[1024], 1);
      for (var k = 1; k <= 1024; k++) {
        expect(lut[k], greaterThanOrEqualTo(lut[k - 1] - 1e-6), reason: 'monotone');
      }
      final brighter = render(img, {
        'advanced': {'exposure': 1},
      });
      expect(meanLuma(brighter), greaterThan(meanLuma(img) + 0.05));
      const j = (40 * 64 + 20) * 3; // blue patch
      double chroma(Float32List d, int k) =>
          math.max(d[k], math.max(d[k + 1], d[k + 2])) - math.min(d[k], math.min(d[k + 1], d[k + 2]));
      final blueSat = render(img, {
        'advanced': {
          'hsl': {
            'blue': {'s': -1},
          },
        },
      });
      expect(chroma(blueSat.data, j), lessThan(chroma(img.data, j) * 0.5), reason: 'blue band desaturated');
      final graded = render(img, {
        'advanced': {
          'grading': {
            'shadows': {'hue': 180, 'sat': 1},
          },
        },
      });
      const dark = (5 * 64 + 4) * 3;
      expect(graded.data[dark + 2], greaterThan(img.data[dark + 2]), reason: 'teal shadows');
      expect(graded.data[dark], lessThan(img.data[dark] + 1e-6));
      for (final adv in <Map<String, Object?>>[
        {'dehaze': 1},
        {'dehaze': -1},
        {'clarity': 1},
        {
          'sharpen': {'amount': 1},
        },
        {'noise': 1},
        {'grain': 1},
        {
          'vignette': {'amount': -1},
        },
        {
          'levels': {'inBlack': 0.5, 'inWhite': 0.5},
        },
      ]) {
        expect(hasNaN(render(img, {'advanced': adv})), isFalse, reason: '$adv');
      }
    });

    test('tools need masks and leave the image alone without them', () {
      final img = chart();
      final recipe = {
        'tools': {
          'sky': {'strength': 1},
          'colorFocus': {'strength': 1},
          'blur': {'strength': 1},
        },
      };
      expect(diffStats(render(img, recipe).data, img.data).max, lessThan(1e-5));
      final sky = Float32List(img.width * img.height)..fillRange(0, img.width * img.height ~/ 2, 1);
      final masks = EditorMasks(width: img.width, height: img.height, sky: sky);
      final out = renderCpu(img, Recipe.fromJson(recipe), masks: masks);
      expect(out.data[(2 * 64 + 30) * 3 + 2], isNot(img.data[(2 * 64 + 30) * 3 + 2]), reason: 'sky changed');
    });
  });
}
