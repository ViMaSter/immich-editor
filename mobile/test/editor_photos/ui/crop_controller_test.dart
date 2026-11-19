import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/ui/editor/crop_controller.dart';

const _w = 1600.0;
const _h = 1000.0;
const _box = ScreenRect(20, 20, 360, 400);

CropController _controller({Geometry? geometry, ScreenRect box = _box}) {
  final c = CropController(geometry: geometry ?? Geometry(), sourceWidth: _w, sourceHeight: _h);
  c.layout(box);
  return c;
}

Matcher _near(double v, [double eps = 1e-6]) => closeTo(v, eps);

void _expectInsideBox(ScreenRect f, ScreenRect box) {
  expect(f.x, greaterThanOrEqualTo(box.x - 1e-6));
  expect(f.y, greaterThanOrEqualTo(box.y - 1e-6));
  expect(f.right, lessThanOrEqualTo(box.right + 1e-6));
  expect(f.bottom, lessThanOrEqualTo(box.bottom + 1e-6));
}

void main() {
  group('frame and anchor', () {
    test('fit shows the crop as large as possible, centred in the box', () {
      final c = _controller();
      final f = c.frame!;
      // 1.6:1 into 360×400 → width-limited
      expect(f.w, _near(360));
      expect(f.h, _near(225));
      expect(f.cx, _near(_box.cx));
      expect(f.cy, _near(_box.cy));
      expect(c.anchor!.scale, _near(360 / _w));
      expect(c.rect.w, _near(_w));
      expect(c.rect.h, _near(_h));
    });

    test('toScreen and toImage are inverse, also when rotated', () {
      final c = _controller(geometry: Geometry(angle: 12.5));
      for (final (x, y) in [(0.0, 0.0), (800.0, 500.0), (1234.5, 77.0), (-40.0, 1200.0)]) {
        final (sx, sy) = c.toScreen(x, y);
        final (ix, iy) = c.toImage(sx, sy);
        expect(ix, _near(x, 1e-9));
        expect(iy, _near(y, 1e-9));
      }
    });

    test('the anchor maps the frame centre to the crop centre', () {
      final c = _controller(geometry: Geometry(angle: -7, crop: const CropRect(cx: 0.4, cy: 0.6, w: 0.5, h: 0.5)));
      final (ix, iy) = c.toImage(c.frame!.cx, c.frame!.cy);
      expect(ix, _near(c.rect.cx));
      expect(iy, _near(c.rect.cy));
      final r = c.frameToRect(c.frame!);
      expect(r.w, _near(c.rect.w));
      expect(r.h, _near(c.rect.h));
    });

    test('rotate90 orientation swaps the image size', () {
      final c = _controller(geometry: Geometry(rotate90: 1));
      expect(c.oriented.width, _h);
      expect(c.oriented.height, _w);
      expect(c.rect.w, _near(_h));
      expect(c.rect.h, _near(_w));
    });

    test('a stored crop is restored in oriented pixels', () {
      final c = _controller(geometry: Geometry(crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.5, h: 0.4)));
      expect(c.rect.cx, _near(800));
      expect(c.rect.cy, _near(500));
      expect(c.rect.w, _near(800));
      expect(c.rect.h, _near(400));
    });

    test('hit test: corners first, inside pans, outside nothing', () {
      final c = _controller();
      final f = c.frame!;
      expect(c.hitTest(f.x + 3, f.y + 2), 0);
      expect(c.hitTest(f.right - 2, f.y), 1);
      expect(c.hitTest(f.x, f.bottom + 5), 2);
      expect(c.hitTest(f.right + 4, f.bottom - 4), 3);
      expect(c.hitTest(f.cx, f.cy), CropController.pan);
      expect(c.hitTest(f.cx, f.y - 60), isNull);
    });
  });

  group('straighten', () {
    test('setAngle shrinks the crop just enough to stay inside the rotated image', () {
      final g = Geometry();
      final c = _controller(geometry: g);
      for (var a = -45.0; a <= 45; a += 2.5) {
        c.setAngle(a);
        expect(g.angle, a.abs() < 0.15 ? 0 : a);
        expect(fitsInside(c.rect, _w, _h, g.angle), isTrue, reason: 'angle $a');
        // Keeps the aspect of the crop before straightening and stays as large as possible
        expect(c.rect.w / c.rect.h, _near(_w / _h, 1e-9));
        final (maxW, _) = maxRectAt(_w, _h, g.angle, _w / _h);
        expect(c.rect.w, _near(math.min(_w, maxW), 1e-6));
      }
    });

    test('the frame stays put and the image zooms behind it', () {
      final c = _controller();
      final frame = c.frame!;
      c.setAngle(10);
      expect(c.frame, frame);
      expect(c.fineGrid, isTrue);
      expect(c.anchor!.scale, _near(frame.w / c.rect.w));
      final (ix, iy) = c.toImage(frame.cx, frame.cy);
      expect(ix, _near(c.rect.cx));
      expect(iy, _near(c.rect.cy));
      c.endStraighten();
      expect(c.fineGrid, isFalse);
      expect(c.base, isNull);
    });

    test('straightening back to 0 during one drag restores the crop', () {
      final g = Geometry();
      final c = _controller(geometry: g);
      c.setAngle(20);
      c.setAngle(0.1); // snaps to level
      expect(g.angle, 0);
      expect(c.rect.w, _near(_w));
      expect(g.crop, isNull);
    });

    test('angles are clamped to ±45° with 0.01° steps', () {
      final g = Geometry();
      final c = _controller(geometry: g);
      c.setAngle(60);
      expect(g.angle, 45);
      c.setAngle(-3.14159);
      expect(g.angle, -3.14);
      c.setAngle(2.6, fine: false);
      expect(g.angle, 3);
    });

    test('a straightened off-centre crop stays inside', () {
      final g = Geometry(crop: const CropRect(cx: 0.2, cy: 0.25, w: 0.3, h: 0.4));
      final c = _controller(geometry: g);
      for (final a in [5.0, 15.0, -30.0, 45.0]) {
        c.setAngle(a);
        expect(fitsInside(c.rect, _w, _h, a), isTrue, reason: 'angle $a');
      }
      expect(g.crop, isNotNull);
    });
  });

  group('corner drag', () {
    test('dragging a corner inwards keeps the opposite corner pinned', () {
      final c = _controller();
      final f = c.frame!;
      expect(c.startDrag(f.right, f.bottom), isTrue);
      final fixed = c.drag!.fixedImage!;
      c.moveDrag(f.right - 100, f.bottom - 60);
      final (ix, iy) = c.toImage(c.frame!.x, c.frame!.y);
      expect(ix, _near(fixed.$1));
      expect(iy, _near(fixed.$2));
      expect(c.frame!.w, _near(f.w - 100));
      expect(c.frame!.h, _near(f.h - 60));
      expect(fitsInside(c.rect, _w, _h, 0), isTrue);
      expect(c.endDrag(), isTrue, reason: 'a corner drag re-fits afterwards');
      expect(c.geometry.crop, isNotNull);
    });

    test('the frame never gets smaller than the minimum size', () {
      final c = _controller();
      final f = c.frame!;
      c.startDrag(f.right, f.bottom);
      c.moveDrag(f.x - 50, f.y - 50);
      expect(c.frame!.w, greaterThanOrEqualTo(CropController.minSize - 1e-9));
      expect(c.frame!.h, greaterThanOrEqualTo(CropController.minSize - 1e-9));
    });

    test('dragging outwards zooms out but never leaves the image', () {
      final g = Geometry(angle: 8, crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.25, h: 0.25));
      final c = _controller(geometry: g);
      final scale0 = c.anchor!.scale;
      final f = c.frame!;
      c.startDrag(f.right, f.bottom);
      final fixed = c.drag!.fixedImage!;
      // Far outside the stage: the pointer is clamped to the box and sits at its edge
      var growing = c.moveDrag(_box.right + 200, _box.bottom + 200);
      expect(growing, isTrue);
      for (var i = 0; i < 400 && growing; i++) {
        growing = c.cornerDragUpdate();
        expect(fitsInside(c.rect, _w, _h, g.angle), isTrue);
        _expectInsideBox(c.frame!, _box);
        final (ix, iy) = c.toImage(c.frame!.x, c.frame!.y);
        expect(ix, _near(fixed.$1, 1e-6));
        expect(iy, _near(fixed.$2, 1e-6));
      }
      expect(growing, isFalse, reason: 'growth stops at the image bounds');
      expect(c.anchor!.scale, lessThan(scale0));
      // It grew to the image's (rotated) edge on at least one side
      final (bw, bh) = rotatedExtent(c.rect.w, c.rect.h, g.angle);
      final touches = [c.rect.cx + bw / 2 - _w, c.rect.cy + bh / 2 - _h].any((d) => d.abs() < 2);
      expect(touches, isTrue);
      c.endDrag();
      expect(c.needsRefit, isTrue);
      c.fit();
      expect(c.needsRefit, isFalse);
      _expectInsideBox(c.frame!, _box);
    });

    test('with a fixed aspect the drag keeps the ratio', () {
      final g = Geometry(aspect: 'square', crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.3, h: 0.48));
      final c = _controller(geometry: g);
      final f = c.frame!;
      c.startDrag(f.x, f.y);
      c.moveDrag(f.x + 30, f.y + 70);
      expect(c.frame!.w, _near(c.frame!.h));
      expect(c.rect.w, _near(c.rect.h));
    });

    test('panning moves the image under the frame and stays inside', () {
      final g = Geometry(crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.5, h: 0.5));
      final c = _controller(geometry: g);
      final f = c.frame!;
      final rect0 = c.rect;
      c.startDrag(f.cx, f.cy);
      expect(c.drag!.hit, CropController.pan);
      c.moveDrag(f.cx + 30, f.cy);
      // Moving the finger right moves the image right: the crop moves left in the image
      expect(c.rect.cx, _near(rect0.cx - 30 / c.anchor!.scale));
      expect(c.frame, f);
      c.moveDrag(f.cx + 5000, f.cy - 5000);
      expect(fitsInside(c.rect, _w, _h, 0), isTrue);
      expect(c.rect.cx, _near(c.rect.w / 2));
      expect(c.rect.cy, _near(_h - c.rect.h / 2));
      expect(c.endDrag(), isFalse, reason: 'a pan does not re-fit');
    });
  });

  group('aspect presets, rotate, reset, commit', () {
    test('every preset gives its ratio and fits the image', () {
      for (final angle in [0.0, 13.0]) {
        for (final (id, _, ratio) in aspects) {
          final g = Geometry(angle: angle);
          final c = _controller(geometry: g);
          final before = c.rect;
          c.setAspect(id, animate: false);
          expect(g.aspect, id);
          final expected = id == 'original' ? _w / _h : ratio;
          if (expected == null) {
            expect(c.rect, same(before), reason: 'free keeps the crop');
          } else {
            expect(c.rect.w / c.rect.h, _near(expected, 1e-9), reason: '$id at $angle°');
          }
          expect(fitsInside(c.rect, _w, _h, angle), isTrue, reason: '$id at $angle°');
          _expectInsideBox(c.frame!, _box);
        }
      }
    });

    test('a preset is as large as possible at the current centre', () {
      final c = _controller();
      c.setAspect('square', animate: false);
      expect(c.rect.h, _near(_h));
      expect(c.rect.cx, _near(_w / 2));
      c.setAspect('16:9', animate: false);
      expect(c.rect.w, _near(_w));
      expect(c.rect.h, _near(_w * 9 / 16));
    });

    test('a preset falls back to the centre when the current centre is cramped', () {
      final g = Geometry(crop: const CropRect(cx: 0.05, cy: 0.5, w: 0.1, h: 0.5));
      final c = _controller(geometry: g);
      c.setAspect('square', animate: false);
      expect(c.rect.cx, _near(_w / 2));
      expect(c.rect.w, _near(_h));
    });

    test('an animated preset change is handed to the stage', () {
      final c = _controller();
      final from = c.frame!;
      c.setAspect('square');
      final animation = c.takeAnimation()!;
      expect(animation.fromFrame, from);
      expect(c.takeAnimation(), isNull);
      c.applyAnimation(animation, 1);
      expect(c.frame, animation.toFrame);
      expect(c.frame!.w, _near(c.frame!.h));
    });

    test('rotate90 turns counter-clockwise and resets the crop', () {
      final g = Geometry(crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.5, h: 0.5));
      final c = _controller(geometry: g);
      c.rotate90();
      expect(g.rotate90, 3);
      expect(g.crop, isNull);
      expect(c.rect.w, _near(_h));
      expect(c.rect.h, _near(_w));
      c.rotate90();
      expect(g.rotate90, 2);
    });

    test('commit stores null for the full level image, else the normalised crop', () {
      var commits = 0;
      final g = Geometry();
      final c = CropController(geometry: g, sourceWidth: _w, sourceHeight: _h, onCommit: () => commits++)..layout(_box);
      c.commit();
      expect(g.crop, isNull);
      c.setAspect('square', animate: false);
      final crop = g.crop!;
      expect(crop.w, _near(_h / _w));
      expect(crop.h, _near(1));
      expect(crop.cx, _near(0.5));
      expect(commits, 2);
    });

    test('reset clears rotation, angle, aspect and crop', () {
      final g = Geometry(
        rotate90: 1,
        angle: 4,
        aspect: 'square',
        crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.5, h: 0.5),
      );
      final c = _controller(geometry: g);
      c.reset();
      expect(g.rotate90, 0);
      expect(g.angle, 0);
      expect(g.aspect, 'free');
      expect(g.crop, isNull);
      expect(c.rect.w, _near(_w));
    });

    test('layout re-fits to a new stage size', () {
      final c = _controller();
      c.layout(const ScreenRect(20, 20, 800, 300));
      expect(c.frame!.h, _near(300));
      expect(c.frame!.w, _near(480));
    });
  });
}
