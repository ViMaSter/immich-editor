// Mask-based tools (port of public/edit/tools.js): Sky, Color focus, Portrait light and
// Blur. Masks arrive already in the image's geometry (see transformMasks): sky, subject
// and depth channels of the image's size, and faces as boxes normalised to the image.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_image.dart';
import 'package:immich_mobile/editor_photos/render/js_math.dart';

/// A sky look: gradient top → horizon, luminance gain, saturation, contrast and an
/// optional gain on the rest of the scene (`SKY_LOOKS` in tools.js)
class SkyLook {
  final List<double> top;
  final List<double> bottom;
  final double tint;
  final double lum;
  final double sat;
  final double contrast;
  final List<double>? scene;

  const SkyLook({
    required this.top,
    required this.bottom,
    required this.tint,
    required this.lum,
    required this.sat,
    required this.contrast,
    this.scene,
  });
}

/// `SKY_LOOKS`, keyed by the recipe's `tools.sky.palette`
const skyLooks = <String, SkyLook>{
  'vivid': SkyLook(
    top: [0.12, 0.32, 0.85],
    bottom: [0.45, 0.7, 0.98],
    tint: 0.18,
    lum: 0.97,
    sat: 1.45,
    contrast: 0.15,
  ),
  'luminous': SkyLook(top: [0.35, 0.65, 0.98], bottom: [0.85, 0.95, 1], tint: 0.25, lum: 1.12, sat: 1.1, contrast: 0),
  'radiant': SkyLook(
    top: [0.3, 0.45, 0.85],
    bottom: [1, 0.78, 0.45],
    tint: 0.35,
    lum: 1.05,
    sat: 1.25,
    contrast: 0.08,
    scene: [1.03, 1.0, 0.96],
  ),
  'ember': SkyLook(
    top: [0.45, 0.25, 0.45],
    bottom: [1, 0.48, 0.18],
    tint: 0.5,
    lum: 0.98,
    sat: 1.35,
    contrast: 0.1,
    scene: [1.06, 0.99, 0.93],
  ),
  'airy': SkyLook(
    top: [0.62, 0.78, 0.95],
    bottom: [0.9, 0.95, 1],
    tint: 0.35,
    lum: 1.15,
    sat: 0.8,
    contrast: -0.1,
    scene: [0.98, 1, 1.03],
  ),
  'afterglow': SkyLook(
    top: [0.38, 0.32, 0.7],
    bottom: [1, 0.62, 0.68],
    tint: 0.45,
    lum: 1.0,
    sat: 1.2,
    contrast: 0.05,
    scene: [1.03, 0.99, 1.0],
  ),
  'stormy': SkyLook(
    top: [0.22, 0.25, 0.32],
    bottom: [0.5, 0.53, 0.58],
    tint: 0.35,
    lum: 0.8,
    sat: 0.55,
    contrast: 0.3,
    scene: [0.97, 0.98, 1.0],
  ),
};

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// `applyTools`: applies the recipe's tools in place, using masks in the image's geometry
RgbImage applyTools(RgbImage img, Recipe recipe, EditorMasks? masks) {
  final t = recipe.tools;
  if (masks == null) {
    return img;
  }
  final width = img.width;
  final height = img.height;
  final data = img.data;
  final n = width * height;

  final sky = masks.sky;
  if (t.sky.strength > 0 && sky != null) {
    final look = skyLooks[t.sky.palette] ?? skyLooks['vivid']!;
    final scene = look.scene == null ? null : Float64List.fromList(look.scene!);
    final top = Float64List.fromList(look.top);
    final bottom = Float64List.fromList(look.bottom);
    final s0 = t.sky.strength;
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final y = (p ~/ width) / height;
      final m = sky[p] * s0;
      final sceneW = (1 - sky[p]) * s0 * 0.5;
      if (scene != null && sceneW > 0) {
        for (var c = 0; c < 3; c++) {
          data[j + c] *= 1 + (scene[c] - 1) * sceneW;
        }
      }
      if (m <= 0.002) {
        continue;
      }
      final l = 0.2126 * data[j] + 0.7152 * data[j + 1] + 0.0722 * data[j + 2];
      final gy = math.min(1.0, y * 1.6);
      for (var c = 0; c < 3; c++) {
        final target = top[c] + (bottom[c] - top[c]) * gy;
        var v = data[j + c];
        v = l + (v - l) * look.sat; // saturation
        v = 0.5 + (v - 0.5) * (1 + look.contrast); // contrast
        v *= look.lum;
        v = v * (1 - look.tint) + target * (l * 1.2 + 0.2) * look.tint; // colour grade
        data[j + c] = data[j + c] + (v - data[j + c]) * m;
      }
    }
  }

  final subject = masks.subject;
  final depth = masks.depth;
  if (t.colorFocus > 0 && (subject != null || depth != null)) {
    final s0 = t.colorFocus;
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final keep = subject != null ? subject[p] : _clamp01((depth![p] - 0.55) * 4);
      final w = (1 - keep) * s0;
      if (w <= 0) {
        continue;
      }
      final l = 0.2126 * data[j] + 0.7152 * data[j + 1] + 0.0722 * data[j + 2];
      for (var c = 0; c < 3; c++) {
        data[j + c] += (l - data[j + c]) * w;
      }
    }
  }

  if (t.portraitLight.strength > 0 && masks.faces.isNotEmpty) {
    final s0 = t.portraitLight.strength;
    final lx = t.portraitLight.x - 0.5;
    final ly = t.portraitLight.y - 0.5;
    final gain = Float32List(n);
    for (final f in masks.faces) {
      final size = math.max(f.w * width, f.h * height);
      final cx = (f.x + f.w / 2) * width + lx * size * 0.9;
      final cy = (f.y + f.h / 2) * height + ly * size * 0.9;
      final radius = size * 1.4;
      if (!cx.isFinite || !cy.isFinite || !radius.isFinite) {
        continue; // the JavaScript loops run zero times on NaN bounds
      }
      final x0 = math.max(0.0, (cx - radius * 2).floorToDouble());
      final x1 = math.min(width.toDouble(), (cx + radius * 2).ceilToDouble());
      final y0 = math.max(0.0, (cy - radius * 2).floorToDouble());
      final y1 = math.min(height.toDouble(), (cy + radius * 2).ceilToDouble());
      final r2 = radius * radius;
      for (var y = y0.toInt(); y < y1; y++) {
        final ddy = (y - cy) * (y - cy);
        for (var x = x0.toInt(); x < x1; x++) {
          final d2 = ((x - cx) * (x - cx) + ddy) / r2;
          final i = y * width + x;
          gain[i] = math.max(gain[i], math.exp(-d2));
        }
      }
    }
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final g = gain[p];
      if (g == 0 || g.isNaN) {
        continue;
      }
      final subjectWeight = subject != null ? 0.35 + 0.65 * subject[p] : 1.0;
      final k = 1 + s0 * 0.55 * g * subjectWeight;
      data[j] = math.min(1.0, data[j] * k * 1.01);
      data[j + 1] = math.min(1.0, data[j + 1] * k);
      data[j + 2] = math.min(1.0, data[j + 2] * k * 0.985);
    }
  }

  if (t.blur.strength > 0 && depth != null) {
    final s0 = t.blur.strength;
    final fx = math.min(width - 1, math.max(0, jsRound(t.blur.focusX * width).toInt()));
    final fy = math.min(height - 1, math.max(0, jsRound(t.blur.focusY * height).toInt()));
    final focusDepth = depth[fy * width + fx];
    final diag = jsHypot(width.toDouble(), height.toDouble());
    final radii = [
      for (final r in const [0.004, 0.011, 0.024]) math.max(1.0, r * diag * s0),
    ];
    // One pass per channel with typed locals (the result is the same as the JavaScript's
    // per-pixel loop: every value is written once, from copies taken before the loop)
    for (var c = 0; c < 3; c++) {
      final original = channelOf(data, n, c);
      final level1 = blurChannel(original, width, height, radii[0]);
      final level2 = blurChannel(original, width, height, radii[1]);
      final level3 = blurChannel(original, width, height, radii[2]);
      for (var p = 0, j = c; p < n; p++, j += 3) {
        var amount = math.min(1.0, (depth[p] - focusDepth).abs() * 3);
        if (subject != null) {
          amount *= 1 - subject[p] * 0.85;
        }
        final level = amount * 3; // 0..3 across original + three blur levels
        if (!(level > 0.02)) {
          continue;
        }
        final i = math.min(2, level.floor());
        final frac = math.min(1.0, level - i);
        final a = i == 0 ? original[p] : (i == 1 ? level1[p] : level2[p]);
        final b = i == 0 ? level1[p] : (i == 1 ? level2[p] : level3[p]);
        data[j] = a + (b - a) * frac;
      }
    }
  }
  return img;
}
