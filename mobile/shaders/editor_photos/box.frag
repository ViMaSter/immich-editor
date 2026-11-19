#version 460 core
#include <flutter/runtime_effect.glsl>
precision highp float;

// One box-blur pass of radius r along x or y with the edge texel repeated (boxH/boxV in
// pipeline.js); three H+V rounds approximate a Gaussian like blurChannel().
uniform vec2 uInSize;
uniform vec4 uParams; // direction x, direction y, radius, flip rows
uniform sampler2D uIn;

out vec4 fragColor;

void main() {
  vec2 p = floor(FlutterFragCoord().xy);
  vec2 dir = uParams.xy;
  float r = uParams.z;
  vec3 sum = vec3(0.0);
  for (int i = 0; i < 257; i++) {
    float o = float(i) - r;
    if (o > r) {
      break;
    }
    vec2 q = clamp(p + dir * o, vec2(0.0), uInSize - 1.0);
    vec2 uv = (q + 0.5) / uInSize;
    if (uParams.w > 0.5) {
      uv.y = 1.0 - uv.y;
    }
    sum += texture(uIn, uv).rgb;
  }
  fragColor = vec4(sum / (2.0 * r + 1.0), 1.0);
}
