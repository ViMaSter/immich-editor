// Crop and straighten maths shared by the crop UI and the renderers (port of geometry.js).
//
// Model (like Google Photos): the crop frame is axis-aligned on screen and the image is
// rotated behind it by `angle`. In image coordinates the crop is therefore a rectangle
// rotated by -angle around its centre (cx, cy). `crop` is stored normalised to the image
// after the 90° rotation: cx, w as fractions of its width, cy, h as fractions of its height.
import 'dart:math' as math;

import 'package:immich_mobile/editor_photos/model/recipe.dart';

const _deg = math.pi / 180;

/// A crop rectangle in oriented-image pixels (centre and size)
class PxRect {
  final double cx;
  final double cy;
  final double w;
  final double h;

  const PxRect(this.cx, this.cy, this.w, this.h);

  PxRect copyWith({double? cx, double? cy, double? w, double? h}) =>
      PxRect(cx ?? this.cx, cy ?? this.cy, w ?? this.w, h ?? this.h);

  @override
  String toString() => 'PxRect($cx, $cy, $w, $h)';
}

class Size2 {
  final double width;
  final double height;

  const Size2(this.width, this.height);
}

Size2 orientedSize(double width, double height, int rotate90) =>
    rotate90 % 2 == 1 ? Size2(height, width) : Size2(width, height);

/// Extent of a w×h rectangle rotated by angle, measured along the image axes
(double, double) rotatedExtent(double w, double h, double angleDeg) {
  final c = math.cos(angleDeg * _deg).abs();
  final s = math.sin(angleDeg * _deg).abs();
  return (w * c + h * s, w * s + h * c);
}

/// Largest rectangle with the given aspect (w/h) centred at (cx, cy) that stays inside a
/// W×H image when rotated by angle
(double, double) maxRectAt(double W, double H, double angleDeg, double aspect, [double? cx, double? cy]) {
  final x = cx ?? W / 2;
  final y = cy ?? H / 2;
  final c = math.cos(angleDeg * _deg).abs();
  final s = math.sin(angleDeg * _deg).abs();
  final halfX = math.max(0.0, math.min(x, W - x));
  final halfY = math.max(0.0, math.min(y, H - y));
  final h = math.min((2 * halfX) / (aspect * c + s), (2 * halfY) / (aspect * s + c));
  return (aspect * h, h);
}

double? aspectValue(String aspectId, double W, double H) {
  if (aspectId == 'original') {
    return W / H;
  }
  for (final (id, _, ratio) in aspects) {
    if (id == aspectId) {
      return ratio;
    }
  }
  return null;
}

PxRect cropToPixels(CropRect? crop, double W, double H) {
  final c = crop ?? const CropRect(cx: 0.5, cy: 0.5, w: 1, h: 1);
  return PxRect(c.cx * W, c.cy * H, c.w * W, c.h * H);
}

CropRect pixelsToCrop(PxRect rect, double W, double H) =>
    CropRect(cx: rect.cx / W, cy: rect.cy / H, w: rect.w / W, h: rect.h / H);

bool fitsInside(PxRect rect, double W, double H, double angleDeg, [double epsilon = 0.5]) {
  final (bw, bh) = rotatedExtent(rect.w, rect.h, angleDeg);
  return rect.cx - bw / 2 >= -epsilon &&
      rect.cx + bw / 2 <= W + epsilon &&
      rect.cy - bh / 2 >= -epsilon &&
      rect.cy + bh / 2 <= H + epsilon;
}

/// Shrinks a rectangle around its centre (keeping its aspect) until it fits at `angle`,
/// first moving the centre inwards if the rectangle could fit elsewhere
PxRect constrainRect(PxRect rect, double W, double H, double angleDeg) {
  var cx = rect.cx;
  var cy = rect.cy;
  var w = rect.w;
  var h = rect.h;
  final (bw, bh) = rotatedExtent(w, h, angleDeg);
  if (bw <= W) {
    cx = math.min(math.max(cx, bw / 2), W - bw / 2);
  }
  if (bh <= H) {
    cy = math.min(math.max(cy, bh / 2), H - bh / 2);
  }
  final moved = PxRect(cx, cy, w, h);
  if (!fitsInside(moved, W, H, angleDeg)) {
    final (mw, _) = maxRectAt(W, H, angleDeg, w / h, cx, cy);
    final scale = math.min(1.0, mw / w);
    w *= scale;
    h *= scale;
  }
  return PxRect(cx, cy, w, h);
}

