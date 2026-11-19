// Per-photo automatic edits ("Enhance", "Dynamic", "Warm", "Cool"), computed from the
// photo's own statistics (port of public/edit/auto.js).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/js_compat.dart';

class PhotoStats {
  final double p01;
  final double p05;
  final double p25;
  final double p50;
  final double p75;
  final double p95;
  final double p99;
  final double clippedHigh;
  final double clippedLow;
  final double saturation;
  final double castRG;
  final double castYB;

  const PhotoStats({
    required this.p01,
    required this.p05,
    required this.p25,
    required this.p50,
    required this.p75,
    required this.p95,
    required this.p99,
    required this.clippedHigh,
    required this.clippedLow,
    required this.saturation,
    required this.castRG,
    required this.castYB,
  });
}

/// Statistics of an image given as interleaved RGB floats in 0..1 ([stride] 3) or RGBA bytes ([stride] 4)
PhotoStats measureRgb(Float32List data, {int stride = 3}) => _measure(data.length ~/ stride, (i) => data[i], stride);

PhotoStats measureRgba8(Uint8List rgba) => _measure(rgba.length ~/ 4, (i) => rgba[i] / 255, 4);

PhotoStats _measure(int n, double Function(int) at, int stride) {
  final hist = Uint32List(256);
  var sat = 0.0;
  var rg = 0.0;
  var yb = 0.0;
  for (var p = 0, j = 0; p < n; p++, j += stride) {
    final r = at(j);
    final g = at(j + 1);
    final b = at(j + 2);
    // Float32 luminance like the pipeline's `luminance()`
    final l = _f32(0.2126 * r + 0.7152 * g + 0.0722 * b);
    hist[math.min(255, math.max(0, jsRound(l * 255).toInt()))]++;
    sat += math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    rg += r - g;
    yb += 0.5 * (r + g) - b;
  }
  double percentile(double q) {
    var acc = 0;
    final target = q * n;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= target) {
        return i / 255;
      }
    }
    return 1;
  }

  var high = 0;
  for (var i = 250; i < 256; i++) {
    high += hist[i];
  }
  var low = 0;
  for (var i = 0; i < 4; i++) {
    low += hist[i];
  }
  return PhotoStats(
    p01: percentile(0.01),
    p05: percentile(0.05),
    p25: percentile(0.25),
    p50: percentile(0.5),
    p75: percentile(0.75),
    p95: percentile(0.95),
    p99: percentile(0.99),
    clippedHigh: high / n,
    clippedLow: low / n,
    saturation: sat / n,
    castRG: rg / n,
    castYB: yb / n,
  );
}

final _f32Buf = Float32List(1);
double _f32(double v) {
  _f32Buf[0] = v;
  return _f32Buf[0];
}

double _r2(double v) => roundTo(v, 2);

Map<String, double> enhanceAdjust(PhotoStats stats) {
  final a = <String, double>{};
  if (stats.p01 > 0.05) {
    a['blackPoint'] = _r2(clampD((stats.p01 - 0.02) * 4, 0, 0.5));
  }
  if (stats.p99 < 0.93) {
    a['whitePoint'] = _r2(clampD((0.97 - stats.p99) * 2.5, 0, 0.5));
  }
  if (stats.p25 < 0.22) {
    a['shadows'] = _r2(clampD((0.27 - stats.p25) * 1.6, 0, 0.45));
  }
  if (stats.clippedHigh > 0.01) {
    a['highlights'] = _r2(-clampD(stats.clippedHigh * 8, 0.05, 0.4));
  }
  final mid = 0.45 - stats.p50;
  if (mid.abs() > 0.05) {
    a['brightness'] = _r2(clampD(mid * 1.1, -0.3, 0.35));
  }
  a['pop'] = 0.15;
  if (stats.saturation < 0.18) {
    a['saturation'] = _r2(clampD((0.2 - stats.saturation) * 1.2, 0, 0.15));
  }
  return a;
}

class AutoRecipe {
  final String id;
  final String name;
  final Map<String, double> adjust;

  const AutoRecipe(this.id, this.name, this.adjust);
}

List<AutoRecipe> autoRecipes(PhotoStats stats) {
  final enhance = enhanceAdjust(stats);
  final cast = clampD(-stats.castYB * 1.5, -0.2, 0.2);
  return [
    AutoRecipe('enhance', 'Enhance', enhance),
    AutoRecipe('dynamic', 'Dynamic', {
      ...enhance,
      'contrast': 0.25,
      'saturation': _r2((enhance['saturation'] ?? 0) + 0.25),
      'pop': 0.3,
    }),
    AutoRecipe('warm', 'Warm', {...enhance, 'warmth': _r2(0.3 + math.max(0, cast))}),
    AutoRecipe('cool', 'Cool', {...enhance, 'warmth': _r2(-0.3 + math.min(0, cast))}),
  ];
}
