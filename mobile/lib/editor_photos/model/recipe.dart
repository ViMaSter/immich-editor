// The edit recipe (port of public/edit/recipe.js). One JSON shape shared with the web
// editor, the editor.photos server and the metadata stored on Immich assets.
// `toJson()` produces exactly what `normalizeRecipe` produces in JavaScript.
import 'dart:convert';
import 'dart:math' as math;

import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/filters.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';

const recipeVersion = 1;

/// Same order and ranges as Google Photos' Adjust panel
const adjustKeys = [
  'hdr',
  'brightness',
  'contrast',
  'whitePoint',
  'highlights',
  'shadows',
  'blackPoint',
  'saturation',
  'warmth',
  'tint',
  'skinTone',
  'blueTone',
  'pop',
  'vignette',
];
const unipolarKeys = {'hdr', 'pop', 'vignette'};
const adjustLabels = {
  'hdr': 'HDR effect',
  'brightness': 'Brightness',
  'contrast': 'Contrast',
  'whitePoint': 'White Point',
  'highlights': 'Highlights',
  'shadows': 'Shadow',
  'blackPoint': 'Black Point',
  'saturation': 'Saturation',
  'warmth': 'Warmth',
  'tint': 'Tint',
  'skinTone': 'Skin Tone',
  'blueTone': 'Blue Tone',
  'pop': 'Pop',
  'vignette': 'Vignette',
};

/// (id, label, ratio)
const aspects = <(String, String, double?)>[
  ('free', 'Free', null),
  ('original', 'Original', null),
  ('16:9', '16:9', 16 / 9),
  ('9:16', '9:16', 9 / 16),
  ('5:4', '5:4', 5 / 4),
  ('4:5', '4:5', 4 / 5),
  ('4:3', '4:3', 4 / 3),
  ('3:4', '3:4', 3 / 4),
  ('3:2', '3:2', 3 / 2),
  ('2:3', '2:3', 2 / 3),
  ('square', 'Square', 1),
];
const skyPalettes = ['vivid', 'luminous', 'radiant', 'ember', 'airy', 'afterglow', 'stormy'];
const maxAngle = 45.0;

Map<String, Object?>? _normalizeCrop(Object? crop) {
  if (crop == null || identical(crop, undefined) || !isObject(crop)) {
    return null;
  }
  final w = clampD(numOr(prop(crop, 'w'), 1), 0.01, 1);
  final h = clampD(numOr(prop(crop, 'h'), 1), 0.01, 1);
  return {
    'cx': jsonNum(roundTo(clampD(numOr(prop(crop, 'cx'), 0.5), 0, 1), 5)),
    'cy': jsonNum(roundTo(clampD(numOr(prop(crop, 'cy'), 0.5), 0, 1), 5)),
    'w': jsonNum(roundTo(w, 5)),
    'h': jsonNum(roundTo(h, 5)),
  };
}

bool _truthy(Object? v) =>
    v != null && !identical(v, undefined) && v != false && v != 0 && v != '' && !(v is double && v.isNaN);

