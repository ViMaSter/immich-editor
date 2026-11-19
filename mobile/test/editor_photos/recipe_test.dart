import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';

import 'fixture_utils.dart';

void main() {
  group('normalizeRecipe fixtures', () {
    final cases = readFixtureJson('recipes.json')! as List;
    for (final raw in cases) {
      final c = raw as Map<String, Object?>;
      final input = c['input'];
      final normalized = c['normalized']! as String;
      test(c['name']! as String, () {
        expect(jsonEncode(normalizeRecipeJson(input)), normalized, reason: 'normalizeRecipeJson');
        final recipe = Recipe.fromJson(input);
        expect(jsonEncode(recipe.toJson()), normalized, reason: 'Recipe.fromJson(x).toJson()');
        expect(recipe.encode(), normalized);
        expect(recipe.describe(), c['describe'], reason: 'describe (with filter names)');
        expect(recipe.isIdentity, c['isIdentity'], reason: 'isIdentity');
        // Normalising is idempotent: the normalised JSON parses back to itself
        final again = Recipe.fromJson(jsonDecode(normalized));
        expect(again.encode(), normalized, reason: 'idempotent');
        expect(again.normalized().encode(), normalized);
        expect(recipe.copy().encode(), normalized, reason: 'copy');
      });
    }
  });

  // Port of 'recipes are clamped and unknown values dropped' in edit-core.test.js
  test('recipes are clamped and unknown values dropped', () {
    final r = Recipe.fromJson({
      'adjust': {'contrast': 5, 'pop': -1, 'nonsense': 3},
      'geometry': {'angle': 90, 'rotate90': -1, 'aspect': 'weird'},
      'filter': {'id': 'x' * 99},
    });
    expect(r.adjust['contrast'], 1);
    expect(r.adjust['pop'], 0);
    expect(r.adjust.containsKey('nonsense'), isFalse);
    expect(r.toJson()['adjust'], isNot(contains('nonsense')));
    expect(r.geometry.angle, 45);
    expect(r.geometry.rotate90, 3);
    expect(r.geometry.aspect, 'free');
    expect(r.filterId, 'none');
    expect(Recipe.defaults().isIdentity, isTrue);
    expect(
      Recipe.fromJson({
        'geometry': {'angle': 0.1},
      }).isIdentity,
      isFalse,
    );
    expect(
      Recipe.fromJson({
        'geometry': {'angle': -4.7},
        'adjust': {'pop': 0.2},
      }).describe(),
      'Straighten −4.7°, Pop +0.20',
    );
  });

  test('a recipe edited with unrounded values re-normalises idempotently', () {
    final r = Recipe.defaults();
    r.adjust['brightness'] = 0.123456;
    r.adjust['hdr'] = -0.5; // unipolar: clamps to 0
    r.adjust['contrast'] = 1.7;
    r.geometry.angle = -7.777;
    r.geometry.rotate90 = 7;
    r.geometry.crop = const CropRect(cx: 0.1234567, cy: 1.2, w: 0.0001, h: 0.5555555);
    r.filterId = 'golden';
    r.filterStrength = 0.3333;
    r.tools.sky.palette = 'nonsense';
    r.tools.sky.strength = 0.875;
    r.tools.portraitLight.x = 0.12345;
    r.tools.blur.focusY = 2;
    r.advanced.exposure = 1.23456;
    r.advanced.curves['rgb']!.addAll([
      [0.9, 0.95],
      [0.1, 0.2],
      [0.1004, 0.3],
      [0.5, 2],
    ]);
    r.advanced.hsl['blue']!.s = -0.33333;
    r.advanced.grading.regions['shadows']!.hue = 359.6;
    r.advanced.vignette.amount = 0.4444;

    final json = r.toJson();
    final encoded = jsonEncode(json);
    expect(jsonEncode(normalizeRecipeJson(json)), encoded, reason: 'normalising normalised JSON changes nothing');
    expect(Recipe.fromJson(json).encode(), encoded);
    expect(Recipe.fromJson(jsonDecode(encoded)).encode(), encoded);
    expect(r.normalized().normalized().encode(), encoded);

    final adjust = json['adjust']! as Map<String, Object?>;
    expect(adjust['brightness'], 0.12);
    expect(adjust['hdr'], 0);
    expect(adjust['contrast'], 1);
    final geometry = json['geometry']! as Map<String, Object?>;
    expect(geometry['angle'], -7.78);
    expect(geometry['rotate90'], 3);
    expect(geometry['crop'], {'cx': 0.12346, 'cy': 1, 'w': 0.01, 'h': 0.55556});
    expect(json['filter'], {'id': 'golden', 'strength': 0.33});
    final tools = json['tools']! as Map<String, Object?>;
    expect(tools['sky'], {'palette': 'vivid', 'strength': 0.88});
    final advanced = json['advanced']! as Map<String, Object?>;
    expect(advanced['exposure'], 1.235);
    expect((advanced['curves']! as Map)['rgb'], [
      [0.1, 0.2],
      [0.5, 1],
      [0.9, 0.95],
    ]);
    expect(((advanced['grading']! as Map)['shadows']! as Map)['hue'], 360);
    expect(r.equals(Recipe.fromJson(json)), isTrue);
  });
}
