// Crop & straighten interaction (port of the crop part of public/edit/editor.js).
//
// Like Google Photos: the frame is axis-aligned on screen and the image rotates and
// scales behind it. The [CropAnchor] ties an oriented-image point to a screen point at a
// given scale; while a corner is dragged the anchor stays put (the opposite corner stays
// pinned to the same image point), and ~0.8 s after release the frame re-fits the stage.
//
// Coordinates: "screen" is the crop stage's local space in logical pixels, "image" is the
// image after the 90° rotation (oriented), in pixels of the preview proxy. The recipe
// stores the crop normalised to that oriented image, so the proxy size does not matter.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';

const _deg = math.pi / 180;

/// An axis-aligned rectangle on screen (stage-local logical pixels)
@immutable
class ScreenRect {
  final double x;
  final double y;
  final double w;
  final double h;

  const ScreenRect(this.x, this.y, this.w, this.h);

  double get cx => x + w / 2;
  double get cy => y + h / 2;
  double get right => x + w;
  double get bottom => y + h;

  /// Top-left, top-right, bottom-left, bottom-right (the order editor.js uses: corner i
  /// is opposite to corner 3 - i)
  List<(double, double)> get corners => [(x, y), (x + w, y), (x, y + h), (x + w, y + h)];

  bool contains(double px, double py) => px > x && px < x + w && py > y && py < y + h;

  static ScreenRect lerp(ScreenRect a, ScreenRect b, double t) =>
      ScreenRect(_lerp(a.x, b.x, t), _lerp(a.y, b.y, t), _lerp(a.w, b.w, t), _lerp(a.h, b.h, t));

  @override
  bool operator ==(Object other) => other is ScreenRect && other.x == x && other.y == y && other.w == w && other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'ScreenRect($x, $y, $w, $h)';
}

/// Image point (ix, iy) is drawn at screen point (sx, sy); [scale] screen px per image px
@immutable
class CropAnchor {
  final double sx;
  final double sy;
  final double ix;
  final double iy;
  final double scale;

  const CropAnchor(this.sx, this.sy, this.ix, this.iy, this.scale);

  static CropAnchor lerp(CropAnchor a, CropAnchor b, double t) => CropAnchor(
    _lerp(a.sx, b.sx, t),
    _lerp(a.sy, b.sy, t),
    _lerp(a.ix, b.ix, t),
    _lerp(a.iy, b.iy, t),
    _lerp(a.scale, b.scale, t),
  );

  @override
  String toString() => 'CropAnchor($sx, $sy → $ix, $iy × $scale)';
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// An animated re-fit of the frame to the stage (260 ms ease-out in the UI)
class FitAnimation {
  final ScreenRect fromFrame;
  final CropAnchor fromAnchor;
  final ScreenRect toFrame;
  final CropAnchor toAnchor;

  const FitAnimation(this.fromFrame, this.fromAnchor, this.toFrame, this.toAnchor);
}

/// One pointer drag on the stage: a corner (0..3) or [CropController.pan]
class CropDrag {
  final int hit;
  final double x0;
  final double y0;
  final PxRect rect0;
  final CropAnchor anchor0;

  /// Image point of the corner opposite the dragged one (corner drags only)
  final (double, double)? fixedImage;

  /// Latest pointer position
  double px;
  double py;
  double? lastRectW;
  double? lastRectH;

  CropDrag({
    required this.hit,
    required this.x0,
    required this.y0,
    required this.rect0,
    required this.anchor0,
    required this.fixedImage,
  }) : px = x0,
       py = y0;
}

class CropController extends ChangeNotifier {
  CropController({required this.geometry, required this.sourceWidth, required this.sourceHeight, this.onCommit}) {
    _initRect();
  }

  /// The recipe's geometry; changed in place (rotate90, angle, aspect, crop)
  final Geometry geometry;

  /// Size of the (unrotated) preview image the stage draws
  final double sourceWidth;
  final double sourceHeight;

  /// Called whenever [commit] wrote the crop into [geometry]
  VoidCallback? onCommit;

  /// Hit value for a drag inside the frame (moves the image)
  static const pan = 4;
  static const handleRadius = 30.0;
  static const minSize = 48.0;
  static const edgeZone = 18.0;
  static const edgeGrowth = 1.035;

  /// Where the frame may go: the stage minus its padding
  ScreenRect box = const ScreenRect(0, 0, 100, 100);
  bool _hasBox = false;

  /// The crop in oriented-image pixels
  late PxRect rect;

  /// The crop before straightening started (setAngle shrinks from this one)
  PxRect? base;
  ScreenRect? frame;
  CropAnchor? anchor;
  CropDrag? drag;

