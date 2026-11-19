// CPU reference renderer: a faithful port of public/edit/pipeline.js (plus the pixel
// parts of advanced.js in cpu_advanced.dart and tools.js in cpu_tools.dart). It is the
// ground truth the GPU shaders are tested against and the fallback preview renderer.
//
// Public API (this file re-exports cpu_image.dart and the tool constants):
//   RgbImage renderCpu(src, recipe, {maxPixels, sourceWidth, sourceHeight, masks})
//       = render() in pipeline.js; the tools run when [masks] are given (in the upright
//       source orientation, any resolution; they are moved into the output geometry here).
//   RgbImage applyToneCpu(img, recipe, {masksInOutputGeometry})
//       = applyTone(): colour and tone in place on an image already in output geometry.
//   RgbImage applyGeometry(img, geometry, {sourceWidth, sourceHeight, maxPixels})
//   EditorMasks? transformMasks(masks, geometry, w0, h0, outWidth, outHeight)
//   OutputMapping (= outputMapping() in geometry.js, evaluated exactly like the JS)
//   Float32List buildToneLut(adjust), double applyLut(lut, v)
//   RgbImage / EditorMasks / FaceBox, fromRgba8, toRgba8, toRgb8, resize, halve,
//   blurChannel, luminance (cpu_image.dart)
//
// Constants for shader uniforms:
//   Cal.warmth … Cal.detailRadius  — `CAL` in pipeline.js (static consts of [Cal])
//   skyLooks['vivid'] …            — `SKY_LOOKS` in tools.js (const Map<String, SkyLook>)
//   toneLutSize                    — `LUT_SIZE` (the tone LUT has toneLutSize + 1 entries)
//
// Images are interleaved RGB Float32 in 0..1, sRGB-encoded. Every step keeps the JS
// arithmetic order and stores into Float32List where the JS stores into Float32Array;
// Math.hypot, Math.imul, Math.round, `%` and Uint8ClampedArray rounding are reproduced
// exactly (js_math.dart). Only Math.exp/sin/cos may differ from V8 by one double ulp,
// which almost never survives the Float32 stores (the fixture tests see no difference).
// Some loops are reorganised for speed (row-major vertical blur, one pass per channel,
// row terms hoisted, typed locals instead of lists), never changing per-value arithmetic.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_advanced.dart';
import 'package:immich_mobile/editor_photos/render/cpu_image.dart';
import 'package:immich_mobile/editor_photos/render/cpu_tools.dart';
import 'package:immich_mobile/editor_photos/render/js_math.dart';

export 'package:immich_mobile/editor_photos/render/cpu_image.dart';
export 'package:immich_mobile/editor_photos/render/cpu_tools.dart' show SkyLook, applyTools, skyLooks;

/// Strength constants (`CAL` in pipeline.js), tuned against Google Photos renders
abstract final class Cal {
  static const warmth = 0.22;
  static const tint = 0.16;
  static const brightness = 0.85;
  static const contrast = 0.9;
  static const whitePoint = 0.22;
  static const blackPoint = 0.12;
  static const highlights = 0.55;
  static const shadows = 0.75;
  static const hdr = 0.6;
  static const saturationUp = 0.85;
  static const saturationDown = 1.0;
  static const skinTone = 0.6;
  static const blueTone = 0.7;
  static const pop = 1.4;
  static const popVibrance = 0.15;
  static const vignette = 0.65;
  static const baseRadius = 0.035;
  static const detailRadius = 0.006;
}

const _deg = math.pi / 180;

/// `outputMapping` from geometry.js, evaluated in the same order as the JavaScript (the
/// model's [outputAffine] is the same map in affine form, equal up to rounding)
class OutputMapping {
  final double _w;
  final double _h;
  final double _rectCx;
  final double _rectCy;
  final double _rectW;
  final double _rectH;
  final double _cos;
  final double _sin;
  final double _sx;
  final double _sy;
  final int _k;