/// The crop shown when nothing has been chosen yet: as large as possible at this angle
PxRect defaultRect(double W, double H, double angleDeg, [double? aspect]) {
  final ratio = aspect ?? W / H;
  final (w, h) = maxRectAt(W, H, angleDeg, ratio);
  return PxRect(W / 2, H / 2, w, h);
}

class EffectiveRect {
  final double W;
  final double H;
  final PxRect rect;

  const EffectiveRect(this.W, this.H, this.rect);
}

/// Effective crop for rendering: the stored crop, or the default, always constrained
EffectiveRect effectiveRect(Geometry geometry, double w0, double h0) {
  final size = orientedSize(w0, h0, geometry.rotate90);
  final angle = geometry.angle;
  final crop = geometry.crop;
  final rect = crop != null ? cropToPixels(crop, size.width, size.height) : defaultRect(size.width, size.height, angle);
  return EffectiveRect(size.width, size.height, constrainRect(rect, size.width, size.height, angle));
}

/// Affine map from output pixel coordinates (u, v; pixel centres at +0.5) to source
/// coordinates in the original (unrotated) image: x = a*u + b*v + c, y = d*u + e*v + f
class Affine {
  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  const Affine(this.a, this.b, this.c, this.d, this.e, this.f);

  (double, double) apply(double u, double v) => (a * u + b * v + c, d * u + e * v + f);

  /// Affine that maps output pixel u to source; `apply(u + 0.5, v + 0.5)` gives the centre
  @override
  String toString() => 'Affine($a, $b, $c, $d, $e, $f)';
}

/// Maps an output pixel (u, v) of the cropped result to source coordinates in the
/// original image. Same maths as `outputMapping` in geometry.js; returned as an affine
/// map of the pixel-centre coordinates (u + 0.5, v + 0.5).
Affine outputAffine(Geometry geometry, double w0, double h0, double outWidth, double outHeight) {
  final eff = effectiveRect(geometry, w0, h0);
  final rect = eff.rect;
  final W = eff.W;
  final H = eff.H;
  final angle = geometry.angle * _deg;
  final cos = math.cos(-angle);
  final sin = math.sin(-angle);
  final sx = rect.w / outWidth;
  final sy = rect.h / outHeight;
  // x' = cx + (U*sx - w/2)*cos - (V*sy - h/2)*sin  with U = u + 0.5
  final ax = sx * cos;
  final bx = -sy * sin;
  final cx = rect.cx - rect.w / 2 * cos + rect.h / 2 * sin;
  final ay = sx * sin;
  final by = sy * cos;
  final cy = rect.cy - rect.w / 2 * sin - rect.h / 2 * cos;
  // Undo the 90° rotation (clockwise steps) to reach original-image coordinates
  return switch (geometry.rotate90) {
    1 => Affine(ay, by, cy, -ax, -bx, W - cx),
    2 => Affine(-ax, -bx, W - cx, -ay, -by, H - cy),
    3 => Affine(-ay, -by, H - cy, ax, bx, cx),
    _ => Affine(ax, bx, cx, ay, by, cy),
  };
}

/// `outputMapping`: maps output pixel (u, v) to source coordinates
(double, double) mapOutputPixel(Affine map, int u, int v) => map.apply(u + 0.5, v + 0.5);

/// Output size for a render: crop size in source pixels, optionally limited to maxPixels
(int, int) outputSize(Geometry geometry, double w0, double h0, [double maxPixels = double.infinity]) {
  final rect = effectiveRect(geometry, w0, h0).rect;
  var w = rect.w;
  var h = rect.h;
  final pixels = w * h;
  if (pixels > maxPixels) {
    final scale = math.sqrt(maxPixels / pixels);
    w *= scale;
    h *= scale;
  }
  return (math.max(1, _jsRound(w)), math.max(1, _jsRound(h)));
}

int _jsRound(double v) => (v - v.floorToDouble() >= 0.5 ? v.floorToDouble() + 1 : v.floorToDouble()).toInt();