  /// Fine 9×9 grid while straightening, thirds otherwise
  bool fineGrid = false;

  /// A corner drag ended and the frame has not been re-fitted yet
  bool needsRefit = false;
  FitAnimation? _pendingAnimation;

  Size2 get oriented => orientedSize(sourceWidth, sourceHeight, geometry.rotate90);

  double? get currentAspect {
    final s = oriented;
    return aspectValue(geometry.aspect, s.width, s.height);
  }

  bool get ready => frame != null && anchor != null;

  void _initRect() {
    final s = oriented;
    final crop = geometry.crop;
    rect = crop != null
        ? constrainRect(cropToPixels(crop, s.width, s.height), s.width, s.height, geometry.angle)
        : defaultRect(s.width, s.height, geometry.angle, currentAspect);
    base = null;
    drag = null;
    fineGrid = false;
    needsRefit = false;
    _pendingAnimation = null;
  }

  /// `initCrop`: the crop from the recipe (or the default) fitted to the stage
  void init() {
    _initRect();
    frame = null;
    anchor = null;
    if (_hasBox) {
      fit();
    } else {
      notifyListeners();
    }
  }

  /// Sets the stage box (on layout); re-fits without animation when it changed.
  /// Does not notify (called during layout; the painter repaints with the new size).
  void layout(ScreenRect stageBox) {
    if (_hasBox && stageBox == box) {
      return;
    }
    box = stageBox;
    _hasBox = true;
    if (drag == null) {
      final (f, a) = fitTarget();
      frame = f;
      anchor = a;
      needsRefit = false;
      _pendingAnimation = null;
    }
  }

  /// Frame and anchor that show [rect] as large as possible, centred in the box
  (ScreenRect, CropAnchor) fitTarget() {
    final aspect = rect.w / rect.h;
    var w = box.w;
    var h = w / aspect;
    if (h > box.h) {
      h = box.h;
      w = h * aspect;
    }
    final f = ScreenRect(box.x + (box.w - w) / 2, box.y + (box.h - h) / 2, w, h);
    return (f, CropAnchor(f.cx, f.cy, rect.cx, rect.cy, w / rect.w));
  }

  /// `fitFrame`: immediately, or as an animation the stage picks up with [takeAnimation]
  void fit({bool animate = false}) {
    needsRefit = false;
    final (f, a) = fitTarget();
    final fromFrame = frame;
    final fromAnchor = anchor;
    if (!animate || fromFrame == null || fromAnchor == null) {
      frame = f;
      anchor = a;
      _pendingAnimation = null;
    } else {
      _pendingAnimation = FitAnimation(fromFrame, fromAnchor, f, a);
    }
    notifyListeners();
  }

  /// The animation requested by `fit(animate: true)`, once
  FitAnimation? takeAnimation() {
    final a = _pendingAnimation;
    _pendingAnimation = null;
    return a;
  }

  /// Applies an animation at eased progress [t] (0..1)
  void applyAnimation(FitAnimation a, double t) {
    frame = ScreenRect.lerp(a.fromFrame, a.toFrame, t);
    anchor = CropAnchor.lerp(a.fromAnchor, a.toAnchor, t);
    notifyListeners();
  }

  // ---- Coordinates -----------------------------------------------------------------

  /// Oriented-image → screen through the anchor
  (double, double) toScreen(double ix, double iy) {
    final an = anchor!;
    final a = geometry.angle * _deg;
    final dx = (ix - an.ix) * an.scale;
    final dy = (iy - an.iy) * an.scale;
    return (an.sx + dx * math.cos(a) - dy * math.sin(a), an.sy + dx * math.sin(a) + dy * math.cos(a));
  }

  /// Screen → oriented-image through the anchor
  (double, double) toImage(double sx, double sy) {
    final an = anchor!;
    final a = -geometry.angle * _deg;
    final dx = (sx - an.sx) / an.scale;
    final dy = (sy - an.sy) / an.scale;
    return (an.ix + dx * math.cos(a) - dy * math.sin(a), an.iy + dx * math.sin(a) + dy * math.cos(a));
  }

  /// Crop rectangle in image coordinates for a frame drawn on screen (anchor unchanged)
  PxRect frameToRect(ScreenRect f) {
    final (cx, cy) = toImage(f.cx, f.cy);
    final scale = anchor!.scale;
    return PxRect(cx, cy, f.w / scale, f.h / scale);
  }

  // ---- Dragging ----------------------------------------------------------------------