  OutputMapping._(
    this._w,
    this._h,
    this._rectCx,
    this._rectCy,
    this._rectW,
    this._rectH,
    this._cos,
    this._sin,
    this._sx,
    this._sy,
    this._k,
  );

  factory OutputMapping(Geometry geometry, double w0, double h0, int outWidth, int outHeight) {
    final eff = effectiveRect(geometry, w0, h0);
    final rect = eff.rect;
    final angle = geometry.angle * _deg;
    return OutputMapping._(
      eff.W,
      eff.H,
      rect.cx,
      rect.cy,
      rect.w,
      rect.h,
      math.cos(-angle),
      math.sin(-angle),
      rect.w / outWidth,
      rect.h / outHeight,
      geometry.rotate90,
    );
  }

  /// Source coordinates (original, unrotated image pixels) of output pixel (u, v) into [out]
  Float64List map(int u, int v, Float64List out) {
    // Position inside the crop, relative to its centre, in oriented-image pixels
    final dy = (v + 0.5) * _sy - _rectH / 2;
    return _mapRow(u, dy * _sin, dy * _cos, out);
  }

  // `map` with the row's terms precomputed (the same values in the same order)
  Float64List _mapRow(int u, double dySin, double dyCos, Float64List out) {
    final dx = (u + 0.5) * _sx - _rectW / 2;
    final x = _rectCx + dx * _cos - dySin;
    final y = _rectCy + dx * _sin + dyCos;
    // Undo the 90° rotation (clockwise steps) to reach original-image coordinates
    switch (_k) {
      case 0:
        out[0] = x;
        out[1] = y;
      case 1:
        out[0] = y;
        out[1] = _w - x;
      case 2:
        out[0] = _w - x;
        out[1] = _h - y;
      default:
        out[0] = _h - y;
        out[1] = x;
    }
    return out;
  }
}

/// Rotates, straightens and crops in one resampling pass (the image scales up to cover
/// the crop, exactly like the crop UI shows it). [sourceWidth]/[sourceHeight] are the size
/// of the original the geometry refers to when [img] is a scaled copy.
RgbImage applyGeometry(
  RgbImage img,
  Geometry geometry, {
  double? sourceWidth,
  double? sourceHeight,
  double maxPixels = double.infinity,
}) {
  final w0 = sourceWidth ?? img.width.toDouble();
  final h0 = sourceHeight ?? img.height.toDouble();
  final (width, height) = outputSize(geometry, w0, h0, maxPixels);
  final map = OutputMapping(geometry, w0, h0, width, height);
  final out = RgbImage(width, height);
  final kx = img.width / w0;
  final ky = img.height / h0;
  final p = Float64List(2);
  // Sample from a pre-shrunk source when the output is much smaller
  var src = img;
  var scale = 1;
  final ratio = math.min((w0 * h0) / (width * height), (img.width * img.height) / (width * height));
  while (ratio / (scale * scale) >= 4 && src.width > 2 && src.height > 2) {
    src = halve(src);
    scale *= 2;
  }
  final fx = (src.width / img.width) * kx;
  final fy = (src.height / img.height) * ky;
  for (var v = 0; v < height; v++) {
    final dy = (v + 0.5) * map._sy - map._rectH / 2;
    final dySin = dy * map._sin;
    final dyCos = dy * map._cos;
    for (var u = 0; u < width; u++) {
      map._mapRow(u, dySin, dyCos, p);
      sampleBilinear(src, p[0] * fx, p[1] * fy, out.data, (v * width + u) * 3);
    }
  }
  return out;
}

// ---- Tone curve (brightness, contrast, black and white point) ---------------

const toneLutSize = 4096;

