// Constants
#define TAU 6.28318530717959

// Utility functions

// Uniforms available to all programs
layout(binding = 0) uniform globals {
  float time;
  vec4 mouse; // xy = position, zw = delta (coordinate space?)
};
