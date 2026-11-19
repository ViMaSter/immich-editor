#version 460 core
#include <flutter/runtime_effect.glsl>
precision highp float;

// editor.photos pixel pipeline (port of public/edit/pipeline.js, advanced.js and tools.js).
//
// One pass applies the stages [uRange.x, uRange.y) to every pixel. Stages that need a
// blurred version of an earlier state (local tone, clarity, dehaze, pop, the blur tool,
// noise reduction, sharpening) read it from a field texture that the renderer computed
// between passes (reduce.frag + box.frag), so the work is split into passes at exactly
// those points and the arithmetic per pixel follows the JavaScript order.
//
// Stage numbers:
//  0 load (geometry from the source, or the previous state)   10 HSL + colour grading
//  1 white balance                                             11 sky, colour focus, portrait light
//  2 exposure                                                  12 blur tool
//  3 shadows / highlights / HDR    (field uBase)               13 vignette
//  4 clarity                       (field uClar)               14 noise reduction  (field uNoise)
//  5 dehaze                        (field uVeil)               15 sharpen          (field uSharp)
//  6 tone curve                                                16 shaped vignette
//  7 pop                           (field uPop)                17 grain
//  8 saturation, vibrance, skin/blue tones, mono, split tone   18 clamp
//  9 levels + curves
//
// Output modes (uRange.z): 0 state (encoded with uEnc), 1 final 8-bit with ordered dither,
// 2 final float (clamped, for tests).

// ---- Pass layout ----
uniform vec2 uSize;      // output size of this pass (px)
uniform vec2 uOrigin;    // position of this pass's (0,0) in full-output pixels
uniform vec2 uFull;      // full output size (px): positional effects use it
uniform vec4 uRange;     // from, to, output mode, 1 = load from the source image
uniform vec4 uIo;        // input offset x/y (state px), state encode scale, bias
uniform vec4 uFlip;      // flip rows of: render-target textures, decoded textures, the source

// ---- Geometry: full-output pixel centre -> original image pixels ----
uniform vec3 uAffX;
uniform vec3 uAffY;
uniform vec4 uSrcRect;   // texture origin in original px (x, y), texels per original px (x, y)
uniform vec4 uSizes;     // size of the uIn texture (w, h), original image size (w, h)

// ---- Adjustments ----
uniform vec4 uWb;        // gain r, g, b (norm applied), active
uniform vec4 uLocal;     // shadows, highlights, hdr, exposure gain (1 = off)
uniform vec4 uClarHaze;  // clarity, dehaze k, active clarity, active dehaze
uniform vec4 uTone;      // brightness, contrast, white point, black point (scaled)
uniform vec4 uTone2;     // gamma, tone active, pop amount, pop vibrance
uniform vec4 uColour;    // saturation, skin, blue, mono
uniform vec4 uSplitS;    // split shadows rgb, amount
uniform vec4 uSplitH;    // split highlights rgb, active colour stage
uniform vec4 uLevels;    // inBlack, inWhite (span), gamma, outBlack
uniform vec4 uLevels2;   // outWhite, levels active, master curve, per-channel curves active
uniform vec4 uHsl0;      // h, s, l of red (w: hsl active)
uniform vec4 uHsl1;
uniform vec4 uHsl2;
uniform vec4 uHsl3;
uniform vec4 uHsl4;
uniform vec4 uHsl5;
uniform vec4 uHsl6;
uniform vec4 uHsl7;
uniform vec4 uGrade0;    // shadows tint rgb, grading active
uniform vec4 uGrade1;    // midtones tint rgb, balance (×0.25)
uniform vec4 uGrade2;    // highlights tint rgb, blend
uniform vec4 uCurveOn;   // r, g, b curve present, master present

// ---- Tools ----
uniform vec4 uMaskOn;    // sky, subject, depth present, masks present
uniform vec4 uSky;       // strength, tint, lum, sat
uniform vec4 uSky2;      // contrast, has scene, -, -
uniform vec4 uSkyTop;    // rgb
uniform vec4 uSkyBottom; // rgb
uniform vec4 uSkyScene;  // rgb
uniform vec4 uFocus;     // colour focus strength, blur strength, focus depth, -
uniform vec4 uLight;     // portrait strength, face count, -, -
uniform vec4 uFace0;     // cx, cy, radius in full-output px
uniform vec4 uFace1;
uniform vec4 uFace2;
uniform vec4 uFace3;
uniform vec4 uFace4;
uniform vec4 uFace5;
uniform vec4 uFace6;
uniform vec4 uFace7;

