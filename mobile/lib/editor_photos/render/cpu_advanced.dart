// Pixel part of public/edit/advanced.js: exposure, clarity, dehaze, levels, curves, HSL
// per colour band, colour grading, noise reduction, sharpening, the shaped vignette and
// film grain. Same arithmetic order as the JavaScript (see cpu_image.dart).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/render/cpu_image.dart';
import 'package:immich_mobile/editor_photos/render/js_math.dart';

/// Exposure in EV, before everything else (linear gain expressed in gamma space)
void applyExposure(RgbImage img, Advanced a) {
  if (a.exposure == 0) {
    return;
  }
  final k = math.pow(2.0, a.exposure / 2.2).toDouble();
  final data = img.data;
  for (var j = 0; j < data.length; j++) {
    data[j] *= k;
  }
}

/// Clarity (large-radius local contrast on midtones) and dehaze (dark-channel veil removal)
void applyClarityDehaze(RgbImage img, Advanced a) {
  final width = img.width;
  final height = img.height;
  final data = img.data;
  final n = width * height;
  final diag = jsHypot(width.toDouble(), height.toDouble());
  if (a.clarity != 0) {
    final l = luminance(img);
    final b = blurChannel(l, width, height, diag * 0.02);
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final mid = 1 - (2 * l[p] - 1).abs();
      final d = (l[p] - b[p]) * a.clarity * 1.6 * mid;
      data[j] += d;
      data[j + 1] += d;
      data[j + 2] += d;
    }
  }
  if (a.dehaze != 0) {
    final dark = Float32List(n);
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      dark[p] = math.min(data[j], math.min(data[j + 1], data[j + 2]));
    }
    final veil = blurChannel(dark, width, height, diag * 0.015);
    const air = 0.95;
    final k = a.dehaze * 0.85;
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final t = math.max(0.15, 1 - k * veil[p]);
      for (var c = 0; c < 3; c++) {
        data[j + c] = k >= 0
            ? (data[j + c] - air * (1 - t)) / t
            : data[j + c] * (1 + k * 0.5) - k * 0.5 * air * veil[p];
      }
    }
  }
}

double _lookup(Float32List lut, double v) {
  final f = math.min(1.0, math.max(0.0, v)) * 1024;
  if (f.isNaN) {
    return f;
  }
  final i = f.floor();
  return i >= 1024 ? lut[1024] : lut[i] + (lut[i + 1] - lut[i]) * (f - i);
}

/// Levels and curves as per-channel LUTs
void applyLevelsCurves(RgbImage img, Advanced a) {
  final lv = a.levels;
  final levelsActive = lv.inBlack != 0 || lv.inWhite != 1 || lv.gamma != 1 || lv.outBlack != 0 || lv.outWhite != 1;
  final curvesActive = curveChannels.any((c) => a.curves[c]!.isNotEmpty);
  if (!levelsActive && !curvesActive) {
    return;
  }
  final master = a.curves['rgb']!.isNotEmpty ? curveLut(a.curves['rgb']!) : null;
  final perR = a.curves['r']!.isNotEmpty ? curveLut(a.curves['r']!) : null;
  final perG = a.curves['g']!.isNotEmpty ? curveLut(a.curves['g']!) : null;
  final perB = a.curves['b']!.isNotEmpty ? curveLut(a.curves['b']!) : null;
  final span = math.max(1e-3, lv.inWhite - lv.inBlack);
  final inBlack = lv.inBlack;
  final outBlack = lv.outBlack;
  final outRange = lv.outWhite - lv.outBlack;
  final exponent = 1 / lv.gamma;
  double apply(double value, Float32List? channel) {
    var v = value;
    if (levelsActive) {
      v = outBlack + outRange * math.pow(math.min(1.0, math.max(0.0, (v - inBlack) / span)), exponent);
    }
    if (master != null) {
      v = _lookup(master, v);
    }
    if (channel != null) {
      v = _lookup(channel, v);
    }
    return v;
  }

  final data = img.data;
  for (var j = 0; j < data.length; j += 3) {
    data[j] = apply(data[j], perR);
    data[j + 1] = apply(data[j + 1], perG);
    data[j + 2] = apply(data[j + 2], perB);
  }
}

