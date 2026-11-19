#version 460 core
#include <flutter/runtime_effect.glsl>
precision highp float;

// Samples one texel of uTex (at uPoint, in uv) and writes uValue + it: used at start-up
// to detect whether render targets keep values outside 0..1 and their row order.
uniform vec2 uPoint;
uniform vec4 uValue;
uniform sampler2D uTex;

out vec4 fragColor;

void main() {
  fragColor = texture(uTex, uPoint) + uValue;
}