Float32List buildToneLut(Map<String, double> adjust) {
  final lut = Float32List(toneLutSize + 1);
  final b = adjust['brightness']! * Cal.brightness;
  final c = adjust['contrast']! * Cal.contrast;
  final wp = adjust['whitePoint']! * Cal.whitePoint;
  final bp = adjust['blackPoint']! * Cal.blackPoint;
  final gamma = math.pow(2.0, -b).toDouble();
  for (var i = 0; i <= toneLutSize; i++) {
    var v = i / toneLutSize;
    // Black point: positive deepens shadows, negative lifts (fades) them
    v = bp >= 0 ? math.max(0.0, (v - bp) / (1 - bp)) : v * (1 + bp) - bp;
    // White point: positive brightens whites, negative dims them
    v = wp >= 0 ? v / (1 - wp) : v * (1 + wp);
    v = math.min(1.0, math.max(0.0, v)); // the curves below are defined on 0..1
    // Brightness: midtone gamma with highlights protected
    v = math.pow(math.max(v, 0.0), gamma).toDouble();
    // Contrast: S-curve around mid-grey that never clips
    if (c > 0) {
      v = v < 0.5 ? 0.5 * math.pow(2 * v, 1 + c) : 1 - 0.5 * math.pow(2 * (1 - v), 1 + c);
    } else if (c < 0) {
      v = 0.5 + (v - 0.5) * (1 + c * 0.6);
    }
    lut[i] = math.min(1.0, math.max(0.0, v));
  }
  return lut;
}

double applyLut(Float32List lut, double v) {
  if (v <= 0) {
    return lut[0];
  }
  if (v >= 1) {
    return lut[toneLutSize];
  }
  if (v.isNaN) {
    return v;
  }
  final f = v * toneLutSize;
  final i = f.toInt();
  return lut[i] + (lut[i + 1] - lut[i]) * (f - i);
}

// ---- Main entry -------------------------------------------------------------

/// Applies colour and tone edits to [img] in place (and returns it): `applyTone` in
/// pipeline.js with `tools: applyTools`. The recipe is normalised first, as the web does
/// before rendering. [masksInOutputGeometry] feed the tools; without them tools are skipped.
RgbImage applyToneCpu(RgbImage img, Recipe recipe, {EditorMasks? masksInOutputGeometry}) =>
    _applyTone(img, recipe.normalized(), masksInOutputGeometry);