/// `rgbToHsl` into [out] (h in degrees, s, l)
void _rgbToHsl(double r, double g, double b, Float64List out) {
  final max = math.max(r, math.max(g, b));
  final min = math.min(r, math.min(g, b));
  final l = (max + min) / 2;
  if (max == min) {
    out[0] = 0;
    out[1] = 0;
    out[2] = l;
    return;
  }
  final d = max - min;
  final s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  final h = max == r ? (g - b) / d + (g < b ? 6 : 0) : (max == g ? (b - r) / d + 2 : (r - g) / d + 4);
  out[0] = h * 60;
  out[1] = s;
  out[2] = l;
}

// `x % 1` for finite x: x - trunc(x) is exact, so it equals fmod (up to the sign of a zero
// result, which the following `+ 1` erases); much faster than double.remainder
double _rem1(double x) => x - x.truncateToDouble();

double _hue2rgb(double p, double q, double t0) {
  final t = _rem1(_rem1(t0) + 1); // ((t % 1) + 1) % 1
  if (t < 1 / 6) {
    return p + (q - p) * 6 * t;
  }
  if (t < 1 / 2) {
    return q;
  }
  if (t < 2 / 3) {
    return p + (q - p) * (2 / 3 - t) * 6;
  }
  return p;
}

/// `hslToRgb` into [out]
void _hslToRgb(double h, double s, double l, Float64List out) {
  if (s == 0 || s.isNaN) {
    out[0] = l;
    out[1] = l;
    out[2] = l;
    return;
  }
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  final hh = h / 360;
  out[0] = _hue2rgb(p, q, hh + 1 / 3);
  out[1] = _hue2rgb(p, q, hh);
  out[2] = _hue2rgb(p, q, hh - 1 / 3);
}

/// HSL per colour band and three-way colour grading
void applyColour(RgbImage img, Advanced a) {
  final hslActive = hslBands.any((band) => !a.hsl[band.$1]!.isIdentity);
  final gradingActive = gradingRegions.any((r) => a.grading.regions[r]!.sat != 0);
  if (!hslActive && !gradingActive) {
    return;
  }
  final data = img.data;
  final bandCount = hslBands.length;
  final centres = Float64List.fromList([for (final b in hslBands) b.$2]);
  final bandH = Float64List.fromList([for (final b in hslBands) a.hsl[b.$1]!.h]);
  final bandS = Float64List.fromList([for (final b in hslBands) a.hsl[b.$1]!.s]);
  final bandL = Float64List.fromList([for (final b in hslBands) a.hsl[b.$1]!.l]);
  final rgb = Float64List(3);
  Float64List tintOf(GradingRegion region) {
    _hslToRgb(region.hue, 1, 0.5, rgb);
    final lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
    return Float64List.fromList([
      (rgb[0] - lum) * region.sat * 0.18,
      (rgb[1] - lum) * region.sat * 0.18,
      (rgb[2] - lum) * region.sat * 0.18,
    ]);
  }

  // Flat [shadows rgb, midtones rgb, highlights rgb]
  final tints = Float64List.fromList([for (final r in gradingRegions) ...tintOf(a.grading.regions[r]!)]);
  final bal = a.grading.balance * 0.25;
  final blend = 0.15 + a.grading.blending * 0.35;
  final hsl = Float64List(3);
  final weights = Float64List(3);
  for (var j = 0; j < data.length; j += 3) {
    var r = data[j];
    var g = data[j + 1];
    var b = data[j + 2];
    if (hslActive) {
      _rgbToHsl(math.min(1.0, math.max(0.0, r)), math.min(1.0, math.max(0.0, g)), math.min(1.0, math.max(0.0, b)), hsl);
      var h = hsl[0];
      var s = hsl[1];
      var l = hsl[2];
      var dh = 0.0;
      var ds = 0.0;
      var dl = 0.0;
      var wsum = 0.0;
      for (var k = 0; k < bandCount; k++) {
        var d = (h - centres[k]).abs();
        if (d > 180) {
          d = 360 - d;
        }
        final w = d >= 45 ? 0.0 : 0.5 + 0.5 * math.cos((math.pi * d) / 45);
        if (w == 0) {
          continue;
        }
        dh += bandH[k] * w;
        ds += bandS[k] * w;
        dl += bandL[k] * w;
        wsum += w;
      }
      if (wsum != 0) {
        final chroma = math.min(1.0, s * 3);
        h = (h + dh * 30 + 360).remainder(360);
        s = math.min(1.0, math.max(0.0, s * (1 + ds)));
        l = math.min(1.0, math.max(0.0, l + dl * 0.25 * chroma));
        _hslToRgb(h, s, l, rgb);
        r = rgb[0];
        g = rgb[1];
        b = rgb[2];
      }
    }
    if (gradingActive) {
      final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      final shadow = math.min(1.0, math.max(0.0, (0.5 - bal - lum) / blend + 0.5));
      final highlight = math.min(1.0, math.max(0.0, (lum - 0.5 - bal) / blend + 0.5));
      final mid = math.max(0.0, 1 - shadow - highlight);
      weights[0] = shadow;
      weights[1] = mid;
      weights[2] = highlight;
      for (var k = 0; k < 3; k++) {
        r += tints[k * 3] * weights[k];
        g += tints[k * 3 + 1] * weights[k];
        b += tints[k * 3 + 2] * weights[k];
      }
    }
    data[j] = r;
    data[j + 1] = g;
    data[j + 2] = b;
  }
}

