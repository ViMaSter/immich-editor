// JavaScript number semantics the pixel pipeline depends on, so the Dart port produces
// the same floats as V8: Math.hypot (V8's scaled Kahan sum, not sqrt(x² + y²)), the
// Uint8ClampedArray store (round half to even) and Math.imul.
import 'dart:math' as math;

/// `Math.hypot(a, b)` exactly as V8 computes it
double jsHypot(double a, double b) {
  final x = a.abs();
  final y = b.abs();
  if (x == double.infinity || y == double.infinity) {
    return double.infinity;
  }
  if (x.isNaN || y.isNaN) {
    return double.nan;
  }
  final max = x > y ? x : y;
  if (max == 0) {
    return 0;
  }
  // Kahan summation of the squares, normalised to the largest value
  var sum = 0.0;
  var compensation = 0.0;
  final nx = x / max;
  var summand = nx * nx - compensation;
  var preliminary = sum + summand;
  compensation = (preliminary - sum) - summand;
  sum = preliminary;
  final ny = y / max;
  summand = ny * ny - compensation;
  preliminary = sum + summand;
  sum = preliminary;
  return math.sqrt(sum) * max;
}

/// The value a `Uint8ClampedArray` stores for [v] (ToUint8Clamp: NaN → 0, ties to even)
int uint8Clamp(double v) {
  if (!(v > 0)) {
    return 0;
  }
  if (v >= 255) {
    return 255;
  }
  final f = v.toInt();
  final half = f + 0.5;
  if (half < v) {
    return f + 1;
  }
  if (v < half) {
    return f;
  }
  return f.isOdd ? f + 1 : f;
}

/// `Math.imul(a, b)`: 32-bit integer multiplication, result as a signed 32-bit int
int imul(int a, int b) => (a.toSigned(32) * b.toSigned(32)).toSigned(32);
