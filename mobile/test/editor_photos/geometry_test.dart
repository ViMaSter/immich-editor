import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_pipeline.dart';

import 'fixture_utils.dart';

// The model evaluates the same expressions as geometry.js; only Math.sin/cos may differ
// by one double ulp, so results agree to ~1e-12 relative.
Matcher near(Object? expected, [double scale = 1]) => closeTo(toD(expected), 1e-9 * scale);

Geometry geometryOf(Object? json) => Recipe.fromJson({'geometry': json}).geometry;

PxRect rectOf(Object? json) {
  final m = json! as Map<String, Object?>;
  return PxRect(toD(m['cx']), toD(m['cy']), toD(m['w']), toD(m['h']));
}

void expectRect(PxRect got, Object? expected, double scale, String reason) {
  final m = expected! as Map<String, Object?>;
  expect(got.cx, near(m['cx'], scale), reason: '$reason cx');
  expect(got.cy, near(m['cy'], scale), reason: '$reason cy');
  expect(got.w, near(m['w'], scale), reason: '$reason w');
  expect(got.h, near(m['h'], scale), reason: '$reason h');
}

void main() {
  group('geometry fixtures', () {
    final fixtures = readFixtureJson('geometry.json')! as Map<String, Object?>;
    List<Map<String, Object?>> cases(String key) => (fixtures[key]! as List).cast<Map<String, Object?>>();

    test('maxRectAt', () {
      for (final c in cases('maxRectAt')) {
        final (w, h) = maxRectAt(
          toD(c['W']),
          toD(c['H']),
          toD(c['angle']),
          toD(c['aspect']),
          c['cx'] == null ? null : toD(c['cx']),
          c['cy'] == null ? null : toD(c['cy']),
        );
        final scale = toD(c['W']) + toD(c['H']);
        expect(w, near(c['w'], scale), reason: '$c');
        expect(h, near(c['h'], scale), reason: '$c');
      }
    });

    test('constrainRect', () {
      for (final c in cases('constrainRect')) {
        final out = constrainRect(rectOf(c['rect']), toD(c['W']), toD(c['H']), toD(c['angle']));
        expectRect(out, c['out'], toD(c['W']), '$c');
      }
    });

    test('defaultRect', () {
      for (final c in cases('defaultRect')) {
        final out = defaultRect(
          toD(c['W']),
          toD(c['H']),
          toD(c['angle']),
          c['aspect'] == null ? null : toD(c['aspect']),
        );
        expectRect(out, c['out'], toD(c['W']), '$c');
      }
    });

    test('effectiveRect', () {
      for (final c in cases('effectiveRect')) {
        final e = effectiveRect(geometryOf(c['geometry']), toD(c['W0']), toD(c['H0']));
        expect(e.W, toD(c['W']));
        expect(e.H, toD(c['H']));
        expectRect(e.rect, c['rect'], toD(c['W0']), '$c');
      }
    });

    test('outputSize', () {
      for (final c in cases('outputSize')) {
        final maxPixels = c['maxPixels'] == null ? double.infinity : toD(c['maxPixels']);
        final size = outputSize(geometryOf(c['geometry']), toD(c['W0']), toD(c['H0']), maxPixels);
        expect(size, (c['width'], c['height']), reason: '$c');
      }
    });

    test('outputMapping (exact port and the model\'s affine form)', () {
      for (final c in cases('outputMapping')) {
        final geometry = geometryOf(c['geometry']);
        final w0 = toD(c['W0']);
        final h0 = toD(c['H0']);
        final outW = c['outWidth']! as int;
        final outH = c['outHeight']! as int;
        final mapping = OutputMapping(geometry, w0, h0, outW, outH);
        final affine = outputAffine(geometry, w0, h0, outW.toDouble(), outH.toDouble());
        final p = Float64List(2);
        for (final raw in c['samples']! as List) {
          final s = raw as List;
          final u = s[0] as int;
          final v = s[1] as int;
          final reason = '${c['geometry']} ${w0}x$h0 → ${outW}x$outH at ($u, $v)';
          mapping.map(u, v, p);
          expect(p[0], near(s[2], w0 + h0), reason: reason);
          expect(p[1], near(s[3], w0 + h0), reason: reason);
          final (x, y) = affine.apply(u + 0.5, v + 0.5);
          expect(x, near(s[2], w0 + h0), reason: '$reason (affine)');
          expect(y, near(s[3], w0 + h0), reason: '$reason (affine)');
          final (mx, my) = mapOutputPixel(affine, u, v);
          expect((mx, my), (x, y));
        }
      }
    });
  });

  // Ports of the geometry tests in edit-core.test.js
  group('behaviour', () {
    test('the largest rotated crop stays inside the image', () {
      for (final angle in const [0.0, 3.5, -12.0, 30.0, 45.0]) {
        for (final aspect in const [4 / 3, 1.0, 9 / 16]) {
          final (w, h) = maxRectAt(4000, 3000, angle, aspect);
          final rect = PxRect(2000, 1500, w, h);
          expect(fitsInside(rect, 4000, 3000, angle), isTrue, reason: '$angle° $aspect');
          final bigger = rect.copyWith(w: rect.w * 1.01, h: rect.h * 1.01);
          expect(fitsInside(bigger, 4000, 3000, angle), isFalse, reason: 'and is maximal');
        }
      }
      // At 0° with the image's own aspect the default crop is the whole image
      final full = defaultRect(4000, 3000, 0);
      expect(full.w.round(), 4000);
      expect(full.h.round(), 3000);
    });

    test('constraining moves a crop inwards before shrinking it', () {
      final moved = constrainRect(const PxRect(3900, 1500, 1000, 750), 4000, 3000, 0);
      expect(moved.w, 1000);
      expect(moved.cx, 3500);
      final shrunk = constrainRect(const PxRect(2000, 1500, 4000, 3000), 4000, 3000, 5);
      expect(shrunk.w, lessThan(4000));
      expect((shrunk.w / shrunk.h - 4 / 3).abs(), lessThan(1e-9));
      expect(fitsInside(shrunk, 4000, 3000, 5), isTrue);
    });

    test('output mapping undoes 90° rotations', () {
      final geometry = Geometry(rotate90: 1);
      // Rotated 90° clockwise: the output's top-left comes from the source's bottom-left
      final p = OutputMapping(geometry, 400, 300, 300, 400).map(0, 0, Float64List(2));
      expect(p[0], closeTo(0.5, 1e-9));
      expect(p[1], closeTo(299.5, 1e-9));
      final (x, y) = mapOutputPixel(outputAffine(geometry, 400, 300, 300, 400), 0, 0);
      expect(x, closeTo(0.5, 1e-9));
      expect(y, closeTo(299.5, 1e-9));
      expect(outputSize(geometry, 400, 300), (300, 400));
      expect(outputSize(Geometry(crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.5, h: 0.5)), 400, 300), (200, 150));
    });
  });
}