RgbImage _applyTone(RgbImage img, Recipe recipe, EditorMasks? masks) {
  final width = img.width;
  final height = img.height;
  final data = img.data;
  final n = width * height;
  final eff = EffectiveAdjust.of(recipe);
  final adjust = eff.adjust;
  final mono = eff.mono;
  final split = eff.split;
  final diag = jsHypot(width.toDouble(), height.toDouble());

  // 1. White balance as channel gains (linear gains expressed in gamma space)
  final warm = adjust['warmth']! * Cal.warmth;
  final tint = adjust['tint']! * Cal.tint;
  if (warm != 0 || tint != 0) {
    final gr = math.pow(1 + warm, 1 / 2.2).toDouble();
    final gg = math.pow(1 - tint, 1 / 2.2).toDouble();
    final gb = math.pow(1 - warm, 1 / 2.2).toDouble();
    final norm = 1 / (0.2126 * gr + 0.7152 * gg + 0.0722 * gb);
    final kr = gr * norm;
    final kg = gg * norm;
    final kb = gb * norm;
    for (var j = 0; j < data.length; j += 3) {
      data[j] *= kr;
      data[j + 1] *= kg;
      data[j + 2] *= kb;
    }
  }

  final adv = recipe.advanced;
  applyExposure(img, adv);

  // 2. Local tone: shadows, highlights and HDR against a smooth luminance base
  final sh = adjust['shadows']! * Cal.shadows;
  final hi = adjust['highlights']! * Cal.highlights;
  final hdr = adjust['hdr']! * Cal.hdr;
  if (adjust['shadows'] != 0 || adjust['highlights'] != 0 || adjust['hdr'] != 0) {
    final lum = luminance(img);
    final base0 = blurChannel(lum, width, height, Cal.baseRadius * diag);
    final hdrBase = math.pow(0.45, 0.45 * hdr).toDouble();
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final l = lum[p];
      if (l <= 1e-5) {
        continue;
      }
      final base = math.max(base0[p], 1e-4);
      var target = l;
      final ws = 1 - smoothstep(0, 0.55, base);
      final wh = smoothstep(0.45, 1, base);
      if (sh != 0) {
        target += sh > 0 ? sh * ws * ws * (1 - target) * 0.9 : sh * ws * target * 0.9;
      }
      if (hi != 0) {
        target += hi > 0 ? hi * wh * (1 - target) * 0.7 : hi * wh * wh * target * 0.6;
      }
      if (hdr != 0) {
        // Compress the base towards mid-grey, keep (slightly boost) local detail
        final detail = l / base;
        final compressed = math.pow(base, 1 - 0.45 * hdr) * hdrBase;
        target = target * (1 - hdr) + compressed * math.pow(detail, 1 + 0.25 * hdr) * hdr;
      }
      final k = target / l;
      data[j] *= k;
      data[j + 1] *= k;
      data[j + 2] *= k;
    }
  }

  applyClarityDehaze(img, adv);

  // 3. Global tone curve
  if (adjust['brightness'] != 0 || adjust['contrast'] != 0 || adjust['whitePoint'] != 0 || adjust['blackPoint'] != 0) {
    final lut = buildToneLut(adjust);
    for (var j = 0; j < data.length; j++) {
      data[j] = applyLut(lut, data[j]);
    }
  }

  // 4. Pop: local contrast on midtones plus a little vibrance
  final pop = adjust['pop']!;
  if (pop != 0) {
    final lum = luminance(img);
    final blurred = blurChannel(lum, width, height, Cal.detailRadius * diag * 4);
    final amount = pop * Cal.pop;
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final l = lum[p];
      final midtone = 1 - (2 * l - 1).abs() * 0.7;
      final delta = (l - blurred[p]) * amount * midtone;
      data[j] += delta;
      data[j + 1] += delta;
      data[j + 2] += delta;
    }
  }

  // 5. Colour: saturation, vibrance from pop, skin and blue tones, filter mono/split
  final sat = adjust['saturation']!;
  final vib = pop * Cal.popVibrance;
  final skin = adjust['skinTone']! * Cal.skinTone;
  final blue = adjust['blueTone']! * Cal.blueTone;
  if (sat != 0 || vib != 0 || skin != 0 || blue != 0 || mono != 0 || split != null) {
    final baseFactor = 1 + (sat > 0 ? sat * Cal.saturationUp : sat * Cal.saturationDown);
    final splitAmount = split?.amount ?? 0.0;
    final splitShadows = Float64List.fromList(split?.shadows ?? const [0.0, 0.0, 0.0]);
    final splitHighlights = Float64List.fromList(split?.highlights ?? const [0.0, 0.0, 0.0]);
    for (var j = 0; j < data.length; j += 3) {
      var r = data[j];
      var g = data[j + 1];
      var b = data[j + 2];
      final l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      final max = math.max(r, math.max(g, b));
      final min = math.min(r, math.min(g, b));
      final chroma = max - min;
      var factor = baseFactor;
      if (vib != 0) {
        factor += vib * (1 - math.min(1.0, chroma * 2));
      }
      if ((skin != 0 || blue != 0) && chroma > 0.02) {
        final hue = _hueOf(r, g, b, max, chroma);
        final satWeight = math.min(1.0, chroma * 4);
        if (skin != 0) {
          factor += skin * _bandWeight(hue, 25, 22) * satWeight;
        }
        if (blue != 0) {
          factor += blue * _bandWeight(hue, 212, 32) * satWeight;
        }
      }
      if (factor != 1) {
        // Limit so no channel clips (keeps highlights from going flat)
        var f = factor;
        if (f > 1 && chroma > 0) {
          if (max > l) {
            f = math.min(f, (1 - l) / (max - l));
          }
          if (min < l) {
            f = math.min(f, l / (l - min));
          }
          f = math.max(1.0, f);
        }
        r = l + (r - l) * f;
        g = l + (g - l) * f;
        b = l + (b - l) * f;
      }
      if (mono != 0) {
        r += (l - r) * mono;
        g += (l - g) * mono;
        b += (l - b) * mono;
      }
      if (split != null) {
        final t = smoothstep(0.1, 0.9, l);
        r += splitAmount * ((1 - t) * splitShadows[0] + t * splitHighlights[0]);
        g += splitAmount * ((1 - t) * splitShadows[1] + t * splitHighlights[1]);
        b += splitAmount * ((1 - t) * splitShadows[2] + t * splitHighlights[2]);
      }
      data[j] = r;
      data[j + 1] = g;
      data[j + 2] = b;
    }
  }

  applyLevelsCurves(img, adv);
  applyColour(img, adv);

  // 6. Tools that need masks (sky, colour focus, portrait light, blur)
  if (masks != null) {
    applyTools(img, recipe, masks);
  }

  // 7. Vignette
  final vignette = adjust['vignette']!;
  if (vignette != 0) {
    final amount = vignette * Cal.vignette;
    final cx = width / 2;
    final cy = height / 2;
    for (var y = 0; y < height; y++) {
      final dy = (y + 0.5 - cy) / cy;
      for (var x = 0; x < width; x++) {
        final dx = (x + 0.5 - cx) / cx;
        final r = math.sqrt((dx * dx + dy * dy) / 2);
        final k = 1 - amount * smoothstep(0.35, 1.05, r);
        final j = (y * width + x) * 3;
        data[j] *= k;
        data[j + 1] *= k;
        data[j + 2] *= k;
      }
    }
  }

  applyFinish(img, adv);

  for (var j = 0; j < data.length; j++) {
    final v = data[j];
    data[j] = v < 0 ? 0 : (v > 1 ? 1 : v);
  }
  return img;
}

