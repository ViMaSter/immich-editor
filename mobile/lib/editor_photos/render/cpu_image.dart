// Image containers and the low-level helpers of public/edit/pipeline.js: 8-bit conversion
// with the 4×4 Bayer dither, halving, bilinear resizing, the 3× box blur and luminance.
//
// Float semantics: like the JavaScript, every intermediate value is a double and every
// store into an image or channel is a Float32 store (Float32List here, Float32Array
// there), in the same order, so results match the web renderer to float precision.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/render/js_math.dart';

/// Interleaved RGB image, values 0..1 (may leave that range mid-pipeline), sRGB-encoded
class RgbImage {
  final int width;
  final int height;
  final Float32List data;

  RgbImage(this.width, this.height, [Float32List? data]) : data = data ?? Float32List(width * height * 3) {
    if (this.data.length != width * height * 3) {
      throw ArgumentError('RgbImage $width×$height needs ${width * height * 3} values, got ${this.data.length}');
    }
  }

  RgbImage clone() => RgbImage(width, height, Float32List.fromList(data));
}

/// A detected face, normalised to the image (0..1), like the server's mask JSON
class FaceBox {
  final double x;
  final double y;
  final double w;
  final double h;
  final double? score;

  const FaceBox({required this.x, required this.y, required this.w, required this.h, this.score});

  factory FaceBox.fromJson(Map<String, Object?> json) => FaceBox(
    x: toD(json['x']),
    y: toD(json['y']),
    w: toD(json['w']),
    h: toD(json['h']),
    score: json['score'] is num ? toD(json['score']) : null,
  );

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'w': w, 'h': h, 'score': ?score};

  @override
  String toString() => 'FaceBox($x, $y, $w, $h, $score)';
}

/// Segmentation masks for the tools: single channels (0..1, row-major, [width]×[height])
/// in the upright source orientation, or — after [transformMasks] — in the output's geometry
class EditorMasks {
  final int width;
  final int height;
  final Float32List? sky;
  final Float32List? subject;
  final Float32List? depth;
  final List<FaceBox> faces;

  const EditorMasks({
    required this.width,
    required this.height,
    this.sky,
    this.subject,
    this.depth,
    this.faces = const [],
  });
}

RgbImage fromRgba8(Uint8List rgba, int width, int height) {
  final img = RgbImage(width, height);
  final d = img.data;
  for (var i = 0, j = 0; j < d.length; i += 4, j += 3) {
    d[j] = rgba[i] / 255;
    d[j + 1] = rgba[i + 1] / 255;
    d[j + 2] = rgba[i + 2] / 255;
  }
  return img;
}

/// `fromRGB`: interleaved RGB samples (8 or 16 bit) scaled by [maxValue]
RgbImage fromRgb(List<int> buffer, int width, int height, {int maxValue = 255}) {
  final img = RgbImage(width, height);
  final d = img.data;
  for (var j = 0; j < d.length; j++) {
    d[j] = buffer[j] / maxValue;
  }
  return img;
}

// Ordered 4×4 dither keeps smooth skies free of banding when going back to 8 bits
final Float64List _bayer = Float64List.fromList([
  for (final v in const [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]) (v + 0.5) / 16 - 0.5,
]);

/// `toRGBA8`: 8-bit RGBA with the Bayer dither, rounded exactly like [toRgb8]
Uint8List toRgba8(RgbImage img, [Uint8List? out]) {
  final width = img.width;
  final data = img.data;
  final result = out ?? Uint8List(width * img.height * 4);
  for (var y = 0, j = 0, i = 0; y < img.height; y++) {
    final row = (y & 3) * 4;
    for (var x = 0; x < width; x++, j += 3, i += 4) {
      final dither = _bayer[row + (x & 3)];
      result[i] = uint8Clamp(jsRound(data[j] * 255 + dither));
      result[i + 1] = uint8Clamp(jsRound(data[j + 1] * 255 + dither));
      result[i + 2] = uint8Clamp(jsRound(data[j + 2] * 255 + dither));
      result[i + 3] = 255;
    }
  }
  return result;
}

/// `toRGB8`: 8-bit RGB with the Bayer dither (Math.round, then clamped)
Uint8List toRgb8(RgbImage img) {
  final width = img.width;
  final data = img.data;
  final out = Uint8List(width * img.height * 3);
  for (var y = 0, j = 0; y < img.height; y++) {
    final row = (y & 3) * 4;
    for (var x = 0; x < width; x++, j += 3) {
      final dither = _bayer[row + (x & 3)];
      for (var c = 0; c < 3; c++) {
        final v = jsRound(data[j + c] * 255 + dither);
        out[j + c] = v < 0 ? 0 : (v > 255 ? 255 : (v.isNaN ? 0 : v.toInt()));
      }
    }
  }
  return out;
}

// ---- Resampling -------------------------------------------------------------

