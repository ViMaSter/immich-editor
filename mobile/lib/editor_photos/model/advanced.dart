// Lightroom-style "Advanced" adjustments (port of public/edit/advanced.js: model part).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/js_compat.dart';

const hslBands = <(String, double)>[
  ('red', 0),
  ('orange', 30),
  ('yellow', 60),
  ('green', 120),
  ('aqua', 180),
  ('blue', 220),
  ('purple', 270),
  ('magenta', 315),
];
const curveChannels = ['rgb', 'r', 'g', 'b'];
const gradingRegions = ['shadows', 'midtones', 'highlights'];
const _defaultGradingHue = {'shadows': 200.0, 'midtones': 30.0, 'highlights': 40.0};

double _clampA(Object? v, double lo, double hi) => math.min(hi, math.max(lo, numOr(v, 0)));
double _r3(double v) => roundTo(v, 3);

/// `normalizeAdvanced` from advanced.js, producing the same JSON (key order included)
Map<String, Object?> normalizeAdvancedJson(Object? input) {
  final x = input is Map ? input : const <String, Object?>{};
  List<List<num>> points(Object? list) {
    final source = list is List ? list.take(16).toList() : const <Object?>[];
    final mapped = source.map((p) => [_r3(_clampA(item(p, 0), 0, 1)), _r3(_clampA(item(p, 1), 0, 1))]).toList();
    // Array.prototype.sort is stable, so is List.sort with this merge sort
    _stableSort(mapped, (p, q) => (p[0] - q[0]).sign.toInt());
    final out = <List<num>>[];
    for (var i = 0; i < mapped.length; i++) {
      if (i == 0 || mapped[i][0] - mapped[i - 1][0] > 0.005) {
        out.add([jsonNum(mapped[i][0]), jsonNum(mapped[i][1])]);
      }
    }
    return out;
  }

  final lv = coalesce(prop(x, 'levels'), const <String, Object?>{});
  final grading = prop(x, 'grading');
  final sharpen = prop(x, 'sharpen');
  final vignette = prop(x, 'vignette');
  final curves = prop(x, 'curves');
  final hsl = prop(x, 'hsl');
  double r3c(Object? v, Object? fallback, double lo, double hi) => _r3(_clampA(coalesce(v, fallback), lo, hi));
  return {
    'exposure': jsonNum(r3c(prop(x, 'exposure'), 0, -3, 3)),
    'clarity': jsonNum(r3c(prop(x, 'clarity'), 0, -1, 1)),
    'dehaze': jsonNum(r3c(prop(x, 'dehaze'), 0, -1, 1)),
    'levels': {
      'inBlack': jsonNum(r3c(prop(lv, 'inBlack'), 0, 0, 0.5)),
      'inWhite': jsonNum(r3c(prop(lv, 'inWhite'), 1, 0.5, 1)),
      'gamma': jsonNum(r3c(prop(lv, 'gamma'), 1, 0.2, 5)),
      'outBlack': jsonNum(r3c(prop(lv, 'outBlack'), 0, 0, 0.5)),
      'outWhite': jsonNum(r3c(prop(lv, 'outWhite'), 1, 0.5, 1)),
    },
    'curves': {for (final c in curveChannels) c: points(prop(curves, c))},
    'hsl': {
      for (final (name, _) in hslBands)
        name: {
          'h': jsonNum(r3c(prop(prop(hsl, name), 'h'), 0, -1, 1)),
          's': jsonNum(r3c(prop(prop(hsl, name), 's'), 0, -1, 1)),
          'l': jsonNum(r3c(prop(prop(hsl, name), 'l'), 0, -1, 1)),
        },
    },
    'grading': {
      for (final r in gradingRegions)
        r: {
          'hue': jsonNum(jsRound(_clampA(coalesce(prop(prop(grading, r), 'hue'), _defaultGradingHue[r]), 0, 360))),
          'sat': jsonNum(r3c(prop(prop(grading, r), 'sat'), 0, 0, 1)),
        },
      'balance': jsonNum(r3c(prop(grading, 'balance'), 0, -1, 1)),
      'blending': jsonNum(r3c(prop(grading, 'blending'), 0.5, 0, 1)),
    },
    'sharpen': {
      'amount': jsonNum(r3c(prop(sharpen, 'amount'), 0, 0, 1)),
      'radius': jsonNum(r3c(prop(sharpen, 'radius'), 1, 0.5, 3)),
    },
    'noise': jsonNum(r3c(prop(x, 'noise'), 0, 0, 1)),
    'grain': jsonNum(r3c(prop(x, 'grain'), 0, 0, 1)),
    'vignette': {
      'amount': jsonNum(r3c(prop(vignette, 'amount'), 0, -1, 1)),
      'midpoint': jsonNum(r3c(prop(vignette, 'midpoint'), 0.5, 0, 1)),
      'roundness': jsonNum(r3c(prop(vignette, 'roundness'), 0, -1, 1)),
      'feather': jsonNum(r3c(prop(vignette, 'feather'), 0.5, 0, 1)),
    },
  };
}