  /// A corner (0..3) within reach, else [pan] inside the frame, else null
  int? hitTest(double x, double y) {
    final f = frame;
    if (f == null) {
      return null;
    }
    int? best;
    var bestDistance = handleRadius;
    final list = f.corners;
    for (var i = 0; i < 4; i++) {
      final d = math.sqrt(math.pow(x - list[i].$1, 2) + math.pow(y - list[i].$2, 2));
      if (d < bestDistance) {
        best = i;
        bestDistance = d;
      }
    }
    if (best != null) {
      return best;
    }
    return f.contains(x, y) ? pan : null;
  }

  /// `onCropPointerDown`; false when the pointer hit neither a corner nor the frame
  bool startDrag(double x, double y) {
    final hit = hitTest(x, y);
    final f = frame;
    final a = anchor;
    if (hit == null || f == null || a == null) {
      return false;
    }
    final fixedCorner = hit == pan ? null : f.corners[3 - hit];
    drag = CropDrag(
      hit: hit,
      x0: x,
      y0: y,
      rect0: rect,
      anchor0: a,
      fixedImage: fixedCorner == null ? null : toImage(fixedCorner.$1, fixedCorner.$2),
    );
    fineGrid = false;
    notifyListeners();
    return true;
  }

  /// `onCropPointerMove`; true when the corner sits at the stage edge and the frame keeps
  /// growing (the stage then calls [cornerDragUpdate] every frame: `startEdgeGrowth`)
  bool moveDrag(double x, double y) {
    final d = drag;
    if (d == null) {
      return false;
    }
    if (d.hit == pan) {
      // Move the image under the frame
      final s = oriented;
      final angle = geometry.angle;
      final a = -angle * _deg;
      final dx = -(x - d.x0) / d.anchor0.scale;
      final dy = -(y - d.y0) / d.anchor0.scale;
      final moved = d.rect0.copyWith(
        cx: d.rect0.cx + dx * math.cos(a) - dy * math.sin(a),
        cy: d.rect0.cy + dx * math.sin(a) + dy * math.cos(a),
      );
      rect = constrainRect(moved, s.width, s.height, angle);
      final f = frame!;
      // The rect's centre sits at the frame's centre (editor.js keeps the anchor's screen
      // point, which is the same thing once the frame has been fitted)
      anchor = CropAnchor(f.cx, f.cy, rect.cx, rect.cy, d.anchor0.scale);
      notifyListeners();
      return false;
    }
    d.px = x;
    d.py = y;
    return cornerDragUpdate();
  }