/// Detail and finishing: noise reduction, sharpening, shaped vignette, film grain
void applyFinish(RgbImage img, Advanced a) {
  final width = img.width;
  final height = img.height;
  final data = img.data;
  final n = width * height;
  final scale = jsHypot(width.toDouble(), height.toDouble()) / 2500;
  if (a.noise != 0) {
    final radius = math.max(1.0, 1.5 * scale);
    final blurredR = blurChannel(channelOf(data, n, 0), width, height, radius);
    final blurredG = blurChannel(channelOf(data, n, 1), width, height, radius);
    final blurredB = blurChannel(channelOf(data, n, 2), width, height, radius);
    final l = luminance(img);
    final lb = blurChannel(l, width, height, radius);
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      // Keep edges: blend less where the pixel differs strongly from its surroundings
      final edge = math.min(1.0, (l[p] - lb[p]).abs() * 12);
      final k = a.noise * (1 - edge) * 0.9;
      data[j] += (blurredR[p] - data[j]) * k;
      data[j + 1] += (blurredG[p] - data[j + 1]) * k;
      data[j + 2] += (blurredB[p] - data[j + 2]) * k;
    }
  }
  if (a.sharpen.amount != 0) {
    final l = luminance(img);
    final b = blurChannel(l, width, height, math.max(1.0, a.sharpen.radius * scale));
    for (var p = 0, j = 0; p < n; p++, j += 3) {
      final d = (l[p] - b[p]) * a.sharpen.amount * 2;
      data[j] += d;
      data[j + 1] += d;
      data[j + 2] += d;
    }
  }
  final v = a.vignette;
  if (v.amount != 0) {
    final cx = width / 2;
    final cy = height / 2;
    final aspect = width / height;
    final round = (v.roundness + 1) / 2; // 0 = follows the frame, 1 = circle
    final inner = 0.2 + v.midpoint * 0.8;
    final soft = 0.05 + v.feather * 0.9;
    final stretchX = 1 + (aspect - 1) * round * (aspect > 1 ? 1 : 0);
    final stretchY = 1 + (1 / aspect - 1) * round * (aspect < 1 ? 1 : 0);
    for (var y = 0; y < height; y++) {
      final dy = (y + 0.5 - cy) / cy * stretchY;
      for (var x = 0; x < width; x++) {
        final dx = (x + 0.5 - cx) / cx * stretchX;
        final r = jsHypot(dx, dy) / math.sqrt2 * 1.2;
        final t = math.min(1.0, math.max(0.0, (r - inner + soft / 2) / soft));
        final w = t * t * (3 - 2 * t) * v.amount;
        final j = (y * width + x) * 3;
        for (var c = 0; c < 3; c++) {
          data[j + c] = w > 0 ? data[j + c] * (1 - w * 0.8) : data[j + c] + (1 - data[j + c]) * -w * 0.8;
        }
      }
    }
  }
  if (a.grain != 0) {
    // Deterministic per-pixel noise, sized to the photo so preview and save match
    final size = math.max(1, jsRound(scale * 1.5).toInt());
    final amount = a.grain;
    for (var y = 0; y < height; y++) {
      final gy = y ~/ size;
      for (var x = 0; x < width; x++) {
        final gx = x ~/ size;
        var h = (gx * 374761393 + gy * 668265263).toSigned(32);
        h = imul(h ^ ((h & 0xFFFFFFFF) >> 13), 1274126177);
        final noise = (((h ^ ((h & 0xFFFFFFFF) >> 16)) & 0xFFFFFFFF) / 4294967296 - 0.5) * amount * 0.12;
        final j = (y * width + x) * 3;
        data[j] += noise;
        data[j + 1] += noise;
        data[j + 2] += noise;
      }
    }
  }
}