void _stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  if (list.length < 2) {
    return;
  }
  final indexed = List.generate(list.length, (i) => (i, list[i]));
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1 - b.$1;
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

class Levels {
  double inBlack;
  double inWhite;
  double gamma;
  double outBlack;
  double outWhite;

  Levels({this.inBlack = 0, this.inWhite = 1, this.gamma = 1, this.outBlack = 0, this.outWhite = 1});

  bool get isIdentity => inBlack == 0 && inWhite == 1 && gamma == 1 && outBlack == 0 && outWhite == 1;

  Map<String, Object?> toRawJson() => {
    'inBlack': inBlack,
    'inWhite': inWhite,
    'gamma': gamma,
    'outBlack': outBlack,
    'outWhite': outWhite,
  };
}

class HslBand {
  double h;
  double s;
  double l;

  HslBand({this.h = 0, this.s = 0, this.l = 0});

  bool get isIdentity => h == 0 && s == 0 && l == 0;
}

class GradingRegion {
  double hue;
  double sat;

  GradingRegion({required this.hue, this.sat = 0});
}

class Grading {
  final Map<String, GradingRegion> regions;
  double balance;
  double blending;

  Grading({required this.regions, this.balance = 0, this.blending = 0.5});
}

class Sharpen {
  double amount;
  double radius;

  Sharpen({this.amount = 0, this.radius = 1});
}

class ShapedVignette {
  double amount;
  double midpoint;
  double roundness;
  double feather;

  ShapedVignette({this.amount = 0, this.midpoint = 0.5, this.roundness = 0, this.feather = 0.5});
}

/// Typed view of the normalised `advanced` object; mutable for the editor UI
class Advanced {
  double exposure;
  double clarity;
  double dehaze;
  final Levels levels;
  final Map<String, List<List<double>>> curves;
  final Map<String, HslBand> hsl;
  final Grading grading;
  final Sharpen sharpen;
  double noise;
  double grain;
  final ShapedVignette vignette;

  Advanced._({
    required this.exposure,
    required this.clarity,
    required this.dehaze,
    required this.levels,
    required this.curves,
    required this.hsl,
    required this.grading,
    required this.sharpen,
    required this.noise,
    required this.grain,
    required this.vignette,
  });

  factory Advanced.defaults() => Advanced.fromJson(null);

  factory Advanced.fromJson(Object? json) {
    final n = normalizeAdvancedJson(json);
    final lv = n['levels']! as Map<String, Object?>;
    final curves = n['curves']! as Map<String, Object?>;
    final hsl = n['hsl']! as Map<String, Object?>;
    final grading = n['grading']! as Map<String, Object?>;
    final sharpen = n['sharpen']! as Map<String, Object?>;
    final vignette = n['vignette']! as Map<String, Object?>;
    return Advanced._(
      exposure: toD(n['exposure']),
      clarity: toD(n['clarity']),
      dehaze: toD(n['dehaze']),
      levels: Levels(
        inBlack: toD(lv['inBlack']),
        inWhite: toD(lv['inWhite']),
        gamma: toD(lv['gamma']),
        outBlack: toD(lv['outBlack']),
        outWhite: toD(lv['outWhite']),
      ),
      curves: {
        for (final c in curveChannels)
          c: [
            for (final p in curves[c]! as List) [toD((p as List)[0]), toD(p[1])],
          ],
      },
      hsl: {
        for (final (name, _) in hslBands)
          name: HslBand(
            h: toD((hsl[name]! as Map)['h']),
            s: toD((hsl[name]! as Map)['s']),
            l: toD((hsl[name]! as Map)['l']),
          ),
      },
      grading: Grading(
        regions: {
          for (final r in gradingRegions)
            r: GradingRegion(hue: toD((grading[r]! as Map)['hue']), sat: toD((grading[r]! as Map)['sat'])),
        },
        balance: toD(grading['balance']),
        blending: toD(grading['blending']),
      ),
      sharpen: Sharpen(amount: toD(sharpen['amount']), radius: toD(sharpen['radius'])),
      noise: toD(n['noise']),
      grain: toD(n['grain']),
      vignette: ShapedVignette(
        amount: toD(vignette['amount']),
        midpoint: toD(vignette['midpoint']),
        roundness: toD(vignette['roundness']),
        feather: toD(vignette['feather']),
      ),
    );
  }