double _hueOf(double r, double g, double b, double max, double chroma) {
  double h;
  if (max == r) {
    h = ((g - b) / chroma).remainder(6);
  } else if (max == g) {
    h = (b - r) / chroma + 2;
  } else {
    h = (r - g) / chroma + 4;
  }
  h *= 60;
  return h < 0 ? h + 360 : h;
}

double _bandWeight(double hue, double centre, double halfWidth) {
  var d = (hue - centre).abs();
  if (d > 180) {
    d = 360 - d;
  }
  return d >= halfWidth ? 0 : 0.5 + 0.5 * math.cos((math.pi * d) / halfWidth);
}

/// Resamples masks (upright source orientation, any resolution) into the output's
/// geometry ([outWidth]×[outHeight] for a [w0]×[h0] original), and maps face boxes the
/// same way (`transformMasks` in pipeline.js)
EditorMasks? transformMasks(EditorMasks? masks, Geometry geometry, double w0, double h0, int outWidth, int outHeight) {
  if (masks == null) {
    return null;
  }
  final map = OutputMapping(geometry, w0, h0, outWidth, outHeight);
  final p = Float64List(2);
  final mw = masks.width;
  final mh = masks.height;
  // Resample every channel present, evaluating the mapping once per output pixel
  // (promoted locals, not a list of channels: element access through a List<Float32List?>
  // is several times slower in AOT code)
  final sky = masks.sky;
  final subject = masks.subject;
  final depth = masks.depth;
  final n = outWidth * outHeight;
  final skyOut = sky == null ? null : Float32List(n);
  final subjectOut = subject == null ? null : Float32List(n);
  final depthOut = depth == null ? null : Float32List(n);
  if (sky != null || subject != null || depth != null) {
    for (var v = 0; v < outHeight; v++) {
      final dy = (v + 0.5) * map._sy - map._rectH / 2;
      final dySin = dy * map._sin;
      final dyCos = dy * map._cos;
      for (var u = 0; u < outWidth; u++) {
        map._mapRow(u, dySin, dyCos, p);
        // Math.min(mw - 1, Math.max(0, …)), without the (slow) generic min/max
        var x = (p[0] / w0) * mw - 0.5;
        if (x < 0) {
          x = 0;
        }
        if (x > mw - 1) {
          x = mw - 1.0;
        }
        var y = (p[1] / h0) * mh - 0.5;
        if (y < 0) {
          y = 0;
        }
        if (y > mh - 1) {
          y = mh - 1.0;
        }
        final x0 = x.toInt(); // floor, x >= 0
        final y0 = y.toInt();
        final x1 = x0 + 1 < mw ? x0 + 1 : mw - 1;
        final y1 = y0 + 1 < mh ? y0 + 1 : mh - 1;
        final ax = x - x0;
        final ay = y - y0;
        final i00 = y0 * mw + x0;
        final i10 = y0 * mw + x1;
        final i01 = y1 * mw + x0;
        final i11 = y1 * mw + x1;
        final o = v * outWidth + u;
        if (sky != null) {
          skyOut![o] = _bilerp(sky, i00, i10, i01, i11, ax, ay);
        }
        if (subject != null) {
          subjectOut![o] = _bilerp(subject, i00, i10, i01, i11, ax, ay);
        }
        if (depth != null) {
          depthOut![o] = _bilerp(depth, i00, i10, i01, i11, ax, ay);
        }
      }
    }
  }

  var faces = const <FaceBox>[];
  if (masks.faces.isNotEmpty) {
    // The mapping is affine: invert it from three points to move face boxes forward
    final o = map.map(0, 0, Float64List(2));
    final ex = map.map(1, 0, Float64List(2));
    final ey = map.map(0, 1, Float64List(2));
    final a = ex[0] - o[0];
    final b = ey[0] - o[0];
    final c = ex[1] - o[1];
    final d = ey[1] - o[1];
    final det0 = a * d - b * c;
    final det = det0 == 0 || det0.isNaN ? 1.0 : det0;
    final scale0 = math.sqrt(det.abs());
    final scale = scale0 == 0 || scale0.isNaN ? 1.0 : scale0;
    FaceBox forward(FaceBox f) {
      final dx = (f.x + f.w / 2) * w0 - o[0];
      final dy = (f.y + f.h / 2) * h0 - o[1];
      final cx = (d * dx - b * dy) / det;
      final cy = (-c * dx + a * dy) / det;
      final size = math.max(f.w * w0, f.h * h0) / scale;
      return FaceBox(
        x: cx / outWidth - size / 2 / outWidth,
        y: cy / outHeight - size / 2 / outHeight,
        w: size / outWidth,
        h: size / outHeight,
        score: f.score,
      );
    }

    faces = masks.faces.map(forward).where((f) => f.x + f.w > 0 && f.y + f.h > 0 && f.x < 1 && f.y < 1).toList();
  }
  return EditorMasks(
    width: outWidth,
    height: outHeight,
    sky: skyOut,
    subject: subjectOut,
    depth: depthOut,
    faces: faces,
  );
}

double _bilerp(Float32List src, int i00, int i10, int i01, int i11, double ax, double ay) {
  final top = src[i00] + (src[i10] - src[i00]) * ax;
  final bottom = src[i01] + (src[i11] - src[i01]) * ax;
  return top + (bottom - top) * ay;
}

/// Full render (`render` in pipeline.js): geometry first (so tone work only touches kept
/// pixels), then tone. [sourceWidth]/[sourceHeight] give the original's size when [src]
/// is a scaled copy; [maxPixels] limits the output size. [masks] (upright source
/// orientation) enable the tools.
RgbImage renderCpu(
  RgbImage src,
  Recipe recipe, {
  double maxPixels = double.infinity,
  double? sourceWidth,
  double? sourceHeight,
  EditorMasks? masks,
}) {
  final r = recipe.normalized();
  final geometric = applyGeometry(
    src,
    r.geometry,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    maxPixels: maxPixels,
  );
  final w0 = sourceWidth ?? src.width.toDouble();
  final h0 = sourceHeight ?? src.height.toDouble();
  final moved = transformMasks(masks, r.geometry, w0, h0, geometric.width, geometric.height);
  return _applyTone(geometric, r, moved);
}