// ---- Finish ----
uniform vec4 uFinish;    // vignette amount (scaled), noise, sharpen amount, grain
uniform vec4 uShape;     // shaped vignette amount, roundness (0..1), inner, soft

// ---- Fields: full-output px per field texel (global fields) ----
uniform vec4 uFieldK;    // base, clarity, veil, pop
uniform vec4 uFieldK2;   // blur levels 1, 2, 3
uniform vec4 uFieldSize0; // base w, h, clarity w, h
uniform vec4 uFieldSize1; // veil w, h, pop w, h
uniform vec4 uFieldSize2; // blur 1 w, h, blur 2 w, h
uniform vec4 uFieldSize3; // blur 3 w, h, masks w, h

uniform sampler2D uIn;
uniform sampler2D uBase;
uniform sampler2D uClar;
uniform sampler2D uVeil;
uniform sampler2D uPop;
uniform sampler2D uBl1;
uniform sampler2D uBl2;
uniform sampler2D uBl3;
uniform sampler2D uNoise;
uniform sampler2D uSharp;
uniform sampler2D uMasks;
uniform sampler2D uCurves;
uniform sampler2D uGrain;

out vec4 fragColor;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const float PI = 3.141592653589793;

float luma(vec3 c) {
  return c.r * LUMA.r + c.g * LUMA.g + c.b * LUMA.b;
}

// SkSL (the Skia backend) does not allow samplers as function parameters, so the texel
// and bilinear helpers are generated per sampler.
#define DEFINE_FETCH(TEXEL, BILINEAR, TEX)                                \
  vec4 TEXEL(vec2 i, vec2 s, float flip) {                                \
    vec2 uv = (i + 0.5) / s;                                              \
    if (flip > 0.5) {                                                     \
      uv.y = 1.0 - uv.y;                                                  \
    }                                                                     \
    return texture(TEX, uv);                                              \
  }                                                                       \
  vec4 BILINEAR(vec2 p, vec2 s, float flip) {                             \
    vec2 f = clamp(p - 0.5, vec2(0.0), s - 1.0);                          \
    vec2 i0 = floor(f);                                                   \
    vec2 i1 = min(i0 + 1.0, s - 1.0);                                     \
    vec2 a = f - i0;                                                      \
    vec4 c00 = TEXEL(i0, s, flip);                                        \
    vec4 c10 = TEXEL(vec2(i1.x, i0.y), s, flip);                          \
    vec4 c01 = TEXEL(vec2(i0.x, i1.y), s, flip);                          \
    vec4 c11 = TEXEL(i1, s, flip);                                        \
    vec4 top = c00 + (c10 - c00) * a.x;                                   \
    vec4 bottom = c01 + (c11 - c01) * a.x;                                \
    return top + (bottom - top) * a.y;                                    \
  }

// Bilinear samples follow sampleBilinear() in pipeline.js: p in pixel units (centres at
// .5), clamped to the edge texels; texels are read exactly at their centres.
DEFINE_FETCH(texelIn, bilinearIn, uIn)
DEFINE_FETCH(texelBase, bilinearBase, uBase)
DEFINE_FETCH(texelClar, bilinearClar, uClar)
DEFINE_FETCH(texelVeil, bilinearVeil, uVeil)
DEFINE_FETCH(texelPop, bilinearPop, uPop)
DEFINE_FETCH(texelBl1, bilinearBl1, uBl1)
DEFINE_FETCH(texelBl2, bilinearBl2, uBl2)
DEFINE_FETCH(texelBl3, bilinearBl3, uBl3)
DEFINE_FETCH(texelNoise, bilinearNoise, uNoise)
DEFINE_FETCH(texelSharp, bilinearSharp, uSharp)
DEFINE_FETCH(texelMasks, bilinearMasks, uMasks)
DEFINE_FETCH(texelCurves, bilinearCurves, uCurves)
DEFINE_FETCH(texelGrain, bilinearGrain, uGrain)

vec3 decodeState(vec3 v) {
  return (v - uIo.w) / uIo.z;
}

vec3 encodeState(vec3 v) {
  return v * uIo.z + uIo.w;
}