  Map<String, Object?> toRawJson() => {
    'exposure': exposure,
    'clarity': clarity,
    'dehaze': dehaze,
    'levels': levels.toRawJson(),
    'curves': {
      for (final c in curveChannels) c: [for (final p in curves[c]!) List<double>.of(p)],
    },
    'hsl': {
      for (final e in hsl.entries) e.key: {'h': e.value.h, 's': e.value.s, 'l': e.value.l},
    },
    'grading': {
      for (final e in grading.regions.entries) e.key: {'hue': e.value.hue, 'sat': e.value.sat},
      'balance': grading.balance,
      'blending': grading.blending,
    },
    'sharpen': {'amount': sharpen.amount, 'radius': sharpen.radius},
    'noise': noise,
    'grain': grain,
    'vignette': {
      'amount': vignette.amount,
      'midpoint': vignette.midpoint,
      'roundness': vignette.roundness,
      'feather': vignette.feather,
    },
  };

  /// Normalised JSON, identical to `normalizeAdvanced` in the web editor
  Map<String, Object?> toJson() => normalizeAdvancedJson(toRawJson());

  bool get levelsActive => !levels.isIdentity;
  bool get curvesActive => curveChannels.any((c) => curves[c]!.isNotEmpty);
  bool get hslActive => hsl.values.any((b) => !b.isIdentity);
  bool get gradingActive => grading.regions.values.any((r) => r.sat != 0);

  bool get isIdentity {
    final n = Advanced.fromJson(toRawJson());
    return n.exposure == 0 &&
        n.clarity == 0 &&
        n.dehaze == 0 &&
        n.levels.isIdentity &&
        !n.curvesActive &&
        !n.hslActive &&
        !n.gradingActive &&
        n.sharpen.amount == 0 &&
        n.noise == 0 &&
        n.grain == 0 &&
        n.vignette.amount == 0;
  }
}

/// Monotone cubic (Fritsch–Carlson) through the points plus the corners, as a 1025-entry LUT
Float32List curveLut(List<List<double>> points) {
  final pts = <List<double>>[
    [0, 0],
    ...points.where((p) => p[0] > 0.005 && p[0] < 0.995),
    [1, 1],
  ];
  for (final p in points) {
    if (p[0] <= 0.005) {
      pts[0] = [0, p[1]];
    }
    if (p[0] >= 0.995) {
      pts[pts.length - 1] = [1, p[1]];
    }
  }
  final n = pts.length;
  final dx = <double>[];
  final dy = <double>[];
  for (var i = 0; i < n - 1; i++) {
    dx.add(pts[i + 1][0] - pts[i][0]);
    dy.add((pts[i + 1][1] - pts[i][1]) / dx[i]);
  }
  final t = List<double>.filled(n, 0);
  t[0] = dy[0];
  t[n - 1] = dy[n - 2];
  for (var i = 1; i < n - 1; i++) {
    t[i] = dy[i - 1] * dy[i] <= 0 ? 0 : (dy[i - 1] + dy[i]) / 2;
  }
  for (var i = 0; i < n - 1; i++) {
    if (dy[i] == 0) {
      t[i] = 0;
      t[i + 1] = 0;
      continue;
    }
    final a = t[i] / dy[i];
    final b = t[i + 1] / dy[i];
    final s = a * a + b * b;
    if (s > 9) {
      final k = 3 / math.sqrt(s);
      t[i] = k * a * dy[i];
      t[i + 1] = k * b * dy[i];
    }
  }
  final lut = Float32List(1025);
  var seg = 0;
  for (var k = 0; k <= 1024; k++) {
    final x = k / 1024;
    while (seg < n - 2 && x > pts[seg + 1][0]) {
      seg++;
    }
    final h = dx[seg];
    final u = (x - pts[seg][0]) / h;
    final u2 = u * u;
    final u3 = u2 * u;
    final h00 = 2 * u3 - 3 * u2 + 1;
    final h10 = u3 - 2 * u2 + u;
    final h01 = -2 * u3 + 3 * u2;
    final h11 = u3 - u2;
    final v = h00 * pts[seg][1] + h10 * h * t[seg] + h01 * pts[seg + 1][1] + h11 * h * t[seg + 1];
    lut[k] = math.min(1, math.max(0, v));
  }
  return lut;
}