/// Bilinear sample at pixel coordinates (x, y) (pixel centres at +0.5), edges clamped
void sampleBilinear(RgbImage img, double x, double y, Float32List out, int o) {
  final width = img.width;
  final height = img.height;
  final data = img.data;
  // Math.min(Math.max(x - 0.5, 0), width - 1), without the (slow) generic min/max
  var fx = x - 0.5;
  if (fx < 0) {
    fx = 0;
  }
  if (fx > width - 1) {
    fx = width - 1.0;
  }
  var fy = y - 0.5;
  if (fy < 0) {
    fy = 0;
  }
  if (fy > height - 1) {
    fy = height - 1.0;
  }
  final x0 = fx.toInt(); // floor, fx >= 0
  final y0 = fy.toInt();
  final x1 = x0 + 1 < width ? x0 + 1 : width - 1;
  final y1 = y0 + 1 < height ? y0 + 1 : height - 1;
  final ax = fx - x0;
  final ay = fy - y0;
  final i00 = (y0 * width + x0) * 3;
  final i10 = (y0 * width + x1) * 3;
  final i01 = (y1 * width + x0) * 3;
  final i11 = (y1 * width + x1) * 3;
  for (var c = 0; c < 3; c++) {
    final top = data[i00 + c] + (data[i10 + c] - data[i00 + c]) * ax;
    final bottom = data[i01 + c] + (data[i11 + c] - data[i01 + c]) * ax;
    out[o + c] = top + (bottom - top) * ay;
  }
}

RgbImage resize(RgbImage img, int width, int height) {
  if (img.width == width && img.height == height) {
    return img;
  }
  // Box-average first when shrinking a lot, so previews don't alias
  var src = img;
  while (src.width >= width * 2 && src.height >= height * 2) {
    src = halve(src);
  }
  final out = RgbImage(width, height);
  final sx = src.width / width;
  final sy = src.height / height;
  for (var v = 0; v < height; v++) {
    for (var u = 0; u < width; u++) {
      sampleBilinear(src, (u + 0.5) * sx, (v + 0.5) * sy, out.data, (v * width + u) * 3);
    }
  }
  return out;
}

/// 2×2 box average (odd trailing rows and columns are dropped)
RgbImage halve(RgbImage img) {
  final width = img.width ~/ 2;
  final height = img.height ~/ 2;
  final out = RgbImage(width, height);
  final s = img.data;
  final d = out.data;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final a = ((2 * y) * img.width + 2 * x) * 3;
      final b = a + img.width * 3;
      final o = (y * width + x) * 3;
      for (var c = 0; c < 3; c++) {
        d[o + c] = (s[a + c] + s[a + 3 + c] + s[b + c] + s[b + 3 + c]) / 4;
      }
    }
  }
  return out;
}

// ---- Filters on single channels --------------------------------------------

/// Three box blurs approximate a Gaussian; O(n) per pass regardless of radius
Float32List blurChannel(Float32List src, int width, int height, double radius) {
  final r = math.max(1, jsRound(radius).toInt());
  final a = Float32List.fromList(src);
  final b = Float32List(src.length);
  final columns = Float64List(width);
  for (var pass = 0; pass < 3; pass++) {
    _boxH(a, b, width, height, r);
    _boxV(b, a, width, height, r, columns);
  }
  return a;
}

void _boxH(Float32List src, Float32List dst, int width, int height, int r) {
  final norm = 1 / (2 * r + 1);
  final last = width - 1;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    var acc = src[row] * (r + 1);
    for (var x = 1; x <= r; x++) {
      acc += src[row + (x < last ? x : last)];
    }
    for (var x = 0; x < width; x++) {
      dst[row + x] = acc * norm;
      final add = x + r + 1;
      final sub = x - r;
      acc += src[row + (add < last ? add : last)] - src[row + (sub > 0 ? sub : 0)];
    }
  }
}

// Vertical pass, row by row for cache locality: [acc] holds one running (double) sum per
// column, updated in exactly the order of the column-by-column JavaScript loop
void _boxV(Float32List src, Float32List dst, int width, int height, int r, Float64List acc) {
  final norm = 1 / (2 * r + 1);
  final last = height - 1;
  for (var x = 0; x < width; x++) {
    acc[x] = src[x] * (r + 1);
  }
  for (var y = 1; y <= r; y++) {
    final row = (y < last ? y : last) * width;
    for (var x = 0; x < width; x++) {
      acc[x] += src[row + x];
    }
  }
  for (var y = 0; y < height; y++) {
    final out = y * width;
    final add = (y + r + 1 < last ? y + r + 1 : last) * width;
    final sub = (y - r > 0 ? y - r : 0) * width;
    for (var x = 0; x < width; x++) {
      dst[out + x] = acc[x] * norm;
      acc[x] += src[add + x] - src[sub + x];
    }
  }
}

/// One channel ([c] = 0, 1, 2) of interleaved RGB [data] with [n] pixels
Float32List channelOf(Float32List data, int n, int c) {
  final out = Float32List(n);
  for (var p = 0, j = c; p < n; p++, j += 3) {
    out[p] = data[j];
  }
  return out;
}

Float32List luminance(RgbImage img) {
  final n = img.width * img.height;
  final l = Float32List(n);
  final d = img.data;
  for (var p = 0, j = 0; p < n; p++, j += 3) {
    l[p] = 0.2126 * d[j] + 0.7152 * d[j + 1] + 0.0722 * d[j + 2];
  }
  return l;
}

double smoothstep(double a, double b, double x) {
  final t = math.min(1.0, math.max(0.0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
}