/// `normalizeRecipe` from recipe.js: validates and clamps anything from the editor,
/// metadata or a suggestion. Key order and number formatting match JSON.stringify.
Map<String, Object?> normalizeRecipeJson(Object? input) {
  final r = input is Map ? input : const <String, Object?>{};
  final gRaw = prop(r, 'geometry');
  final g = _truthy(gRaw) ? gRaw : const <String, Object?>{};
  final source = prop(r, 'source');
  final aspectIds = aspects.map((a) => a.$1).toSet();
  final filter = prop(r, 'filter');
  final filterId = prop(filter, 'id');
  final aspect = prop(g, 'aspect');
  final out = <String, Object?>{
    'v': recipeVersion,
    'source': prop(source, 'kind') == 'raw' && prop(source, 'rawAssetId') is String
        ? {
            'kind': 'raw',
            'rawAssetId': prop(source, 'rawAssetId'),
            'baselineId': prop(source, 'baselineId') is String ? prop(source, 'baselineId') : null,
          }
        : {'kind': 'jpeg'},
    'geometry': {
      'rotate90': jsonNum(((jsRound(numOr(prop(g, 'rotate90'))) % 4) + 4) % 4),
      'angle': jsonNum(roundTo(clampD(numOr(prop(g, 'angle')), -maxAngle, maxAngle), 2)),
      'aspect': aspect is String && aspectIds.contains(aspect) ? aspect : 'free',
      'crop': _normalizeCrop(prop(g, 'crop')),
    },
    'adjust': <String, Object?>{},
    'filter': {
      'id': filterId is String && filterId.length <= 40 ? filterId : 'none',
      'strength': jsonNum(roundTo(clampD(numOr(prop(filter, 'strength'), 1), 0, 1), 2)),
    },
    'tools': <String, Object?>{},
    'advanced': normalizeAdvancedJson(prop(r, 'advanced')),
  };
  final adjust = out['adjust']! as Map<String, Object?>;
  final adjustIn = prop(r, 'adjust');
  for (final key in adjustKeys) {
    final min = unipolarKeys.contains(key) ? 0.0 : -1.0;
    adjust[key] = jsonNum(roundTo(clampD(numOr(prop(adjustIn, key)), min, 1), 2));
  }
  final toolsRaw = prop(r, 'tools');
  final t = _truthy(toolsRaw) ? toolsRaw : const <String, Object?>{};
  final sky = prop(t, 'sky');
  final palette = prop(sky, 'palette');
  final pl = prop(t, 'portraitLight');
  final blur = prop(t, 'blur');
  final focus = prop(blur, 'focus');
  final tools = out['tools']! as Map<String, Object?>;
  tools['sky'] = {
    'palette': palette is String && skyPalettes.contains(palette) ? palette : 'vivid',
    'strength': jsonNum(roundTo(clampD(numOr(prop(sky, 'strength')), 0, 1), 2)),
  };
  tools['colorFocus'] = {
    'strength': jsonNum(roundTo(clampD(numOr(prop(prop(t, 'colorFocus'), 'strength')), 0, 1), 2)),
  };
  tools['portraitLight'] = {
    'x': jsonNum(roundTo(clampD(numOr(prop(pl, 'x'), 0.3), 0, 1), 3)),
    'y': jsonNum(roundTo(clampD(numOr(prop(pl, 'y'), 0.25), 0, 1), 3)),
    'strength': jsonNum(roundTo(clampD(numOr(prop(pl, 'strength')), 0, 1), 2)),
  };
  tools['blur'] = {
    'strength': jsonNum(roundTo(clampD(numOr(prop(blur, 'strength')), 0, 1), 2)),
    'focus': {
      'x': jsonNum(roundTo(clampD(numOr(prop(focus, 'x'), 0.5), 0, 1), 3)),
      'y': jsonNum(roundTo(clampD(numOr(prop(focus, 'y'), 0.5), 0, 1), 3)),
    },
  };
  return out;
}

class CropRect {
  final double cx;
  final double cy;
  final double w;
  final double h;

  const CropRect({required this.cx, required this.cy, required this.w, required this.h});

  Map<String, Object?> toRawJson() => {'cx': cx, 'cy': cy, 'w': w, 'h': h};

  @override
  String toString() => 'CropRect($cx, $cy, $w, $h)';
}

class Geometry {
  int rotate90;
  double angle;
  String aspect;
  CropRect? crop;

  Geometry({this.rotate90 = 0, this.angle = 0, this.aspect = 'free', this.crop});

  Geometry copy() => Geometry(rotate90: rotate90, angle: angle, aspect: aspect, crop: crop);

  Map<String, Object?> toRawJson() => {
    'rotate90': rotate90,
    'angle': angle,
    'aspect': aspect,
    'crop': crop?.toRawJson(),
  };
}