float smoothstep01(float a, float b, float x) {
  float t = clamp((x - a) / (b - a), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// ---- Tone curve, evaluated like buildToneLut + applyLut (4096-entry LUT, linear) ----
float toneAt(float v0) {
  float v = v0;
  float b = uTone.x;
  float c = uTone.y;
  float wp = uTone.z;
  float bp = uTone.w;
  v = bp >= 0.0 ? max(0.0, (v - bp) / (1.0 - bp)) : v * (1.0 + bp) - bp;
  v = wp >= 0.0 ? v / (1.0 - wp) : v * (1.0 + wp);
  v = clamp(v, 0.0, 1.0);
  v = pow(max(v, 0.0), uTone2.x);
  if (c > 0.0) {
    v = v < 0.5 ? 0.5 * pow(2.0 * v, 1.0 + c) : 1.0 - 0.5 * pow(2.0 * (1.0 - v), 1.0 + c);
  } else if (c < 0.0) {
    v = 0.5 + (v - 0.5) * (1.0 + c * 0.6);
  }
  return clamp(v, 0.0, 1.0);
}

float applyTone(float v) {
  if (v <= 0.0) {
    return toneAt(0.0);
  }
  if (v >= 1.0) {
    return toneAt(1.0);
  }
  float f = v * 4096.0;
  float i = floor(f);
  float a = toneAt(i / 4096.0);
  float b = toneAt((i + 1.0) / 4096.0);
  return a + (b - a) * (f - i);
}

// ---- Curves LUT texture: 1025 × 4 (rows r, g, b, master), 16 bits per value in r/g ----
float curveValue(float i, float row) {
  vec4 t = texelCurves(vec2(i, row), vec2(1025.0, 4.0), uFlip.y);
  return (floor(t.r * 255.0 + 0.5) * 256.0 + floor(t.g * 255.0 + 0.5)) / 65535.0;
}

// lookup() in advanced.js: clamp, then linear between the two nearest entries
float curveLookup(float v, float row) {
  float f = clamp(v, 0.0, 1.0) * 1024.0;
  float i = floor(f);
  float a = curveValue(i, row);
  if (i >= 1024.0) {
    return a;
  }
  float b = curveValue(i + 1.0, row);
  return a + (b - a) * (f - i);
}

// ---- Colour helpers ----
float hueOf(vec3 c, float mx, float chroma) {
  float h;
  if (mx == c.r) {
    h = (c.g - c.b) / chroma;
  } else if (mx == c.g) {
    h = (c.b - c.r) / chroma + 2.0;
  } else {
    h = (c.r - c.g) / chroma + 4.0;
  }
  h *= 60.0;
  return h < 0.0 ? h + 360.0 : h;
}

float bandWeight(float hue, float centre, float halfWidth) {
  float d = abs(hue - centre);
  if (d > 180.0) {
    d = 360.0 - d;
  }
  return d >= halfWidth ? 0.0 : 0.5 + 0.5 * cos((PI * d) / halfWidth);
}

vec3 rgbToHsl(vec3 c) {
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  float l = (mx + mn) / 2.0;
  if (mx == mn) {
    return vec3(0.0, 0.0, l);
  }
  float d = mx - mn;
  float s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
  float h;
  if (mx == c.r) {
    h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
  } else if (mx == c.g) {
    h = (c.b - c.r) / d + 2.0;
  } else {
    h = (c.r - c.g) / d + 4.0;
  }
  return vec3(h * 60.0, s, l);
}

float hue2rgb(float p, float q, float t0) {
  float t = t0 - floor(t0);
  if (t < 1.0 / 6.0) {
    return p + (q - p) * 6.0 * t;
  }
  if (t < 0.5) {
    return q;
  }
  if (t < 2.0 / 3.0) {
    return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
  }
  return p;
}

vec3 hslToRgb(float h, float s, float l) {
  if (s == 0.0) {
    return vec3(l);
  }
  float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
  float p = 2.0 * l - q;
  float hh = h / 360.0;
  return vec3(hue2rgb(p, q, hh + 1.0 / 3.0), hue2rgb(p, q, hh), hue2rgb(p, q, hh - 1.0 / 3.0));
}

void addBand(vec4 band, float centre, float h, inout vec4 acc) {
  float d = abs(h - centre);
  if (d > 180.0) {
    d = 360.0 - d;
  }
  float w = d >= 45.0 ? 0.0 : 0.5 + 0.5 * cos((PI * d) / 45.0);
  if (w != 0.0) {
    acc += vec4(band.x * w, band.y * w, band.z * w, w);
  }
}

float faceGain(vec4 face, vec2 px, float current) {
  if (face.z <= 0.0) {
    return current;
  }
  float r = face.z;
  if (px.x < max(0.0, floor(face.x - r * 2.0)) || px.x >= min(uFull.x, ceil(face.x + r * 2.0)) ||
      px.y < max(0.0, floor(face.y - r * 2.0)) || px.y >= min(uFull.y, ceil(face.y + r * 2.0))) {
    return current;
  }
  float d2 = ((px.x - face.x) * (px.x - face.x) + (px.y - face.y) * (px.y - face.y)) / (r * r);
  return max(current, exp(-d2));
}

bool runs(float stage) {
  return stage >= uRange.x && stage < uRange.y;
}

// Bayer 4×4 ordered dither like toRGB8() in pipeline.js
float bayer(vec2 px) {
  float x = mod(px.x, 4.0);
  float y = mod(px.y, 4.0);
  float i = y * 4.0 + x;
  float v = 0.0;
  if (i < 0.5) { v = 0.0; } else if (i < 1.5) { v = 8.0; } else if (i < 2.5) { v = 2.0; } else if (i < 3.5) { v = 10.0; }
  else if (i < 4.5) { v = 12.0; } else if (i < 5.5) { v = 4.0; } else if (i < 6.5) { v = 14.0; } else if (i < 7.5) { v = 6.0; }
  else if (i < 8.5) { v = 3.0; } else if (i < 9.5) { v = 11.0; } else if (i < 10.5) { v = 1.0; } else if (i < 11.5) { v = 9.0; }
  else if (i < 12.5) { v = 15.0; } else if (i < 13.5) { v = 7.0; } else if (i < 14.5) { v = 13.0; } else { v = 5.0; }
  return (v + 0.5) / 16.0 - 0.5;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 local = floor(frag);                 // integer pixel of this pass
  vec2 px = local + uOrigin;                // integer pixel in the full output
  vec2 centre = px + 0.5;                   // its centre
  // Original-image position of this pixel (for the source and the masks)
  vec2 orig = vec2(dot(uAffX, vec3(centre, 1.0)), dot(uAffY, vec3(centre, 1.0)));

  // 0. Load
  vec3 c;
  if (uRange.w > 0.5) {
    vec2 sp = (orig - uSrcRect.xy) * uSrcRect.zw;
    c = bilinearIn(sp, uSizes.xy, uFlip.z).rgb;
  } else {
    c = decodeState(texelIn(local + uIo.xy, uSizes.xy, uFlip.x).rgb);
  }

  vec3 masks = vec3(0.0);
  if (uMaskOn.w > 0.5) {
    vec2 ms = uFieldSize3.zw;
    masks = bilinearMasks(vec2(orig.x / uSizes.z * ms.x, orig.y / uSizes.w * ms.y), ms, uFlip.y).rgb;
  }

  // 1. White balance
  if (runs(1.0) && uWb.w > 0.5) {
    c *= uWb.rgb;
  }
  // 2. Exposure
  if (runs(2.0) && uLocal.w != 1.0) {
    c *= uLocal.w;
  }
  // 3. Shadows, highlights, HDR against the smooth luminance base
  if (runs(3.0) && (uLocal.x != 0.0 || uLocal.y != 0.0 || uLocal.z != 0.0)) {
    float l = luma(c);
    if (l > 1e-5) {
      float base = max(luma(decodeState(bilinearBase(centre / uFieldK.x, uFieldSize0.xy, uFlip.x).rgb)), 1e-4);
      float target = l;
      float ws = 1.0 - smoothstep01(0.0, 0.55, base);
      float wh = smoothstep01(0.45, 1.0, base);
      float sh = uLocal.x;
      float hi = uLocal.y;
      float hdr = uLocal.z;
      if (sh != 0.0) {
        target += sh > 0.0 ? sh * ws * ws * (1.0 - target) * 0.9 : sh * ws * target * 0.9;
      }
      if (hi != 0.0) {
        target += hi > 0.0 ? hi * wh * (1.0 - target) * 0.7 : hi * wh * wh * target * 0.6;
      }
      if (hdr != 0.0) {
        float detail = l / base;
        float compressed = pow(base, 1.0 - 0.45 * hdr) * pow(0.45, 0.45 * hdr);
        target = target * (1.0 - hdr) + compressed * pow(detail, 1.0 + 0.25 * hdr) * hdr;
      }
      c *= target / l;
    }
  }
  // 4. Clarity
  if (runs(4.0) && uClarHaze.z > 0.5) {
    float l = luma(c);
    float b = luma(decodeState(bilinearClar(centre / uFieldK.y, uFieldSize0.zw, uFlip.x).rgb));
    float mid = 1.0 - abs(2.0 * l - 1.0);
    c += (l - b) * uClarHaze.x * 1.6 * mid;
  }
  // 5. Dehaze (dark-channel veil)
  if (runs(5.0) && uClarHaze.w > 0.5) {
    float veil = decodeState(bilinearVeil(centre / uFieldK.z, uFieldSize1.xy, uFlip.x).rgb).r;
    float k = uClarHaze.y;
    float t = max(0.15, 1.0 - k * veil);
    if (k >= 0.0) {
      c = (c - 0.95 * (1.0 - t)) / t;
    } else {
      c = c * (1.0 + k * 0.5) - k * 0.5 * 0.95 * veil;
    }
  }
  // 6. Tone curve
  if (runs(6.0) && uTone2.y > 0.5) {
    c = vec3(applyTone(c.r), applyTone(c.g), applyTone(c.b));
  }
  // 7. Pop
  if (runs(7.0) && uTone2.z != 0.0) {
    float l = luma(c);
    float b = luma(decodeState(bilinearPop(centre / uFieldK.w, uFieldSize1.zw, uFlip.x).rgb));
    float midtone = 1.0 - abs(2.0 * l - 1.0) * 0.7;
    c += (l - b) * uTone2.z * midtone;
  }
  // 8. Saturation, vibrance, skin and blue tones, mono, split tone
  if (runs(8.0) && uSplitH.w > 0.5) {
    float l = luma(c);
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float chroma = mx - mn;
    float sat = uColour.x;
    float factor = 1.0 + sat;
    float vib = uTone2.w;
    if (vib != 0.0) {
      factor += vib * (1.0 - min(1.0, chroma * 2.0));
    }
    if ((uColour.y != 0.0 || uColour.z != 0.0) && chroma > 0.02) {
      float hue = hueOf(c, mx, chroma);
      float satWeight = min(1.0, chroma * 4.0);
      if (uColour.y != 0.0) {
        factor += uColour.y * bandWeight(hue, 25.0, 22.0) * satWeight;
      }
      if (uColour.z != 0.0) {
        factor += uColour.z * bandWeight(hue, 212.0, 32.0) * satWeight;
      }
    }
    if (factor != 1.0) {
      float f = factor;
      if (f > 1.0 && chroma > 0.0) {
        if (mx > l) {
          f = min(f, (1.0 - l) / (mx - l));
        }
        if (mn < l) {
          f = min(f, l / (l - mn));
        }
        f = max(1.0, f);
      }
      c = l + (c - l) * f;
    }
    if (uColour.w != 0.0) {
      c += (l - c) * uColour.w;
    }
    if (uSplitS.w != 0.0) {
      float t = smoothstep01(0.1, 0.9, l);
      c += uSplitS.w * ((1.0 - t) * uSplitS.rgb + t * uSplitH.rgb);
    }
  }
  // 9. Levels and curves
  if (runs(9.0) && (uLevels2.y > 0.5 || uLevels2.z > 0.5 || uLevels2.w > 0.5)) {
    vec3 v = c;
    if (uLevels2.y > 0.5) {
      v = uLevels.w + (uLevels2.x - uLevels.w) * pow(clamp((v - uLevels.x) / uLevels.y, 0.0, 1.0), vec3(1.0 / uLevels.z));
    }
    if (uLevels2.z > 0.5) {
      v = vec3(curveLookup(v.r, 3.0), curveLookup(v.g, 3.0), curveLookup(v.b, 3.0));
    }
    if (uCurveOn.x > 0.5) {
      v.r = curveLookup(v.r, 0.0);
    }
    if (uCurveOn.y > 0.5) {
      v.g = curveLookup(v.g, 1.0);
    }
    if (uCurveOn.z > 0.5) {
      v.b = curveLookup(v.b, 2.0);
    }
    c = v;
  }
  // 10. HSL bands and colour grading
  if (runs(10.0)) {
    if (uHsl0.w > 0.5) {
      vec3 hsl = rgbToHsl(clamp(c, 0.0, 1.0));
      vec4 acc = vec4(0.0);
      addBand(uHsl0, 0.0, hsl.x, acc);
      addBand(uHsl1, 30.0, hsl.x, acc);
      addBand(uHsl2, 60.0, hsl.x, acc);
      addBand(uHsl3, 120.0, hsl.x, acc);
      addBand(uHsl4, 180.0, hsl.x, acc);
      addBand(uHsl5, 220.0, hsl.x, acc);
      addBand(uHsl6, 270.0, hsl.x, acc);
      addBand(uHsl7, 315.0, hsl.x, acc);
      if (acc.w != 0.0) {
        float chroma = min(1.0, hsl.y * 3.0);
        float h = mod(hsl.x + acc.x * 30.0 + 360.0, 360.0);
        float s = clamp(hsl.y * (1.0 + acc.y), 0.0, 1.0);
        float l = clamp(hsl.z + acc.z * 0.25 * chroma, 0.0, 1.0);
        c = hslToRgb(h, s, l);
      }
    }
    if (uGrade0.w > 0.5) {
      float lum = luma(c);
      float bal = uGrade1.w;
      float blend = uGrade2.w;
      float shadow = clamp((0.5 - bal - lum) / blend + 0.5, 0.0, 1.0);
      float highlight = clamp((lum - 0.5 - bal) / blend + 0.5, 0.0, 1.0);
      float mid = max(0.0, 1.0 - shadow - highlight);
      c += uGrade0.rgb * shadow;
      c += uGrade1.rgb * mid;
      c += uGrade2.rgb * highlight;
    }
  }
  // 11. Sky, colour focus, portrait light
  if (runs(11.0) && uMaskOn.w > 0.5) {
    if (uSky.x > 0.0 && uMaskOn.x > 0.5) {
      float y = px.y / uFull.y;
      float sky = masks.r;
      float m = sky * uSky.x;
      float sceneW = (1.0 - sky) * uSky.x * 0.5;
      if (uSky2.y > 0.5 && sceneW > 0.0) {
        c *= 1.0 + (uSkyScene.rgb - 1.0) * sceneW;
      }
      if (m > 0.002) {
        float l = luma(c);
        float gy = min(1.0, y * 1.6);
        vec3 target = uSkyTop.rgb + (uSkyBottom.rgb - uSkyTop.rgb) * gy;
        vec3 v = l + (c - l) * uSky.w;
        v = 0.5 + (v - 0.5) * (1.0 + uSky2.x);
        v *= uSky.z;
        v = v * (1.0 - uSky.y) + target * (l * 1.2 + 0.2) * uSky.y;
        c = c + (v - c) * m;
      }
    }
    if (uFocus.x > 0.0 && (uMaskOn.y > 0.5 || uMaskOn.z > 0.5)) {
      float keep = uMaskOn.y > 0.5 ? masks.g : clamp((masks.b - 0.55) * 4.0, 0.0, 1.0);
      float w = (1.0 - keep) * uFocus.x;
      if (w > 0.0) {
        float l = luma(c);
        c += (l - c) * w;
      }
    }
    if (uLight.x > 0.0 && uLight.y > 0.5) {
      float gain = 0.0;
      gain = faceGain(uFace0, px, gain);
      gain = faceGain(uFace1, px, gain);
      gain = faceGain(uFace2, px, gain);
      gain = faceGain(uFace3, px, gain);
      gain = faceGain(uFace4, px, gain);
      gain = faceGain(uFace5, px, gain);
      gain = faceGain(uFace6, px, gain);
      gain = faceGain(uFace7, px, gain);
      if (gain != 0.0) {
        float subject = uMaskOn.y > 0.5 ? 0.35 + 0.65 * masks.g : 1.0;
        float k = 1.0 + uLight.x * 0.55 * gain * subject;
        c = vec3(min(1.0, c.r * k * 1.01), min(1.0, c.g * k), min(1.0, c.b * k * 0.985));
      }
    }
  }
  // 12. Blur tool (depth-dependent blend of three blur levels)
  if (runs(12.0) && uFocus.y > 0.0 && uMaskOn.z > 0.5) {
    float amount = min(1.0, abs(masks.b - uFocus.z) * 3.0);
    if (uMaskOn.y > 0.5) {
      amount *= 1.0 - masks.g * 0.85;
    }
    float level = amount * 3.0;
    if (level > 0.02) {
      float i = min(2.0, floor(level));
      float frac = min(1.0, level - i);
      vec3 l1 = decodeState(bilinearBl1(centre / uFieldK2.x, uFieldSize2.xy, uFlip.x).rgb);
      vec3 l2 = decodeState(bilinearBl2(centre / uFieldK2.y, uFieldSize2.zw, uFlip.x).rgb);
      vec3 l3 = decodeState(bilinearBl3(centre / uFieldK2.z, uFieldSize3.xy, uFlip.x).rgb);
      vec3 a = i < 0.5 ? c : (i < 1.5 ? l1 : l2);
      vec3 b = i < 0.5 ? l1 : (i < 1.5 ? l2 : l3);
      c = a + (b - a) * frac;
    }
  }
  // 13. Vignette
  if (runs(13.0) && uFinish.x != 0.0) {
    vec2 cc = uFull / 2.0;
    float dy = (px.y + 0.5 - cc.y) / cc.y;
    float dx = (px.x + 0.5 - cc.x) / cc.x;
    float r = sqrt((dx * dx + dy * dy) / 2.0);
    c *= 1.0 - uFinish.x * smoothstep01(0.35, 1.05, r);
  }
  // 14. Noise reduction (edge-aware blend towards the blurred image)
  if (runs(14.0) && uFinish.y != 0.0) {
    vec3 blurred = decodeState(texelNoise(local + uIo.xy, uSizes.xy, uFlip.x).rgb);
    float l = luma(c);
    float lb = luma(blurred);
    float edge = min(1.0, abs(l - lb) * 12.0);
    float k = uFinish.y * (1.0 - edge) * 0.9;
    c += (blurred - c) * k;
  }
  // 15. Sharpen
  if (runs(15.0) && uFinish.z != 0.0) {
    float l = luma(c);
    float b = luma(decodeState(texelSharp(local + uIo.xy, uSizes.xy, uFlip.x).rgb));
    c += (l - b) * uFinish.z * 2.0;
  }
  // 16. Shaped vignette
  if (runs(16.0) && uShape.x != 0.0) {
    vec2 cc = uFull / 2.0;
    float aspect = uFull.x / uFull.y;
    float dx = (px.x + 0.5 - cc.x) / cc.x;
    float dy = (px.y + 0.5 - cc.y) / cc.y;
    dx *= 1.0 + (aspect - 1.0) * uShape.y * (aspect > 1.0 ? 1.0 : 0.0);
    dy *= 1.0 + (1.0 / aspect - 1.0) * uShape.y * (aspect < 1.0 ? 1.0 : 0.0);
    float r = length(vec2(dx, dy)) / 1.4142135623730951 * 1.2;
    float t = clamp((r - uShape.z + uShape.w / 2.0) / uShape.w, 0.0, 1.0);
    float w = t * t * (3.0 - 2.0 * t) * uShape.x;
    c = w > 0.0 ? c * (1.0 - w * 0.8) : c + (1.0 - c) * -w * 0.8;
  }
  // 17. Grain (hash precomputed per pixel on the CPU, 16 bits in r/g)
  if (runs(17.0) && uFinish.w != 0.0) {
    vec4 g = texelGrain(local, uSize, uFlip.y);
    float n = (floor(g.r * 255.0 + 0.5) * 256.0 + floor(g.g * 255.0 + 0.5)) / 65536.0;
    c += (n - 0.5) * uFinish.w * 0.12;
  }
  // 18. Clamp
  if (runs(18.0)) {
    c = clamp(c, 0.0, 1.0);
  }

  if (uRange.z > 1.5) {
    fragColor = vec4(c, 1.0);
  } else if (uRange.z > 0.5) {
    fragColor = vec4(clamp((c * 255.0 + bayer(px)) / 255.0, 0.0, 1.0), 1.0);
  } else {
    fragColor = vec4(encodeState(c), 1.0);
  }
}