  /// Corner drag like Google Photos: the opposite corner stays pinned to the same spot of
  /// the image. When the frame outgrows the stage the view zooms out around that corner,
  /// and holding the pointer at the edge keeps revealing more of the photo, always within
  /// its bounds. Returns true while it keeps growing at the edge.
  bool cornerDragUpdate() {
    final d = drag;
    final fixedImage = d?.fixedImage;
    final current = frame;
    if (d == null || d.hit == pan || fixedImage == null || current == null) {
      return false;
    }
    final s = oriented;
    final angle = geometry.angle;
    final (fixedX, fixedY) = toScreen(fixedImage.$1, fixedImage.$2);
    final left = d.hit == 0 || d.hit == 2;
    final top = d.hit == 0 || d.hit == 1;
    final px = d.px;
    final py = d.py;
    final x = math.min(box.right, math.max(box.x, px));
    final y = math.min(box.bottom, math.max(box.y, py));
    var w = math.max(minSize, left ? fixedX - x : x - fixedX);
    var h = math.max(minSize, top ? fixedY - y : y - fixedY);
    final atEdgeX = left ? px <= box.x + edgeZone : px >= box.right - edgeZone;
    final atEdgeY = top ? py <= box.y + edgeZone : py >= box.bottom - edgeZone;
    if (atEdgeX) {
      w *= edgeGrowth;
    }
    if (atEdgeY) {
      h *= edgeGrowth;
    }
    final aspect = currentAspect;
    if (aspect != null) {
      if (atEdgeX || atEdgeY) {
        // Growing at an edge: the edge-touching side leads, the other follows the ratio
        if (atEdgeX && !atEdgeY) {
          h = w / aspect;
        } else if (atEdgeY && !atEdgeX) {
          w = h * aspect;
        } else if (w / h > aspect) {
          h = w / aspect;
        } else {
          w = h * aspect;
        }
      } else if (w / h > aspect) {
        w = h * aspect;
      } else {
        h = w / aspect;
      }
    }
    ScreenRect frameAt(double fw, double fh) =>
        ScreenRect(left ? fixedX - fw : fixedX, top ? fixedY - fh : fixedY, fw, fh);
    ScreenRect candidate(double t) => frameAt(current.w + (w - current.w) * t, current.h + (h - current.h) * t);
    var next = candidate(1);
    if (!fitsInside(frameToRect(next), s.width, s.height, angle)) {
      var lo = 0.0;
      var hi = 1.0;
      for (var i = 0; i < 14; i++) {
        final mid = (lo + hi) / 2;
        if (fitsInside(frameToRect(candidate(mid)), s.width, s.height, angle)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      next = candidate(lo);
    }
    final nextRect = frameToRect(next);
    // Zoom out around the pinned corner if the frame no longer fits the stage
    final availW = left ? fixedX - box.x : box.right - fixedX;
    final availH = top ? fixedY - box.y : box.bottom - fixedY;
    final k = math.min(1.0, math.min(availW / next.w, availH / next.h));
    if (k < 1) {
      anchor = CropAnchor(fixedX, fixedY, fixedImage.$1, fixedImage.$2, anchor!.scale * k);
      next = frameAt(next.w * k, next.h * k);
    }
    frame = next;
    rect = nextRect;
    notifyListeners();
    final grew = (nextRect.w - (d.lastRectW ?? 0)).abs() > 0.5 || (nextRect.h - (d.lastRectH ?? 0)).abs() > 0.5;
    d.lastRectW = nextRect.w;
    d.lastRectH = nextRect.h;
    return (atEdgeX || atEdgeY) && grew;
  }

  /// `onCropPointerUp`: commits; true when the frame should re-fit (after 0.8 s)
  bool endDrag() {
    final d = drag;
    if (d == null) {
      return false;
    }
    drag = null;
    commit();
    if (d.hit != pan) {
      needsRefit = true;
    }
    notifyListeners();
    return needsRefit;
  }

  // ---- Straighten, rotate, aspect -------------------------------------------------------

  /// `setAngle`: continuous (0.01° internally), snaps to level near 0. The frame stays put
  /// on screen; the crop shrinks (the image zooms) just enough to stay covered.
  void setAngle(double value, {bool fine = true}) {
    var angle = clampD(value, -maxAngle, maxAngle);
    angle = fine ? jsRound(angle * 100) / 100 : jsRound(angle);
    if (angle.abs() < 0.15) {
      angle = 0;
    }
    if (angle == geometry.angle) {
      return;
    }
    final s = oriented;
    final b = base ??= rect;
    geometry.angle = angle;
    final (maxW, _) = maxRectAt(s.width, s.height, angle, b.w / b.h, b.cx, b.cy);
    final scale = math.min(1.0, maxW / b.w);
    rect = constrainRect(b.copyWith(w: b.w * scale, h: b.h * scale), s.width, s.height, angle);
    final f = frame;
    if (f != null) {
      anchor = CropAnchor(f.cx, f.cy, rect.cx, rect.cy, f.w / rect.w);
    }
    fineGrid = true;
    commit();
    notifyListeners();
  }

  /// `endStraighten`: the next straightening starts from the crop as it is now
  void endStraighten() {
    base = null;
    fineGrid = false;
    notifyListeners();
  }

  /// 90° counter-clockwise, like Google Photos; resets the crop
  void rotate90() {
    geometry.rotate90 = (geometry.rotate90 + 3) % 4;
    geometry.crop = null;
    init();
    commit();
  }

  /// Back to the uncropped, unrotated photo
  void reset() {
    geometry.rotate90 = 0;
    geometry.angle = 0;
    geometry.aspect = 'free';
    geometry.crop = null;
    init();
    onCommit?.call();
  }

  /// `setAspect`: the largest crop of that ratio around the current centre (or centred if
  /// that would be much smaller), animated into place
  void setAspect(String id, {bool animate = true}) {
    geometry.aspect = id;
    final ratio = currentAspect;
    if (ratio != null) {
      final s = oriented;
      final angle = geometry.angle;
      final (maxW, maxH) = maxRectAt(s.width, s.height, angle, ratio, rect.cx, rect.cy);
      final (centredW, centredH) = maxRectAt(s.width, s.height, angle, ratio);
      final useMax = maxW > centredW * 0.7;
      rect = constrainRect(
        PxRect(
          useMax ? rect.cx : s.width / 2,
          useMax ? rect.cy : s.height / 2,
          useMax ? maxW : centredW,
          useMax ? maxH : centredH,
        ),
        s.width,
        s.height,
        angle,
      );
    }
    base = null;
    fit(animate: animate);
    commit();
  }

  /// `commitCrop`: writes the crop to the recipe (null when it is the full, level image)
  void commit() {
    final s = oriented;
    final full = (rect.w - s.width).abs() < 0.5 && (rect.h - s.height).abs() < 0.5 && geometry.angle == 0;
    geometry.crop = full ? null : pixelsToCrop(rect, s.width, s.height);
    onCommit?.call();
  }
}