class SkyTool {
  String palette;
  double strength;

  SkyTool({this.palette = 'vivid', this.strength = 0});
}

class PortraitLightTool {
  double x;
  double y;
  double strength;

  PortraitLightTool({this.x = 0.3, this.y = 0.25, this.strength = 0});
}

class BlurTool {
  double strength;
  double focusX;
  double focusY;

  BlurTool({this.strength = 0, this.focusX = 0.5, this.focusY = 0.5});
}

class Tools {
  final SkyTool sky;
  double colorFocus;
  final PortraitLightTool portraitLight;
  final BlurTool blur;

  Tools({required this.sky, this.colorFocus = 0, required this.portraitLight, required this.blur});

  bool get any => sky.strength > 0 || colorFocus > 0 || portraitLight.strength > 0 || blur.strength > 0;

  Map<String, Object?> toRawJson() => {
    'sky': {'palette': sky.palette, 'strength': sky.strength},
    'colorFocus': {'strength': colorFocus},
    'portraitLight': {'x': portraitLight.x, 'y': portraitLight.y, 'strength': portraitLight.strength},
    'blur': {
      'strength': blur.strength,
      'focus': {'x': blur.focusX, 'y': blur.focusY},
    },
  };
}

/// Typed, mutable recipe. Values are kept as set by the editor; [toJson] normalises.
class Recipe {
  Map<String, Object?> source;
  final Geometry geometry;
  final Map<String, double> adjust;
  String filterId;
  double filterStrength;
  final Tools tools;
  Advanced advanced;

  Recipe._({
    required this.source,
    required this.geometry,
    required this.adjust,
    required this.filterId,
    required this.filterStrength,
    required this.tools,
    required this.advanced,
  });

  factory Recipe.defaults() => Recipe.fromJson(null);

  /// Parses (and normalises) a recipe from JSON: metadata, suggestions, the web editor
  factory Recipe.fromJson(Object? json) {
    final n = normalizeRecipeJson(json);
    final g = n['geometry']! as Map<String, Object?>;
    final crop = g['crop'] as Map<String, Object?>?;
    final adjust = n['adjust']! as Map<String, Object?>;
    final filter = n['filter']! as Map<String, Object?>;
    final t = n['tools']! as Map<String, Object?>;
    final sky = t['sky']! as Map<String, Object?>;
    final pl = t['portraitLight']! as Map<String, Object?>;
    final blur = t['blur']! as Map<String, Object?>;
    final focus = blur['focus']! as Map<String, Object?>;
    return Recipe._(
      source: Map<String, Object?>.of(n['source']! as Map<String, Object?>),
      geometry: Geometry(
        rotate90: (g['rotate90']! as num).toInt(),
        angle: toD(g['angle']),
        aspect: g['aspect']! as String,
        crop: crop == null
            ? null
            : CropRect(cx: toD(crop['cx']), cy: toD(crop['cy']), w: toD(crop['w']), h: toD(crop['h'])),
      ),
      adjust: {for (final key in adjustKeys) key: toD(adjust[key])},
      filterId: filter['id']! as String,
      filterStrength: toD(filter['strength']),
      tools: Tools(
        sky: SkyTool(palette: sky['palette']! as String, strength: toD(sky['strength'])),
        colorFocus: toD((t['colorFocus']! as Map)['strength']),
        portraitLight: PortraitLightTool(x: toD(pl['x']), y: toD(pl['y']), strength: toD(pl['strength'])),
        blur: BlurTool(strength: toD(blur['strength']), focusX: toD(focus['x']), focusY: toD(focus['y'])),
      ),
      advanced: Advanced.fromJson(n['advanced']),
    );
  }

  Map<String, Object?> toRawJson() => {
    'v': recipeVersion,
    'source': source,
    'geometry': geometry.toRawJson(),
    'adjust': Map<String, Object?>.of(adjust),
    'filter': {'id': filterId, 'strength': filterStrength},
    'tools': tools.toRawJson(),
    'advanced': advanced.toRawJson(),
  };

