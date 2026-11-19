#version 460 core
#include <flutter/runtime_effect.glsl>
precision highp float;

// Box-downsamples a state image by an integer factor k before a large blur (fields only
// need to be smooth), optionally taking the dark channel min(r, g, b) per texel first.
uniform vec2 uInSize;
uniform vec4 uParams; // k, mode (0 = rgb, 1 = min of rgb), flip rows, -
uniform sampler2D uIn;

out vec4 fragColor;

void main() {
  vec2 cell = floor(FlutterFragCoord().xy);
  float k = uParams.x;
  vec3 sum = vec3(0.0);
  float n = 0.0;
  for (int j = 0; j < 32; j++) {
    if (float(j) >= k) {
      break;
    }
    for (int i = 0; i < 32; i++) {
      if (float(i) >= k) {
        break;
      }
      vec2 p = cell * k + vec2(float(i), float(j));
      if (p.x < uInSize.x && p.y < uInSize.y) {
        vec2 uv = (p + 0.5) / uInSize;
        if (uParams.z > 0.5) {
          uv.y = 1.0 - uv.y;
        }
        vec3 c = texture(uIn, uv).rgb;
        sum += uParams.y > 0.5 ? vec3(min(c.r, min(c.g, c.b))) : c;
        n += 1.0;
      }
    }
  }
  fragColor = vec4(sum / max(n, 1.0), 1.0);
}