  /// Normalised JSON, byte-identical to the web editor's `normalizeRecipe` output
  Map<String, Object?> toJson() => normalizeRecipeJson(toRawJson());

  String encode() => jsonEncode(toJson());

  Recipe copy() => Recipe.fromJson(toRawJson());

  /// The normalised version of this recipe (values rounded like the web stores them)
  Recipe normalized() => Recipe.fromJson(toJson());

  bool equals(Recipe other) => encode() == other.encode();

  bool get isIdentity {
    final r = normalized();
    final g = r.geometry;
    final crop = g.crop;
    final fullCrop = crop == null || ((crop.w - 1).abs() < 1e-4 && (crop.h - 1).abs() < 1e-4);
    return g.rotate90 == 0 &&
        g.angle == 0 &&
        fullCrop &&
        adjustKeys.every((key) => r.adjust[key] == 0) &&
        (r.filterId == 'none' || r.filterStrength == 0) &&
        !r.tools.any &&
        r.advanced.isIdentity;
  }

  /// Short human summary, e.g. "Straighten −4.7°, Pop +0.20, B&W"
  String describe() {
    final r = normalized();
    final parts = <String>[];
    final angle = r.geometry.angle;
    if (angle != 0) {
      parts.add('Straighten ${angle > 0 ? '+' : '−'}${_jsString(angle.abs())}°');
    }
    if (r.geometry.rotate90 != 0) {
      parts.add('Rotate ${r.geometry.rotate90 * 90}°');
    }
    final crop = r.geometry.crop;
    if (crop != null && (crop.w < 0.999 || crop.h < 0.999)) {
      parts.add('Crop');
    }
    for (final key in adjustKeys) {
      final value = r.adjust[key]!;
      if (value != 0) {
        parts.add('${adjustLabels[key]} ${value > 0 ? '+' : '−'}${value.abs().toStringAsFixed(2)}');
      }
    }
    if (r.filterId != 'none' && r.filterStrength > 0) {
      parts.add(filters[r.filterId]?.name ?? r.filterId);
    }
    if (r.tools.sky.strength != 0) {
      parts.add('Sky (${r.tools.sky.palette})');
    }
    if (r.tools.colorFocus != 0) {
      parts.add('Color focus');
    }
    if (r.tools.portraitLight.strength != 0) {
      parts.add('Portrait light');
    }
    if (r.tools.blur.strength != 0) {
      parts.add('Blur');
    }
    if (!r.advanced.isIdentity) {
      parts.add('Advanced');
    }
    return parts.isEmpty ? 'No changes' : parts.join(', ');
  }
}

String _jsString(double v) {
  final n = jsonNum(v);
  return n is int ? '$n' : v.toString();
}

/// Effective adjust values: the user's sliders plus the chosen filter scaled by strength
class EffectiveAdjust {
  final Map<String, double> adjust;
  final double mono;
  final SplitTone? split;

  const EffectiveAdjust(this.adjust, this.mono, this.split);

  factory EffectiveAdjust.of(Recipe recipe) {
    final filter = filters[recipe.filterId];
    final strength = filter != null ? recipe.filterStrength : 0.0;
    final adjust = Map<String, double>.of(recipe.adjust);
    final fa = filter?.adjust;
    if (fa != null) {
      for (final key in adjustKeys) {
        final v = fa[key];
        if (v != null && v != 0) {
          final lo = unipolarKeys.contains(key) ? 0.0 : -1.0;
          adjust[key] = math.min(1, math.max(lo, adjust[key]! + v * strength));
        }
      }
    }
    final split = filter?.split;
    return EffectiveAdjust(
      adjust,
      filter?.mono == true ? strength : 0,
      split == null
          ? null
          : SplitTone(shadows: split.shadows, highlights: split.highlights, amount: split.amount * strength),
    );
  }
}
